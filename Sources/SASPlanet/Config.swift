import Foundation

extension Notification.Name {
    static let configChanged = Notification.Name("SASConfigChanged")
}

/// Download mode, as in SAS.Planet's "Source" menu.
enum DownloadMode: Int {
    case cache = 0          // Cache only
    case internet = 1       // Internet only (always download)
    case cacheInternet = 2  // Internet & Cache
}

/// Application settings, persisted in UserDefaults (SAS.Planet keeps these in SASPlanet.ini).
final class Config {
    static let shared = Config()
    /// Test copies (SAS_DEBUG=1) keep separate settings so they never disturb a running copy.
    static let defaults: UserDefaults = ProcessInfo.processInfo.environment["SAS_DEBUG"] == "1"
        ? (UserDefaults(suiteName: "org.sasgis.sasplanet.macos.debug") ?? .standard) : .standard
    private let d = Config.defaults

    private init() {
        d.register(defaults: [
            "centerLat": 51.5074, "centerLon": -0.1278, "zoom": 11,
            "mainMap": "google.sat", "layers": [String](),
            "downloadMode": DownloadMode.cacheInternet.rawValue,
            "statusBarVisible": true, "miniMapVisible": true, "scaleLineVisible": true,
            "zoomToCursor": true, "usePrevForMap": true, "usePrevForLayers": true,
            "zoomAnimation": true, "inertialMovement": true, "nightMode": false,
            "tileGridZoom": -1, "lonLatGrid": 0.0,
            "maxConnections": 4, "miniMapZoomDelta": 4,
            "toolbarsHidden": [String](), "folderOverrides": [String: String](),
            "fillZoom": -1, "fillMode": 0, "fillMapId": "", "fillFilter": false,
        ])
    }

    private func changed() { NotificationCenter.default.post(name: .configChanged, object: self) }

    var centerLat: Double { get { d.double(forKey: "centerLat") } set { d.set(newValue, forKey: "centerLat") } }
    var centerLon: Double { get { d.double(forKey: "centerLon") } set { d.set(newValue, forKey: "centerLon") } }
    var zoom: Int { get { d.integer(forKey: "zoom") } set { d.set(newValue, forKey: "zoom") } }

    var mainMapId: String { get { d.string(forKey: "mainMap") ?? "google.sat" } set { d.set(newValue, forKey: "mainMap"); changed() } }
    var layerIds: [String] { get { d.stringArray(forKey: "layers") ?? [] } set { d.set(newValue, forKey: "layers"); changed() } }

    var downloadMode: DownloadMode {
        get { DownloadMode(rawValue: d.integer(forKey: "downloadMode")) ?? .cacheInternet }
        set { d.set(newValue.rawValue, forKey: "downloadMode"); changed() }
    }

    private func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    private func setBool(_ k: String, _ v: Bool) { d.set(v, forKey: k); changed() }

    var statusBarVisible: Bool { get { bool("statusBarVisible") } set { setBool("statusBarVisible", newValue) } }
    var miniMapVisible: Bool { get { bool("miniMapVisible") } set { setBool("miniMapVisible", newValue) } }
    var scaleLineVisible: Bool { get { bool("scaleLineVisible") } set { setBool("scaleLineVisible", newValue) } }
    var zoomToCursor: Bool { get { bool("zoomToCursor") } set { setBool("zoomToCursor", newValue) } }
    var usePrevForMap: Bool { get { bool("usePrevForMap") } set { setBool("usePrevForMap", newValue) } }
    var usePrevForLayers: Bool { get { bool("usePrevForLayers") } set { setBool("usePrevForLayers", newValue) } }
    var zoomAnimation: Bool { get { bool("zoomAnimation") } set { setBool("zoomAnimation", newValue) } }
    var inertialMovement: Bool { get { bool("inertialMovement") } set { setBool("inertialMovement", newValue) } }
    var nightMode: Bool { get { bool("nightMode") } set { setBool("nightMode", newValue) } }

    /// -1 = no tile boundaries, 0 = current zoom, n = absolute internal zoom n-1 (SAS shows z1..z24)
    var tileGridZoom: Int { get { d.integer(forKey: "tileGridZoom") } set { d.set(newValue, forKey: "tileGridZoom"); changed() } }
    /// 0 = no grid, -1 = auto, otherwise step in degrees
    var lonLatGrid: Double { get { d.double(forKey: "lonLatGrid") } set { d.set(newValue, forKey: "lonLatGrid"); changed() } }

    var maxConnections: Int {
        get { max(1, min(16, d.integer(forKey: "maxConnections"))) }
        set { d.set(newValue, forKey: "maxConnections"); changed() }
    }
    var miniMapZoomDelta: Int {
        get { max(1, min(10, d.integer(forKey: "miniMapZoomDelta"))) }
        set { d.set(newValue, forKey: "miniMapZoomDelta"); changed() }
    }

    var hiddenToolbars: Set<String> {
        get { Set(d.stringArray(forKey: "toolbarsHidden") ?? []) }
        set { d.set(Array(newValue), forKey: "toolbarsHidden"); changed() }
    }

    /// Cached Tiles Map: internal zoom to show (-1 = hidden), mode, source map ("" = main), date filter
    var fillZoom: Int { get { d.integer(forKey: "fillZoom") } set { d.set(newValue, forKey: "fillZoom"); changed() } }
    var fillMode: Int { get { d.integer(forKey: "fillMode") } set { d.set(newValue, forKey: "fillMode"); changed() } }
    var fillMapId: String { get { d.string(forKey: "fillMapId") ?? "" } set { d.set(newValue, forKey: "fillMapId"); changed() } }
    var fillFilter: Bool { get { bool("fillFilter") } set { setBool("fillFilter", newValue) } }
    var fillFrom: Date {
        get { d.object(forKey: "fillFrom") as? Date ?? DateComponents(calendar: .current, year: 2000, month: 1, day: 1).date! }
        set { d.set(newValue, forKey: "fillFrom"); changed() }
    }
    var fillTo: Date {
        get { d.object(forKey: "fillTo") as? Date ?? Calendar.current.startOfDay(for: Date()) }
        set { d.set(newValue, forKey: "fillTo"); changed() }
    }

    /// Per-map override of the folder name inside the cache (SAS "NameInCache").
    var folderOverrides: [String: String] {
        get { d.dictionary(forKey: "folderOverrides") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "folderOverrides"); changed() }
    }

    /// Root cache folder (SAS.Planet: <program>\cache). Default ~/SASPlanet/cache
    var cacheURL: URL {
        get {
            if let p = d.string(forKey: "cachePath"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("SASPlanet", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "cachePath"); changed() }
    }
}
