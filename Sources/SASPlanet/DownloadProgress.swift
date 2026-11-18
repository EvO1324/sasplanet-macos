import AppKit

/// Download progress window (frmProgressDownload).
final class DownloadProgressController: NSWindowController, NSWindowDelegate {
    private static var open: [DownloadProgressController] = []

    let session: DownloadSession
    weak var main: MainWindowController?
    private let logView = NSTextView()
    private let progress = NSProgressIndicator()
    private var values: [NSTextField] = []
    private let autoClose = NSButton(checkboxWithTitle: "Close this window once finished", target: nil, action: nil)
    private let pauseBtn = NSButton(title: SASStr.pause, target: nil, action: nil)
    private let status = [NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private var timer: Timer?
    private var lastLogCount = -1

    static func open(session: DownloadSession, main: MainWindowController?) {
        let c = DownloadProgressController(session: session, main: main)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        session.start()
        c.refresh()
    }

    init(session: DownloadSession, main: MainWindowController?) {
        self.session = session
        self.main = main
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Please wait..."
        w.minSize = NSSize(width: 400, height: 380)
        super.init(window: w)
        w.delegate = self
        w.isReleasedWhenClosed = false
        build()
        let offset = CGFloat(Self.open.count * 24)
        if let mf = main?.window?.frame {
            w.setFrameTopLeftPoint(NSPoint(x: mf.midX - 220 + offset, y: mf.maxY - 120 - offset))
        } else { w.center() }
        autoClose.state = session.options.closeWhenFinished ? .on : .off
        session.onChange = { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let c = window?.contentView else { return }
        let W: CGFloat = 440
        // status bar (bottom)
        let sb = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 22))
        sb.autoresizingMask = [.width]
        let sbLine = NSBox(frame: NSRect(x: 0, y: 21, width: W, height: 1)); sbLine.boxType = .separator; sbLine.autoresizingMask = [.width]
        sb.addSubview(sbLine)
        for (i, l) in status.enumerated() {
            l.font = .systemFont(ofSize: 11)
            l.frame = NSRect(x: [6, 70, 260][i], y: 3, width: [60, 185, 170][i], height: 16)
            sb.addSubview(l)
        }
        c.addSubview(sb)

        // bottom toolbar + buttons
        let ops: [(NSImage?, String, () -> Void)] = [
            (Icons.menu(10, size: 18), "Selection Manager", { [weak self] in self?.reopenSelection() }),
            (Icons.menu(43, size: 18), "Fit to Screen", { [weak self] in self?.fit() }),
            (MainWindowController.mapIcon.map { i -> NSImage in let c = i.copy() as! NSImage; c.size = NSSize(width: 18, height: 18); return c },
             session.map.name, { [weak self] in self?.gotoMap() }),
            (Icons.menu(25, size: 18), "Save current session", { [weak self] in self?.saveSession() }),
        ]
        var x: CGFloat = 6
        for (img, tip, act) in ops {
            let b = ToolButton(image: img, tooltip: tip, action: act)
            b.frame = NSRect(x: x, y: 28, width: 30, height: 30)
            c.addSubview(b)
            x += 30
        }
        pauseBtn.target = self; pauseBtn.action = #selector(pausePressed(_:))
        pauseBtn.frame = NSRect(x: W - 184, y: 28, width: 86, height: 30)
        pauseBtn.autoresizingMask = [.minXMargin]
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed(_:)))
        quit.frame = NSRect(x: W - 94, y: 28, width: 86, height: 30)
        quit.autoresizingMask = [.minXMargin]
        c.addSubview(pauseBtn)
        c.addSubview(quit)

        autoClose.frame = NSRect(x: 10, y: 64, width: 300, height: 18)
        autoClose.font = .systemFont(ofSize: 12)
        c.addSubview(autoClose)

        // labels
        let names = ["Process not more than:", "Processed total:", "Downloaded total:", "Approx. to download:", "Time remaining:"]
        var y: CGFloat = 88 + CGFloat(names.count - 1) * 20
        for n in names {
            let l = UI.label(n, NSRect(x: 10, y: y, width: 150, height: 17))
            l.alignment = .right
            let v = UI.label("", NSRect(x: 166, y: y, width: W - 176, height: 17))
            v.autoresizingMask = [.width]
            c.addSubview(l); c.addSubview(v)
            values.append(v)
            y -= 20
        }
        let top = 88 + CGFloat(names.count) * 20 + 4
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.frame = NSRect(x: 8, y: top, width: W - 16, height: 20)
        progress.autoresizingMask = [.width]
        c.addSubview(progress)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: top + 26, width: W - 16, height: 420 - top - 34))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = logView
        c.addSubview(scroll)
    }

    // MARK: refresh

    private static func time(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "~" }
        let t = Int(s)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60, sec = t % 60
        return (d > 0 ? "\(d)d " : "") + String(format: "%02d:%02d:%02d", h, m, sec)
    }

    func refresh() {
        let s = session.stats
        let total = session.total
        let pct = total > 0 ? Int((Double(s.processed) / Double(total) * 100).rounded(.down)) : 100
        let name = session.map.name
        if session.isFinished {
            window?.title = "\(SASStr.loadComplete) \(name)"
        } else if session.isPaused {
            window?.title = String(format: SASStr.paused, "\(pct)%") + " " + name
        } else {
            window?.title = String(format: SASStr.downloadingCaption, "\(pct)%") + " " + name
        }
        pauseBtn.title = session.isPaused ? SASStr.resume : SASStr.pause
        pauseBtn.isEnabled = !session.isFinished
        progress.doubleValue = total > 0 ? Double(s.processed) / Double(total) : 1

        let elapsed = session.elapsed
        let remainingTiles = max(0, total - s.processed)
        let remainingTime = s.processed > 0 ? elapsed / Double(s.processed) * Double(remainingTiles) : .infinity
        let avg = s.downloaded > 0 ? Double(s.bytes) / Double(s.downloaded) : 0
        let ratio = s.processed > 0 ? Double(s.downloaded) / Double(s.processed) : 1
        values[0].stringValue = "\(total) \(SASStr.files)"
        values[1].stringValue = "\(s.processed) \(SASStr.files)"
        values[2].stringValue = "\(s.downloaded) (\(Geo.formatDataSize(kb: Double(s.bytes) / 1024))) \(SASStr.files)"
        values[3].stringValue = s.downloaded > 0 ? Geo.formatDataSize(kb: avg * Double(remainingTiles) * ratio / 1024) : "~"
        values[4].stringValue = session.isFinished ? Self.time(0) : Self.time(remainingTime)

        if let t = session.lastTile {
            status[0].stringValue = "z\(t.z + 1)"
            status[1].stringValue = "X:\(t.x); Y:\(t.y)"
        } else {
            status[0].stringValue = "z\((session.zooms.first ?? 0) + 1)"
        }
        status[2].stringValue = session.lastSize > 0 ? Geo.formatDataSize(kb: Double(session.lastSize) / 1024) : ""

        let lines = session.log
        if lines.count != lastLogCount || lines.last != logView.string.components(separatedBy: "\n").last {
            lastLogCount = lines.count
            logView.string = lines.suffix(200).joined(separator: "\n")
            logView.scrollToEndOfDocument(nil)
        }
        main?.updateStatus()
        if Config.shared.fillZoom >= 0 && !session.isPaused { FillMapLayer.shared.invalidateSoon() }

        if session.isFinished {
            if timer != nil { main?.selectionManager.refreshCoverage() }
            timer?.invalidate(); timer = nil
            if autoClose.state == .on { close() }
        }
    }

    // MARK: actions

    @objc private func pausePressed(_ s: Any?) { session.togglePause(); refresh() }

    @objc private func quitPressed(_ s: Any?) { close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !session.isFinished, !session.isCancelled else { return true }
        let a = NSAlert()
        a.messageText = "Stop this download?"
        a.informativeText = "You can save the session first to resume it later."
        a.addButton(withTitle: "Stop")
        a.addButton(withTitle: "Save Session and Stop")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return saveSessionModal()
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        session.cancel()
        timer?.invalidate()
        session.onChange = nil
        Self.open.removeAll { $0 === self }
        main?.updateStatus()
    }

    private func reopenSelection() {
        main?.map.selection = session.region.polygon
        main?.selectionManager.show(polygon: session.region.polygon)
    }

    private func fit() {
        main?.selectionManager.show(polygon: session.region.polygon)
        main?.selectionManager.fitToScreen()
    }

    private func gotoMap() { Config.shared.mainMapId = session.map.isLayer ? Config.shared.mainMapId : session.map.id }

    @discardableResult
    private func saveSessionModal() -> Bool {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(session.map.folder)_session.sls.json"
        p.directoryURL = DownloadSession.sessionsDir
        try? FileManager.default.createDirectory(at: DownloadSession.sessionsDir, withIntermediateDirectories: true)
        guard p.runModal() == .OK, let u = p.url else { return false }
        do { try session.save(to: u); return true } catch { NSAlert(error: error).runModal(); return false }
    }

    private func saveSession() { saveSessionModal() }
}
