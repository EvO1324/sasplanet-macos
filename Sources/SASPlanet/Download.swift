import Foundation

struct DownloadOptions: Codable {
    var startPaused = false
    var closeWhenFinished = false
    var tryIfTNE = false
    var tneOnlyBefore: Date? = nil
    var overwrite = false
    var overwriteOnlyIfDifferent = false
    var overwriteOnlyBefore: Date? = nil
    var autosaveMinutes: Int? = nil
    var autosavePrefix = ""
    var parts = 1
}

struct DownloadSessionState: Codable {
    var mapId: String
    var region: Region
    var zooms: [Int]
    var options: DownloadOptions
    var cursor: TileCursor
    var total: Int
    var processed: Int
    var downloaded: Int
    var downloadedBytes: Int
    var elapsed: TimeInterval
}

final class DownloadSession {
    let map: MapType
    let region: Region
    let zooms: [Int]
    var options: DownloadOptions
    let total: Int
    private let iterator: RegionIterator

    private let lock = NSLock()
    private(set) var processed = 0
    private(set) var downloaded = 0
    private(set) var downloadedBytes = 0
    private(set) var failed = 0
    private(set) var lastTile: (x: Int, y: Int, z: Int)?
    private(set) var lastSize = 0
    private var elapsedBefore: TimeInterval = 0
    private var runningSince: Date?
    private(set) var isPaused = false
    private(set) var isFinished = false
    private(set) var isCancelled = false
    private(set) var inFlight = 0
    private var workersAlive = 0
    private var lastAutosave = Date()
    private var logLines: [String] = []
    private let pauseCond = NSCondition()

    var onLog: ((String) -> Void)?
    var onChange: (() -> Void)?

    init(map: MapType, region: Region, zooms: [Int], options: DownloadOptions, resume: DownloadSessionState? = nil) {
        self.map = map
        self.region = region
        self.zooms = zooms.sorted()
        self.options = options
        total = resume?.total ?? zooms.reduce(0) { $0 + region.tileCount($1) }
        iterator = RegionIterator(region: region, zooms: zooms, cursor: resume?.cursor ?? TileCursor())
        if let r = resume {
            processed = r.processed
            downloaded = r.downloaded
            downloadedBytes = r.downloadedBytes
            elapsedBefore = r.elapsed
        }
        isPaused = options.startPaused
    }

    // MARK: control

    func start() {
        let n = max(1, min(options.parts, Config.shared.maxConnections))
        if !isPaused { runningSince = Date() }
        DownloadManager.shared.register(self)
        lock.lock(); workersAlive = n; lock.unlock()
        for _ in 0..<n {
            Thread.detachNewThread { [weak self] in self?.worker() }
        }
        if isPaused { log(SASStr.userStop) }
    }

    func togglePause() { isPaused ? resume() : pause() }

    func pause() {
        guard !isPaused, !isFinished else { return }
        pauseCond.lock(); isPaused = true; pauseCond.unlock()
        lock.lock()
        if let s = runningSince { elapsedBefore += Date().timeIntervalSince(s); runningSince = nil }
        lock.unlock()
        log(SASStr.userStop)
        changed()
    }

    func resume() {
        guard isPaused, !isFinished else { return }
        lock.lock(); runningSince = Date(); lock.unlock()
        pauseCond.lock(); isPaused = false; pauseCond.broadcast(); pauseCond.unlock()
        changed()
    }

    func cancel() {
        isCancelled = true
        pauseCond.lock(); isPaused = false; pauseCond.broadcast(); pauseCond.unlock()
    }

    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsedBefore + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var stats: (processed: Int, downloaded: Int, bytes: Int, inFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        return (processed, downloaded, downloadedBytes, inFlight)
    }

    var log: [String] { lock.lock(); defer { lock.unlock() }; return logLines }

    // MARK: worker

    private func worker() {
        let storage = TileStorage.shared
        while !isCancelled {
            pauseCond.lock()
            while isPaused && !isCancelled { pauseCond.wait() }
            pauseCond.unlock()
            if isCancelled { break }
            guard let t = iterator.next() else { break }
            process(t, storage)
            maybeAutosave()
        }
        lock.lock()
        workersAlive -= 1
        let last = workersAlive == 0
        lock.unlock()
        if last {
            if !isCancelled {
                isFinished = true
                lock.lock()
                if let s = runningSince { elapsedBefore += Date().timeIntervalSince(s); runningSince = nil }
                lock.unlock()
                log(SASStr.processFilesComplete)
            }
            DispatchQueue.main.async { DownloadManager.shared.unregister(self) }
            changed()
        }
    }

    private func process(_ t: (x: Int, y: Int, z: Int), _ storage: TileStorage) {
        let path = storage.displayPath(map, t.x, t.y, t.z)
        log(String(format: SASStr.processedFile, "[z\(t.z + 1)/x\(t.x)/y\(t.y)]\n\(path)"))
        lock.lock(); lastTile = t; lock.unlock()

        var existingSize: Int?
        switch storage.state(map, t.x, t.y, t.z) {
        case .tile(let u, let date):
            if !options.overwrite {
                log(SASStr.fileExistsShort); done(); return
            }
            if let before = options.overwriteOnlyBefore, date >= before {
                log(SASStr.fileBeCreateTime); done(); return
            }
            log(SASStr.loadProcessRepl)
            if options.overwriteOnlyIfDifferent {
                existingSize = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil
            }
        case .tne(let date):
            if !options.tryIfTNE {
                log(SASStr.tneExistsShort); done(); return
            }
            if let before = options.tneOnlyBefore, date >= before {
                log(SASStr.tneBeCreateTime); done(); return
            }
            log(SASStr.loadProcess)
        case .none:
            log(SASStr.loadProcess)
        }

        var attempt = 0
        while !isCancelled {
            attempt += 1
            lock.lock(); inFlight += 1; lock.unlock()
            let result = fetchSync(t)
            lock.lock(); inFlight -= 1; lock.unlock()
            switch result {
            case .tile(let data, let ext):
                if let es = existingSize, es == data.count {
                    log(SASStr.fileBeCreateLen)
                } else {
                    storage.write(data, ext: ext, map, t.x, t.y, t.z)
                    log("(Ok!)")
                }
                lock.lock()
                downloaded += 1
                downloadedBytes += data.count
                lastSize = data.count
                lock.unlock()
                let key = TileKey(mapId: map.id, x: t.x, y: t.y, z: t.z)
                DispatchQueue.main.async { TileProvider.shared.invalidate(key) }
                done()
                return
            case .notFound:
                storage.writeTNE(map, t.x, t.y, t.z)
                log(SASStr.tileNotExists)
                done()
                return
            case .failed:
                if attempt >= 4 {
                    log("Error: " + SASStr.noConnection + " — tile skipped")
                    lock.lock(); failed += 1; lock.unlock()
                    done()
                    return
                }
                let wait = attempt * 5
                log(SASStr.noConnection + "\n" + String(format: SASStr.waitTime, wait))
                for _ in 0..<(wait * 10) where !isCancelled { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }

    private func fetchSync(_ t: (x: Int, y: Int, z: Int)) -> TileFetcher.Result {
        let sem = DispatchSemaphore(value: 0)
        var r: TileFetcher.Result = .failed("")
        TileFetcher.shared.fetch(map, x: t.x, y: t.y, z: t.z) { res in r = res; sem.signal() }
        sem.wait()
        return r
    }

    private func done() {
        lock.lock(); processed += 1; lock.unlock()
        changed()
    }

    private func log(_ s: String) {
        lock.lock()
        logLines.append(s)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 300) }
        lock.unlock()
        onLog?(s)
    }

    private var changeScheduled = false
    private func changed() {
        lock.lock()
        let schedule = !changeScheduled
        changeScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.changeScheduled = false; self.lock.unlock()
            self.onChange?()
        }
    }

    // MARK: sessions

    var state: DownloadSessionState {
        let s = stats
        return DownloadSessionState(mapId: map.id, region: region, zooms: zooms, options: options,
                                    cursor: iterator.snapshot, total: total, processed: s.processed,
                                    downloaded: s.downloaded, downloadedBytes: s.bytes, elapsed: elapsed)
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(state).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> DownloadSessionState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(DownloadSessionState.self, from: Data(contentsOf: url))
    }

    static var sessionsDir: URL {
        Config.shared.cacheURL.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    func autosave() {
        let dir = Self.sessionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm"
        let name = "\(options.autosavePrefix)\(map.folder)_z\(zooms.map { String($0 + 1) }.joined(separator: "-"))_\(f.string(from: Date())).sls.json"
        try? save(to: dir.appendingPathComponent(name))
    }

    private func maybeAutosave() {
        guard let m = options.autosaveMinutes, m > 0 else { return }
        lock.lock()
        let due = Date().timeIntervalSince(lastAutosave) >= Double(m * 60)
        if due { lastAutosave = Date() }
        lock.unlock()
        if due { autosave() }
    }
}

final class DownloadManager {
    static let shared = DownloadManager()
    private(set) var sessions: [DownloadSession] = []

    func register(_ s: DownloadSession) { if !sessions.contains(where: { $0 === s }) { sessions.append(s) } }
    func unregister(_ s: DownloadSession) { sessions.removeAll { $0 === s } }

    var activeRequests: Int { sessions.reduce(0) { $0 + $1.stats.inFlight } }
    var hasRunningSessions: Bool { sessions.contains { !$0.isFinished && !$0.isCancelled } }
    func autosaveAll() { sessions.filter { !$0.isFinished }.forEach { $0.autosave() } }
}

enum SASStr {
    static let fileBeCreateTime = "The tile is newer than the entered age, skipping."
    static let tneBeCreateTime = "The tne is newer than the entered age, skipping."
    static let fileBeCreateLen = "The tile size is equal to the existing one, skipping."
    static let processFilesComplete = "The task is completed!"
    static let loadComplete = "Download completed"
    static let tileNotExists = "Tile is not found!"
    static let noConnection = "Error connecting to server"
    static let waitTime = "Wait %d seconds..."
    static let fileExistsShort = "The tile already exists"
    static let tneExistsShort = "The tne already exists"
    static let files = "files"
    static let paused = "Paused... (%@)"
    static let resume = "Resume"
    static let pause = "Pause"
    static let userStop = "Paused by user..."
    static let downloadingCaption = "%@ Downloading"
    static let loadProcess = "Downloading..."
    static let loadProcessRepl = "Downloading with overwrite..."
    static let processedFile = "Processing tile: %@ ..."
}
