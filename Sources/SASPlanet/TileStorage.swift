import Foundation

final class TileStorage {
    static let shared = TileStorage()
    static let exts = ["jpg", "png", "jpeg", "gif", "webp", "bmp"]

    enum State {
        case tile(URL, Date)
        case tne(Date)
        case none
    }

    private let fm = FileManager.default

    func base(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> URL {
        Config.shared.cacheURL
            .appendingPathComponent(m.folder, isDirectory: true)
            .appendingPathComponent("z\(z + 1)", isDirectory: true)
            .appendingPathComponent(String(x >> 10), isDirectory: true)
            .appendingPathComponent("x\(x)", isDirectory: true)
            .appendingPathComponent(String(y >> 10), isDirectory: true)
            .appendingPathComponent("y\(y)")
    }

    private func mtime(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    func state(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> State {
        let b = base(m, x, y, z).path
        // ext order
        for e in [m.defaultExt] + Self.exts.filter({ $0 != m.defaultExt }) {
            if let t = mtime(b + "." + e) { return .tile(URL(fileURLWithPath: b + "." + e), t) }
        }
        if let t = mtime(b + ".tne") { return .tne(t) }
        return .none
    }

    func read(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> Data? {
        if case .tile(let u, _) = state(m, x, y, z) { return try? Data(contentsOf: u) }
        return nil
    }

    @discardableResult
    func write(_ data: Data, ext: String, _ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> URL? {
        let b = base(m, x, y, z)
        let dir = b.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // cleanup
            for e in Self.exts + ["tne"] where e != ext {
                let p = b.path + "." + e
                if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
            }
            let u = URL(fileURLWithPath: b.path + "." + ext)
            try data.write(to: u, options: .atomic)
            return u
        } catch {
            return nil
        }
    }

    func writeTNE(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) {
        let b = base(m, x, y, z)
        try? fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: b.path + ".tne", contents: Data())
    }

    // delete
    @discardableResult
    func delete(_ m: MapType, _ x: Int, _ y: Int, _ z: Int, tiles: Bool = true, tne: Bool = true) -> Bool {
        let b = base(m, x, y, z).path
        var removed = false
        if tiles {
            for e in Self.exts where fm.fileExists(atPath: b + "." + e) {
                removed = (try? fm.removeItem(atPath: b + "." + e)) != nil || removed
            }
        }
        if tne, fm.fileExists(atPath: b + ".tne") {
            removed = (try? fm.removeItem(atPath: b + ".tne")) != nil || removed
        }
        return removed
    }

    func displayPath(_ m: MapType, _ x: Int, _ y: Int, _ z: Int) -> String {
        switch state(m, x, y, z) {
        case .tile(let u, _): return u.path
        default: return base(m, x, y, z).path + "." + m.defaultExt
        }
    }

    static func ext(forContentType ct: String?, data: Data) -> String? {
        let c = (ct ?? "").lowercased()
        if c.contains("jpeg") || c.contains("jpg") { return "jpg" }
        if c.contains("png") { return "png" }
        if c.contains("webp") { return "webp" }
        if c.contains("gif") { return "gif" }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return nil
    }
}
