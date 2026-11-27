import AppKit

enum UpdateChecker {
    static let repo = "EvO1324/sasplanet-macos"

    private static let lastCheckKey = "updateLastCheck"
    private static let skipKey = "updateSkipVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    struct Release { let version: String; let name: String; let notes: String; let page: URL }

    static func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SASPlanet-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, code == 200, let data = data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = o["tag_name"] as? String,
                  let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else {
                let msg = code == 404 ? "No releases have been published yet." : (err?.localizedDescription ?? "GitHub returned an unexpected response (\(code)).")
                DispatchQueue.main.async { done(.failure(NSError(domain: "Update", code: code, userInfo: [NSLocalizedDescriptionKey: msg]))) }
                return
            }
            let r = Release(version: tag, name: o["name"] as? String ?? tag, notes: o["body"] as? String ?? "", page: page)
            DispatchQueue.main.async { done(.success(r)) }
        }.resume()
    }

    static func checkAtLaunch(over window: NSWindow?) {
        let d = Config.defaults
        if let last = d.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        fetchLatest { r in
            guard case .success(let rel) = r else { return }
            d.set(Date(), forKey: lastCheckKey)
            guard isNewer(rel.version, than: currentVersion), d.string(forKey: skipKey) != rel.version else { return }
            offer(rel, over: window, manual: false)
        }
    }

    static func checkNow(over window: NSWindow?) {
        fetchLatest { r in
            switch r {
            case .success(let rel):
                Config.defaults.set(Date(), forKey: lastCheckKey)
                if isNewer(rel.version, than: currentVersion) {
                    offer(rel, over: window, manual: true)
                } else {
                    let a = NSAlert()
                    a.messageText = "You're up to date"
                    a.informativeText = "SAS.Planet \(currentVersion) is the latest version."
                    show(a, over: window) { _ in }
                }
            case .failure(let e):
                let a = NSAlert()
                a.messageText = "Couldn't check for updates"
                a.informativeText = e.localizedDescription
                show(a, over: window) { _ in }
            }
        }
    }

    private static func offer(_ rel: Release, over window: NSWindow?, manual: Bool) {
        let a = NSAlert()
        a.messageText = "A new version of SAS.Planet is available"
        var info = "Version \(rel.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is available. You have \(currentVersion)."
        let notes = plain(rel.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\nWhat's new:\n" + String(notes.prefix(600)) + (notes.count > 600 ? "…" : "") }
        info += "\n\nTo update: download the zip, unzip it and drag SASPlanet into Applications, choosing Replace. Your cache and settings are kept."
        a.informativeText = info
        if let i = Icons.image("AppIcon.png") { a.icon = i }
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if !manual { a.addButton(withTitle: "Skip This Version") }
        show(a, over: window) { resp in
            switch resp {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(rel.page)
            case .alertThirdButtonReturn: Config.defaults.set(rel.version, forKey: skipKey)
            default: break
            }
        }
    }

    static func plain(_ md: String) -> String {
        var s = md.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s
    }

    private static func show(_ a: NSAlert, over window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = window, w.attachedSheet == nil { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }
}
