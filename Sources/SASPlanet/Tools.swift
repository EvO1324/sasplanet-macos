import Foundation
import CoreGraphics
import SQLite3

// MARK: - Folder cache formats (u_TileFileName*.pas)

enum CacheFormat: String, CaseIterable {
    case sas = "SAS.Planet"
    case gmv = "GoogleMV (SAS.Planet old)"
    case es = "EarthSlicer 1.95"
    case gmTiles = "GlobalMapper Tiles"
    case gmAux = "GlobalMapper Aux"
    case gmBing = "GlobalMapper Bing"
    case mobac = "Mobile Atlas Creator (MOBAC)"
    case osmand = "OsmAnd+"
    case tms = "TileMapService (TMS)"

    /// Relative path without extension, plus the extension rule.
    func path(_ x: Int, _ y: Int, _ z: Int, ext: String) -> String {
        func z2(_ z: Int) -> String { z >= 9 ? String(z + 1) : "0" + String(z + 1) }
        switch self {
        case .sas: return "z\(z + 1)/\(x >> 10)/x\(x)/\(y >> 10)/y\(y).\(ext)"
        case .gmv:
            var s = "t"
            if z > 0 {
                var mask = 1 << (z - 1)
                for _ in 1...z {
                    s.append(x & mask == 0 ? (y & mask == 0 ? "q" : "t") : (y & mask == 0 ? "r" : "s"))
                    mask >>= 1
                }
            }
            return "\(z2(z))/\(s).\(ext)"
        case .es:
            func full(_ i: Int, _ z: Int) -> String {
                let w = z < 4 ? 0 : z < 7 ? 2 : z < 10 ? 3 : z < 14 ? 4 : z < 17 ? 5 : z < 20 ? 6 : 7
                let s = String(i)
                return w == 0 ? s : String((String(repeating: "0", count: w) + s).suffix(w))
            }
            let zs = z2(z)
            let file = "\(zs)-\(full(x, z))-\(full(y, z))"
            var dir: String
            if z < 6 { dir = zs + "/" }
            else if z < 10 {
                dir = zs + "/" + String(UnicodeScalar(UInt8(60 + z))) + full(x >> 5, z - 5) + full(y >> 5, z - 5) + "/"
            } else {
                dir = "10-" + full(x >> (z - 9), 9) + "-" + full(y >> (z - 9), 9) + "/" + zs + "/" +
                    String(UnicodeScalar(UInt8(60 + z))) + full(x >> 5, z - 5) + full(y >> 5, z - 5) + "/"
            }
            return dir + file + "." + ext
        case .gmTiles: return "z\(z)/\(y)/\(x).\(ext)"
        case .gmAux: return "z\(z)/\(y)_\(x).\(ext)"
        case .gmBing: return "\(z)/\(y)/\(x).\(ext)"
        case .mobac: return "\(z)/\(x)/\(y).\(ext)"
        case .osmand: return "\(z)/\(x)/\(y).\(ext).tile"
        case .tms: return "\(z)/\(x)/\((1 << z) - 1 - y).\(ext)"
        }
    }
}

// MARK: - Tile sinks

protocol TileSink: AnyObject {
    /// Returns false when the tile was skipped (exists and replace is off).
    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool
    func finish() throws
}

final class FolderSink: TileSink {
    let root: URL, format: CacheFormat, replace: Bool
    init(root: URL, format: CacheFormat, replace: Bool) { self.root = root; self.format = format; self.replace = replace }
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        ["jpg", "png", "jpeg", "gif", "webp"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent(format.path(x, y, z, ext: $0)).path) }
    }
    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool {
        let u = root.appendingPathComponent(format.path(x, y, z, ext: ext))
        if !replace && FileManager.default.fileExists(atPath: u.path) { return false }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
        return true
    }
    func finish() throws {}
}

final class ZipSink: TileSink {
    let zip: ZipWriter, format: CacheFormat, prefix: String
    init(url: URL, format: CacheFormat, prefix: String) throws { zip = try ZipWriter(url: url); self.format = format; self.prefix = prefix }
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool { false }
    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool {
        zip.add(prefix + format.path(x, y, z, ext: ext), data); return true
    }
    func finish() throws { zip.finish() }
}

/// POSIX ustar archive writer.
final class TarSink: TileSink {
    let fh: FileHandle, format: CacheFormat, prefix: String
    init(url: URL, format: CacheFormat, prefix: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url); self.format = format; self.prefix = prefix
    }
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool { false }
    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool {
        var name = prefix + format.path(x, y, z, ext: ext)
        var pre = ""
        if name.utf8.count > 100, let cut = name.lastIndex(of: "/") {
            pre = String(name[..<cut]); name = String(name[name.index(after: cut)...])
        }
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ off: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[off + i] = b } }
        put(name, 0, 100)
        put("0000644\0", 100, 8); put("0000000\0", 108, 8); put("0000000\0", 116, 8)
        put(String(format: "%011o\0", data.count), 124, 12)
        put(String(format: "%011o\0", Int(Date().timeIntervalSince1970)), 136, 12)
        for i in 148..<156 { h[i] = 32 }
        h[156] = UInt8(ascii: "0")
        put("ustar\0", 257, 6); put("00", 263, 2)
        put(pre, 345, 155)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", sum), 148, 8)
        fh.write(Data(h)); fh.write(data)
        let pad = (512 - data.count % 512) % 512
        if pad > 0 { fh.write(Data(count: pad)) }
        return true
    }
    func finish() throws { fh.write(Data(count: 1024)); try fh.close() }
}

/// RMaps / OsmAnd / Locus sqlitedb, and OruxMaps (u_ExportTaskToRMapsSQLite / OruxMaps).
final class SQLiteSink: TileSink {
    enum Kind: String { case rmaps = "RMaps", osmand = "OsmAnd", locus = "Locus", orux = "OruxMaps" }
    let kind: Kind, replace: Bool
    private var db: OpaquePointer?
    private var stmt: OpaquePointer?
    private var count = 0
    private var origin: [Int: (x: Int, y: Int)] = [:]   // OruxMaps: tile rect origin per zoom
    private static let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, kind: Kind, replace: Bool, center: LonLat, origins: [Int: (Int, Int)] = [:]) throws {
        self.kind = kind; self.replace = replace
        self.origin = origins.mapValues { (x: $0.0, y: $0.1) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "SAS", code: 20, userInfo: [NSLocalizedDescriptionKey: "Cannot create \(url.path)"]) }
        exec("PRAGMA synchronous=OFF"); exec("PRAGMA journal_mode=MEMORY")
        switch kind {
        case .orux:
            exec("CREATE TABLE IF NOT EXISTS tiles (x int, y int, z int, image blob, PRIMARY KEY (x,y,z))")
            exec("CREATE INDEX IF NOT EXISTS IND on tiles (x,y,z)")
            exec("CREATE TABLE IF NOT EXISTS android_metadata (locale TEXT)")
            exec("INSERT INTO android_metadata VALUES ('en_US')")
            sqlite3_prepare_v2(db, "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO tiles (x,y,z,image) VALUES (?,?,?,?)", -1, &stmt, nil)
        default:
            exec("CREATE TABLE IF NOT EXISTS tiles (x int, y int, z int, s int, image blob, PRIMARY KEY (x,y,z,s))")
            exec("CREATE INDEX IF NOT EXISTS IND on tiles (x,y,z,s)")
            switch kind {
            case .osmand:
                exec("CREATE TABLE IF NOT EXISTS info (minzoom INTEGER, maxzoom INTEGER, tilenumbering TEXT, timecolumn TEXT, expireminutes TEXT)")
                exec("INSERT OR REPLACE INTO info (minzoom, maxzoom, tilenumbering, timecolumn, expireminutes) VALUES (0,0,\"BigPlanet\",\"no\",\"0\")")
            case .locus:
                exec("CREATE TABLE IF NOT EXISTS info (minzoom INTEGER, maxzoom INTEGER, center_x DOUBLE, center_y DOUBLE, zooms TEXT, provider INTEGER)")
                exec("INSERT OR REPLACE INTO info (minzoom, maxzoom, center_x, center_y) VALUES (0,0,\(center.lon),\(center.lat))")
            default:
                exec("CREATE TABLE IF NOT EXISTS info (maxzoom Int, minzoom Int)")
                exec("INSERT OR REPLACE INTO info (minzoom, maxzoom) VALUES (0,0)")
            }
            sqlite3_prepare_v2(db, "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO tiles (x,y,z,s,image) VALUES (?,?,?,0,?)", -1, &stmt, nil)
        }
        exec("BEGIN")
    }

    private func exec(_ s: String) { sqlite3_exec(db, s, nil, nil, nil) }
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool { false }

    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool {
        if kind == .orux {
            let o = origin[z] ?? (0, 0)
            sqlite3_bind_int(stmt, 1, Int32(x - o.x)); sqlite3_bind_int(stmt, 2, Int32(y - o.y)); sqlite3_bind_int(stmt, 3, Int32(z))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(x)); sqlite3_bind_int(stmt, 2, Int32(y)); sqlite3_bind_int(stmt, 3, Int32(17 - z))
        }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(data.count), Self.T) }
        sqlite3_step(stmt); sqlite3_reset(stmt)
        count += 1
        if count % 2000 == 0 { exec("COMMIT"); exec("BEGIN") }
        return true
    }

    func finish() throws {
        exec("COMMIT")
        sqlite3_finalize(stmt)
        switch kind {
        case .locus:
            exec("UPDATE info SET maxzoom = (SELECT DISTINCT z FROM tiles ORDER BY z ASC LIMIT 1)")
            exec("UPDATE info SET minzoom = (SELECT DISTINCT z FROM tiles ORDER BY z DESC LIMIT 1)")
        case .rmaps, .osmand:
            exec("UPDATE info SET minzoom = (SELECT DISTINCT z FROM tiles ORDER BY z ASC LIMIT 1)")
            exec("UPDATE info SET maxzoom = (SELECT DISTINCT z FROM tiles ORDER BY z DESC LIMIT 1)")
        case .orux: break
        }
        sqlite3_close(db)
    }
}

/// Google Earth KML: extracts tiles to a folder and writes one GroundOverlay per tile with level-of-detail regions.
final class KMLSink: TileSink {
    let kmlURL: URL, root: URL, relative: Bool
    private var body = ""
    init(url: URL, relative: Bool) {
        kmlURL = url; self.relative = relative
        root = URL(fileURLWithPath: url.deletingPathExtension().path + "_files", isDirectory: true)
    }
    func exists(_ x: Int, _ y: Int, _ z: Int) -> Bool { false }
    func put(_ x: Int, _ y: Int, _ z: Int, _ data: Data, ext: String) throws -> Bool {
        let rel = "z\(z + 1)/\(x)/\(y).\(ext)"
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
        let tl = Geo.lonLat(CGPoint(x: x * 256, y: y * 256), z), br = Geo.lonLat(CGPoint(x: (x + 1) * 256, y: (y + 1) * 256), z)
        let box = "<north>\(tl.lat)</north><south>\(br.lat)</south><east>\(br.lon)</east><west>\(tl.lon)</west>"
        let href = relative ? root.lastPathComponent + "/" + rel : u.path
        body += "<GroundOverlay><name>\(rel)</name><drawOrder>\(z)</drawOrder>" +
            "<Region><LatLonAltBox>\(box)</LatLonAltBox><Lod><minLodPixels>128</minLodPixels><maxLodPixels>1024</maxLodPixels></Lod></Region>" +
            "<Icon><href>\(href)</href></Icon><LatLonBox>\(box)</LatLonBox></GroundOverlay>\r\n"
        return true
    }
    func finish() throws {
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\r\n<name>\(kmlURL.deletingPathExtension().lastPathComponent)</name>\r\n" + body + "</Document></kml>"
        try doc.data(using: .utf8)?.write(to: kmlURL)
    }
}

// MARK: - Tile reading with optional overlay / lower-zoom fill

struct TileSource {
    let map: MapType
    let layer: MapType?
    let usePrevZoom: Bool
    let jpegQuality: Int

    var needsRender: Bool { layer != nil || usePrevZoom }
    var outExt: String { layer != nil ? "png" : map.defaultExt }

    func read(_ x: Int, _ y: Int, _ z: Int) -> (Data, String)? {
        if !needsRender {
            guard case .tile(let u, _) = TileStorage.shared.state(map, x, y, z), let d = try? Data(contentsOf: u) else { return nil }
            return (d, u.pathExtension.lowercased())
        }
        if layer == nil, case .tile(let u, _) = TileStorage.shared.state(map, x, y, z), let d = try? Data(contentsOf: u) {
            return (d, u.pathExtension.lowercased())
        }
        func load(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> CGImage? { TileStorage.shared.read(m, x, y, z).flatMap(TileProvider.decode) }
        var base = load(map, x, y, z)
        var crop: CGRect?
        if base == nil && usePrevZoom && z > 0 {
            for d in 1...min(z, 8) {
                if let p = load(map, x >> d, y >> d, z - d) {
                    let sub = CGFloat(p.width) / CGFloat(1 << d)
                    crop = CGRect(x: CGFloat(x - ((x >> d) << d)) * sub, y: CGFloat(y - ((y >> d) << d)) * sub, width: sub, height: sub)
                    base = p; break
                }
            }
        }
        let over = layer.flatMap { load($0, x, y, z) }
        guard base != nil || over != nil else { return nil }
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        if var b = base {
            if let c = crop, let cc = b.cropping(to: c) { b = cc }
            ctx.draw(b, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        if let o = over { ctx.draw(o, in: CGRect(x: 0, y: 0, width: 256, height: 256)) }
        guard let img = ctx.makeImage() else { return nil }
        let png = outExt == "png"
        return ImageEnc.encode(img, jpeg: !png, quality: jpegQuality).map { ($0, png ? "png" : "jpg") }
    }
}

// MARK: - Copy / export job

final class TileJobTask: LongTask {
    struct Job { let source: TileSource; let sink: TileSink; let deleteSource: Bool }
    let name: String
    let jobs: [Job]
    let region: Region
    let zooms: [Int]
    let outputsList: [URL]
    let afterFinish: (() throws -> Void)?
    private(set) var cancelled = false
    private(set) var outputs: [URL] = []
    private var written = 0, skipped = 0, missing = 0
    var onProgress: ((Double, String) -> Void)?
    var title: String { name }
    var note: String? {
        "\(written) tiles written" + (skipped > 0 ? ", \(skipped) skipped (already there)" : "") +
            (missing > 0 ? ", \(missing) not in the cache" : "") + "."
    }

    init(name: String, jobs: [Job], region: Region, zooms: [Int], outputs: [URL], afterFinish: (() throws -> Void)? = nil) {
        self.name = name; self.jobs = jobs; self.region = region; self.zooms = zooms.sorted()
        outputsList = outputs; self.afterFinish = afterFinish
    }
    func cancel() { cancelled = true }

    func run() throws {
        let perJob = zooms.reduce(0) { $0 + region.tileCount($1) }
        let total = max(1, perJob * jobs.count)
        var processed = 0
        for job in jobs {
            let it = RegionIterator(region: region, zooms: zooms)
            while let t = it.next() {
                if cancelled { break }
                processed += 1
                if let (d, ext) = job.source.read(t.x, t.y, t.z) {
                    if try job.sink.put(t.x, t.y, t.z, d, ext: ext) { written += 1 } else { skipped += 1 }
                    if job.deleteSource {
                        TileStorage.shared.delete(job.source.map, t.x, t.y, t.z)
                        let k = TileKey(mapId: job.source.map.id, x: t.x, y: t.y, z: t.z)
                        DispatchQueue.main.async { TileProvider.shared.invalidate(k) }
                    }
                } else {
                    missing += 1
                }
                if processed % 100 == 0 {
                    onProgress?(Double(processed) / Double(total), "\(job.source.map.name) z\(t.z + 1): \(processed) of \(total) tiles")
                }
            }
            try job.sink.finish()
            if cancelled { break }
        }
        if !cancelled {
            try afterFinish?()
            outputs = outputsList
        }
        onProgress?(1, "\(processed) of \(total) tiles")
    }
}

// MARK: - Generate lower zooms (u_ThreadGenPrevZoom)

final class GenerateTask: LongTask {
    let map: MapType
    let fromZoom: Int
    let toZooms: [Int]
    let region: Region
    let replace: Bool
    let fullOnly: Bool
    let cascade: Bool
    let quality: CGInterpolationQuality
    private(set) var cancelled = false
    private(set) var outputs: [URL] = []
    private var made = 0, skipped = 0
    var onProgress: ((Double, String) -> Void)?
    var title: String { "Generate: \(map.name)" }
    var note: String? { "\(made) tiles generated" + (skipped > 0 ? ", \(skipped) skipped." : ".") }

    init(map: MapType, fromZoom: Int, toZooms: [Int], region: Region, replace: Bool, fullOnly: Bool, cascade: Bool, quality: CGInterpolationQuality) {
        self.map = map; self.fromZoom = fromZoom; self.toZooms = toZooms.filter { $0 < fromZoom }.sorted(by: >)
        self.region = region; self.replace = replace; self.fullOnly = fullOnly; self.cascade = cascade; self.quality = quality
    }
    func cancel() { cancelled = true }

    func run() throws {
        let total = max(1, toZooms.reduce(0) { $0 + region.tileCount($1) })
        var processed = 0
        var src = fromZoom
        let st = TileStorage.shared
        let png = map.defaultExt == "png" || map.isLayer
        for zt in toZooms {
            if cancelled { break }
            let d = src - zt
            let n = 1 << d
            let cell = 256 / CGFloat(n)
            let it = RegionIterator(region: region, zooms: [zt])
            while let t = it.next() {
                if cancelled { break }
                processed += 1
                if processed % 50 == 0 { onProgress?(Double(processed) / Double(total), "z\(zt + 1) from z\(src + 1): \(processed) of \(total) tiles") }
                if !replace, case .tile = st.state(map, t.x, t.y, zt) { skipped += 1; continue }
                guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: (png ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue) else { continue }
                if !png { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
                ctx.interpolationQuality = quality
                var found = 0
                for cy in 0..<n {
                    for cx in 0..<n {
                        guard let img = st.read(map, (t.x << d) + cx, (t.y << d) + cy, src).flatMap(TileProvider.decode) else { continue }
                        found += 1
                        // CG origin is bottom-left
                        ctx.draw(img, in: CGRect(x: CGFloat(cx) * cell, y: 256 - CGFloat(cy + 1) * cell, width: cell, height: cell))
                    }
                }
                if found == 0 || (fullOnly && found < n * n) { skipped += 1; continue }
                guard let img = ctx.makeImage(), let data = ImageEnc.encode(img, jpeg: !png, quality: 90) else { continue }
                st.write(data, ext: png ? "png" : "jpg", map, t.x, t.y, zt)
                made += 1
                let k = TileKey(mapId: map.id, x: t.x, y: t.y, z: zt)
                DispatchQueue.main.async { TileProvider.shared.invalidate(k) }
            }
            if cascade { src = zt }
        }
        onProgress?(1, "\(processed) of \(total) tiles")
    }
}

// MARK: - OruxMaps calibration file

enum OruxCalibration {
    static func write(dir: URL, name: String, region: Region, zooms: [Int]) throws {
        var t = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<OruxTracker xmlns=\"http://oruxtracker.com/app/res/calibration\"\r\nversionCode=\"3.0\">\r\n" +
            "<MapCalibration layers=\"true\" layerLevel=\"0\">\r\n<MapName><![CDATA[\(name)]]></MapName>\r\n"
        for z in zooms.sorted() {
            let b = region.tileBounds(z)
            let xMax = b.x1 - b.x0 + 1, yMax = b.y1 - b.y0 + 1
            let tl = Geo.lonLat(CGPoint(x: b.x0 * 256, y: b.y0 * 256), z), br = Geo.lonLat(CGPoint(x: (b.x1 + 1) * 256, y: (b.y1 + 1) * 256), z)
            let f8 = { (v: Double) in String(format: "%.8f", v) }, f6 = { (v: Double) in String(format: "%.6f", v) }
            t += "<OruxTracker  versionCode=\"2.1\">\r\n<MapCalibration layers=\"false\" layerLevel=\"\(z)\">\r\n" +
                "<MapName><![CDATA[\(name)]]></MapName>\r\n" +
                "<MapChunks xMax=\"\(xMax)\" yMax=\"\(yMax)\" datum=\"WGS84\" projection=\"Mercator\" img_height=\"256\" img_width=\"256\" file_name=\"\(name)\" />\r\n" +
                "<MapDimensions height=\"\(yMax * 256)\" width=\"\(xMax * 256)\" />\r\n" +
                "<MapBounds minLat=\"\(f8(br.lat))\" maxLat=\"\(f8(tl.lat))\" minLon=\"\(f8(tl.lon))\" maxLon=\"\(f8(br.lon))\" />\r\n" +
                "<CalibrationPoints>\r\n" +
                "<CalibrationPoint corner=\"TL\" lon=\"\(f6(tl.lon))\" lat=\"\(f6(tl.lat))\" />\r\n" +
                "<CalibrationPoint corner=\"BR\" lon=\"\(f6(br.lon))\" lat=\"\(f6(br.lat))\" />\r\n" +
                "<CalibrationPoint corner=\"TR\" lon=\"\(f6(br.lon))\" lat=\"\(f6(tl.lat))\" />\r\n" +
                "<CalibrationPoint corner=\"BL\" lon=\"\(f6(tl.lon))\" lat=\"\(f6(br.lat))\" />\r\n" +
                "</CalibrationPoints>\r\n</MapCalibration>\r\n</OruxTracker>\r\n"
        }
        t += "</MapCalibration>\r\n</OruxTracker>"
        try t.data(using: .utf8)?.write(to: dir.appendingPathComponent(name + ".otrk2.xml"))
    }
}
