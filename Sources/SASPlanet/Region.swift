import Foundation
import CoreGraphics

struct Region: Codable {
    var polygon: [LonLat]

    var isRectangle: Bool {
        guard polygon.count == 4 else { return false }
        let lons = Set(polygon.map(\.lon)), lats = Set(polygon.map(\.lat))
        return lons.count == 2 && lats.count == 2
    }

    var bbox: (w: Double, s: Double, e: Double, n: Double) {
        (polygon.map(\.lon).min() ?? 0, polygon.map(\.lat).min() ?? 0,
         polygon.map(\.lon).max() ?? 0, polygon.map(\.lat).max() ?? 0)
    }

    func pixelBounds(_ z: Int) -> CGRect {
        let b = bbox
        let a = Geo.pixel(LonLat(lon: b.w, lat: b.n), z), c = Geo.pixel(LonLat(lon: b.e, lat: b.s), z)
        return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
    }

    func tileBounds(_ z: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let r = pixelBounds(z)
        let n = (1 << z) - 1
        let x0 = max(0, Int(floor(r.minX / 256))), y0 = max(0, Int(floor(r.minY / 256)))
        let x1 = min(n, Int(ceil(r.maxX / 256)) - 1), y1 = min(n, Int(ceil(r.maxY / 256)) - 1)
        return (x0, y0, max(x0, x1), max(y0, y1))
    }

    func rows(_ z: Int) -> [(y: Int, x0: Int, x1: Int)] {
        let t = tileBounds(z)
        if isRectangle { return (t.y0...t.y1).map { ($0, t.x0, t.x1) } }
        let pts = polygon.map { Geo.pixel($0, z) }
        var out: [(Int, Int, Int)] = []
        for ty in t.y0...t.y1 {
            let y0 = CGFloat(ty) * 256, y1 = y0 + 256
            let clipped = Self.clipBand(pts, y0, y1)
            guard let minX = clipped.map(\.x).min(), let maxX = clipped.map(\.x).max() else { continue }
            let a = max(t.x0, Int(floor(minX / 256))), b = min(t.x1, Int(ceil(maxX / 256)) - 1)
            if a <= b { out.append((ty, a, max(a, b))) }
        }
        return out
    }

    func tileIntersects(_ x: Int, _ y: Int, _ z: Int, pts: [CGPoint]) -> Bool {
        if isRectangle { return true }
        let r = CGRect(x: CGFloat(x) * 256, y: CGFloat(y) * 256, width: 256, height: 256)
        let clipped = Self.clipBand(pts, r.minY, r.maxY)
        guard !clipped.isEmpty else { return false }
        let c2 = Self.clipBandX(clipped, r.minX, r.maxX)
        return !c2.isEmpty
    }

    func tileCount(_ z: Int) -> Int {
        if isRectangle {
            let t = tileBounds(z)
            return (t.x1 - t.x0 + 1) * (t.y1 - t.y0 + 1)
        }
        let pts = polygon.map { Geo.pixel($0, z) }
        var n = 0
        for r in rows(z) {
            if r.x1 - r.x0 > 4096 { n += r.x1 - r.x0 + 1; continue } // approx
            for x in r.x0...r.x1 where tileIntersects(x, r.y, z, pts: pts) { n += 1 }
        }
        return n
    }

    static func clipBand(_ poly: [CGPoint], _ y0: CGFloat, _ y1: CGFloat) -> [CGPoint] {
        var p = clip(poly) { $0.y >= y0 } intersect: { a, b in
            let t = (y0 - a.y) / (b.y - a.y); return CGPoint(x: a.x + (b.x - a.x) * t, y: y0)
        }
        p = clip(p) { $0.y <= y1 } intersect: { a, b in
            let t = (y1 - a.y) / (b.y - a.y); return CGPoint(x: a.x + (b.x - a.x) * t, y: y1)
        }
        return p
    }

    static func clipBandX(_ poly: [CGPoint], _ x0: CGFloat, _ x1: CGFloat) -> [CGPoint] {
        var p = clip(poly) { $0.x >= x0 } intersect: { a, b in
            let t = (x0 - a.x) / (b.x - a.x); return CGPoint(x: x0, y: a.y + (b.y - a.y) * t)
        }
        p = clip(p) { $0.x <= x1 } intersect: { a, b in
            let t = (x1 - a.x) / (b.x - a.x); return CGPoint(x: x1, y: a.y + (b.y - a.y) * t)
        }
        return p
    }

    private static func clip(_ poly: [CGPoint], inside: (CGPoint) -> Bool, intersect: (CGPoint, CGPoint) -> CGPoint) -> [CGPoint] {
        guard !poly.isEmpty else { return [] }
        var out: [CGPoint] = []
        var prev = poly[poly.count - 1]
        for cur in poly {
            let ci = inside(cur), pi = inside(prev)
            if ci {
                if !pi { out.append(intersect(prev, cur)) }
                out.append(cur)
            } else if pi {
                out.append(intersect(prev, cur))
            }
            prev = cur
        }
        return out
    }
}

struct TileCursor: Codable {
    var zoomIndex = 0
    var rowIndex = 0
    var x: Int? = nil
}

final class RegionIterator {
    let region: Region
    let zooms: [Int]
    private(set) var cursor: TileCursor
    private var rows: [(y: Int, x0: Int, x1: Int)] = []
    private var rowsZoom = -1
    private var pts: [CGPoint] = []
    private let lock = NSLock()

    init(region: Region, zooms: [Int], cursor: TileCursor = TileCursor()) {
        self.region = region
        self.zooms = zooms.sorted()
        self.cursor = cursor
    }

    func next() -> (x: Int, y: Int, z: Int)? {
        lock.lock(); defer { lock.unlock() }
        while cursor.zoomIndex < zooms.count {
            let z = zooms[cursor.zoomIndex]
            if rowsZoom != z {
                rows = region.rows(z)
                pts = region.polygon.map { Geo.pixel($0, z) }
                rowsZoom = z
            }
            while cursor.rowIndex < rows.count {
                let r = rows[cursor.rowIndex]
                var x = cursor.x ?? r.x0
                while x <= r.x1 {
                    let cx = x
                    x += 1
                    cursor.x = x
                    if region.tileIntersects(cx, r.y, z, pts: pts) { return (cx, r.y, z) }
                }
                cursor.rowIndex += 1
                cursor.x = nil
            }
            cursor.zoomIndex += 1
            cursor.rowIndex = 0
            cursor.x = nil
        }
        return nil
    }

    var snapshot: TileCursor { lock.lock(); defer { lock.unlock() }; return cursor }
}
