import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation, NSComboBoxDelegate {
    let cfg = Config.shared
    let map: MapView
    let zoomBar = ZoomBarView()
    let statusBar = StatusBarView()
    let miniMap: MiniMapView
    let dock = ToolbarDock()

    private var tbMove: ToolButton!
    private var tbRect: ToolButton!
    private var tbCalc: ToolButton!
    private var tbCircle: ToolButton!
    private var tbSource: ToolButton!
    private var tbMap: ToolButton!
    private var tbLayers: ToolButton!
    private var tbFullScreen: ToolButton!
    private var tbMapZap: ToolButton!
    private var tbGeocoder: ToolButton!
    private let searchBox = NSComboBox()
    private let fillFrom = NSDatePicker()
    private let fillTo = NSDatePicker()

    private var geocoder = "OSM"
    private var saveTimer: Timer?
    private var miniMapConstraints: [NSLayoutConstraint] = []
    private var statusConstraint: NSLayoutConstraint!

    lazy var selectionManager = SelectionManagerController(main: self)

    init() {
        let m = MapRegistry.byId(Config.shared.mainMapId) ?? MapRegistry.maps.first { $0.id == "google.sat" }!
        map = MapView(map: m)
        miniMap = MiniMapView(main: map)
        let w = SASWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "SAS.Planet"
        w.minSize = NSSize(width: 640, height: 420)
        w.collectionBehavior = [.fullScreenPrimary]
        super.init(window: w)
        w.delegate = self
        buildLayout()
        restoreState()
        if !w.setFrameUsingName("SASMainWindow") { w.center() }
        w.setFrameAutosaveName("SASMainWindow")
        NotificationCenter.default.addObserver(forName: .configChanged, object: nil, queue: .main) { [weak self] _ in self?.applyConfig() }
        applyConfig()
        Shortcuts.install(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        buildToolbars()

        let mapContainer = NSView()
        for v in [dock, zoomBar, mapContainer, map, miniMap, statusBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(dock)
        content.addSubview(zoomBar)
        content.addSubview(mapContainer)
        mapContainer.addSubview(map)
        mapContainer.addSubview(miniMap)
        mapContainer.addSubview(statusBar)

        statusConstraint = statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height)
        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: content.topAnchor),
            dock.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            zoomBar.topAnchor.constraint(equalTo: dock.bottomAnchor),
            zoomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            zoomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            zoomBar.widthAnchor.constraint(equalToConstant: ZoomBarView.width),

            mapContainer.topAnchor.constraint(equalTo: dock.bottomAnchor),
            mapContainer.leadingAnchor.constraint(equalTo: zoomBar.trailingAnchor),
            mapContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mapContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            map.topAnchor.constraint(equalTo: mapContainer.topAnchor),
            map.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            map.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor),
            statusConstraint,

            miniMap.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            miniMap.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            miniMap.widthAnchor.constraint(equalToConstant: MiniMapView.size.width),
            miniMap.heightAnchor.constraint(equalToConstant: MiniMapView.size.height),
        ])

        map.onViewChanged = { [weak self] in self?.viewChanged() }
        map.onMouseMoved = { [weak self] in self?.updateStatus() }
        map.onToolChanged = { [weak self] in self?.updateToolButtons() }
        map.onSelectionFinished = { [weak self] poly in
            guard let self = self else { return }
            self.map.tool = .move
            self.selectionManager.show(polygon: poly)
        }
        zoomBar.onZoom = { [weak self] z in self?.map.setZoom(z) }
        TileProvider.shared.onUpdate.append { [weak self] in self?.updateStatus() }
    }

    private func buildToolbars() {
        // main toolbar
        tbMove = ToolButton(image: Icons.panel(8), tooltip: "Move") { [weak self] in self?.map.tool = .move }
        tbRect = ToolButton(image: Icons.panel(10), tooltip: "Rectangular Selection (⌥R)", style: .split) { [weak self] in self?.map.tool = .selectRect }
        tbRect.menuProvider = { [weak self] in self?.selectionMenu() ?? NSMenu() }
        tbCalc = ToolButton(image: Icons.panel(9), tooltip: "Distance calculation (⌘L)") { [weak self] in self?.map.tool = .distance }
        tbCircle = ToolButton(image: Icons.panel(24), tooltip: "Circle Calculation") { [weak self] in self?.map.tool = .circle }
        tbMapZap = ToolButton(image: Icons.panel(7), tooltip: "Cached tiles map", style: .dropdown)
        tbMapZap.menuProvider = { [weak self] in self?.cachedTilesMenu() ?? NSMenu() }
        let tbGoTo = ToolButton(image: Icons.panel(11), tooltip: "Go to (⌘G)") { [weak self] in self?.showGoTo(nil) }
        tbFullScreen = ToolButton(image: Icons.panel(4), tooltip: "Full screen (⌃⌘F)") { [weak self] in self?.window?.toggleFullScreen(nil) }
        let mainTB = ToolbarGroup(key: "main", title: "Main", items: [tbMove, tbRect, tbCalc, tbCircle, ToolSeparator(), tbMapZap, tbGoTo, ToolSeparator(), tbFullScreen])

        // sources toolbar
        tbSource = ToolButton(image: Icons.panel(0), tooltip: "Select data source", style: .dropdown)
        tbSource.menuProvider = { [weak self] in self?.sourceMenu() ?? NSMenu() }
        tbMap = ToolButton(image: Self.mapIcon, title: map.mainMap.name, tooltip: "Selected basemap", style: .dropdown)
        tbMap.menuProvider = { [weak self] in
            let m = NSMenu(); self?.fillMapsMenu(m); return m
        }
        tbLayers = ToolButton(image: Icons.panel(3), tooltip: "Select overlay layers", style: .dropdown)
        tbLayers.menuProvider = { [weak self] in
            let m = NSMenu(); self?.fillLayersMenu(m); return m
        }
        let srcTB = ToolbarGroup(key: "sources", title: "Sources", items: [tbSource, tbMap, tbLayers])

        // TODO: placemarks.... buttons are just placeholders for now ewbgjfkehrsbgsbgjyhs
        let marks = [(15, "Add Placemark"), (16, "Add Path"), (17, "Add Polygon"), (18, "Placemark Manager"), (19, "Hide All Placemarks")].map { idx, tip -> ToolButton in
            let b = ToolButton(image: Icons.panel(idx), tooltip: tip + " (not available yet)")
            b.isEnabled = false
            return b
        }
        let marksTB = ToolbarGroup(key: "marks", title: "Placemarks", items: marks)

        // TODO gps (prob CoreLocation + serial for external receivers?) Probably totally useless and I rlly can't be bothered.
        let gps = [(14, "Connect to GPS receiver", ToolButton.Style.button), (6, "Show GPS track", .split), (5, "Follow GPS Position", .split)].map { idx, tip, st -> ToolButton in
            let b = ToolButton(image: Icons.panel(idx), tooltip: tip + " (not available yet)", style: st)
            b.isEnabled = false
            return b
        }
        let gpsTB = ToolbarGroup(key: "gps", title: "GPS", items: gps)

        // search toolbar
        tbGeocoder = ToolButton(image: nil, title: geocoder, tooltip: "Search engine", style: .dropdown)
        tbGeocoder.menuProvider = { [weak self] in self?.geocoderMenu() ?? NSMenu() }
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        searchBox.widthAnchor.constraint(equalToConstant: 250).isActive = true
        searchBox.placeholderString = "Place name or coordinates"
        searchBox.completes = false
        searchBox.numberOfVisibleItems = 12
        searchBox.target = self
        searchBox.action = #selector(searchBoxAction(_:))
        searchBox.delegate = self
        let tbSearch = ToolButton(image: Icons.menu(74, size: 18), tooltip: "Search") { [weak self] in self?.doSearch() }
        let searchTB = ToolbarGroup(key: "search", title: "Search", items: [tbGeocoder, searchBox, tbSearch])

        // fill dates
        for (p, d) in [(fillFrom, cfg.fillFrom), (fillTo, cfg.fillTo)] {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .yearMonthDay
            p.dateValue = d
            p.controlSize = .small
            p.toolTip = "Time interval for the Cached Tiles Map (View > Cached Tiles Map > Within Time Interval)"
            p.target = self
            p.action = #selector(fillDatesChanged(_:))
        }
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 12); return l
        }
        let fillTB = ToolbarGroup(key: "filldates", title: "Time Interval for Cached Tiles Map",
                                  items: [label("Fill From"), fillFrom, label("To"), fillTo])

        dock.addRow([searchTB, fillTB])
        dock.addRow([mainTB, srcTB, marksTB, gpsTB])
    }

    static var mapIcon: NSImage? {
        guard let i = Icons.mapIcon?.copy() as? NSImage else { return nil }
        i.size = NSSize(width: 24, height: 24)
        return i
    }

    // MARK: - State

    private func restoreState() {
        map.restore(LonLat(lon: cfg.centerLon, lat: cfg.centerLat), zoom: cfg.zoom)
        map.layers = cfg.layerIds.compactMap { MapRegistry.byId($0) }.filter { $0.isLayer }
        zoomBar.zoom = map.zoom
    }

    private func saveState() {
        let c = map.centerLonLat
        cfg.centerLat = c.lat
        cfg.centerLon = c.lon
        cfg.zoom = map.zoom
    }

    private func applyConfig() {
        if let m = MapRegistry.byId(cfg.mainMapId), m != map.mainMap { map.mainMap = m }
        let layers = cfg.layerIds.compactMap { MapRegistry.byId($0) }.filter { $0.isLayer }
        if layers.map(\.id) != map.layers.map(\.id) { map.layers = layers }
        tbMap.title = map.mainMap.name
        tbSource.image = Icons.panel([DownloadMode.internet: 0, .cache: 1, .cacheInternet: 2][cfg.downloadMode] ?? 2)
        statusBar.isHidden = !cfg.statusBarVisible
        statusConstraint.constant = cfg.statusBarVisible ? StatusBarView.height : 0
        map.bottomInset = cfg.statusBarVisible ? StatusBarView.height : 0
        miniMap.isHidden = !cfg.miniMapVisible
        if map.nightMode != cfg.nightMode { map.nightMode = cfg.nightMode }
        dock.applyVisibility(hidden: cfg.hiddenToolbars)
        tbMapZap.isChecked = cfg.fillZoom >= 0
        map.needsDisplay = true
        miniMap.needsDisplay = true
        updateStatus()
    }

    private func viewChanged() {
        zoomBar.zoom = map.zoom
        miniMap.needsDisplay = true
        updateStatus()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.saveState() }
    }

    func updateStatus() {
        guard cfg.statusBarVisible else { return }
        let ll = map.cursorLonLat
        let z = map.zoom
        let d = TileFetcher.shared.downloaded
        statusBar.items = [
            "z\(z + 1)",
            Geo.formatLonLat(ll),
            Geo.formatMetersPerPixel(Geo.metersPerPixel(lat: ll.lat, z: z)),
            "Downloaded \(d.count) (\(Geo.formatDataSize(kb: Double(d.bytes) / 1024)))",
            "Queue \(TileProvider.shared.queueCount + DownloadManager.shared.activeRequests)",
        ]
        let p = Geo.pixel(ll, z)
        let n = (1 << z) - 1
        let tx = max(0, min(n, Int(p.x / 256))), ty = max(0, min(n, Int(p.y / 256)))
        statusBar.filePath = TileStorage.shared.displayPath(map.mainMap, tx, ty, z)
    }

    private func updateToolButtons() {
        tbMove.isChecked = map.tool == .move
        tbRect.isChecked = map.tool == .selectRect || map.tool == .selectPolygon
        tbRect.image = Icons.panel(map.tool == .selectPolygon ? 13 : 10)
        tbCalc.isChecked = map.tool == .distance
        tbCircle.isChecked = map.tool == .circle
    }

    func windowWillClose(_ notification: Notification) { saveState() }
    func windowDidEnterFullScreen(_ notification: Notification) { tbFullScreen.isChecked = true }
    func windowDidExitFullScreen(_ notification: Notification) { tbFullScreen.isChecked = false }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateToolButtons()
        window?.makeFirstResponder(map)
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier?.rawValue {
        case "maps": fillMapsMenu(menu)
        case "layers": fillLayersMenu(menu)
        case "layerSettings": fillLayerSettingsMenu(menu)
        case "fill": fillCachedTilesMenu(menu)
        default: break
        }
    }

    func fillMapsMenu(_ menu: NSMenu) {
        for g in MapRegistry.groups {
            let maps = MapRegistry.maps.filter { $0.group == g }
            guard !maps.isEmpty else { continue }
            let sub = NSMenu(title: g)
            for m in maps {
                let hot = Shortcuts.bindings.first { $0.mapOnly && $0.title == m.name }?.label
                let it = NSMenuItem(title: m.name + (hot.map { "\t\($0)" } ?? ""), action: #selector(selectMap(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = m.id
                it.state = m.id == map.mainMap.id ? .on : .off
                sub.addItem(it)
            }
            let gi = NSMenuItem(title: g, action: nil, keyEquivalent: "")
            gi.submenu = sub
            if maps.contains(where: { $0.id == map.mainMap.id }) { gi.state = .mixed }
            menu.addItem(gi)
        }
    }

    func fillLayersMenu(_ menu: NSMenu) {
        let hide = NSMenuItem(title: "Hide All", action: #selector(hideAllLayers(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        for g in MapRegistry.groups {
            let layers = MapRegistry.layers.filter { $0.group == g }
            guard !layers.isEmpty else { continue }
            let sub = NSMenu(title: g)
            for l in layers {
                let it = NSMenuItem(title: l.name, action: #selector(toggleLayer(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = l.id
                it.state = cfg.layerIds.contains(l.id) ? .on : .off
                sub.addItem(it)
            }
            let gi = NSMenuItem(title: g, action: nil, keyEquivalent: "")
            gi.submenu = sub
            menu.addItem(gi)
        }
    }

    func fillLayerSettingsMenu(_ menu: NSMenu) {
        for l in MapRegistry.layers {
            let it = NSMenuItem(title: l.name, action: #selector(editLayerSettings(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.id
            menu.addItem(it)
        }
    }

    private func selectionMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ icon: Int, _ sel: Selector?) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = sel == nil ? nil : self
            it.image = Icons.menu(icon)
            m.addItem(it)
        }
        add("Rectangular Selection", 10, #selector(selectByRect(_:)))
        add("Polygonal Selection", 13, #selector(selectByPolygon(_:)))
        add("Polyline Selection", 21, nil)
        add("By Coordinates", 12, #selector(selectByCoordinates(_:)))
        add("Visible Area", 20, #selector(selectVisibleArea(_:)))
        m.addItem(.separator())
        add("Last Selection", 44, #selector(selectLast(_:)))
        add("Edit Last Selection", 31, nil)
        add("Load from File", 34, #selector(loadSelectionFromFile(_:)))
        return m
    }

    private func sourceMenu() -> NSMenu {
        let m = NSMenu()
        for (t, icon, sel, mode) in [("Cache", 1, #selector(setSourceCache(_:)), DownloadMode.cache),
                                     ("Internet", 0, #selector(setSourceInternet(_:)), .internet),
                                     ("Internet & Cache", 2, #selector(setSourceBoth(_:)), .cacheInternet)] {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            it.image = Icons.menu(icon)
            it.state = cfg.downloadMode == mode ? .on : .off
            m.addItem(it)
        }
        return m
    }

    private func cachedTilesMenu() -> NSMenu {
        let m = NSMenu()
        fillCachedTilesMenu(m)
        return m
    }

    func fillCachedTilesMenu(_ menu: NSMenu) {
        func item(_ t: String, _ sel: Selector, tag: Int = 0, obj: Any? = nil, on: Bool) -> NSMenuItem {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self; it.tag = tag; it.representedObject = obj
            it.state = on ? .on : .off
            return it
        }
        let showFor = NSMenu(title: "Show for...")
        showFor.addItem(item("Displayed Main Map", #selector(setFillMap(_:)), obj: "", on: cfg.fillMapId.isEmpty))
        showFor.addItem(.separator())
        for m in MapRegistry.all { showFor.addItem(item(m.name, #selector(setFillMap(_:)), obj: m.id, on: cfg.fillMapId == m.id)) }
        let sf = NSMenuItem(title: "Show for...", action: nil, keyEquivalent: "")
        sf.submenu = showFor
        menu.addItem(sf)
        menu.addItem(.separator())
        menu.addItem(item("Hide", #selector(setFillZoom(_:)), tag: -1, on: cfg.fillZoom < 0))
        let zm = NSMenu(title: "Zoom")
        for z in 0..<24 {
            let it = item("z\(z + 1)", #selector(setFillZoom(_:)), tag: z, on: cfg.fillZoom == z)
            if z - map.zoom > 7 { it.title += "  (zoom in to see)" }
            zm.addItem(it)
        }
        let zi = NSMenuItem(title: cfg.fillZoom >= 0 ? "Show for Zoom: z\(cfg.fillZoom + 1)" : "Show for Zoom", action: nil, keyEquivalent: "")
        zi.submenu = zm
        menu.addItem(zi)
        menu.addItem(.separator())
        menu.addItem(item("Mark Nonexistent Tiles", #selector(setFillMode(_:)), tag: 0, on: cfg.fillMode == 0))
        menu.addItem(item("Mark Existing Tiles", #selector(setFillMode(_:)), tag: 1, on: cfg.fillMode == 1))
        menu.addItem(item("Use Age Gradient", #selector(setFillMode(_:)), tag: 2, on: cfg.fillMode == 2))
        menu.addItem(.separator())
        menu.addItem(item("Within Time Interval", #selector(toggleFillFilter(_:)), on: cfg.fillFilter))
    }

    @objc func setFillZoom(_ sender: NSMenuItem) { cfg.fillZoom = sender.tag; FillMapLayer.shared.invalidate() }
    @objc func setFillMode(_ sender: NSMenuItem) { cfg.fillMode = sender.tag }
    @objc func setFillMap(_ sender: NSMenuItem) { cfg.fillMapId = sender.representedObject as? String ?? "" }
    @objc func toggleFillFilter(_ sender: Any?) { cfg.fillFilter.toggle() }
    @objc func fillDatesChanged(_ sender: NSDatePicker) {
        if sender === fillFrom { cfg.fillFrom = sender.dateValue } else { cfg.fillTo = sender.dateValue }
    }

    private func geocoderMenu() -> NSMenu {
        let m = NSMenu()
        for (t, key) in [("OSM (Nominatim)", "OSM"), ("Coordinates", "Coordinates")] {
            let it = NSMenuItem(title: t, action: #selector(selectGeocoder(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = geocoder == key ? .on : .off
            m.addItem(it)
        }
        return m
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectByRect(_:)): item.state = map.tool == .selectRect ? .on : .off
        case #selector(selectByPolygon(_:)): item.state = map.tool == .selectPolygon ? .on : .off
        case #selector(toolDistance(_:)): item.state = map.tool == .distance ? .on : .off
        case #selector(toolCircle(_:)): item.state = map.tool == .circle ? .on : .off
        case #selector(toolMove(_:)): item.state = map.tool == .move ? .on : .off
        case #selector(selectLast(_:)): return map.selection != nil
        case #selector(toggleToolbar(_:)):
            item.state = cfg.hiddenToolbars.contains(item.representedObject as? String ?? "") ? .off : .on
        case #selector(toggleStatusBar(_:)): item.state = cfg.statusBarVisible ? .on : .off
        case #selector(toggleMiniMap(_:)): item.state = cfg.miniMapVisible ? .on : .off
        case #selector(toggleScaleLine(_:)): item.state = cfg.scaleLineVisible ? .on : .off
        case #selector(setTileGrid(_:)): item.state = cfg.tileGridZoom == item.tag ? .on : .off
        case #selector(setLonLatGrid(_:)): item.state = cfg.lonLatGrid == (item.representedObject as? Double ?? 0) ? .on : .off
        case #selector(toggleZoomToCursor(_:)): item.state = cfg.zoomToCursor ? .on : .off
        case #selector(toggleUsePrevMap(_:)): item.state = cfg.usePrevForMap ? .on : .off
        case #selector(toggleUsePrevLayers(_:)): item.state = cfg.usePrevForLayers ? .on : .off
        case #selector(toggleZoomAnimation(_:)): item.state = cfg.zoomAnimation ? .on : .off
        case #selector(toggleInertia(_:)): item.state = cfg.inertialMovement ? .on : .off
        case #selector(toggleNightMode(_:)): item.state = cfg.nightMode ? .on : .off
        case #selector(togglePrevSelection(_:)): item.state = map.showSelection ? .on : .off
        case #selector(toggleBorders(_:)): item.state = window?.styleMask.contains(.titled) == false ? .on : .off
        case #selector(toggleFullScreenAction(_:)):
            item.state = window?.styleMask.contains(.fullScreen) == true ? .on : .off
        case #selector(setSourceCache(_:)): item.state = cfg.downloadMode == .cache ? .on : .off
        case #selector(setSourceInternet(_:)): item.state = cfg.downloadMode == .internet ? .on : .off
        case #selector(setSourceBoth(_:)): item.state = cfg.downloadMode == .cacheInternet ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Actions: Operations

    @objc func zoomIn(_ sender: Any?) { map.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { map.zoomOut() }
    @objc func toolMove(_ sender: Any?) { map.tool = .move }
    @objc func toolDistance(_ sender: Any?) { map.tool = .distance }
    @objc func toolCircle(_ sender: Any?) { map.tool = .circle }
    @objc func selectByRect(_ sender: Any?) { map.tool = .selectRect }
    @objc func selectByPolygon(_ sender: Any?) { map.tool = .selectPolygon }

    @objc func selectVisibleArea(_ sender: Any?) {
        let r = map.visibleLonLatRect
        let poly = MapView.rectPolygon(LonLat(lon: r.w, lat: r.n), LonLat(lon: r.e, lat: r.s))
        map.selection = poly
        selectionManager.show(polygon: poly)
    }

    @objc func selectLast(_ sender: Any?) {
        guard let s = map.selection else { return }
        selectionManager.show(polygon: s)
    }

    @objc func selectByCoordinates(_ sender: Any?) {
        guard let w = window else { return }
        let r = map.visibleLonLatRect
        let a = NSAlert()
        a.messageText = "Selection by Coordinates"
        a.informativeText = "Enter the top-left and bottom-right corners (decimal degrees or degrees/minutes/seconds)."
        let tl = NSTextField(string: String(format: "%.6f, %.6f", r.n, r.w))
        let br = NSTextField(string: String(format: "%.6f, %.6f", r.s, r.e))
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Top-left (lat, lon):"), tl],
                                      [NSTextField(labelWithString: "Bottom-right (lat, lon):"), br]])
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 56)
        tl.widthAnchor.constraint(equalToConstant: 250).isActive = true
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            guard let p1 = Geo.parseLonLat(tl.stringValue), let p2 = Geo.parseLonLat(br.stringValue) else { NSSound.beep(); return }
            let poly = MapView.rectPolygon(p1, p2)
            self.map.selection = poly
            self.selectionManager.show(polygon: poly)
        }
    }

    @objc func showGoTo(_ sender: Any?) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Go to"
        a.informativeText = "Coordinates, e.g. 36.8312, -2.4634 or N36°49'52\" W2°27'48\""
        let field = NSTextField(string: "")
        field.placeholderString = "Latitude, Longitude"
        let c = map.centerLonLat
        field.stringValue = String(format: "%.6f, %.6f", c.lat, c.lon)
        let zoomPop = NSPopUpButton()
        for z in 1...24 { zoomPop.addItem(withTitle: "z\(z)") }
        zoomPop.selectItem(at: map.zoom)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Coordinates:"), field],
                                      [NSTextField(labelWithString: "Zoom:"), zoomPop]])
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 56)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        a.accessoryView = grid
        a.addButton(withTitle: "Go to")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            guard let ll = Geo.parseLonLat(field.stringValue) else { NSSound.beep(); return }
            self.map.setCenter(ll, zoom: zoomPop.indexOfSelectedItem)
            self.map.searchMarker = ll
        }
    }

    @objc func openFile(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowExtensions(["json", "hlg"])
        p.directoryURL = DownloadSession.sessionsDir
        guard p.runModal() == .OK, let u = p.url else { return }
        if u.pathExtension.lowercased() == "hlg" { openHLG(u); return }
        do {
            let st = try DownloadSession.load(from: u)
            guard let m = MapRegistry.byId(st.mapId) else { throw NSError(domain: "SAS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown map \(st.mapId)"]) }
            var o = st.options
            o.startPaused = true
            let s = DownloadSession(map: m, region: st.region, zooms: st.zooms, options: o, resume: st)
            map.selection = st.region.polygon
            DownloadProgressController.open(session: s, main: self)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func loadSelectionFromFile(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowExtensions(["hlg"])
        guard p.runModal() == .OK, let u = p.url else { return }
        openHLG(u)
    }

    private func openHLG(_ u: URL) {
        guard let poly = HLG.read(u) else { NSSound.beep(); return }
        map.selection = poly
        selectionManager.show(polygon: poly)
        selectionManager.fitToScreen()
    }

    // MARK: - Actions: View

    @objc func toggleToolbar(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var h = cfg.hiddenToolbars
        if h.contains(key) { h.remove(key) } else { h.insert(key) }
        cfg.hiddenToolbars = h
    }
    @objc func toggleStatusBar(_ sender: Any?) { cfg.statusBarVisible.toggle() }
    @objc func toggleMiniMap(_ sender: Any?) { cfg.miniMapVisible.toggle() }
    @objc func toggleScaleLine(_ sender: Any?) { cfg.scaleLineVisible.toggle() }
    @objc func setTileGrid(_ sender: NSMenuItem) { cfg.tileGridZoom = sender.tag }
    @objc func setLonLatGrid(_ sender: NSMenuItem) { cfg.lonLatGrid = sender.representedObject as? Double ?? 0 }
    @objc func toggleZoomToCursor(_ sender: Any?) { cfg.zoomToCursor.toggle() }
    @objc func toggleUsePrevMap(_ sender: Any?) { cfg.usePrevForMap.toggle() }
    @objc func toggleUsePrevLayers(_ sender: Any?) { cfg.usePrevForLayers.toggle() }
    @objc func toggleZoomAnimation(_ sender: Any?) { cfg.zoomAnimation.toggle() }
    @objc func toggleInertia(_ sender: Any?) { cfg.inertialMovement.toggle() }
    @objc func toggleNightMode(_ sender: Any?) { cfg.nightMode.toggle() }
    @objc func togglePrevSelection(_ sender: Any?) { map.showSelection.toggle() }
    @objc func toggleFullScreenAction(_ sender: Any?) { window?.toggleFullScreen(sender) }

    @objc func toggleBorders(_ sender: Any?) {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let frame = w.frame
        if w.styleMask.contains(.titled) {
            w.styleMask = [.borderless, .resizable]
        } else {
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "SAS.Planet"
        }
        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(map)
    }

    @objc func lonLatGridAuto(_ sender: Any?) { cfg.lonLatGrid = cfg.lonLatGrid == -1 ? 0 : -1 }

    func selectMapId(_ id: String) { if MapRegistry.byId(id) != nil { cfg.mainMapId = id } }

    @objc func showShortcuts(_ sender: Any?) { Shortcuts.showList(over: window) }

    // MARK: - Actions: Source / Maps / Layers

    @objc func setSourceCache(_ sender: Any?) { cfg.downloadMode = .cache }
    @objc func setSourceInternet(_ sender: Any?) { cfg.downloadMode = .internet }
    @objc func setSourceBoth(_ sender: Any?) { cfg.downloadMode = .cacheInternet }

    @objc func selectMap(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        cfg.mainMapId = id
    }

    @objc func toggleLayer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var l = cfg.layerIds
        if let i = l.firstIndex(of: id) { l.remove(at: i) } else { l.append(id) }
        cfg.layerIds = l
    }

    @objc func hideAllLayers(_ sender: Any?) { cfg.layerIds = [] }

    // MARK: - Actions: Settings

    @objc func editMapSettings(_ sender: Any?) { editSettings(for: map.mainMap) }

    @objc func editLayerSettings(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let l = MapRegistry.byId(id) else { return }
        editSettings(for: l)
    }

    private func editSettings(for m: MapType) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Map Settings: \(m.name)"
        a.informativeText = "Folder name inside the cache (SAS.Planet \"NameInCache\"). Set this to match the folder your existing SAS.Planet cache uses for this map."
        let folder = NSTextField(string: m.folder)
        let url = NSTextField(labelWithString: m.urls(x: 0, y: 0, z: 0).first?.absoluteString.replacingOccurrences(of: "x=0&y=0&z=0", with: "x={x}&y={y}&z={z}") ?? "")
        url.font = .systemFont(ofSize: 11)
        url.textColor = .secondaryLabelColor
        url.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: Config.shared.cacheURL.appendingPathComponent(m.folder).path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Cache folder name:"), folder],
                                      [NSTextField(labelWithString: "Full path:"), path],
                                      [NSTextField(labelWithString: "URL:"), url]])
        grid.frame = NSRect(x: 0, y: 0, width: 460, height: 80)
        folder.widthAnchor.constraint(equalToConstant: 300).isActive = true
        path.widthAnchor.constraint(equalToConstant: 300).isActive = true
        url.widthAnchor.constraint(equalToConstant: 300).isActive = true
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Reset to Default")
        a.beginSheetModal(for: w) { resp in
            var o = Config.shared.folderOverrides
            switch resp {
            case .alertFirstButtonReturn:
                let v = folder.stringValue.trimmingCharacters(in: .whitespaces)
                if v.isEmpty || v == m.defaultFolder { o.removeValue(forKey: m.id) } else { o[m.id] = v }
            case .alertThirdButtonReturn:
                o.removeValue(forKey: m.id)
            default: return
            }
            Config.shared.folderOverrides = o
            TileProvider.shared.reset()
        }
    }

    @objc func showOptions(_ sender: Any?) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Options"
        let path = NSTextField(string: cfg.cacheURL.path)
        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        let chooser = FolderChooser(field: path)
        choose.target = chooser
        choose.action = #selector(FolderChooser.choose(_:))
        let conn = NSPopUpButton()
        for i in 1...8 { conn.addItem(withTitle: "\(i)") }
        conn.selectItem(at: cfg.maxConnections - 1)
        let row = NSStackView(views: [path, choose])
        path.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Cache folder:"), row],
                                      [NSTextField(labelWithString: "Max concurrent downloads:"), conn]])
        grid.frame = NSRect(x: 0, y: 0, width: 520, height: 60)
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            _ = chooser
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            let p = (path.stringValue as NSString).expandingTildeInPath
            if p != self.cfg.cacheURL.path { self.cfg.cacheURL = URL(fileURLWithPath: p, isDirectory: true); TileProvider.shared.reset() }
            self.cfg.maxConnections = conn.indexOfSelectedItem + 1
        }
    }

    final class FolderChooser: NSObject {
        let field: NSTextField
        init(field: NSTextField) { self.field = field }
        @objc func choose(_ sender: Any?) {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.prompt = "Use as Cache"
            if p.runModal() == .OK, let u = p.url { field.stringValue = u.path }
        }
    }

    @objc func revealCache(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: cfg.cacheURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([cfg.cacheURL])
    }

    // MARK: - Search

    @objc func selectGeocoder(_ sender: NSMenuItem) {
        geocoder = sender.representedObject as? String ?? "OSM"
        tbGeocoder.title = geocoder
    }

    @objc func searchBoxAction(_ sender: Any?) {
        // search
        if let r = pendingResults.first(where: { $0.name == searchBox.stringValue }) {
            goToResult(r)
        } else {
            doSearch()
        }
    }

    private struct SearchResult { let name: String; let ll: LonLat; let zoom: Int }
    private var pendingResults: [SearchResult] = []

    func doSearch() {
        let q = searchBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let ll = Geo.parseLonLat(q) {
            goToResult(SearchResult(name: q, ll: ll, zoom: max(map.zoom, 14)))
            return
        }
        guard geocoder == "OSM" else { NSSound.beep(); return }
        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        comps.queryItems = [.init(name: "format", value: "jsonv2"), .init(name: "limit", value: "10"), .init(name: "q", value: q)]
        var req = URLRequest(url: comps.url!)
        req.setValue("SASPlanet-macOS/0.1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let arr = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
            let results: [SearchResult] = arr.compactMap { o in
                guard let lat = Double(o["lat"] as? String ?? ""), let lon = Double(o["lon"] as? String ?? "") else { return nil }
                let name = o["display_name"] as? String ?? "\(lat), \(lon)"
                let rank = o["place_rank"] as? Int ?? 16
                return SearchResult(name: name, ll: LonLat(lon: lon, lat: lat), zoom: min(18, max(4, rank - 1)))
            }
            DispatchQueue.main.async { self?.showResults(results) }
        }.resume()
    }

    private func showResults(_ results: [SearchResult]) {
        guard !results.isEmpty else { NSSound.beep(); return }
        if results.count == 1 { goToResult(results[0]); return }
        pendingResults = results
        let menu = NSMenu()
        for (i, r) in results.enumerated() {
            let it = NSMenuItem(title: r.name, action: #selector(pickResult(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: searchBox.bounds.height + 4), in: searchBox)
    }

    @objc private func pickResult(_ sender: NSMenuItem) {
        guard pendingResults.indices.contains(sender.tag) else { return }
        goToResult(pendingResults[sender.tag])
    }

    private func goToResult(_ r: SearchResult) {
        map.setCenter(r.ll, zoom: r.zoom)
        map.searchMarker = r.ll
        if !searchBox.objectValues.contains(where: { ($0 as? String) == searchBox.stringValue }) {
            searchBox.insertItem(withObjectValue: searchBox.stringValue, at: 0)
        }
        window?.makeFirstResponder(map)
    }

    // MARK: - Help

    @objc func openURLItem(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}
