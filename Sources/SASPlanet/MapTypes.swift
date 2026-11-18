import Foundation

/// A map or overlay layer source (SAS.Planet: one .zmp map definition).
/// URL templates use {x} {y} {z} (0-based zoom), {q} (Bing quadkey) and {s} (rotating subdomain).
struct MapType: Equatable {
    let id: String
    let name: String
    let group: String
    let isLayer: Bool
    /// Default folder name inside the cache (zmp "NameInCache")
    let defaultFolder: String
    let templates: [String]
    var subdomains: [String] = []
    /// Highest zoom the server provides (0-based internal zoom)
    let maxZoom: Int
    let defaultExt: String
    /// nil = browser-like user agent
    var userAgent: String? = nil
    var referer: String? = nil
    /// Some providers forbid bulk downloading; downloads above this many tiles are refused.
    var bulkLimit: Int? = nil
    var policyNote: String? = nil

    var folder: String { Config.shared.folderOverrides[id] ?? defaultFolder }

    static let appUA = "SASPlanet-macOS/0.3 (+https://github.com/sasgis/sas.planet.src)"

    static func quadkey(_ x: Int, _ y: Int, _ z: Int) -> String {
        guard z > 0 else { return "0" }
        var q = ""
        for i in stride(from: z, to: 0, by: -1) {
            let mask = 1 << (i - 1)
            q.append(Character(String((x & mask != 0 ? 1 : 0) + (y & mask != 0 ? 2 : 0))))
        }
        return q
    }

    /// Candidate tile URLs, tried in order with failover.
    func urls(x: Int, y: Int, z: Int) -> [URL] {
        var out: [String] = []
        for t in templates {
            let base = t.replacingOccurrences(of: "{x}", with: String(x))
                .replacingOccurrences(of: "{y}", with: String(y))
                .replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{q}", with: t.contains("{q}") ? Self.quadkey(x, y, z) : "")
            if base.contains("{s}"), !subdomains.isEmpty {
                let n = subdomains.count, start = (x + y) % n
                for k in 0..<n { out.append(base.replacingOccurrences(of: "{s}", with: subdomains[(start + k) % n])) }
            } else {
                out.append(base)
            }
        }
        return out.compactMap(URL.init(string:))
    }

    static func == (a: MapType, b: MapType) -> Bool { a.id == b.id }
}

enum MapRegistry {
    private static func google(_ id: String, _ name: String, _ folder: String, _ lyrs: String, _ maxZ: Int, _ ext: String, layer: Bool = false) -> MapType {
        MapType(id: "google.\(id)", name: name, group: "Google", isLayer: layer, defaultFolder: folder,
                templates: ["https://www.google.com/maps/vt?lyrs=\(lyrs)&hl=en&x={x}&y={y}&z={z}",
                            "https://mt{s}.google.com/vt/lyrs=\(lyrs)&hl=en&x={x}&y={y}&z={z}"],
                subdomains: ["0", "1", "2", "3"], maxZoom: maxZ, defaultExt: ext, referer: "https://www.google.com/maps")
    }

    private static func bing(_ id: String, _ name: String, _ folder: String, _ path: String, _ ext: String) -> MapType {
        MapType(id: "bing.\(id)", name: name, group: "Bing", isLayer: false, defaultFolder: folder,
                templates: ["https://ecn.t{s}.tiles.virtualearth.net/tiles/\(path)"], subdomains: ["0", "1", "2", "3"],
                maxZoom: 19, defaultExt: ext, userAgent: MapType.appUA)
    }

    private static func esri(_ id: String, _ name: String, _ folder: String, _ service: String, _ maxZ: Int, _ ext: String, layer: Bool = false) -> MapType {
        MapType(id: "esri.\(id)", name: name, group: "ESRI", isLayer: layer, defaultFolder: folder,
                templates: ["https://server.arcgisonline.com/ArcGIS/rest/services/\(service)/MapServer/tile/{z}/{y}/{x}",
                            "https://services.arcgisonline.com/ArcGIS/rest/services/\(service)/MapServer/tile/{z}/{y}/{x}"],
                maxZoom: maxZ, defaultExt: ext, userAgent: MapType.appUA)
    }

    private static func xyz(_ group: String, _ id: String, _ name: String, _ folder: String, _ tmpl: String, subs: [String] = [],
                            maxZ: Int, ext: String = "png", layer: Bool = false, bulk: Int? = nil, note: String? = nil) -> MapType {
        MapType(id: "\(group.lowercased()).\(id)", name: name, group: group, isLayer: layer, defaultFolder: folder,
                templates: [tmpl], subdomains: subs, maxZoom: maxZ, defaultExt: ext, userAgent: MapType.appUA,
                bulkLimit: bulk, policyNote: note)
    }

    static let maps: [MapType] = [
        bing("sat", "Satellite (Bing)", "vesat", "a{q}.jpeg?g=1", "jpg"),
        bing("hybrid", "Hybrid (Bing)", "vehyb", "h{q}.jpeg?g=1&mkt=en-us", "jpg"),
        bing("map", "Map (Bing)", "vemap", "r{q}.png?g=1&mkt=en-us&shading=hill", "jpg"),

        esri("sat", "World Imagery (ESRI)", "ArcGIS.Imagery", "World_Imagery", 19, "jpg"),
        esri("street", "World Street Map (ESRI)", "ArcGIS.StreetMap", "World_Street_Map", 19, "jpg"),
        esri("topo", "World Topo Map (ESRI)", "ArcGIS.TopoMap", "World_Topo_Map", 19, "jpg"),
        esri("natgeo", "National Geographic (ESRI)", "ArcGIS.NatGeo", "NatGeo_World_Map", 15, "jpg"),

        google("landscape", "Landscape (Google)", "landscape", "p", 20, "jpg"),
        google("landscape_nn", "Landscape w/o names (Google)", "landscape_nn", "t", 15, "jpg"),
        google("map", "Map (Google)", "map", "m", 21, "png"),
        google("sat", "Satellite (Google maps)", "sat", "s", 21, "jpg"),
        google("transit", "Transit (Google)", "transit", "m,transit", 21, "png"),

        xyz("OSM", "mapnik", "OpenStreetMap (Mapnik)", "osmmapMapnik", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", maxZ: 19,
            bulk: 250, note: "The OpenStreetMap tile servers forbid bulk downloading (tile usage policy)."),
        xyz("OSM", "hot", "Humanitarian (OSM)", "osm_hot", "https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png", subs: ["a", "b", "c"], maxZ: 19),
        xyz("OSM", "cyclosm", "CyclOSM (OSM)", "osm_cyclosm", "https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png", subs: ["a", "b", "c"], maxZ: 19),
        xyz("OSM", "opentopo", "OpenTopoMap", "opentopomap", "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png", subs: ["a", "b", "c"], maxZ: 16),

        xyz("Other", "carto_light", "Carto Positron (light)", "carto_light", "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png", subs: ["a", "b", "c", "d"], maxZ: 19),
        xyz("Other", "carto_dark", "Carto Dark Matter", "carto_dark", "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png", subs: ["a", "b", "c", "d"], maxZ: 19),
    ]

    static let layers: [MapType] = [
        esri("ref", "Boundaries & Places (ESRI)", "ArcGIS.Reference", "Reference/World_Boundaries_and_Places", 19, "png", layer: true),
        google("hybrid", "Hybrid (Google)", "both", "h", 21, "png", layer: true),
        xyz("OSM", "seamap", "OpenSeaMap (sea marks)", "openseamap", "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png", maxZ: 18, layer: true),
        xyz("OSM", "hiking", "Hiking trails (Waymarked)", "waymarked_hiking", "https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png", maxZ: 17, layer: true),
    ]

    static var all: [MapType] { maps + layers }

    static func byId(_ id: String) -> MapType? { all.first { $0.id == id } }

    static var groups: [String] {
        var seen = [String]()
        for m in all where !seen.contains(m.group) { seen.append(m.group) }
        return seen.sorted { a, b in a == "Other" ? false : (b == "Other" ? true : a < b) }
    }
}
