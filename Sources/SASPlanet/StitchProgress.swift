import AppKit

/// Simple progress window for stitching (frm_ProgressSimple).
final class StitchProgressController: NSWindowController, NSWindowDelegate {
    private static var open: [StitchProgressController] = []
    let task: LongTask
    weak var main: MainWindowController?
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Preparing…")
    private let button = NSButton(title: "Cancel", target: nil, action: nil)
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private var started = Date()
    private var finished = false

    static func open(task: LongTask, main: MainWindowController?) {
        let c = StitchProgressController(task: task, main: main)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.start()
    }

    init(task: LongTask, main: MainWindowController?) {
        self.task = task
        self.main = main
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = task.title
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        let c = w.contentView!
        label.frame = NSRect(x: 16, y: 88, width: 428, height: 34)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        bar.frame = NSRect(x: 16, y: 64, width: 428, height: 20)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        button.frame = NSRect(x: 352, y: 14, width: 92, height: 30)
        button.target = self; button.action = #selector(buttonPressed(_:))
        reveal.frame = NSRect(x: 236, y: 14, width: 116, height: 30)
        reveal.target = self; reveal.action = #selector(revealPressed(_:))
        reveal.isHidden = true
        [label, bar, button, reveal].forEach { c.addSubview($0) }
        if let mf = main?.window?.frame { w.setFrameTopLeftPoint(NSPoint(x: mf.midX - 230, y: mf.maxY - 160)) } else { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func start() {
        started = Date()
        task.onProgress = { [weak self] p, msg in
            DispatchQueue.main.async {
                guard let self = self, !self.finished else { return }
                self.bar.doubleValue = p
                let el = Date().timeIntervalSince(self.started)
                let left = p > 0.02 ? el / p * (1 - p) : 0
                self.label.stringValue = "\(msg) — \(Int(p * 100))%" + (left > 0 ? ", about \(Self.fmt(left)) left" : "")
            }
        }
        let t = task
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: Error?
            do { try t.run() } catch { err = error }
            DispatchQueue.main.async { self?.done(err) }
        }
    }

    private static func fmt(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func done(_ err: Error?) {
        finished = true
        bar.doubleValue = 1
        button.title = "Close"
        if let e = err {
            label.stringValue = "Error: \(e.localizedDescription)"
            label.textColor = .systemRed
            window?.title = "Failed"
            return
        }
        if task.cancelled {
            label.stringValue = "Cancelled."
            window?.title = "Cancelled"
            return
        }
        window?.title = "The task is completed!"
        var msg = "Saved \(task.outputs.count) file\(task.outputs.count == 1 ? "" : "s") in \(Self.fmt(Date().timeIntervalSince(started)))."
        if let n = task.note { msg += " " + n }
        label.stringValue = msg
        label.toolTip = msg
        if (task as? StitchTask)?.missingTiles ?? 0 > 0 { label.textColor = .systemOrange }
        reveal.isHidden = task.outputs.isEmpty
    }

    @objc private func buttonPressed(_ s: Any?) {
        if !finished { task.cancel(); button.isEnabled = false; label.stringValue = "Cancelling…" } else { close() }
    }

    @objc private func revealPressed(_ s: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(task.outputs)
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { task.cancel() }
        Self.open.removeAll { $0 === self }
    }
}
