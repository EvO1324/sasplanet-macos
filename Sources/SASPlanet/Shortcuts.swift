import AppKit

enum Shortcuts {
    struct Binding {
        let keyCode: UInt16
        let mods: NSEvent.ModifierFlags
        let label: String
        let title: String
        let action: (MainWindowController) -> Void
        var mapOnly = false // map focus only
    }

    private enum K {
        static let a: UInt16 = 0, s: UInt16 = 1, g: UInt16 = 5, c: UInt16 = 8, b: UInt16 = 11, r: UInt16 = 15, t: UInt16 = 17
        static let v: UInt16 = 9
        static let i: UInt16 = 34, p: UInt16 = 35, l: UInt16 = 37, n: UInt16 = 45, m: UInt16 = 46
        static let f1: UInt16 = 122, f11: UInt16 = 103, pgUp: UInt16 = 116, pgDn: UInt16 = 121
    }

    static let bindings: [Binding] = [
        Binding(keyCode: K.pgUp, mods: [], label: "PgUp", title: "Zoom In") { $0.zoomIn(nil) },
        Binding(keyCode: K.pgDn, mods: [], label: "PgDn", title: "Zoom Out") { $0.zoomOut(nil) },
        Binding(keyCode: K.g, mods: [.control], label: "Ctrl+G", title: "Go to...") { $0.showGoTo(nil) },
        Binding(keyCode: K.l, mods: [.control], label: "Ctrl+L", title: "Distance Calculation") { $0.toolDistance(nil) },
        Binding(keyCode: K.r, mods: [.option], label: "Alt+R", title: "Rectangular Selection") { $0.selectByRect(nil) },
        Binding(keyCode: K.p, mods: [.option], label: "Alt+P", title: "Polygonal Selection") { $0.selectByPolygon(nil) },
        Binding(keyCode: K.a, mods: [.control], label: "Ctrl+A", title: "Visible Area selection") { $0.selectVisibleArea(nil) },
        Binding(keyCode: K.b, mods: [.control], label: "Ctrl+B", title: "Last Selection") { $0.selectLast(nil) },
        Binding(keyCode: K.f11, mods: [], label: "F11", title: "Full screen") { $0.toggleFullScreenAction(nil) },
        Binding(keyCode: K.f11, mods: [.option], label: "Alt+F11", title: "Hide Window Borders") { $0.toggleBorders(nil) },
        Binding(keyCode: K.s, mods: [.option], label: "Alt+S", title: "Status Bar") { $0.toggleStatusBar(nil) },
        Binding(keyCode: K.m, mods: [.option], label: "Alt+M", title: "Overview Map") { $0.toggleMiniMap(nil) },
        Binding(keyCode: K.l, mods: [.option], label: "Alt+L", title: "Scale Legend") { $0.toggleScaleLine(nil) },
        Binding(keyCode: K.n, mods: [.option], label: "Alt+N", title: "Night Mode (Color Inversion)") { $0.toggleNightMode(nil) },
        Binding(keyCode: K.f1, mods: [], label: "F1", title: "Lat/Lon Grid: Auto") { $0.lonLatGridAuto(nil) },
        Binding(keyCode: K.c, mods: [.option], label: "Alt+C", title: "Source: Cache") { $0.setSourceCache(nil) },
        Binding(keyCode: K.i, mods: [.option], label: "Alt+I", title: "Source: Internet") { $0.setSourceInternet(nil) },
        Binding(keyCode: K.b, mods: [.option], label: "Alt+B", title: "Source: Internet & Cache") { $0.setSourceBoth(nil) },
        Binding(keyCode: K.p, mods: [.control, .option], label: "Ctrl+Alt+P", title: "Map Settings") { $0.editMapSettings(nil) },
        Binding(keyCode: K.g, mods: [.control, .option], label: "Ctrl+Alt+G", title: "Connect to GPS Receiver (not available)") { _ in NSSound.beep() },
        Binding(keyCode: K.t, mods: [.control, .option], label: "Ctrl+Alt+T", title: "Show GPS Track (not available)") { _ in NSSound.beep() },
        Binding(keyCode: K.s, mods: [.control, .option], label: "Ctrl+Alt+S", title: "GPS: Add Placemark (not available)") { _ in NSSound.beep() },
        // map hotkeys
        Binding(keyCode: K.g, mods: [], label: "G", title: "Satellite (Google maps)", action: { $0.selectMapId("google.sat") }, mapOnly: true),
        Binding(keyCode: K.m, mods: [], label: "M", title: "Map (Google)", action: { $0.selectMapId("google.map") }, mapOnly: true),
        Binding(keyCode: K.v, mods: [], label: "V", title: "Satellite (Bing)", action: { $0.selectMapId("bing.sat") }, mapOnly: true),
    ]

    private static var monitor: Any?

    static func install(_ mw: MainWindowController) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak mw] e in
            guard let mw = mw, let w = e.window, w === mw.window else { return e }
            let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
            let typing = w.firstResponder is NSText
            for b in bindings where b.keyCode == e.keyCode && b.mods == mods {
                // text field guard
                if typing && !(b.keyCode == K.f1 || b.keyCode == K.f11) { continue }
                if b.mapOnly && !(w.firstResponder is MapView) { continue }
                b.action(mw)
                return nil
            }
            return e
        }
    }

    static let extras: [(String, String)] = [
        ("Delete (⌦, fn+⌫) held + click", "Delete the tile under the cursor from the cache"),
        ("Insert / Help held + click", "Download the tile under the cursor (overwrite)"),
        ("Shift while drawing a rectangle", "Snap to the visible tile boundaries / lat-lon grid"),
        ("Arrow keys", "Move the map (accelerates while held)"),
        ("Esc", "Cancel the current drawing; press again to return to Move"),
        ("Enter", "Finish a polygon selection"),
        ("Backspace (⌫)", "Remove the last point (distance / polygon)"),
        ("Double-click", "Zoom in"),
        ("Mouse wheel / pinch", "Zoom"),
    ]

    static func showList(over window: NSWindow?) {
        var lines = bindings.map { "\($0.label.padding(toLength: 12, withPad: " ", startingAt: 0))  \($0.title)" }
        lines.append("")
        lines += extras.map { "\($0.0):  \($0.1)" }
        let a = NSAlert()
        a.messageText = "Keyboard Shortcuts"
        a.informativeText = "SAS.Planet's shortcuts work as on Windows (Ctrl = ⌃ Control, Alt = ⌥ Option). The menus also show the Mac ⌘ versions."
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        tv.string = lines.joined(separator: "\n")
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isEditable = false
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        a.accessoryView = sv
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}

final class SASWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
