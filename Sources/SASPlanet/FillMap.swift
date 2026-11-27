import Foundation
import CoreGraphics

final class FillMapLayer {
    static let shared = FillMapLayer()

    enum Mode: Int { case unexisting = 0, existing = 1, gradient = 2 }

    struct Settings: Equatable {
        var zoom: Int // fill zoom
        var mapId: String // source map
        var mode: Mode
        var filter: Bool
        var from: Date
        var to: Date
    }

    private final class Entry {
        let image: CGImage?
        let gen: Int
        init(_ i: CGImage?, _ g: Int) { image = i; gen = g }
    }

    private let cache = NSCache<NSString, Entry>()
    private var inflight = Set<String>()
    private var gen = 0
    private var invalidateScheduled = false
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    var onUpdate: [() -> Void] = []

    init() { cache.countLimit = 3000 }

    func invalidate() {
        gen += 1
        onUpdate.forEach { $0() }
    }

    func invalidateSoon() {
        guard !invalidateScheduled else { return }
        invalidateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.invalidateScheduled = false
            self?.invalidate()
        }
    }

    func image(map: MapType, z: Int, tx: Int, ty: Int, s: Settings) -> CGImage? {
        let key = "\(map.id)/\(z)/\(tx)/\(ty)/\(s.zoom)/\(s.mode.rawValue)/\(s.filter)/\(s.from.timeIntervalSince1970)/\(s.to.timeIntervalSince1970)"
        let e = cache.object(forKey: key as NSString)
        if (e == nil || e!.gen < gen) && !inflight.contains(key) {
            inflight.insert(key)
            let g = gen
            queue.addOperation { [weak self] in
                let img = Self.compute(map: map, z: z, tx: tx, ty: ty, s: s)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.inflight.remove(key)
                    self.cache.setObject(Entry(img, g), forKey: key as NSString)
                    self.onUpdate.forEach { $0() }
                }
            }
        }
        return e?.image
    }

    func cancelPending() { queue.cancelAllOperations(); inflight.removeAll() }

    // MARK: computation

    private enum CellState { case missing, tne(Date), tile(Date) }

    private static let noTile: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 110)
    private static let tneColor: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 110)

    private static func color(_ st: CellState, _ s: Settings) -> (UInt8, UInt8, UInt8, UInt8)? {
        let lastDay = Calendar.current.startOfDay(for: s.to).addingTimeInterval(86400)
        let firstDay = Calendar.current.startOfDay(for: s.from)
        func inRange(_ d: Date) -> Bool { d >= firstDay && d < lastDay }
        switch st {
        case .tne:
            return s.mode == .existing ? nil : tneColor
        case .missing:
            return s.mode == .unexisting ? noTile : nil
        case .tile(let d):
            switch s.mode {
            case .unexisting: return s.filter && !inRange(d) ? noTile : nil
            case .existing: return !s.filter || inRange(d) ? noTile : nil
            case .gradient:
                let start = s.filter ? firstDay : DateComponents(calendar: .current, year: 2000, month: 1, day: 1).date!
                let span = max(1, lastDay.timeIntervalSince(start))
                let f = min(1, max(0, lastDay.timeIntervalSince(d) / span))
                if s.filter && !inRange(d) { return nil }
                let r = UInt8(min(255, f * 2 * 255)), g = UInt8(min(255, (1 - f) * 2 * 255))
                return (r, g, 0, 110)
            }
        }
    }

    private static func listDir(_ dir: String, needDates: Bool) -> [Int: CellState] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [Int: CellState] = [:]
        for n in names where n.hasPrefix("y") {
            guard let dot = n.firstIndex(of: "."), let y = Int(n[n.index(after: n.startIndex)..<dot]) else { continue }
            let ext = n[n.index(after: dot)...].lowercased()
            var date = Date.distantPast
            if needDates {
                var st = stat()
                if stat(dir + "/" + n, &st) == 0 { date = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) }
            }
            if ext == "tne" {
                if case .tile = out[y] { continue }
                out[y] = .tne(date)
            } else if TileStorage.exts.contains(ext) {
                out[y] = .tile(date)
            }
        }
        return out
    }

    private static func compute(map: MapType, z: Int, tx: Int, ty: Int, s: Settings) -> CGImage? {
        let fz = s.zoom
        let needDates = s.filter || s.mode == .gradient
        let root = Config.shared.cacheURL.appendingPathComponent(map.folder).appendingPathComponent("z\(fz + 1)").path
        let d = fz - z
        let n = d > 0 ? 1 << d : 1
        let fx0 = d >= 0 ? tx << d : tx >> -d
        let fy0 = d >= 0 ? ty << d : ty >> -d
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var any = false
        var dirCache: [String: [Int: CellState]] = [:]
        for cx in 0..<n {
            let fx = fx0 + cx
            for cy in 0..<n {
                let fy = fy0 + cy
                let dir = "\(root)/\(fx >> 10)/x\(fx)/\(fy >> 10)"
                if dirCache[dir] == nil { dirCache[dir] = listDir(dir, needDates: needDates) }
                let st = dirCache[dir]![fy] ?? .missing
                if let c = color(st, s) {
                    let i = (cy * n + cx) * 4
                    let a = Double(c.3) / 255
                    px[i] = UInt8(Double(c.0) * a); px[i + 1] = UInt8(Double(c.1) * a); px[i + 2] = UInt8(Double(c.2) * a); px[i + 3] = c.3
                    any = true
                }
            }
        }
        guard any else { return nil }
        let data = Data(px) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
