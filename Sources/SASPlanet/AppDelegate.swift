import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!

    func applicationDidFinishLaunching(_ n: Notification) {
        if let icon = Icons.image("AppIcon.png") ?? Icons.image("icon64.png") { NSApp.applicationIconImage = icon }
        NSApp.appearance = NSAppearance(named: .aqua)  // SAS.Planet's classic light look
        main = MainWindowController()
        NSApp.mainMenu = buildMainMenu()
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugHooks.install(self)
        if ProcessInfo.processInfo.environment["SAS_DEBUG"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in DeveloperMessage.showIfNeeded(over: self?.main.window) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DownloadManager.shared.hasRunningSessions {
            let a = NSAlert()
            a.messageText = "Downloads are still running."
            a.informativeText = "Quit anyway? Unfinished downloads can be resumed later from a saved session."
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            DownloadManager.shared.autosaveAll()
        }
        return .terminateNow
    }

    // MARK: - Menu construction

    private typealias Spec = MenuSpec

    private func buildMainMenu() -> NSMenu {
        let bar = NSMenu()

        // Application menu (macOS)
        bar.addItem(sub("SAS.Planet", [
            .item("About SAS.Planet", #selector(showAbout(_:)), target: self),
            .sep,
            .item("Options…", #selector(MainWindowController.showOptions(_:)), key: ","),
            .sep,
            .item("Hide SAS.Planet", #selector(NSApplication.hide(_:)), key: "h"),
            .item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option]),
            .item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .sep,
            .item("Quit SAS.Planet", #selector(NSApplication.terminate(_:)), key: "q"),
        ]))

        // Operations
        bar.addItem(sub("Operations", [
            .disabled("Create Shortcut"),
            .item("Open…", #selector(MainWindowController.openFile(_:)), key: "o", icon: 34),
            .disabled("Open Offline Map…", icon: 34),
            .sep,
            .item("Zoom In", #selector(MainWindowController.zoomIn(_:)), key: pageUp, mods: [], icon: 23),
            .item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), key: pageDown, mods: [], icon: 24),
            .sep,
            .item("Go to…", #selector(MainWindowController.showGoTo(_:)), key: "g", icon: 11),
            .item("Distance Calculation", #selector(MainWindowController.toolDistance(_:)), key: "l", icon: 9),
            .item("Circle Calculation", #selector(MainWindowController.toolCircle(_:)), icon: 65),
            .sep,
            .submenu("Selection Manager", [
                .item("Rectangular Selection", #selector(MainWindowController.selectByRect(_:)), key: "r", mods: [.option], icon: 10),
                .item("Polygonal Selection", #selector(MainWindowController.selectByPolygon(_:)), key: "p", mods: [.option], icon: 13),
                .disabled("Polyline Selection", icon: 21),
                .item("By Coordinates", #selector(MainWindowController.selectByCoordinates(_:)), icon: 12),
                .item("Visible Area", #selector(MainWindowController.selectVisibleArea(_:)), key: "a", mods: [.command, .shift], icon: 20),
                .sep,
                .item("Last Selection", #selector(MainWindowController.selectLast(_:)), key: "b", icon: 44),
                .disabled("Edit Last Selection", icon: 31),
                .item("Load from File", #selector(MainWindowController.loadSelectionFromFile(_:)), icon: 34),
            ]),
            .sep,
            .item("Cache Manager (show cache folder)", #selector(MainWindowController.revealCache(_:))),
            .sep,
            .item("Quit", #selector(NSApplication.terminate(_:)), icon: 29),
        ]))

        // Edit (needed on macOS for copy/paste in text fields)
        bar.addItem(sub("Edit", [
            .item("Undo", Selector(("undo:")), key: "z"),
            .item("Redo", Selector(("redo:")), key: "z", mods: [.command, .shift]),
            .sep,
            .item("Cut", #selector(NSText.cut(_:)), key: "x"),
            .item("Copy", #selector(NSText.copy(_:)), key: "c"),
            .item("Paste", #selector(NSText.paste(_:)), key: "v"),
            .item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
        ]))

        // View
        var tileGrid: [Spec] = [.tagged("No", #selector(MainWindowController.setTileGrid(_:)), tag: -1),
                                .tagged("Current Zoom", #selector(MainWindowController.setTileGrid(_:)), tag: 0), .sep]
        for z in 1...24 { tileGrid.append(.tagged("z\(z)", #selector(MainWindowController.setTileGrid(_:)), tag: z)) }
        var lonLat: [Spec] = [.valued("No", #selector(MainWindowController.setLonLatGrid(_:)), value: 0.0)]
        for (t, v) in [("10°", 10.0), ("5°", 5.0), ("2°", 2.0), ("1°", 1.0), ("0.5°", 0.5), ("0.25°", 0.25), ("0.125°", 0.125)] {
            lonLat.append(.valued(t, #selector(MainWindowController.setLonLatGrid(_:)), value: v))
        }
        lonLat += [.sep, .valued("Auto", #selector(MainWindowController.setLonLatGrid(_:)), value: -1.0)]

        let toolbars: [Spec] = [("Main", "main"), ("Sources", "sources"), ("GPS", "gps"), ("Placemarks", "marks"),
                                ("Search", "search"), ("Time Interval for Cached Tiles Map", "filldates")].map {
            .valued($0.0, #selector(MainWindowController.toggleToolbar(_:)), value: $0.1)
        } + [.disabled("Zoom"), .disabled("Favorites"), .disabled("Search Results"), .disabled("Merge Polygons"),
             .disabled("Elevation Profile"), .disabled("Sensors"), .sep, .disabled("Lock Toolbars")]

        bar.addItem(sub("View", [
            .submenu("Toolbars", toolbars),
            .submenu("Interface", [
                .item("Status Bar", #selector(MainWindowController.toggleStatusBar(_:)), key: "s", mods: [.option]),
                .item("Overview Map", #selector(MainWindowController.toggleMiniMap(_:)), key: "m", mods: [.option]),
                .item("Scale Legend", #selector(MainWindowController.toggleScaleLine(_:)), key: "l", mods: [.option]),
            ]),
            .submenu("Cached Tiles Map", []),
            .submenu("Tile Boundaries", tileGrid),
            .disabledSub("GenShtab Maps Boundaries"),
            .submenu("Lat/Lon Grid", lonLat),
            .disabledSub("Projection"),
            .disabledSub("Distance and Area Calculator"),
            .disabledSub("Maps"),
            .disabledSub("Versions"),
            .sep,
            .item("Full screen", #selector(MainWindowController.toggleFullScreenAction(_:)), key: "f", mods: [.command, .control], icon: 4),
            .item("Hide Window Borders", #selector(MainWindowController.toggleBorders(_:)), key: "f", mods: [.command, .control, .option]),
            .item("Zoom to Cursor", #selector(MainWindowController.toggleZoomToCursor(_:))),
            .item("Use Maps from Lower Zooms", #selector(MainWindowController.toggleUsePrevMap(_:))),
            .item("Use Layers from Lower Zooms", #selector(MainWindowController.toggleUsePrevLayers(_:))),
            .disabled("Use Vector Layers from Lower Zooms"),
            .item("Zoom Animation", #selector(MainWindowController.toggleZoomAnimation(_:))),
            .item("Inertial Movement", #selector(MainWindowController.toggleInertia(_:))),
            .disabled("Azimuth Circle"),
            .item("Night Mode (Color Inversion)", #selector(MainWindowController.toggleNightMode(_:)), key: "n", mods: [.option]),
            .item("Previous Selection", #selector(MainWindowController.togglePrevSelection(_:))),
            .disabled("Full Map Cursor"),
            .disabled("Navigation Arrow"),
            .disabled("Sun Calculator", icon: 66),
            .disabled("Moon Calculator", icon: 75),
            .disabled("Debug Info"),
        ]))

        // Source
        bar.addItem(sub("Source", [
            .item("Cache", #selector(MainWindowController.setSourceCache(_:)), key: "c", mods: [.option], icon: 1),
            .item("Internet", #selector(MainWindowController.setSourceInternet(_:)), key: "i", mods: [.option], icon: 0),
            .item("Internet & Cache", #selector(MainWindowController.setSourceBoth(_:)), key: "b", mods: [.option], icon: 2),
        ]))

        // Maps / Layers (dynamic)
        let maps = NSMenuItem(title: "Maps", action: nil, keyEquivalent: "")
        maps.submenu = NSMenu(title: "Maps")
        maps.submenu?.identifier = NSUserInterfaceItemIdentifier("maps")
        maps.submenu?.delegate = main
        bar.addItem(maps)
        let layers = NSMenuItem(title: "Layers", action: nil, keyEquivalent: "")
        layers.submenu = NSMenu(title: "Layers")
        layers.submenu?.identifier = NSUserInterfaceItemIdentifier("layers")
        layers.submenu?.delegate = main
        bar.addItem(layers)

        bar.addItem(sub("Favorites", [.disabled("Add to Favorites"), .disabled("Manage Favorites")]))

        bar.addItem(sub("Placemarks", [
            .disabled("Add Placemark", icon: 15), .disabled("Add Path", icon: 16), .disabled("Add Polygon", icon: 17), .sep,
            .disabled("Placemark Manager", icon: 18), .disabled("Hide All Placemarks", icon: 19), .sep,
            .disabled("Marks Database"), .disabled("Show Placemark Names"), .disabled("Project New Placemark"),
            .disabled("Merge Polygons"), .sep, .disabled("Icons Settings"),
        ]))

        bar.addItem(sub("GPS", [
            .disabled("Connect to GPS Receiver", icon: 14), .disabled("Show GPS Track", icon: 6),
            .disabled("Follow GPS Position", icon: 5), .disabled("Centered GPS Position"), .sep,
            .disabled("Add Placemark", icon: 15), .disabled("Add Track to Database", icon: 25),
            .disabled("Delete Track", icon: 35), .sep, .disabled("Options", icon: 20),
        ]))

        if let view = bar.items.first(where: { $0.title == "View" })?.submenu,
           let fill = view.items.first(where: { $0.title == "Cached Tiles Map" })?.submenu {
            fill.identifier = NSUserInterfaceItemIdentifier("fill")
            fill.delegate = main
        }
        let layerSettings = NSMenuItem(title: "Layer Settings", action: nil, keyEquivalent: "")
        layerSettings.submenu = NSMenu(title: "Layer Settings")
        layerSettings.submenu?.identifier = NSUserInterfaceItemIdentifier("layerSettings")
        layerSettings.submenu?.delegate = main
        let settings = sub("Settings", [
            .item("Map Settings", #selector(MainWindowController.editMapSettings(_:)), key: "p", mods: [.command, .option]),
            .sep,
            .item("Options", #selector(MainWindowController.showOptions(_:)), icon: 20),
            .disabled("Interface Options"),
            .submenu("Language", [.checked("English")]),
        ])
        settings.submenu?.insertItem(layerSettings, at: 1)
        bar.addItem(settings)

        bar.addItem(sub("Help", [
            .url("Online Help (http://sasgis.org/wikisasiya)", "http://sasgis.org/wikisasiya/", icon: 26),
            .url("Web Site (http://sasgis.org)", "http://sasgis.org/", icon: 26),
            .url("Community (http://sasgis.org/forum)", "http://sasgis.org/forum/", icon: 26),
            .sep,
            .url("Issue Tracker (GitHub)", "https://github.com/sasgis/sas.planet.src/issues", icon: 70),
            .sep,
            .disabled("Pascal Script IDE"),
            .disabled("Command Line Parameters"),
            .sep,
            .disabled("Check for Updates"),
            .sep,
            .item("Keyboard Shortcuts…", #selector(MainWindowController.showShortcuts(_:)), key: "/", mods: [.command, .shift]),
            .item("A Message from the Developer…", #selector(showDeveloperMessage(_:)), target: self, icon: 71),
            .item("About", #selector(showAbout(_:)), target: self, icon: 27),
        ]))
        return bar
    }

    private let pageUp = String(Character(UnicodeScalar(NSPageUpFunctionKey)!))
    private let pageDown = String(Character(UnicodeScalar(NSPageDownFunctionKey)!))

    private func sub(_ title: String, _ items: [Spec]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = make(title, items)
        return it
    }

    private func make(_ title: String, _ items: [Spec]) -> NSMenu {
        let m = NSMenu(title: title)
        for s in items {
            switch s {
            case .sep:
                m.addItem(.separator())
            case let .full(t, sel, key, mods, target, icon):
                let it = NSMenuItem(title: t, action: sel, keyEquivalent: key)
                it.keyEquivalentModifierMask = mods
                it.target = target
                if let i = icon { it.image = Icons.menu(i) }
                m.addItem(it)
            case let .tagged(t, sel, tag):
                let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                it.tag = tag
                m.addItem(it)
            case let .valued(t, sel, value):
                let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                it.representedObject = value
                m.addItem(it)
            case let .disabled(t, icon):
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.isEnabled = false
                if let i = icon { it.image = Icons.menu(i) }
                m.addItem(it)
            case let .disabledSub(t):
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.submenu = NSMenu(title: t)
                it.isEnabled = false
                m.addItem(it)
            case let .checked(t):
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.state = .on
                m.addItem(it)
            case let .submenu(t, children):
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.submenu = make(t, children)
                m.addItem(it)
            case let .url(t, u, icon):
                let it = NSMenuItem(title: t, action: #selector(MainWindowController.openURLItem(_:)), keyEquivalent: "")
                it.representedObject = u
                if let i = icon { it.image = Icons.menu(i) }
                m.addItem(it)
            }
        }
        m.autoenablesItems = true
        return m
    }

    @objc func showDeveloperMessage(_ sender: Any?) { DeveloperMessage.show(over: main.window) }

    @objc func showAbout(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "SAS.Planet for macOS"
        a.informativeText = """
        Native macOS port of SAS.Planet.

        Based on SAS.Planet © 2007–present, SAS.Planet development team (https://github.com/sasgis/sas.planet.src).
        Licensed under the GNU General Public License v3.

        Map data © Google. Bulk downloading may breach the map provider's terms of service.
        """
        if let i = Icons.image("icon64.png") { a.icon = i }
        a.runModal()
    }
}

/// Declarative menu description.
enum MenuSpec {
    case sep
    case full(String, Selector, key: String, mods: NSEvent.ModifierFlags, target: AnyObject?, icon: Int?)
    case tagged(String, Selector, tag: Int)
    case valued(String, Selector, value: Any)
    case disabled(String, icon: Int?)
    case disabledSub(String)
    case checked(String)
    case submenu(String, [MenuSpec])
    case url(String, String, icon: Int?)

    static func item(_ t: String, _ s: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command],
                     target: AnyObject? = nil, icon: Int? = nil) -> MenuSpec {
        .full(t, s, key: key, mods: key.isEmpty ? [] : mods, target: target, icon: icon)
    }
    static func disabled(_ t: String) -> MenuSpec { .disabled(t, icon: nil) }
    static func url(_ t: String, _ u: String) -> MenuSpec { .url(t, u, icon: nil) }
}
