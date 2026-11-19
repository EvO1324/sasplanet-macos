import Foundation
import CoreGraphics
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Something the progress window can run.
protocol LongTask: AnyObject {
    var title: String { get }
    var cancelled: Bool { get }
    var outputs: [URL] { get }
    var note: String? { get }
    var onProgress: ((Double, String) -> Void)? { get set }
    func run() throws
    func cancel()
}

extension StitchTask: LongTask {
    var title: String { "Stitching: \(opts.output.lastPathComponent)" }
    var note: String? { missingTiles > 0 ? "\(missingTiles) tiles were not in the cache (left blank)." : nil }
}

// MARK: - Image encoding helpers

/// SAS.Planet's JPEG quality (libjpeg 1–100) converted to Apple ImageIO's compression factor.
/// ImageIO's scale is much gentler: 0.60 there equals roughly libjpeg quality 87. Matching on the
/// first luminance quantization value (measured from ImageIO) keeps "60%" meaning the same as on Windows.
enum JPEGQuality {
    // (libjpeg luminance Q[0] value, ImageIO factor that produces it)
    private static let points: [(Double, Double)] = [
        (1, 0.90), (2, 0.775), (3, 0.675), (4, 0.575), (6, 0.50), (7, 0.45), (9, 0.40),
        (12, 0.35), (15, 0.30), (19, 0.25), (23, 0.20), (26, 0.15), (28, 0.10),
    ]

    static func factor(_ quality: Int) -> Double {
        let q = Double(max(1, min(100, quality)))
        if q >= 100 { return 1.0 }
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        let q0 = max(1, (16 * scale + 50) / 100)
        if q0 <= points[0].0 { return points[0].1 }
        for i in 1..<points.count where q0 <= points[i].0 {
            let (a, fa) = points[i - 1], (b, fb) = points[i]
            return fa + (fb - fa) * (q0 - a) / (b - a)
        }
        return 0.05
    }
}

enum ImageEnc {
    static func encode(_ img: CGImage, jpeg: Bool, quality: Int = 85) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, jpeg ? [kCGImageDestinationLossyCompressionQuality: JPEGQuality.factor(quality)] as CFDictionary : nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func image(fromRGBA data: Data, width: Int, height: Int, alpha: Bool) -> CGImage? {
        guard let p = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue),
                       provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Minimal ZIP writer (stored entries) for KMZ

final class ZipWriter {
    private let fh: FileHandle
    private var central = Data()
    private var count = 0
    private var offset: UInt32 = 0

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        d.withUnsafeBytes { p in for b in p.bindMemory(to: UInt8.self) { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFFFFFF
    }

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url)
    }

    func add(_ name: String, _ data: Data) {
        let n = Array(name.utf8), crc = Self.crc32(data), size = UInt32(data.count)
        var h = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        u32(0x04034b50); u16(20); u16(0x0800); u16(0); u16(0); u16(0x21)
        u32(crc); u32(size); u32(size); u16(UInt16(n.count)); u16(0)
        h.append(contentsOf: n)
        fh.write(h); fh.write(data)
        var c = Data()
        func c16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { c.append(contentsOf: $0) } }
        func c32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { c.append(contentsOf: $0) } }
        c32(0x02014b50); c16(20); c16(20); c16(0x0800); c16(0); c16(0); c16(0x21)
        c32(crc); c32(size); c32(size); c16(UInt16(n.count)); c16(0); c16(0); c16(0); c16(0); c32(0); c32(offset)
        c.append(contentsOf: n)
        central.append(c)
        offset += UInt32(h.count) + size
        count += 1
    }

    func finish() {
        fh.write(central)
        var e = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { e.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { e.append(contentsOf: $0) } }
        u32(0x06054b50); u16(0); u16(0); u16(UInt16(count)); u16(UInt16(count)); u32(UInt32(central.count)); u32(offset); u16(0)
        fh.write(e)
        try? fh.close()
    }
}

// MARK: - KMZ (Stitch format, u_BitmapMapCombinerKMZ)

enum KMZWriter {
    /// Splits the image into `piece`-sized JPEGs placed as GroundOverlays.
    static func write(_ r: BandRenderer, to url: URL, piece: Int, quality: Int, report: (Double) -> Void) throws {
        let zip = try ZipWriter(url: url)
        let base = url.deletingPathExtension().lastPathComponent
        var kml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<kml xmlns=\"http://earth.google.com/kml/2.2\">\r\n<Folder>\r\n<name>\(base)</name>\r\n"
        let nx = (r.width + piece - 1) / piece, ny = (r.height + piece - 1) / piece
        var done = 0
        for i in 1...nx {
            for j in 1...ny {
                if r.isCancelled() { zip.finish(); return }
                let px = CGRect(x: r.rect.minX + CGFloat((i - 1) * piece), y: r.rect.minY + CGFloat((j - 1) * piece),
                                width: CGFloat(min(piece, r.width - (i - 1) * piece)), height: CGFloat(min(piece, r.height - (j - 1) * piece)))
                let sub = BandRenderer(map: r.map, layer: r.layer, z: r.z, rect: px, polygon: r.polygon, transparent: false, isCancelled: r.isCancelled)
                let rgba = sub.render(y: 0, h: sub.height)
                guard let img = ImageEnc.image(fromRGBA: rgba, width: sub.width, height: sub.height, alpha: false),
                      let jpg = ImageEnc.encode(img, jpeg: true, quality: quality) else { continue }
                let name = "\(base)\(i)_\(j).jpg"
                zip.add("files/" + name, jpg)
                let tl = Geo.lonLat(CGPoint(x: px.minX, y: px.minY), r.z), br = Geo.lonLat(CGPoint(x: px.maxX, y: px.maxY), r.z)
                kml += "<GroundOverlay>\r\n<name>\(name)</name>\r\n<drawOrder>75</drawOrder>\r\n"
                kml += "<Icon><href>files/\(name)</href><viewBoundScale>0.75</viewBoundScale></Icon>\r\n<LatLonBox>\r\n"
                kml += "<north>\(tl.lat)</north>\r\n<south>\(br.lat)</south>\r\n<east>\(br.lon)</east>\r\n<west>\(tl.lon)</west>\r\n"
                kml += "</LatLonBox>\r\n</GroundOverlay>\r\n"
                done += 1
                report(Double(done) / Double(nx * ny))
            }
        }
        kml += "</Folder>\r\n</kml>"
        zip.add("doc.kml", Data(kml.utf8))
        zip.finish()
    }
}

// MARK: - MBTiles export (u_StorageExportToMBTiles)

struct MBTilesOptions {
    var map: MapType
    var layer: MapType?
    var zooms: [Int]
    var output: URL
    var recreate = true
    var replaceExisting = true
    var usePrevZoom = false
    var xyzScheme = false
    var name = ""
    var description = ""
    var attribution = ""
    var jpegQuality = 85
}

final class MBTilesExportTask: LongTask {
    let opts: MBTilesOptions
    let region: Region
    private(set) var cancelled = false
    private(set) var outputs: [URL] = []
    private var written = 0, missing = 0
    var onProgress: ((Double, String) -> Void)?
    var title: String { "Export: \(opts.output.lastPathComponent)" }
    var note: String? {
        "\(written) tiles written" + (missing > 0 ? "; \(missing) were not in the cache and were skipped." : ".")
    }

    init(opts: MBTilesOptions, region: Region) { self.opts = opts; self.region = region }
    func cancel() { cancelled = true }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func run() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: opts.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if opts.recreate, fm.fileExists(atPath: opts.output.path) { try fm.removeItem(at: opts.output) }
        var db: OpaquePointer?
        guard sqlite3_open(opts.output.path, &db) == SQLITE_OK, let db = db else {
            throw NSError(domain: "SAS", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(opts.output.path)"])
        }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        exec("PRAGMA synchronous=OFF")
        exec("PRAGMA journal_mode=MEMORY")
        exec("CREATE TABLE IF NOT EXISTS metadata (name text, value text)")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS metadata_idx ON metadata (name)")
        exec("CREATE TABLE IF NOT EXISTS tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS tiles_idx on tiles (zoom_level, tile_column, tile_row)")

        let composite = opts.layer != nil || opts.usePrevZoom
        let format = opts.layer != nil ? "png" : opts.map.defaultExt == "png" ? "png" : "jpg"
        let b = region.bbox
        let zs = opts.zooms.sorted()
        let meta: [(String, String)] = [
            ("name", opts.name.isEmpty ? opts.map.name : opts.name),
            ("type", opts.map.isLayer ? "overlay" : "baselayer"),
            ("version", "1.3"),
            ("description", opts.description.isEmpty ? opts.map.name : opts.description),
            ("format", format),
            ("bounds", "\(b.w),\(b.s),\(b.e),\(b.n)"),
            ("attribution", opts.attribution),
            ("minzoom", "\(zs.first ?? 0)"),
            ("maxzoom", "\(zs.last ?? 0)"),
            ("center", "\((b.w + b.e) / 2),\((b.s + b.n) / 2),\(zs.first ?? 0)"),
            ("scheme", opts.xyzScheme ? "xyz" : "tms"),
        ]
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO metadata (name, value) VALUES (?,?)", -1, &stmt, nil)
        for (k, v) in meta {
            sqlite3_bind_text(stmt, 1, k, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, v, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt); sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)

        let insert = opts.replaceExisting ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        sqlite3_prepare_v2(db, "\(insert) INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?,?,?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }

        let total = max(1, zs.reduce(0) { $0 + region.tileCount($1) })
        var processed = 0
        exec("BEGIN")
        let it = RegionIterator(region: region, zooms: zs)
        while let t = it.next() {
            if cancelled { break }
            processed += 1
            var data: Data?
            if composite {
                data = compositeTile(t.x, t.y, t.z, png: format == "png")
            } else {
                data = TileStorage.shared.read(opts.map, t.x, t.y, t.z)
            }
            if let d = data {
                let row = opts.xyzScheme ? t.y : (1 << t.z) - 1 - t.y
                sqlite3_bind_int(stmt, 1, Int32(t.z))
                sqlite3_bind_int(stmt, 2, Int32(t.x))
                sqlite3_bind_int(stmt, 3, Int32(row))
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(d.count), Self.SQLITE_TRANSIENT) }
                sqlite3_step(stmt); sqlite3_reset(stmt)
                written += 1
            } else {
                missing += 1
            }
            if processed % 200 == 0 {
                exec("COMMIT"); exec("BEGIN")
                onProgress?(Double(processed) / Double(total), "z\(t.z + 1): \(processed) of \(total) tiles")
            }
        }
        exec("COMMIT")
        onProgress?(1, "\(processed) of \(total) tiles")
        if cancelled { try? fm.removeItem(at: opts.output) } else { outputs = [opts.output] }
    }

    /// Map tile (or scaled parent when missing) with the overlay drawn on top, re-encoded.
    private func compositeTile(_ x: Int, _ y: Int, _ z: Int, png: Bool) -> Data? {
        func load(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> CGImage? {
            TileStorage.shared.read(m, x, y, z).flatMap(TileProvider.decode)
        }
        var base = load(opts.map, x, y, z)
        var crop: CGRect?
        if base == nil && opts.usePrevZoom {
            for d in 1...min(z, 8) {
                if let p = load(opts.map, x >> d, y >> d, z - d) {
                    let sub = CGFloat(p.width) / CGFloat(1 << d)
                    crop = CGRect(x: CGFloat(x - ((x >> d) << d)) * sub, y: CGFloat(y - ((y >> d) << d)) * sub, width: sub, height: sub)
                    base = p
                    break
                }
            }
        }
        let over = opts.layer.flatMap { load($0, x, y, z) }
        guard base != nil || over != nil else { return nil }
        if opts.layer == nil, crop == nil, let b = base { return ImageEnc.encode(b, jpeg: !png, quality: opts.jpegQuality) }
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        if var b = base {
            if let c = crop, let cc = b.cropping(to: c) { b = cc }
            ctx.draw(b, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        if let o = over { ctx.draw(o, in: CGRect(x: 0, y: 0, width: 256, height: 256)) }
        guard let img = ctx.makeImage() else { return nil }
        return ImageEnc.encode(img, jpeg: !png, quality: opts.jpegQuality)
    }
}
