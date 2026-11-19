import AppKit

/// Test hooks, active only when launched with SAS_DEBUG=1.
/// Post a distributed notification "org.sasgis.sasplanet.debug" with object = command string:
///   "snap <path>"                 save a PNG of the main window (or the key/front window)
///   "snapall <dir>"               save every visible window
///   "goto <lat> <lon> <zoom>"     move the map
///   "map <id>" / "layers <id,id>" / "tool move|rect|poly|distance|circle"
///   "select <n> <w> <s> <e>"      make a rectangular selection and open the Selection Manager
///   "click <x> <y>" / "move <x> <y>"   synthesize a click / mouse move on the map (view coordinates)
///   "key <keyCode>"               key press on the map
///   "menu <path>"                 perform a menu item, e.g. "menu View/Interface/Status Bar"
///   "button <window title>|<button title>"  press a button in a window
enum DebugHooks {
    static func install(_ app: AppDelegate) {
        guard ProcessInfo.processInfo.environment["SAS_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.sasgis.sasplanet.debug"), object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            run(cmd, app)
        }
    }

    static func snapshot(_ w: NSWindow, to path: String) {
        // Capture the real composited window (own windows need no screen-recording permission)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return
        }
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func run(_ cmd: String, _ app: AppDelegate) {
        let p = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = p.count > 1 ? p[1] : ""
        let nums = arg.split(separator: " ").compactMap { Double($0) }
        guard let mw = app.main else { return }
        let map = mw.map
        switch p.first ?? "" {
        case "snap":
            if let w = NSApp.keyWindow ?? mw.window { snapshot(w, to: arg) }
        case "snapall":
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                snapshot(w, to: "\(arg)/win\(i)_\(w.title.replacingOccurrences(of: "/", with: "-")).png")
            }
        case "goto" where nums.count >= 3:
            map.setCenter(LonLat(lon: nums[1], lat: nums[0]), zoom: Int(nums[2]) - 1)
        case "smtab":
            let a = arg.split(separator: " ").map(String.init)
            mw.selectionManager.debugSelect(tab: a.first ?? "Download", zoom: a.count > 1 ? Int(a[1]) : nil, format: a.count > 2 ? a[2] : nil)
        case "fill" where nums.count >= 1:
            Config.shared.fillZoom = Int(nums[0]) - 1
            if nums.count > 1 { Config.shared.fillMode = Int(nums[1]) }
        case "keyev":
            // keyev <keyCode> [ctrl] [alt] [shift] [up]
            let a = arg.split(separator: " ").map(String.init)
            guard let code = UInt16(a.first ?? ""), let w = mw.window else { return }
            var f: NSEvent.ModifierFlags = []
            if a.contains("ctrl") { f.insert(.control) }
            if a.contains("alt") { f.insert(.option) }
            if a.contains("shift") { f.insert(.shift) }
            w.makeFirstResponder(map)
            if let e = NSEvent.keyEvent(with: a.contains("up") ? .keyUp : .keyDown, location: .zero, modifierFlags: f,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        case "state":
            let c = Config.shared
            try? "map=\(c.mainMapId) night=\(c.nightMode) status=\(c.statusBarVisible) mini=\(c.miniMapVisible) grid=\(c.lonLatGrid) src=\(c.downloadMode.rawValue) tool=\(map.tool) zoom=\(map.zoom + 1) center=\(map.centerLonLat) sheet=\(mw.window?.attachedSheet != nil) titled=\(mw.window?.styleMask.contains(.titled) ?? false) windows=\(NSApp.windows.map { "\($0.title)|vis=\($0.isVisible)|\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))|lvl=\($0.level.rawValue)" })"
                .write(toFile: arg, atomically: true, encoding: .utf8)
        case "purge": TileProvider.shared.simulateMemoryPressure()
        case "map": Config.shared.mainMapId = arg
        case "layers": Config.shared.layerIds = arg.isEmpty ? [] : arg.split(separator: ",").map(String.init)
        case "tool":
            map.tool = ["move": .move, "rect": .selectRect, "poly": .selectPolygon, "distance": .distance, "circle": .circle][arg] ?? .move
        case "select" where nums.count == 4:
            let poly = MapView.rectPolygon(LonLat(lon: nums[1], lat: nums[0]), LonLat(lon: nums[3], lat: nums[2]))
            map.selection = poly
            mw.selectionManager.show(polygon: poly)
        case "click" where nums.count == 2, "move" where nums.count == 2:
            guard let w = map.window else { return }
            let wp = map.convert(NSPoint(x: nums[0], y: nums[1]), to: nil)
            let types: [NSEvent.EventType] = p[0] == "click" ? [.leftMouseDown, .leftMouseUp] : [.mouseMoved]
            for t in types {
                if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    switch t {
                    case .leftMouseDown: map.mouseDown(with: e)
                    case .leftMouseUp: map.mouseUp(with: e)
                    default: map.mouseMoved(with: e)
                    }
                }
            }
        case "key" where nums.count == 1:
            if let w = map.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                             isARepeat: false, keyCode: UInt16(nums[0])) {
                map.keyDown(with: e)
            }
        case "menu":
            var menu = NSApp.mainMenu
            let parts = arg.split(separator: "/").map(String.init)
            for (i, t) in parts.enumerated() {
                guard let m = menu, let item = m.items.first(where: { $0.title == t }) else { return }
                if i == parts.count - 1 {
                    m.update()
                    m.performActionForItem(at: m.index(of: item))
                } else {
                    if let s = item.submenu { s.delegate?.menuNeedsUpdate?(s) }
                    menu = item.submenu
                }
            }
        case "button":
            let bits = arg.split(separator: "|").map(String.init)
            guard bits.count == 2, let w = NSApp.windows.first(where: { $0.title == bits[0] && $0.isVisible }) ?? NSApp.keyWindow else { return }
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == bits[1] { return b }
                for s in v.subviews { if let b = find(s) { return b } }
                return nil
            }
            if let root = w.contentView, let b = find(root) { b.performClick(nil) }
        default: break
        }
    }
}
