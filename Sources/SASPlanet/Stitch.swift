import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct StitchOptions {
    enum Format: String, CaseIterable {
        case jpeg = "JPEG", png = "PNG", geotiff = "GeoTIFF", kmz = "KMZ"
        var ext: String { [.jpeg: "jpg", .png: "png", .geotiff: "tif", .kmz: "kmz"][self]! }
    }
    var map: MapType
    var layer: MapType?
    var zoom: Int
    var format: Format = .jpeg
    var output: URL
    var georef: Set<String> = [".w"]   // georef types
    var preciseCrop = false
    var splitH = 1
    var splitV = 1
    var skipExisting = false
    var jpegQuality = 50
    var pngAlpha = true
    var kmzPiece = 1024
    var removeBlank = false
    var blankPercent = 100.0
    var zipResults = false
}

final class BandRenderer {
    let map: MapType
    let layer: MapType?
    let z: Int
    let rect: CGRect
    let polygon: [CGPoint]?
    let transparent: Bool
    let isCancelled: () -> Bool
    private(set) var missing = 0
    private var blankByRow: [Int: Int] = [:]
    var blankPixels: Int { blankByRow.values.reduce(0, +) }
    let width: Int, height: Int
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var bitmapInfo: UInt32 { transparent ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue }

    init(map: MapType, layer: MapType?, z: Int, rect: CGRect, polygon: [CGPoint]?, transparent: Bool, isCancelled: @escaping () -> Bool) {
        self.map = map; self.layer = layer; self.z = z; self.rect = rect
        self.polygon = polygon; self.transparent = transparent; self.isCancelled = isCancelled
        width = Int(rect.width); height = Int(rect.height)
    }

    var bands: [(y: Int, h: Int)] {
        var out: [(Int, Int)] = []
        var y = 0
        while y < height {
            let worldY = Int(rect.minY) + y
            let next = (worldY / 256 + 1) * 256 - Int(rect.minY)
            let h = min(height, next) - y
            out.append((y, h))
            y += h
        }
        return out
    }

    private func loadTiles(_ m: MapType, ty: Int, tx0: Int, tx1: Int) -> [CGImage?] {
        var imgs = [CGImage?](repeating: nil, count: tx1 - tx0 + 1)
        let lock = NSLock()
        var miss = 0
        DispatchQueue.concurrentPerform(iterations: imgs.count) { i in
            var img: CGImage?
            if let d = TileStorage.shared.read(m, tx0 + i, ty, z) { img = TileProvider.decode(d) }
            lock.lock()
            imgs[i] = img
            if img == nil { miss += 1 }
            lock.unlock()
        }
        if m == map { missing += miss }
        return imgs
    }

    func render(y: Int, h: Int) -> Data {
        let bpr = width * 4
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: space, bitmapInfo: bitmapInfo) else { return Data(count: bpr * h) }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -(rect.minY + CGFloat(y)))
        let band = CGRect(x: rect.minX, y: rect.minY + CGFloat(y), width: rect.width, height: CGFloat(h))
        if !transparent {
            // sas grey
            ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(192) / 255, CGFloat(192) / 255, CGFloat(192) / 255, 1])!)
            ctx.fill(band)
        }
        if let poly = polygon {
            ctx.addLines(between: poly)
            ctx.closePath()
            ctx.clip()
        }
        ctx.interpolationQuality = .none
        let tx0 = Int(rect.minX) / 256, tx1 = (Int(rect.maxX) - 1) / 256
        for ty in (Int(band.minY) / 256)...((Int(band.maxY) - 1) / 256) {
            for m in [map] + (layer.map { [$0] } ?? []) {
                if isCancelled() { break }
                let imgs = loadTiles(m, ty: ty, tx0: tx0, tx1: tx1)
                for (i, img) in imgs.enumerated() {
                    guard let img = img else { continue }
                    TileRenderer.drawImage(ctx, img, CGRect(x: CGFloat(tx0 + i) * 256, y: CGFloat(ty) * 256, width: 256, height: 256))
                }
            }
        }
        guard let p = ctx.data else { return Data(count: bpr * h) }
        let px = p.bindMemory(to: UInt8.self, capacity: bpr * h)
        var blank = 0
        var i = 0
        let n = bpr * h
        if transparent {
            while i < n { if px[i + 3] == 0 { blank += 1 }; i += 4 }
        } else {
            while i < n { if px[i] == 192 && px[i + 1] == 192 && px[i + 2] == 192 { blank += 1 }; i += 4 }
        }
        blankByRow[y] = blank
        return Data(bytes: p, count: n)
    }
}

private final class BandStream {
    let r: BandRenderer
    let bands: [(y: Int, h: Int)]
    var bandIndex = 0
    var buf = Data()
    var pos = 0
    var onBand: ((Int) -> Void)?

    init(_ r: BandRenderer) { self.r = r; bands = r.bands }

    func getBytes(_ out: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var written = 0
        while written < count {
            if pos >= buf.count {
                guard bandIndex < bands.count, !r.isCancelled() else { break }
                let b = bands[bandIndex]
                buf = r.render(y: b.y, h: b.h)
                pos = 0
                bandIndex += 1
                onBand?(bandIndex)
            }
            let n = min(count - written, buf.count - pos)
            buf.withUnsafeBytes { src in (out + written).copyMemory(from: src.baseAddress! + pos, byteCount: n) }
            pos += n
            written += n
        }
        return written
    }

    func skip(_ count: Int) -> Int {
        var left = count
        while left > 0 {
            if pos >= buf.count {
                guard bandIndex < bands.count else { break }
                let b = bands[bandIndex]
                buf = r.render(y: b.y, h: b.h)
                pos = 0
                bandIndex += 1
            }
            let n = min(left, buf.count - pos)
            pos += n
            left -= n
        }
        return count - left
    }

    func rewind() { bandIndex = 0; buf = Data(); pos = 0 }

    func provider() -> CGDataProvider? {
        var cb = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                Unmanaged<BandStream>.fromOpaque(info!).takeUnretainedValue().getBytes(buffer, count)
            },
            skipForward: { info, count in
                off_t(Unmanaged<BandStream>.fromOpaque(info!).takeUnretainedValue().skip(Int(count)))
            },
            rewind: { info in Unmanaged<BandStream>.fromOpaque(info!).takeUnretainedValue().rewind() },
            releaseInfo: { info in Unmanaged<BandStream>.fromOpaque(info!).release() })
        return CGDataProvider(sequentialInfo: Unmanaged.passRetained(self).toOpaque(), callbacks: &cb)
    }
}

final class StitchTask {
    let opts: StitchOptions
    let region: Region
    private(set) var cancelled = false
    var onProgress: ((Double, String) -> Void)?
    private(set) var outputs: [URL] = []
    private(set) var missingTiles = 0
    private(set) var removedBlank = 0
    var kmzPieceCount: Int {
        let f = fullRect
        return Int(ceil(f.width / CGFloat(opts.kmzPiece)) * ceil(f.height / CGFloat(opts.kmzPiece)))
    }

    init(opts: StitchOptions, region: Region) { self.opts = opts; self.region = region }

    func cancel() { cancelled = true }

    var fullRect: CGRect {
        let r = region.pixelBounds(opts.zoom)
        return CGRect(x: floor(r.minX), y: floor(r.minY), width: ceil(r.maxX) - floor(r.minX), height: ceil(r.maxY) - floor(r.minY))
    }

    var parts: [(rect: CGRect, url: URL)] {
        let f = fullRect
        let base = opts.output.deletingPathExtension()
        let ext = opts.output.pathExtension.isEmpty ? opts.format.ext : opts.output.pathExtension
        var out: [(CGRect, URL)] = []
        let cols = max(1, opts.splitH), rows = max(1, opts.splitV)
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = f.minX + floor(f.width * CGFloat(c) / CGFloat(cols)), x1 = f.minX + floor(f.width * CGFloat(c + 1) / CGFloat(cols))
                let y0 = f.minY + floor(f.height * CGFloat(r) / CGFloat(rows)), y1 = f.minY + floor(f.height * CGFloat(r + 1) / CGFloat(rows))
                let url = cols * rows == 1 ? base.appendingPathExtension(ext)
                    : URL(fileURLWithPath: base.path + "_\(r + 1)-\(c + 1)").appendingPathExtension(ext)
                out.append((CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), url))
            }
        }
        return out
    }

    func validate() -> String? {
        for p in parts {
            if p.rect.width < 1 || p.rect.height < 1 { return "The selection is empty at this zoom." }
            if opts.format == .jpeg && (p.rect.width > 65500 || p.rect.height > 65500) {
                return "JPEG images are limited to 65,500 pixels per side (this one is \(Int(p.rect.width))×\(Int(p.rect.height))). Use Split image, a lower zoom, or GeoTIFF."
            }
        }
        return nil
    }

    static func cacheCoverage(map: MapType, region: Region, zoom: Int) -> (cached: Int, total: Int) {
        let t = region.tileBounds(zoom)
        var cached = 0, total = 0
        let pts = region.polygon.map { Geo.pixel($0, zoom) }
        for r in region.rows(zoom) {
            for x in r.x0...r.x1 where region.tileIntersects(x, r.y, zoom, pts: pts) {
                total += 1
                if case .tile = TileStorage.shared.state(map, x, r.y, zoom) { cached += 1 }
            }
        }
        _ = t
        return (cached, total)
    }

    private func hasAnyTile(_ rect: CGRect) -> Bool {
        let z = opts.zoom
        let x0 = Int(rect.minX) / 256, x1 = (Int(rect.maxX) - 1) / 256
        let y0 = Int(rect.minY) / 256, y1 = (Int(rect.maxY) - 1) / 256
        for m in [opts.map] + (opts.layer.map { [$0] } ?? []) {
            for y in y0...y1 { for x in x0...x1 { if case .tile = TileStorage.shared.state(m, x, y, z) { return true } } }
        }
        return false
    }

    private func sidecars(of image: URL) -> [URL] {
        let dir = image.deletingLastPathComponent(), stem = image.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0 != image.lastPathComponent && ($0.hasPrefix(stem + ".")) }
            .filter { n in [".kml", ".map", ".tab", ".dat", ".prj", "w", ".aux.xml"].contains { n.hasSuffix($0) } }
            .map { dir.appendingPathComponent($0) }
    }

    func run() throws {
        let cov = Self.cacheCoverage(map: opts.map, region: region, zoom: opts.zoom)
        missingTiles = cov.total - cov.cached
        let ps = parts
        let poly = opts.preciseCrop && !region.isRectangle ? region.polygon.map { Geo.pixel($0, opts.zoom) } : nil
        let totalBands = ps.reduce(0) { acc, p in
            acc + BandRenderer(map: opts.map, layer: nil, z: opts.zoom, rect: p.rect, polygon: nil, transparent: false, isCancelled: { false }).bands.count
        }
        var doneBands = 0
        for (i, p) in ps.enumerated() {
            if cancelled { break }
            if opts.skipExisting && FileManager.default.fileExists(atPath: p.url.path) { continue }
            if opts.removeBlank && opts.format != .kmz && !hasAnyTile(p.rect) {
                // skip blank
                removedBlank += 1
                doneBands += BandRenderer(map: opts.map, layer: nil, z: opts.zoom, rect: p.rect, polygon: nil, transparent: false, isCancelled: { false }).bands.count
                continue
            }
            try FileManager.default.createDirectory(at: p.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let transparent = opts.format == .png && opts.pngAlpha
            let r = BandRenderer(map: opts.map, layer: opts.layer, z: opts.zoom, rect: p.rect, polygon: poly,
                                 transparent: transparent, isCancelled: { [weak self] in self?.cancelled ?? true })
            let label = ps.count > 1 ? "Part \(i + 1) of \(ps.count): " : ""
            let report: (Int) -> Void = { [weak self] b in
                self?.onProgress?(Double(doneBands + b) / Double(max(1, totalBands)), "\(label)\(Int(p.rect.width))×\(Int(p.rect.height)) px")
            }
            switch opts.format {
            case .jpeg, .png: try writeImageIO(r, to: p.url, report: report)
            case .geotiff: try GeoTIFFWriter.write(r, to: p.url, report: report)
            case .kmz:
                let nb = r.bands.count
                removedBlank += try KMZWriter.write(r, to: p.url, piece: opts.kmzPiece, quality: opts.jpegQuality,
                                                    removeBlankAt: opts.removeBlank ? opts.blankPercent : nil) { f in report(Int(f * Double(nb))) }
            }
            if cancelled { try? FileManager.default.removeItem(at: p.url); break }
            doneBands += r.bands.count
            if opts.removeBlank && opts.format != .kmz {
                let pct = Double(r.blankPixels) / Double(max(1, r.width * r.height)) * 100
                if pct >= opts.blankPercent {
                    try? FileManager.default.removeItem(at: p.url)
                    removedBlank += 1
                    continue
                }
            }
            if opts.format != .kmz { Georef.write(opts.georef, image: p.url, rect: p.rect, zoom: opts.zoom) }
            outputs.append(p.url)
        }
        if opts.zipResults && !cancelled && !outputs.isEmpty {
            onProgress?(1, "Packing ZIP…")
            let zipURL = opts.output.deletingPathExtension().appendingPathExtension("zip")
            let zip = try ZipWriter(url: zipURL)
            for img in outputs {
                for f in [img] + sidecars(of: img) {
                    if let d = try? Data(contentsOf: f) { zip.add(f.lastPathComponent, d) }
                }
            }
            zip.finish()
            outputs.append(zipURL)
        }
    }

    private func writeImageIO(_ r: BandRenderer, to url: URL, report: @escaping (Int) -> Void) throws {
        let stream = BandStream(r)
        stream.onBand = report
        guard let provider = stream.provider(),
              let img = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: r.bitmapInfo),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NSError(domain: "SAS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create the image (\(r.width)×\(r.height) px)."])
        }
        let type = (opts.format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw NSError(domain: "SAS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
        }
        var props: [CFString: Any] = [:]
        if opts.format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = JPEGQuality.factor(opts.jpegQuality) }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) && !cancelled {
            throw NSError(domain: "SAS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Writing the image failed (\(r.width)×\(r.height) px). Try Split image or GeoTIFF."])
        }
    }
}

// MARK: - GeoTIFF

enum GeoTIFFWriter {
    static func write(_ r: BandRenderer, to url: URL, report: (Int) -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "SAS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
        }
        defer { try? fh.close() }
        let W = r.width, H = r.height
        let dataSize = UInt64(W) * UInt64(H) * 3
        let big = dataSize > 4_000_000_000
        var out = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }

        // tiff header
        if big { out.append(contentsOf: [0x49, 0x49]); u16(43); u16(8); u16(0); u64(0) }
        else { out.append(contentsOf: [0x49, 0x49]); u16(42); u32(0) }
        fh.write(out)
        var offset = UInt64(out.count)

        var stripOffsets: [UInt64] = [], stripCounts: [UInt64] = []
        let bands = stride(from: 0, to: H, by: 256).map { (y: $0, h: min(256, H - $0)) }
        for (i, b) in bands.enumerated() {
            if r.isCancelled() { return }
            let rgba = r.render(y: b.y, h: b.h)
            var rgb = Data(count: W * b.h * 3)
            rgb.withUnsafeMutableBytes { dst in
                rgba.withUnsafeBytes { src in
                    let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                    var j = 0, k = 0
                    for _ in 0..<(W * b.h) { d[k] = s[j]; d[k + 1] = s[j + 1]; d[k + 2] = s[j + 2]; j += 4; k += 3 }
                }
            }
            fh.write(rgb)
            stripOffsets.append(offset)
            stripCounts.append(UInt64(rgb.count))
            offset += UInt64(rgb.count)
            report(i + 1)
        }
        // align
        if offset % 2 == 1 { fh.write(Data([0])); offset += 1 }

        let res = 2 * Double.pi * Geo.R / Geo.worldSize(r.z)
        let tieX = Double(r.rect.minX) * res - Double.pi * Geo.R
        let tieY = Double.pi * Geo.R - Double(r.rect.minY) * res
        let geoKeys: [UInt16] = [1, 1, 0, 3, 1024, 0, 1, 1, 1025, 0, 1, 1, 3072, 0, 1, 3857]
        let software = Array("SAS.Planet for macOS\0".utf8)

        enum V { case short([UInt16]), long([UInt64]), ascii([UInt8]), double([Double]) }
        var tags: [(UInt16, V)] = [
            (256, .long([UInt64(W)])), (257, .long([UInt64(H)])), (258, .short([8, 8, 8])), (259, .short([1])),
            (262, .short([2])), (273, .long(stripOffsets)), (277, .short([3])), (278, .long([256])),
            (279, .long(stripCounts)), (284, .short([1])), (305, .ascii(software)),
            (33550, .double([res, res, 0])), (33922, .double([0, 0, 0, tieX, tieY, 0])), (34735, .short(geoKeys)),
        ]
        tags.sort { $0.0 < $1.0 }

        let entrySize = big ? 20 : 12
        let ifdSize = (big ? 8 : 2) + tags.count * entrySize + (big ? 8 : 4)
        var extra = Data()
        let extraBase = offset + UInt64(ifdSize)
        out = Data()
        if big { u64(UInt64(tags.count)) } else { u16(UInt16(tags.count)) }
        let inlineMax = big ? 8 : 4
        for (tag, v) in tags {
            var payload = Data(), type: UInt16 = 0, count = 0
            func p16(_ x: UInt16) { var y = x.littleEndian; withUnsafeBytes(of: &y) { payload.append(contentsOf: $0) } }
            func p32(_ x: UInt32) { var y = x.littleEndian; withUnsafeBytes(of: &y) { payload.append(contentsOf: $0) } }
            func p64(_ x: UInt64) { var y = x.littleEndian; withUnsafeBytes(of: &y) { payload.append(contentsOf: $0) } }
            switch v {
            case .short(let a): type = 3; count = a.count; a.forEach(p16)
            case .long(let a):
                if big { type = 16; a.forEach(p64) } else { type = 4; a.forEach { p32(UInt32($0)) } }
                count = a.count
            case .ascii(let a): type = 2; count = a.count; payload.append(contentsOf: a)
            case .double(let a): type = 12; count = a.count; a.forEach { p64($0.bitPattern) }
            }
            u16(tag); u16(type)
            if big { u64(UInt64(count)) } else { u32(UInt32(count)) }
            if payload.count <= inlineMax {
                payload.append(Data(count: inlineMax - payload.count))
                out.append(payload)
            } else {
                let at = extraBase + UInt64(extra.count)
                if big { u64(at) } else { u32(UInt32(at)) }
                extra.append(payload)
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }
        if big { u64(0) } else { u32(0) }
        fh.write(out)
        fh.write(extra)
        // patch offset
        try fh.seek(toOffset: big ? 8 : 4)
        var hdr = Data()
        if big { var x = offset.littleEndian; withUnsafeBytes(of: &x) { hdr.append(contentsOf: $0) } }
        else { var x = UInt32(offset).littleEndian; withUnsafeBytes(of: &x) { hdr.append(contentsOf: $0) } }
        fh.write(hdr)
    }
}

// MARK: - georef files

enum Georef {
    static let crlf = "\r\n"

    static func write(_ kinds: Set<String>, image: URL, rect: CGRect, zoom z: Int) {
        let tl = Geo.lonLat(CGPoint(x: rect.minX, y: rect.minY), z)
        let br = Geo.lonLat(CGPoint(x: rect.maxX, y: rect.maxY), z)
        let c = Geo.lonLat(CGPoint(x: rect.maxX - floor(rect.width / 2), y: rect.maxY - floor(rect.height / 2)), z)
        let W = Int(rect.width), H = Int(rect.height)
        let name = image.lastPathComponent
        func save(_ s: String, _ url: URL) { try? s.data(using: .utf8)?.write(to: url) }

        if kinds.contains(".w") {
            let res = 2 * Double.pi * Geo.R / Geo.worldSize(z)
            let m1x = Double(rect.minX) * res - Double.pi * Geo.R
            let m1y = Double.pi * Geo.R - Double(rect.minY) * res
            let cellX = res, cellY = -res
            let ox = m1x + abs(cellX / 2), oy = m1y - abs(cellY / 2)
            let t = [cellX, 0, 0, cellY, ox, oy].map { r16($0) }.joined(separator: crlf) + crlf
            save(t, image.deletingPathExtension().appendingPathExtension(image.pathExtension + "w"))
            save(prj, image.deletingPathExtension().appendingPathExtension("prj"))
            save("<PAMDataset>" + crlf + "<SRS>" + prj + "</SRS>" + crlf + "<Metadata>" + crlf +
                 "<MDI key=\"PyramidResamplingType\">NEAREST</MDI>" + crlf + "</Metadata>" + crlf + "</PAMDataset>",
                 URL(fileURLWithPath: image.path + ".aux.xml"))
        }
        if kinds.contains(".map") {
            func deg(_ v: Double) -> String { String(Int(abs(v))) }
            func mins(_ v: Double) -> String { String(format: "%.4f", (abs(v) - floor(abs(v))) * 60) }
            func pt(_ id: Int, _ x: Int, _ y: Int, _ lon: Double, _ lat: Double) -> String {
                let lo = deg(lon) + ", " + mins(lon) + (lon < 0 ? ",W" : ",E")
                let la = deg(lat) + ", " + mins(lat) + (lat < 0 ? ",S" : ",N")
                return String(format: "Point%02d,xy,    %d, %d,in, deg, %@, %@, grid,   ,           ,           ,N", id, x, y, la, lo) + crlf
            }
            var t = "OziExplorer Map Data File Version 2.2" + crlf + name + crlf + name + crlf +
                "1 ,Map Code," + crlf + "WGS 84,,   0.0000,   0.0000,WGS 84" + crlf + "Reserved 1" + crlf + "Reserved 2" + crlf +
                "Magnetic Variation,,,E" + crlf + "Map Projection,Mercator,PolyCal,No,AutoCalOnly,No,BSBUseWPX,No" + crlf
            t += pt(1, 0, 0, tl.lon, tl.lat) + pt(2, W / 2, 0, c.lon, tl.lat) + pt(3, W, 0, br.lon, tl.lat)
            t += pt(4, 0, H / 2, tl.lon, c.lat) + pt(5, W / 2, H / 2, c.lon, c.lat) + pt(6, W, H / 2, br.lon, c.lat)
            t += pt(7, 0, H, tl.lon, br.lat) + pt(8, W / 2, H, c.lon, br.lat) + pt(9, W, H, br.lon, br.lat)
            for i in 10...30 {
                t += String(format: "Point%02d,xy,     ,     ,in, deg,    ,        ,N,    ,        ,W, grid,   ,           ,           ,N", i) + crlf
            }
            let f6 = { (v: Double) in String(format: "%.6f", v) }
            t += "Projection Setup,,,,,,,,,," + crlf +
                "Map Feature = MF ; Map Comment = MC     These follow if they exist" + crlf +
                "Track File = TF      These follow if they exist" + crlf +
                "Moving Map Parameters = MM?    These follow if they exist" + crlf +
                "MM0,Yes" + crlf + "MMPNUM,4" + crlf +
                "MMPXY,1,0,0" + crlf + "MMPXY,2,\(W),0" + crlf + "MMPXY,3,\(W),\(H)" + crlf + "MMPXY,4,0,\(H)" + crlf +
                "MMPLL,1, \(f6(tl.lon)), \(f6(tl.lat))" + crlf + "MMPLL,2, \(f6(br.lon)), \(f6(tl.lat))" + crlf +
                "MMPLL,3, \(f6(br.lon)), \(f6(br.lat))" + crlf + "MMPLL,4, \(f6(tl.lon)), \(f6(br.lat))" + crlf +
                "MM1B,\(f6(Geo.metersPerPixel(lat: c.lat, z: z)))" + crlf +
                "MOP,Map Open Position,0,0" + crlf + "IWH,Map Image Width/Height,\(W),\(H)" + crlf
            save(t, image.deletingPathExtension().appendingPathExtension("map"))
        }
        if kinds.contains(".tab") {
            func pt(_ n: Int, _ lon: Double, _ lat: Double, _ x: Int, _ y: Int) -> String {
                String(format: "  (%.8f, %.8f) (%d, %d) Label \"Point %d\"", lon, lat, x, y, n)
            }
            let t = "!table" + crlf + "!version 300" + crlf + "!charset Neutral" + crlf + crlf + "Definition Table" + crlf +
                "  File \"\(name)\"" + crlf + "  Type \"RASTER\"" + crlf +
                pt(1, tl.lon, tl.lat, 0, 0) + "," + crlf + pt(2, br.lon, br.lat, W, H) + "," + crlf +
                pt(3, tl.lon, br.lat, 0, H) + "," + crlf + pt(4, br.lon, tl.lat, W, 0) + "," + crlf +
                pt(5, c.lon, c.lat, W / 2, H / 2) + "," + crlf + pt(6, c.lon, tl.lat, W / 2, 0) + "," + crlf +
                pt(7, tl.lon, c.lat, 0, H / 2) + "," + crlf + pt(8, br.lon, c.lat, W, H / 2) + "," + crlf +
                pt(9, c.lon, br.lat, W / 2, H) + crlf +
                " CoordSys Earth Projection 10, 157, 7, 0" + crlf + " Units \"degree\"" + crlf
            save(t, image.deletingPathExtension().appendingPathExtension("tab"))
        }
        if kinds.contains(".dat") {
            let t = "2" + crlf + "\(tl.lon),\(tl.lat)" + crlf + "\(br.lon),\(tl.lat)" + crlf + "\(br.lon),\(br.lat)" + crlf +
                "\(tl.lon),\(br.lat)" + crlf + "(SASPlanet)" + crlf
            save(t, image.deletingPathExtension().appendingPathExtension("dat"))
        }
        if kinds.contains(".kml") {
            let t = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + crlf +
                "<kml><GroundOverlay><name>\(name)</name><color>88ffffff</color><Icon>" + crlf +
                "<href>\(name)</href>" + crlf + "<viewBoundScale>0.75</viewBoundScale></Icon><LatLonBox>" + crlf +
                "<north>\(tl.lat)</north>" + crlf + "<south>\(br.lat)</south>" + crlf +
                "<east>\(br.lon)</east>" + crlf + "<west>\(tl.lon)</west>" + crlf + "</LatLonBox></GroundOverlay></kml>"
            save(t, image.deletingPathExtension().appendingPathExtension("kml"))
        }
    }

    static func r16(_ v: Double) -> String {
        var s = String(format: "%.16f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static let prj = [
        "PROJCS[\"WGS 84 / Pseudo-Mercator\",", "GEOGCS[\"WGS 84\",", "DATUM[\"WGS_1984\",",
        "SPHEROID[\"WGS 84\",6378137,298.257223563,", "AUTHORITY[\"EPSG\",\"7030\"]],", "AUTHORITY[\"EPSG\",\"6326\"]],",
        "PRIMEM[\"Greenwich\",0,", "AUTHORITY[\"EPSG\",\"8901\"]],", "UNIT[\"degree\",0.0174532925199433,",
        "AUTHORITY[\"EPSG\",\"9122\"]],", "AUTHORITY[\"EPSG\",\"4326\"]],", "PROJECTION[\"Mercator_1SP\"],",
        "PARAMETER[\"central_meridian\",0],", "PARAMETER[\"scale_factor\",1],", "PARAMETER[\"false_easting\",0],",
        "PARAMETER[\"false_northing\",0],", "UNIT[\"metre\",1,", "AUTHORITY[\"EPSG\",\"9001\"]],",
        "AXIS[\"Easting\",EAST],", "AXIS[\"Northing\",NORTH],",
        "EXTENSION[\"PROJ4\",\"+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 +y_0=0 +k=1 +units=m +nadgrids=@null +wktext +no_defs\"],",
        "AUTHORITY[\"EPSG\",\"3857\"]]",
    ].joined(separator: "\r\n")
}
