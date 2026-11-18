import Foundation
import CoreGraphics
import ImageIO

// MARK: - Network

/// Downloads tiles with host failover. Thread-safe; completions run on a background queue.
final class TileFetcher {
    static let shared = TileFetcher()

    enum Result {
        case tile(Data, String)  // data, extension
        case notFound
        case failed(String)
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private let session: URLSession
    private let lock = NSLock()
    private var badUntil: [String: Date] = [:]
    private var _count = 0
    private var _bytes = 0

    /// Totals for the status bar ("Downloaded N (x MB)")
    var downloaded: (count: Int, bytes: Int) { lock.lock(); defer { lock.unlock() }; return (_count, _bytes) }

    private init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 30
        c.httpMaximumConnectionsPerHost = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    private func isBad(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (badUntil[host] ?? .distantPast) > Date()
    }

    private func markBad(_ host: String) {
        lock.lock(); badUntil[host] = Date().addingTimeInterval(60); lock.unlock()
    }

    func fetch(_ m: MapType, x: Int, y: Int, z: Int, completion: @escaping (Result) -> Void) {
        let all = m.urls(x: x, y: y, z: z)
        var urls = all.filter { !isBad($0.host ?? "") }
        if urls.isEmpty { urls = all }
        attempt(m, Array(urls.prefix(4)), 0, completion)
    }

    private func attempt(_ m: MapType, _ urls: [URL], _ i: Int, _ completion: @escaping (Result) -> Void) {
        guard i < urls.count else { completion(.failed("All servers failed")); return }
        let url = urls[i]
        var req = URLRequest(url: url)
        req.setValue(m.userAgent ?? Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let r = m.referer { req.setValue(r, forHTTPHeaderField: "Referer") }
        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { completion(.notFound); return }
            if err == nil, code == 200, let data = data, !data.isEmpty,
               let ext = TileStorage.ext(forContentType: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), data: data),
               !(resp?.mimeType ?? "image").hasPrefix("text") {
                self.lock.lock(); self._count += 1; self._bytes += data.count; self.lock.unlock()
                completion(.tile(data, ext))
                return
            }
            // timeouts, throttling (403/429/5xx) or junk: avoid this host for a while, try the next
            self.markBad(url.host ?? "")
            self.attempt(m, urls, i + 1, completion)
        }.resume()
    }
}

// MARK: - Viewer tile provider

final class ImageBox {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

struct TileKey: Hashable {
    let mapId: String
    let x: Int, y: Int, z: Int
    var nsKey: NSString { "\(mapId)/\(z)/\(x)/\(y)" as NSString }
}

/// Supplies decoded tiles to the map views: memory cache -> disk cache -> internet,
/// following the Source mode. All public methods are main-thread only.
final class TileProvider {
    static let shared = TileProvider()

    private let mem = NSCache<NSString, ImageBox>()
    private var inflight = Set<TileKey>()
    private var negative: [TileKey: Date] = [:]
    private var pending: [TileKey] = []
    private var running = 0
    private var wanted: [String: Set<TileKey>] = [:]
    private let io: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()

    var onUpdate: [() -> Void] = []
    private var updateScheduled = false

    var queueCount: Int { pending.count + running }

    private init() {
        mem.totalCostLimit = 512 * 1024 * 1024
        NotificationCenter.default.addObserver(forName: .configChanged, object: nil, queue: .main) { [weak self] _ in
            self?.negative.removeAll()
        }
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func image(_ k: TileKey) -> CGImage? { mem.object(forKey: k.nsKey)?.image }

    func setWanted(_ s: Set<TileKey>, client: String) {
        wanted[client] = s
        let all = allWanted()
        pending.removeAll { k in
            if all.contains(k) { return false }
            inflight.remove(k)
            return true
        }
    }

    private func allWanted() -> Set<TileKey> { wanted.values.reduce(into: Set<TileKey>()) { $0.formUnion($1) } }

    /// Forget everything (cache folder or folder names changed).
    func reset() {
        mem.removeAllObjects()
        negative.removeAll()
        scheduleUpdate()
    }

    /// A tile changed on disk (downloaded or deleted elsewhere).
    func invalidate(_ k: TileKey) {
        if Config.shared.fillZoom >= 0 { FillMapLayer.shared.invalidateSoon() }
        mem.removeObject(forKey: k.nsKey)
        negative.removeValue(forKey: k)
        scheduleUpdate()
    }

    func store(_ img: CGImage, _ k: TileKey) {
        mem.setObject(ImageBox(img), forKey: k.nsKey, cost: img.width * img.height * 4)
        scheduleUpdate()
    }

    func request(_ k: TileKey) {
        if mem.object(forKey: k.nsKey) != nil || inflight.contains(k) { return }
        if let exp = negative[k] {
            if exp > Date() { return }
            negative.removeValue(forKey: k)
        }
        guard let m = MapRegistry.byId(k.mapId) else { return }
        inflight.insert(k)
        let mode = Config.shared.downloadMode
        io.addOperation { [weak self] in
            var img: CGImage?
            var needNet = false
            if mode == .internet {
                needNet = true
            } else {
                switch TileStorage.shared.state(m, k.x, k.y, k.z) {
                case .tile(let u, _):
                    if let d = try? Data(contentsOf: u) { img = Self.decode(d) }
                    if img == nil { needNet = mode != .cache }
                case .tne:
                    needNet = false
                case .none:
                    needNet = mode != .cache
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let img = img {
                    self.inflight.remove(k)
                    self.store(img, k)
                } else if needNet {
                    self.pending.append(k)
                    self.pump()
                } else {
                    self.inflight.remove(k)
                    self.negative[k] = Date().addingTimeInterval(3600)
                }
            }
        }
    }

    private func pump() {
        let all = allWanted()
        while running < Config.shared.maxConnections, let k = pending.popLast() {
            guard all.contains(k), let m = MapRegistry.byId(k.mapId) else { inflight.remove(k); continue }
            running += 1
            TileFetcher.shared.fetch(m, x: k.x, y: k.y, z: k.z) { [weak self] result in
                var img: CGImage?
                var retryAfter: TimeInterval = 30
                switch result {
                case .tile(let data, let ext):
                    TileStorage.shared.write(data, ext: ext, m, k.x, k.y, k.z)
                    img = Self.decode(data)
                case .notFound:
                    TileStorage.shared.writeTNE(m, k.x, k.y, k.z)
                    retryAfter = 3600
                case .failed:
                    break
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.running -= 1
                    self.inflight.remove(k)
                    if let img = img { self.store(img, k) } else { self.negative[k] = Date().addingTimeInterval(retryAfter) }
                    if Config.shared.fillZoom >= 0 { FillMapLayer.shared.invalidateSoon() }
                    self.scheduleUpdate()
                    self.pump()
                }
            }
        }
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self = self else { return }
            self.updateScheduled = false
            self.onUpdate.forEach { $0() }
        }
    }
}
