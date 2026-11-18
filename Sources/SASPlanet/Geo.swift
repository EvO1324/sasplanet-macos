import Foundation
import CoreGraphics

struct LonLat: Equatable, Codable {
    var lon: Double
    var lat: Double
}

/// Web Mercator (EPSG:3857) tile math, matching SAS.Planet's Google projection.
enum Geo {
    static let R = 6378137.0
    static let maxLat = 85.05112877980659
    static let tileSize = 256.0

    static func worldSize(_ z: Int) -> Double { tileSize * pow(2.0, Double(z)) }

    static func pixel(_ ll: LonLat, _ z: Int) -> CGPoint {
        let s = worldSize(z)
        let lat = max(min(ll.lat, maxLat), -maxLat) * .pi / 180
        let x = (ll.lon + 180) / 360 * s
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * s
        return CGPoint(x: x, y: y)
    }

    static func lonLat(_ p: CGPoint, _ z: Int) -> LonLat {
        let s = worldSize(z)
        let lon = Double(p.x) / s * 360 - 180
        let n = Double.pi - 2 * .pi * Double(p.y) / s
        return LonLat(lon: lon, lat: atan(sinh(n)) * 180 / .pi)
    }

    static func metersPerPixel(lat: Double, z: Int) -> Double {
        cos(lat * .pi / 180) * 2 * .pi * R / worldSize(z)
    }

    /// Geodesic distance on the WGS84 ellipsoid (Vincenty inverse), metres.
    static func distance(_ a: LonLat, _ b: LonLat) -> Double {
        let aE = 6378137.0, f = 1 / 298.257223563, bE = aE * (1 - f)
        let L = (b.lon - a.lon) * .pi / 180
        let U1 = atan((1 - f) * tan(a.lat * .pi / 180))
        let U2 = atan((1 - f) * tan(b.lat * .pi / 180))
        let sinU1 = sin(U1), cosU1 = cos(U1), sinU2 = sin(U2), cosU2 = cos(U2)
        var lambda = L, iter = 0
        var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0, cos2Alpha = 0.0, cos2SigmaM = 0.0
        repeat {
            let sinL = sin(lambda), cosL = cos(lambda)
            sinSigma = sqrt(pow(cosU2 * sinL, 2) + pow(cosU1 * sinU2 - sinU1 * cosU2 * cosL, 2))
            if sinSigma == 0 { return 0 }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosL
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinL / sinSigma
            cos2Alpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cos2Alpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cos2Alpha : 0
            let C = f / 16 * cos2Alpha * (4 + f * (4 - 3 * cos2Alpha))
            let prev = lambda
            lambda = L + (1 - C) * f * sinAlpha * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            iter += 1
            if abs(lambda - prev) < 1e-12 { break }
        } while iter < 200
        if iter >= 200 { return haversine(a, b) }
        let u2 = cos2Alpha * (aE * aE - bE * bE) / (bE * bE)
        let A = 1 + u2 / 16384 * (4096 + u2 * (-768 + u2 * (320 - 175 * u2)))
        let B = u2 / 1024 * (256 + u2 * (-128 + u2 * (74 - 47 * u2)))
        let dSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        return bE * A * (sigma - dSigma)
    }

    static func haversine(_ a: LonLat, _ b: LonLat) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371008.8 * asin(min(1, sqrt(h)))
    }

    // MARK: formatting (SAS.Planet default: degrees/minutes/seconds with 4 decimals)

    static func dms(_ v: Double, pos: String, neg: String) -> String {
        var a = abs(v)
        var deg = floor(a)
        a = (a - deg) * 60
        var min = floor(a)
        var sec = (a - min) * 60
        sec = (sec * 10000).rounded() / 10000
        if sec >= 60 { sec -= 60; min += 1 }
        if min >= 60 { min -= 60; deg += 1 }
        return String(format: "%@%d°%02d'%07.4f\"", v < 0 ? neg : pos, Int(deg), Int(min), sec)
    }

    static func formatLonLat(_ ll: LonLat) -> String {
        "\(dms(ll.lat, pos: "N", neg: "S")) \(dms(ll.lon, pos: "E", neg: "W"))"
    }

    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func fmt(_ v: Double, _ digits: Int) -> String {
        number.minimumFractionDigits = digits
        number.maximumFractionDigits = digits
        return number.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func formatDistance(_ m: Double) -> String {
        if m < 1000 { return "\(fmt(m, m < 10 ? 2 : (m < 100 ? 1 : 0))) m" }
        return "\(fmt(m / 1000, m < 10000 ? 2 : (m < 100000 ? 1 : 0))) km"
    }

    static func formatMetersPerPixel(_ m: Double) -> String {
        if m < 1000 { return "\(fmt(m, 2)) m/pixel" }
        return "\(fmt(m / 1000, 2)) km/pixel"
    }

    static func formatDataSize(kb: Double) -> String {
        if kb < 1024 { return "\(fmt(kb, 1)) KB" }
        if kb < 1024 * 1024 { return "\(fmt(kb / 1024, 1)) MB" }
        return "\(fmt(kb / 1024 / 1024, 2)) GB"
    }

    /// Parses "51.5, -0.12", "N51°30'26\" W0°7'39\"", "51 30 26 N 0 7 39 W" etc.
    static func parseLonLat(_ s: String) -> LonLat? {
        let t = s.uppercased().replacingOccurrences(of: ",", with: " ")
        // decimal pair
        let dec = t.split(whereSeparator: { $0 == " " || $0 == ";" }).compactMap { Double($0) }
        if dec.count == 2, !t.contains("°"), !t.contains("N"), !t.contains("S"), !t.contains("E"), !t.contains("W") {
            return valid(LonLat(lon: dec[1], lat: dec[0]))
        }
        // DMS with hemispheres
        let re = try! NSRegularExpression(pattern: #"([NSEW])?\s*(-?\d+(?:\.\d+)?)\s*[°D ]?\s*(?:(\d+(?:\.\d+)?)\s*['M ]?\s*)?(?:(\d+(?:\.\d+)?)\s*(?:"|''|S(?![EW]))?)?\s*([NSEW])?"#)
        var lat: Double?, lon: Double?
        let ns = t as NSString
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let dStr = g(2), let d = Double(dStr) else { continue }
            var v = abs(d) + (Double(g(3) ?? "") ?? 0) / 60 + (Double(g(4) ?? "") ?? 0) / 3600
            if d < 0 { v = -v }
            let hemi = g(1) ?? g(5)
            switch hemi {
            case "N": lat = v
            case "S": lat = -v
            case "E": lon = v
            case "W": lon = -v
            default: if lat == nil { lat = v } else if lon == nil { lon = v }
            }
        }
        if let la = lat, let lo = lon { return valid(LonLat(lon: lo, lat: la)) }
        return nil
    }

    private static func valid(_ ll: LonLat) -> LonLat? {
        (-90...90).contains(ll.lat) && (-180...180).contains(ll.lon) ? ll : nil
    }
}
