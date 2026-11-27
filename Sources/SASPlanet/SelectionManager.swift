import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - small control helpers

enum UI {
    static func label(_ s: String, _ f: NSRect, bold: Bool = false, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.frame = f
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }
    static func check(_ s: String, _ f: NSRect, _ target: AnyObject?, _ sel: Selector?, on: Bool = false) -> NSButton {
        let b = NSButton(checkboxWithTitle: s, target: target, action: sel)
        b.frame = f
        b.state = on ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }
    static func header(_ s: String, width: CGFloat) -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        v.addSubview(label(s, NSRect(x: 6, y: 3, width: width - 12, height: 17)))
        let line = NSBox(frame: NSRect(x: 0, y: 23, width: width, height: 1))
        line.boxType = .separator
        v.addSubview(line)
        return v
    }
    static func datePicker(_ f: NSRect, _ d: Date = Date()) -> NSDatePicker {
        let p = NSDatePicker(frame: f)
        p.datePickerStyle = .textFieldAndStepper
        p.datePickerElements = .yearMonthDay
        p.dateValue = d
        p.font = .systemFont(ofSize: 12)
        return p
    }
    static func spinner(_ f: NSRect, value: Int, min: Int, max: Int) -> (NSTextField, NSStepper) {
        let t = NSTextField(frame: NSRect(x: f.minX, y: f.minY, width: f.width - 16, height: f.height))
        t.integerValue = value
        t.font = .systemFont(ofSize: 12)
        let s = NSStepper(frame: NSRect(x: f.maxX - 15, y: f.minY - 1, width: 15, height: f.height + 2))
        s.minValue = Double(min); s.maxValue = Double(max); s.integerValue = value
        s.valueWraps = false
        t.formatter = { let n = NumberFormatter(); n.minimum = NSNumber(value: min); n.maximum = NSNumber(value: max); n.allowsFloats = false; return n }()
        s.target = t
        s.action = #selector(NSTextField.takeIntegerValueFrom(_:))
        return (t, s)
    }
}

final class ZoomsSelectView: FlippedView {
    private(set) var boxes: [NSButton] = []
    let all: NSButton
    var onChange: (() -> Void)?

    init(frame: NSRect, single: Bool = false) {
        all = NSButton(checkboxWithTitle: "All", target: nil, action: nil)
        super.init(frame: frame)
        addSubview(UI.label("Zooms:", NSRect(x: 0, y: 0, width: frame.width, height: 17)))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 20, width: frame.width, height: frame.height - 46))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: frame.width - 18, height: CGFloat(24 * 18 + 4)))
        for z in 1...24 {
            let b = UI.check("\(z)", NSRect(x: 4, y: 2 + CGFloat(z - 1) * 18, width: 70, height: 18), self, #selector(changed(_:)))
            b.tag = z - 1
            doc.addSubview(b)
            boxes.append(b)
        }
        scroll.documentView = doc
        addSubview(scroll)
        all.frame = NSRect(x: 0, y: frame.height - 22, width: frame.width, height: 18)
        all.target = self
        all.action = #selector(toggleAll(_:))
        all.font = .systemFont(ofSize: 12)
        addSubview(all)
        scrollTo(10)
    }
    required init?(coder: NSCoder) { fatalError() }

    func scrollTo(_ z: Int) {
        guard let sv = boxes.first?.superview?.enclosingScrollView else { return }
        let y = max(0, CGFloat(z) * 18 - sv.contentSize.height / 2)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    var selected: [Int] { boxes.filter { $0.state == .on }.map(\.tag) }

    func select(_ zs: [Int]) {
        for b in boxes { b.state = zs.contains(b.tag) ? .on : .off }
        updateAll()
    }

    private func updateAll() {
        let n = selected.count
        all.allowsMixedState = n != 0 && n != 24
        all.state = n == 0 ? .off : (n == 24 ? .on : .mixed)
    }

    @objc private func changed(_ s: Any?) { updateAll(); onChange?() }
    @objc private func toggleAll(_ s: Any?) {
        let on = selected.count < 24
        boxes.forEach { $0.state = on ? .on : .off }
        updateAll()
        onChange?()
    }
}

func makeMapPopup(_ f: NSRect, includeLayers: Bool = true, selected: String) -> NSPopUpButton {
    let p = NSPopUpButton(frame: f, pullsDown: false)
    p.font = .systemFont(ofSize: 12)
    for m in MapRegistry.maps + (includeLayers ? MapRegistry.layers : []) {
        p.addItem(withTitle: m.name)
        p.lastItem?.representedObject = m.id
    }
    if let i = p.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) { p.selectItem(at: i) }
    return p
}

// MARK: - Selection Manager

final class SelectionManagerController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    weak var main: MainWindowController?
    private(set) var region = Region(polygon: [])
    private let tabs = NSTabView()
    private var dontClose: ToolButton!
    private let W: CGFloat = 600, H: CGFloat = 470

    private var dlMap: NSPopUpButton!
    private var dlStat: NSTextField!
    private var dlZooms: ZoomsSelectView!
    private var dlStartPaused: NSButton!
    private var dlCloseWhenDone: NSButton!
    private var dlTryTNE: NSButton!
    private var dlTneBefore: NSButton!
    private var dlTneDate: NSDatePicker!
    private var dlOverwrite: NSButton!
    private var dlOnlyDifferent: NSButton!
    private var dlOverwriteBefore: NSButton!
    private var dlOverwriteDate: NSDatePicker!
    private var dlAutosave: NSButton!
    private var dlAutosaveMin: NSTextField!
    private var dlPrefixCheck: NSButton!
    private var dlPrefix: NSTextField!
    private var dlSplit: NSButton!
    private var dlParts: NSTextField!

    private var stFormat: NSPopUpButton!
    private var stPath: NSTextField!
    private var stPathEdited = false
    private var stMap: NSPopUpButton!
    private var stLayer: NSPopUpButton!
    private var stZoom: NSPopUpButton!
    private var stStat: NSTextField!
    private var stCoverage: NSTextField!
    private var stDownloadMissing: NSButton!
    private var stAddLayers: NSButton!
    private var stPrecise: NSButton!
    private var stQualityLabel: NSTextField!
    private var stQuality: NSTextField!
    private var stQualityStep: NSStepper!
    private var stAlpha: NSButton!
    private var stKmzLabel: NSTextField!
    private var stRemoveBlank: NSButton!
    private var stBlankPct: NSTextField!
    private var stZip: NSButton!
    private var stKmzSize: NSPopUpButton!
    private var stGeoref: [NSButton] = []
    private var stSplitH: NSTextField!
    private var stSplitV: NSTextField!
    private var stSkipExisting: NSButton!
    private var coverageToken = 0

    private var exFormat: NSPopUpButton!
    private var exPath: NSTextField!
    private var exPathEdited = false
    private var exMap: NSPopUpButton!
    private var exLayer: NSPopUpButton!
    private var exZooms: ZoomsSelectView!
    private var exStat: NSTextField!
    private var exAddLayers: NSButton!
    private var exRecreate: NSButton!
    private var exReplace: NSButton!
    private var exPrev: NSButton!
    private var exXYZ: NSButton!
    private var exName: NSTextField!
    private var exDesc: NSTextField!
    private var exAttr: NSTextField!

    private var genMap: NSPopUpButton!
    private var genFrom: NSPopUpButton!
    private var genStat: NSTextField!
    private var genResampler: NSPopUpButton!
    private var genReplace: NSButton!
    private var genFullOnly: NSButton!
    private var genCascade: NSButton!
    private var genZooms: ZoomsSelectView!

    private var cpPath: NSTextField!
    private var cpFormat: NSPopUpButton!
    private var cpReplace: NSButton!
    private var cpMaps: [NSButton] = []
    private var cpAllMaps: NSButton!
    private var cpMove: NSButton!
    private var cpSubfolder: NSButton!
    private var cpZooms: ZoomsSelectView!
    private var cpStat: NSTextField!

    private var exNameFormatLabel: NSTextField!
    private var exNameFormat: NSPopUpButton!

    private var delMap: NSPopUpButton!
    private var delZooms: ZoomsSelectView!
    private var delTiles: NSButton!
    private var delTNE: NSButton!
    private var delStat: NSTextField!

    init(main: MainWindowController) {
        self.main = main
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        w.title = "Selection Manager"
        w.isFloatingPanel = false
        w.hidesOnDeactivate = false
        w.minSize = NSSize(width: 600, height: 470)
        super.init(window: w)
        w.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(polygon: [LonLat]) {
        region = Region(polygon: polygon)
        let cur = main?.map.mainMap.id ?? "google.sat"
        for p in [dlMap, delMap] { if let i = p?.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { p?.selectItem(at: i) } }
        if dlZooms.selected.isEmpty, let z = main?.map.zoom { dlZooms.select([z]); dlZooms.scrollTo(z) }
        if delZooms.selected.isEmpty, let z = main?.map.zoom { delZooms.select([z]); delZooms.scrollTo(z) }
        if exZooms.selected.isEmpty, let z = main?.map.zoom { exZooms.select([z]); exZooms.scrollTo(z) }
        if let i = exMap.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { exMap.selectItem(at: i) }
        updateExportPath()
        if let i = genMap.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { genMap.selectItem(at: i) }
        if let z = main?.map.zoom {
            if genFrom.indexOfSelectedItem <= 0 { genFrom.selectItem(at: z) }
            if cpZooms.selected.isEmpty { cpZooms.select([z]); cpZooms.scrollTo(z) }
        }
        for b in cpMaps where b.identifier?.rawValue == cur && !cpMaps.contains(where: { $0.state == .on }) { b.state = .on }
        if let i = stMap.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { stMap.selectItem(at: i) }
        if let z = main?.map.zoom, stZoom.indexOfSelectedItem < 0 || !stZoomTouched { stZoom.selectItem(at: z) }
        let visibleLayer = main?.map.layers.first?.id
        if let l = visibleLayer, let i = stLayer.itemArray.firstIndex(where: { ($0.representedObject as? String) == l }) { stLayer.selectItem(at: i) }
        updateStitchPath()
        updateStats()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: build

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        tabs.frame = NSRect(x: 6, y: 44, width: W - 12, height: H - 50)
        tabs.autoresizingMask = [.width, .height]
        tabs.font = .systemFont(ofSize: 12)
        content.addSubview(tabs)

        tabs.addTabViewItem(tab("Download", buildDownload()))
        tabs.addTabViewItem(tab("Stitch", buildStitch()))
        tabs.addTabViewItem(tab("Generate", buildGenerate()))
        tabs.addTabViewItem(tab("Delete", buildDelete()))
        tabs.addTabViewItem(tab("Export", buildExport()))
        tabs.addTabViewItem(tab("Copy", buildCopy()))

        let bar = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 40))
        bar.autoresizingMask = [.width]
        content.addSubview(bar)
        bar.frame.origin.y = 0
        dontClose = ToolButton(image: Icons.menu(46, size: 18), tooltip: "Do not close this window after start")
        dontClose.action = { [weak self] in self?.dontClose.isChecked.toggle() }
        dontClose.frame = NSRect(x: 8, y: 6, width: 30, height: 30)
        bar.addSubview(dontClose)

        let ops: [(Int, String, () -> Void, Bool)] = [
            (28, "Copy BBOX coordinates", { [weak self] in self?.copyBBox() }, true),
            (17, "Store selection as Polygon (placemarks not available yet)", {}, false),
            (43, "Fit to Screen", { [weak self] in self?.fitToScreen() }, true),
            (25, "Save selection info to file", { [weak self] in self?.saveSelection() }, true),
        ]
        var x = W - 190 - CGFloat(ops.count) * 30 - 10
        for (icon, tip, act, enabled) in ops {
            let b = ToolButton(image: Icons.menu(icon, size: 18), tooltip: tip, action: act)
            b.isEnabled = enabled
            b.frame = NSRect(x: x, y: 6, width: 30, height: 30)
            b.autoresizingMask = [.minXMargin]
            bar.addSubview(b)
            x += 30
        }
        let start = NSButton(title: "Start", target: self, action: #selector(startPressed(_:)))
        start.frame = NSRect(x: W - 180, y: 7, width: 84, height: 28)
        start.keyEquivalent = "\r"
        start.autoresizingMask = [.minXMargin]
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.frame = NSRect(x: W - 92, y: 7, width: 84, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        cancel.autoresizingMask = [.minXMargin]
        bar.addSubview(start)
        bar.addSubview(cancel)
    }

    private func tab(_ title: String, _ v: NSView) -> NSTabViewItem {
        let t = NSTabViewItem(identifier: title)
        t.label = title
        t.view = v
        return t
    }

    private var tabW: CGFloat { W - 32 }

    private func placeholder(_ head: String, _ text: String) -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 380))
        v.addSubview(UI.header(head, width: tabW))
        let l = UI.label(text, NSRect(x: 10, y: 40, width: tabW - 20, height: 40), color: .secondaryLabelColor)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        v.addSubview(l)
        return v
    }

    private func buildDownload() -> NSView {
        let d = Config.defaults
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Download Tiles", width: tabW))
        let colW = tabW - 120
        v.addSubview(UI.label("Map/Overlay layer:", NSRect(x: 4, y: 30, width: colW, height: 17)))
        dlMap = makeMapPopup(NSRect(x: 2, y: 49, width: colW - 4, height: 24), selected: Config.shared.mainMapId)
        dlMap.target = self; dlMap.action = #selector(statsChanged(_:))
        v.addSubview(dlMap)
        dlStat = UI.label("_", NSRect(x: 4, y: 78, width: colW, height: 17))
        v.addSubview(dlStat)
        let sep = NSBox(frame: NSRect(x: 2, y: 98, width: colW - 4, height: 1)); sep.boxType = .separator
        v.addSubview(sep)

        var y: CGFloat = 106
        func row(_ h: CGFloat = 22) -> CGFloat { defer { y += h }; return y }
        dlStartPaused = UI.check("Start paused", NSRect(x: 6, y: row(), width: 300, height: 18), nil, nil, on: d.bool(forKey: "dl.startPaused"))
        dlCloseWhenDone = UI.check("Close download window once finish", NSRect(x: 6, y: row(), width: 300, height: 18), nil, nil, on: d.bool(forKey: "dl.closeWhenDone"))
        dlTryTNE = UI.check("Try download if tne exists", NSRect(x: 6, y: row(), width: 300, height: 18), self, #selector(enableSubs(_:)), on: d.bool(forKey: "dl.tryTNE"))
        let yT = row(26)
        dlTneBefore = UI.check("only created before", NSRect(x: 26, y: yT + 2, width: 140, height: 18), self, #selector(enableSubs(_:)))
        dlTneDate = UI.datePicker(NSRect(x: 168, y: yT, width: 110, height: 22))
        dlOverwrite = UI.check("Overwrite old tiles", NSRect(x: 6, y: row(), width: 300, height: 18), self, #selector(enableSubs(_:)), on: d.bool(forKey: "dl.overwrite"))
        dlOnlyDifferent = UI.check("only if different", NSRect(x: 26, y: row(), width: 200, height: 18), nil, nil)
        let yO = row(28)
        dlOverwriteBefore = UI.check("only created before", NSRect(x: 26, y: yO + 2, width: 140, height: 18), self, #selector(enableSubs(_:)))
        dlOverwriteDate = UI.datePicker(NSRect(x: 168, y: yO, width: 110, height: 22))
        let yA = row(28)
        dlAutosave = UI.check("Autosave session, min:", NSRect(x: 6, y: yA + 2, width: 160, height: 18), self, #selector(enableSubs(_:)))
        let (asField, asStep) = UI.spinner(NSRect(x: 168, y: yA, width: 60, height: 22), value: 15, min: 1, max: 1440)
        dlAutosaveMin = asField
        let yP = row(28)
        dlPrefixCheck = UI.check("File name prefix:", NSRect(x: 26, y: yP + 2, width: 140, height: 18), self, #selector(enableSubs(_:)))
        dlPrefix = NSTextField(frame: NSRect(x: 168, y: yP, width: 160, height: 22))
        let yS = row(28)
        dlSplit = UI.check("Split selection to, parts*:", NSRect(x: 6, y: yS + 2, width: 180, height: 18), self, #selector(enableSubs(_:)))
        let (pField, pStep) = UI.spinner(NSRect(x: 188, y: yS, width: 50, height: 22), value: 2, min: 2, max: 16)
        dlParts = pField
        let hint = UI.label("* - Limited by max concurrent http(s) requests for current map: \(Config.shared.maxConnections)",
                            NSRect(x: 6, y: row(), width: colW, height: 17), size: 11, color: .secondaryLabelColor)
        hint.font = NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)

        for c in [dlStartPaused, dlCloseWhenDone, dlTryTNE, dlTneBefore, dlTneDate, dlOverwrite, dlOnlyDifferent,
                  dlOverwriteBefore, dlOverwriteDate, dlAutosave, asField, asStep, dlPrefixCheck, dlPrefix, dlSplit, pField, pStep, hint] as [NSView?] {
            if let c = c { v.addSubview(c) }
        }
        dlZooms = ZoomsSelectView(frame: NSRect(x: tabW - 110, y: 30, width: 104, height: 350))
        dlZooms.onChange = { [weak self] in self?.updateStats() }
        v.addSubview(dlZooms)
        enableSubs(nil)
        return v
    }

    private var stZoomTouched = false

    private func buildStitch() -> NSView {
        let d = Config.defaults
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Stitch Selection", width: tabW))
        v.addSubview(UI.label("Output format:", NSRect(x: 4, y: 33, width: 100, height: 17)))
        stFormat = NSPopUpButton(frame: NSRect(x: 104, y: 28, width: 150, height: 24), pullsDown: false)
        stFormat.addItems(withTitles: StitchOptions.Format.allCases.map(\.rawValue))
        stFormat.selectItem(withTitle: d.string(forKey: "st.format") ?? "JPEG")
        stFormat.target = self; stFormat.action = #selector(stitchFormatChanged(_:))
        v.addSubview(stFormat)

        v.addSubview(UI.label("Save to:", NSRect(x: 4, y: 63, width: 60, height: 17)))
        stPath = NSTextField(frame: NSRect(x: 64, y: 60, width: tabW - 110, height: 22))
        stPath.font = .systemFont(ofSize: 12)
        stPath.target = self; stPath.action = #selector(stitchPathEdited(_:))
        stPath.delegate = self
        v.addSubview(stPath)
        let browse = NSButton(title: "...", target: self, action: #selector(chooseStitchPath(_:)))
        browse.frame = NSRect(x: tabW - 42, y: 58, width: 40, height: 26)
        v.addSubview(browse)

        v.addSubview(UI.label("Map:", NSRect(x: 4, y: 90, width: 200, height: 17)))
        stMap = makeMapPopup(NSRect(x: 2, y: 108, width: 258, height: 24), includeLayers: false, selected: Config.shared.mainMapId)
        stMap.target = self; stMap.action = #selector(stitchSourceChanged(_:))
        v.addSubview(stMap)
        v.addSubview(UI.label("Overlay layer:", NSRect(x: 268, y: 90, width: 190, height: 17)))
        stLayer = NSPopUpButton(frame: NSRect(x: 266, y: 108, width: 200, height: 24), pullsDown: false)
        stLayer.font = .systemFont(ofSize: 12)
        stLayer.addItem(withTitle: "No")
        for l in MapRegistry.layers { stLayer.addItem(withTitle: l.name); stLayer.lastItem?.representedObject = l.id }
        v.addSubview(stLayer)
        v.addSubview(UI.label("Zoom:", NSRect(x: 474, y: 90, width: 80, height: 17)))
        stZoom = NSPopUpButton(frame: NSRect(x: 472, y: 108, width: tabW - 474, height: 24), pullsDown: false)
        for z in 1...24 { stZoom.addItem(withTitle: "\(z)") }
        stZoom.target = self; stZoom.action = #selector(stitchZoomChanged(_:))
        v.addSubview(stZoom)

        stStat = UI.label("_", NSRect(x: 4, y: 138, width: tabW - 8, height: 17))
        v.addSubview(stStat)
        stCoverage = UI.label("", NSRect(x: 4, y: 158, width: 330, height: 17), color: .secondaryLabelColor)
        v.addSubview(stCoverage)
        stDownloadMissing = NSButton(title: "Download missing tiles…", target: self, action: #selector(downloadMissing(_:)))
        stDownloadMissing.frame = NSRect(x: 336, y: 152, width: 200, height: 26)
        stDownloadMissing.bezelStyle = .rounded
        stDownloadMissing.controlSize = .small
        stDownloadMissing.isHidden = true
        v.addSubview(stDownloadMissing)

        var y: CGFloat = 186
        func opt(_ t: String, enabled: Bool, on: Bool = false) -> NSButton {
            let b = UI.check(t, NSRect(x: 6, y: y, width: 300, height: 18), nil, nil, on: on)
            b.isEnabled = enabled
            if !enabled { b.toolTip = "Not available yet" }
            v.addSubview(b)
            y += 21
            return b
        }
        _ = opt("Add visible Placemarks", enabled: false)
        _ = opt("Use postprocessing settings", enabled: false)
        _ = opt("Add visible Grids", enabled: false)
        stAddLayers = opt("Add visible Layers", enabled: true)
        stAddLayers.target = self; stAddLayers.action = #selector(addLayersToggled(_:))
        _ = opt("Add visible Cached Tiles Map", enabled: false)
        stPrecise = opt("Precise cropping by the polygon", enabled: true, on: d.bool(forKey: "st.precise"))
        stPrecise.toolTip = "Precise cropping of the image along the boundaries of the polygon"

        stQualityLabel = UI.label("Quality, %", NSRect(x: 8, y: y + 8, width: 70, height: 17))
        let (q, qs) = UI.spinner(NSRect(x: 80, y: y + 6, width: 60, height: 22), value: d.object(forKey: "st.quality") as? Int ?? 50, min: 1, max: 100)
        stQuality = q; stQualityStep = qs
        stAlpha = UI.check("Include alpha channel", NSRect(x: 6, y: y + 8, width: 200, height: 18), nil, nil, on: true)
        stKmzLabel = UI.label("Tile size, pix:", NSRect(x: 150, y: y + 8, width: 90, height: 17))
        stKmzSize = NSPopUpButton(frame: NSRect(x: 240, y: y + 4, width: 84, height: 24), pullsDown: false)
        stKmzSize.addItems(withTitles: ["256x256", "512x512", "1024x1024", "2048x2048", "4096x4096", "8192x8192"])
        stKmzSize.selectItem(withTitle: "1024x1024")
        stKmzSize.font = .systemFont(ofSize: 11)
        [stQualityLabel, stQuality, stQualityStep, stAlpha, stKmzLabel, stKmzSize].forEach { v.addSubview($0!) }

        let yb = y + 36
        stRemoveBlank = UI.check("Remove blank images if ≥", NSRect(x: 6, y: yb, width: 180, height: 18), self, #selector(blankToggled(_:)),
                                 on: d.bool(forKey: "st.removeBlank"))
        stRemoveBlank.toolTip = "Delete stitched images (and their georeference files) whose share of blank grey #C0C0C0 pixels — areas with no cached tiles — is at or above this percentage. 100 = only completely blank images."
        let (bp, bps) = UI.spinner(NSRect(x: 186, y: yb - 2, width: 58, height: 22), value: d.object(forKey: "st.blankPct") as? Int ?? 100, min: 1, max: 100)
        stBlankPct = bp
        let pctLabel = UI.label("% blank", NSRect(x: 248, y: yb, width: 70, height: 17))
        stZip = UI.check("Pack results into a ZIP (for Infinite Flight)", NSRect(x: 6, y: yb + 22, width: 320, height: 18), nil, nil,
                         on: d.bool(forKey: "st.zip"))
        stZip.toolTip = "Puts the remaining images and their georeference files into <name>.zip next to them."
        [stRemoveBlank, bp, bps, pctLabel, stZip].forEach { v.addSubview($0!) }
        blankToggled(nil)

        let gx: CGFloat = 330
        v.addSubview(UI.label("Create georeferencing file:", NSRect(x: gx, y: 186, width: 220, height: 17)))
        let saved = Set(d.stringArray(forKey: "st.georef") ?? [".w", ".map"])
        for (i, k) in [".map", ".tab", ".w", ".dat", ".kml"].enumerated() {
            let b = UI.check(k, NSRect(x: gx + 4, y: 206 + CGFloat(i) * 19, width: 90, height: 18), nil, nil, on: saved.contains(k))
            stGeoref.append(b)
            v.addSubview(b)
        }
        let box = NSBox(frame: NSRect(x: gx - 2, y: 300, width: tabW - gx, height: 84))
        box.title = "Split image"
        box.titleFont = .systemFont(ofSize: 11)
        v.addSubview(box)
        let inner = FlippedView(frame: box.contentView?.bounds ?? .zero)
        box.contentView = inner
        inner.addSubview(UI.label("horizontally:", NSRect(x: 4, y: 6, width: 80, height: 17)))
        let (sh, shs) = UI.spinner(NSRect(x: 82, y: 4, width: 50, height: 22), value: 1, min: 1, max: 1000)
        inner.addSubview(UI.label("vertically:", NSRect(x: 138, y: 6, width: 62, height: 17)))
        let (sv, svs) = UI.spinner(NSRect(x: 196, y: 4, width: 46, height: 22), value: 1, min: 1, max: 1000)
        stSplitH = sh; stSplitV = sv
        [sh, shs, sv, svs].forEach { inner.addSubview($0) }
        stSkipExisting = UI.check("Skip existing result files", NSRect(x: 4, y: 34, width: 220, height: 18), nil, nil)
        inner.addSubview(stSkipExisting)

        stitchFormatChanged(nil)
        return v
    }

    @objc private func stitchFormatChanged(_ s: Any?) {
        let f = StitchOptions.Format(rawValue: stFormat.titleOfSelectedItem ?? "JPEG") ?? .jpeg
        stQualityLabel.isHidden = f != .jpeg && f != .kmz
        stQuality.isHidden = f != .jpeg && f != .kmz
        stQualityStep.isHidden = f != .jpeg && f != .kmz
        stAlpha.isHidden = f != .png
        stKmzLabel.isHidden = f != .kmz
        stKmzSize.isHidden = f != .kmz
        stGeoref.forEach { $0.isEnabled = f != .kmz }
        stZip?.isEnabled = f != .kmz
        updateStitchPath()
        updateStats()
    }

    @objc private func stitchSourceChanged(_ s: Any?) { updateStitchPath(); updateStats() }
    @objc private func blankToggled(_ s: Any?) { stBlankPct?.isEnabled = stRemoveBlank.state == .on }
    @objc private func stitchZoomChanged(_ s: Any?) { stZoomTouched = true; updateStitchPath(); updateStats() }
    @objc private func stitchPathEdited(_ s: Any?) { stPathEdited = true }
    @objc private func addLayersToggled(_ s: Any?) {
        if stAddLayers.state == .on, stLayer.indexOfSelectedItem == 0, let l = main?.map.layers.first?.id,
           let i = stLayer.itemArray.firstIndex(where: { ($0.representedObject as? String) == l }) {
            stLayer.selectItem(at: i)
        }
    }

    private var stitchFormat: StitchOptions.Format { StitchOptions.Format(rawValue: stFormat.titleOfSelectedItem ?? "JPEG") ?? .jpeg }

    private func updateStitchPath() {
        guard stPath != nil else { return }
        let ext = stitchFormat.ext
        if stPathEdited, !stPath.stringValue.isEmpty {
            let u = URL(fileURLWithPath: (stPath.stringValue as NSString).expandingTildeInPath)
            stPath.stringValue = u.deletingPathExtension().appendingPathExtension(ext).path
            return
        }
        let dir = Config.defaults.string(forKey: "st.dir")
            ?? Config.shared.cacheURL.deletingLastPathComponent().appendingPathComponent("stitched").path
        let m = selectedMap(stMap)?.folder ?? "map"
        stPath.stringValue = (dir as NSString).appendingPathComponent("\(m)_z\(stZoom.indexOfSelectedItem + 1).\(ext)")
    }

    @objc private func chooseStitchPath(_ s: Any?) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = URL(fileURLWithPath: stPath.stringValue).lastPathComponent
        p.directoryURL = URL(fileURLWithPath: stPath.stringValue).deletingLastPathComponent()
        p.allowExtensions([stitchFormat.ext])
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url, let self = self else { return }
            self.stPath.stringValue = u.path
            self.stPathEdited = true
        }
    }

    @objc private func downloadMissing(_ s: Any?) {
        dlZooms.select([stZoom.indexOfSelectedItem])
        dlZooms.scrollTo(stZoom.indexOfSelectedItem)
        if let id = selectedMap(stMap)?.id, let i = dlMap.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) { dlMap.selectItem(at: i) }
        updateStats()
        tabs.selectTabViewItem(withIdentifier: "Download")
    }

    private func updateCoverage() {
        guard stCoverage != nil, let m = selectedMap(stMap), !region.polygon.isEmpty else { return }
        let z = stZoom.indexOfSelectedItem
        let reg = region
        coverageToken += 1
        let token = coverageToken
        stCoverage.stringValue = "Checking cache…"
        stDownloadMissing.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let total = reg.tileCount(z)
            let cov: (cached: Int, total: Int) = total > 2_000_000 ? (-1, total) : StitchTask.cacheCoverage(map: m, region: reg, zoom: z)
            DispatchQueue.main.async {
                guard let self = self, token == self.coverageToken else { return }
                if cov.cached < 0 {
                    self.stCoverage.stringValue = "\(cov.total) tiles (too many to check the cache)"
                } else {
                    let missing = cov.total - cov.cached
                    self.stCoverage.stringValue = "In cache: \(cov.cached) of \(cov.total) tiles" + (missing > 0 ? " — \(missing) missing" : " ✓")
                    self.stCoverage.textColor = missing > 0 ? .systemOrange : .secondaryLabelColor
                    self.stDownloadMissing.isHidden = missing == 0
                }
            }
        }
    }

    private func startStitch() -> Bool {
        guard let m = selectedMap(stMap), !region.polygon.isEmpty, let w = window else { NSSound.beep(); return false }
        let path = (stPath.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { NSSound.beep(); return false }
        var o = StitchOptions(map: m, layer: (stLayer.selectedItem?.representedObject as? String).flatMap(MapRegistry.byId),
                              zoom: stZoom.indexOfSelectedItem, output: URL(fileURLWithPath: path))
        o.format = stitchFormat
        o.georef = Set(stGeoref.filter { $0.state == .on }.map(\.title))
        o.preciseCrop = stPrecise.state == .on
        o.splitH = max(1, stSplitH.integerValue)
        o.splitV = max(1, stSplitV.integerValue)
        o.skipExisting = stSkipExisting.state == .on
        o.jpegQuality = max(1, min(100, stQuality.integerValue))
        o.pngAlpha = stAlpha.state == .on
        o.kmzPiece = Int(stKmzSize.titleOfSelectedItem?.split(separator: "x").first ?? "1024") ?? 1024
        o.removeBlank = stRemoveBlank.state == .on
        o.blankPercent = Double(max(1, min(100, stBlankPct.integerValue)))
        o.zipResults = stZip.state == .on && o.format != .kmz
        let d = Config.defaults
        d.set(o.format.rawValue, forKey: "st.format")
        d.set(Array(o.georef), forKey: "st.georef")
        d.set(o.preciseCrop, forKey: "st.precise")
        d.set(o.jpegQuality, forKey: "st.quality")
        d.set(o.removeBlank, forKey: "st.removeBlank")
        d.set(Int(o.blankPercent), forKey: "st.blankPct")
        d.set(stZip.state == .on, forKey: "st.zip")
        d.set(o.output.deletingLastPathComponent().path, forKey: "st.dir")
        let task = StitchTask(opts: o, region: region)
        if let err = task.validate() {
            let a = NSAlert(); a.messageText = "Cannot stitch"; a.informativeText = err
            a.beginSheetModal(for: w)
            return false
        }
        if o.format == .kmz && task.kmzPieceCount > 100 {
            let a = NSAlert()
            a.messageText = "This KMZ will contain \(task.kmzPieceCount) image pieces."
            a.informativeText = "Garmin devices show at most 100 per map. Google Earth has no such limit."
            a.addButton(withTitle: "Create Anyway"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return false }
        }
        StitchProgressController.open(task: task, main: main)
        return true
    }

    private func buildExport() -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Export", width: tabW))
        let colW = tabW - 120
        v.addSubview(UI.label("Format:", NSRect(x: 4, y: 33, width: 60, height: 17)))
        exFormat = NSPopUpButton(frame: NSRect(x: 62, y: 28, width: 190, height: 24), pullsDown: false)
        exFormat.autoenablesItems = false
        exFormat.addItems(withTitles: ["MBTiles", "OruxMaps (SQLite)", "RMaps (SQLite)", "Locus (SQLite)", "OsmAnd (SQLite)",
                                       "Zip archive", "Tar archive", "Google Earth (KML)"])
        // TODO jnx/img export, need to figure out the garmin formats first and rlly not worth doing for IF. Will leave this feature out.
        for f in ["Garmin (JNX)", "Garmin (IMG)", "SAS4Android"] {
            exFormat.addItem(withTitle: f + " — not available yet")
            exFormat.lastItem?.isEnabled = false
        }
        exFormat.target = self; exFormat.action = #selector(exportFormatChanged(_:))
        v.addSubview(exFormat)
        exNameFormatLabel = UI.label("Names:", NSRect(x: 258, y: 33, width: 48, height: 17))
        exNameFormat = NSPopUpButton(frame: NSRect(x: 304, y: 28, width: tabW - 120 - 306, height: 24), pullsDown: false)
        exNameFormat.toolTip = "Tile name format inside the archive"
        exNameFormat.addItems(withTitles: CacheFormat.allCases.map(\.rawValue))
        exNameFormat.font = .systemFont(ofSize: 11)
        v.addSubview(exNameFormatLabel)
        v.addSubview(exNameFormat)
        exNameFormatLabel.isHidden = true
        exNameFormat.isHidden = true
        v.addSubview(UI.label("Save to:", NSRect(x: 4, y: 63, width: 60, height: 17)))
        exPath = NSTextField(frame: NSRect(x: 62, y: 60, width: colW - 108, height: 22))
        exPath.font = .systemFont(ofSize: 12)
        exPath.delegate = self
        v.addSubview(exPath)
        let browse = NSButton(title: "...", target: self, action: #selector(chooseExportPath(_:)))
        browse.frame = NSRect(x: colW - 44, y: 58, width: 40, height: 26)
        v.addSubview(browse)

        v.addSubview(UI.label("Map:", NSRect(x: 4, y: 90, width: 200, height: 17)))
        exMap = makeMapPopup(NSRect(x: 2, y: 108, width: (colW - 10) / 2, height: 24), includeLayers: true, selected: Config.shared.mainMapId)
        exMap.target = self; exMap.action = #selector(exportSourceChanged(_:))
        v.addSubview(exMap)
        v.addSubview(UI.label("Overlay layer:", NSRect(x: (colW - 10) / 2 + 8, y: 90, width: 200, height: 17)))
        exLayer = NSPopUpButton(frame: NSRect(x: (colW - 10) / 2 + 6, y: 108, width: (colW - 10) / 2, height: 24), pullsDown: false)
        exLayer.font = .systemFont(ofSize: 12)
        exLayer.addItem(withTitle: "No")
        for l in MapRegistry.layers { exLayer.addItem(withTitle: l.name); exLayer.lastItem?.representedObject = l.id }
        v.addSubview(exLayer)
        exStat = UI.label("_", NSRect(x: 4, y: 138, width: colW, height: 17))
        v.addSubview(exStat)

        var y: CGFloat = 166
        func opt(_ t: String, on: Bool, enabled: Bool = true) -> NSButton {
            let b = UI.check(t, NSRect(x: 6, y: y, width: colW - 10, height: 18), nil, nil, on: on)
            b.isEnabled = enabled
            v.addSubview(b); y += 21
            return b
        }
        exAddLayers = opt("Add visible Layers", on: false)
        exAddLayers.target = self; exAddLayers.action = #selector(exportAddLayers(_:))
        _ = opt("Add visible Placemarks, Grids, Cached Tiles Map", on: false, enabled: false)
        exRecreate = opt("Recreate target database if exists", on: true)
        exReplace = opt("Replace existing tiles", on: true)
        exPrev = opt("Use tiles from lower zooms (on unavailable tile)", on: false)
        _ = opt("Use postprocessing settings", on: false, enabled: false)
        exXYZ = opt("Use XYZ scheme", on: false)
        _ = opt("Make TileMill compatible structure", on: false, enabled: false)

        y += 4
        for (t, keyPath) in [("Name:", 0), ("Description:", 1), ("Attribution:", 2)] {
            v.addSubview(UI.label(t, NSRect(x: 6, y: y + 3, width: 80, height: 17)))
            let f = NSTextField(frame: NSRect(x: 88, y: y, width: colW - 96, height: 22))
            f.font = .systemFont(ofSize: 12)
            v.addSubview(f)
            switch keyPath { case 0: exName = f; case 1: exDesc = f; default: exAttr = f }
            y += 26
        }
        exAttr.stringValue = "© Google"
        exZooms = ZoomsSelectView(frame: NSRect(x: tabW - 110, y: 30, width: 104, height: 350))
        exZooms.onChange = { [weak self] in self?.updateStats() }
        v.addSubview(exZooms)
        return v
    }

    @objc private func exportSourceChanged(_ s: Any?) { updateExportPath(); updateStats() }

    private var exportExt: String {
        switch exFormat.titleOfSelectedItem ?? "" {
        case let t where t.hasPrefix("MBTiles"): return "mbtiles"
        case let t where t.hasPrefix("OruxMaps"): return ""
        case let t where t.hasPrefix("Zip"): return "zip"
        case let t where t.hasPrefix("Tar"): return "tar"
        case let t where t.hasPrefix("Google Earth"): return "kml"
        default: return "sqlitedb"
        }
    }

    @objc private func exportFormatChanged(_ s: Any?) {
        let archive = exportExt == "zip" || exportExt == "tar"
        exNameFormatLabel.isHidden = !archive
        exNameFormat.isHidden = !archive
        let mb = exportExt == "mbtiles"
        [exRecreate, exXYZ, exName, exDesc, exAttr].forEach { $0?.isEnabled = mb }
        exPathEdited = false
        updateExportPath()
    }
    @objc private func exportAddLayers(_ s: Any?) {
        if exAddLayers.state == .on, exLayer.indexOfSelectedItem == 0, let l = main?.map.layers.first?.id,
           let i = exLayer.itemArray.firstIndex(where: { ($0.representedObject as? String) == l }) { exLayer.selectItem(at: i) }
    }

    private func updateExportPath() {
        guard exPath != nil, !exPathEdited || exPath.stringValue.isEmpty else { return }
        let dir = Config.defaults.string(forKey: "ex.dir")
            ?? Config.shared.cacheURL.deletingLastPathComponent().appendingPathComponent("export").path
        let m = selectedMap(exMap)?.folder ?? "map"
        let ext = exportExt
        exPath.stringValue = (dir as NSString).appendingPathComponent(ext.isEmpty ? m : "\(m).\(ext)")
    }

    @objc private func chooseExportPath(_ s: Any?) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = URL(fileURLWithPath: exPath.stringValue).lastPathComponent
        p.directoryURL = URL(fileURLWithPath: exPath.stringValue).deletingLastPathComponent()
        if !exportExt.isEmpty { p.allowExtensions([exportExt]) }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url, let self = self else { return }
            self.exPath.stringValue = u.path
            self.exPathEdited = true
        }
    }

    private func startExport() -> Bool {
        guard let m = selectedMap(exMap), !exZooms.selected.isEmpty, !region.polygon.isEmpty else { NSSound.beep(); return false }
        let path = (exPath.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { NSSound.beep(); return false }
        var o = MBTilesOptions(map: m, layer: (exLayer.selectedItem?.representedObject as? String).flatMap(MapRegistry.byId),
                               zooms: exZooms.selected, output: URL(fileURLWithPath: path))
        o.recreate = exRecreate.state == .on
        o.replaceExisting = exReplace.state == .on
        o.usePrevZoom = exPrev.state == .on
        o.xyzScheme = exXYZ.state == .on
        o.name = exName.stringValue
        o.description = exDesc.stringValue
        o.attribution = exAttr.stringValue
        Config.defaults.set(o.output.deletingLastPathComponent().path, forKey: "ex.dir")
        if exportExt == "mbtiles" {
            StitchProgressController.open(task: MBTilesExportTask(opts: o, region: region), main: main)
            return true
        }
        let src = TileSource(map: m, layer: o.layer, usePrevZoom: o.usePrevZoom, jpegQuality: 90)
        let b = region.bbox
        let center = LonLat(lon: (b.w + b.e) / 2, lat: (b.s + b.n) / 2)
        let out = o.output
        let fmt = CacheFormat(rawValue: exNameFormat.titleOfSelectedItem ?? "") ?? .sas
        let title = exFormat.titleOfSelectedItem ?? ""
        let zooms = exZooms.selected
        let reg = region
        do {
            let sink: TileSink
            var after: (() throws -> Void)?
            switch exportExt {
            case "zip": sink = try ZipSink(url: out, format: fmt, prefix: m.folder + "/")
            case "tar": sink = try TarSink(url: out, format: fmt, prefix: m.folder + "/")
            case "kml": sink = KMLSink(url: out, relative: true)
            case "":
                // oruxmaps
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var origins: [Int: (Int, Int)] = [:]
                for z in zooms { let tb = reg.tileBounds(z); origins[z] = (tb.x0, tb.y0) }
                sink = try SQLiteSink(url: out.appendingPathComponent("OruxMapsImages.db"), kind: .orux, replace: o.replaceExisting,
                                      center: center, origins: origins)
                let name = out.lastPathComponent
                after = { try OruxCalibration.write(dir: out, name: name, region: reg, zooms: zooms) }
            default:
                let kind: SQLiteSink.Kind = title.hasPrefix("OsmAnd") ? .osmand : title.hasPrefix("Locus") ? .locus : .rmaps
                sink = try SQLiteSink(url: out, kind: kind, replace: o.replaceExisting, center: center)
            }
            let t = TileJobTask(name: "Export: \(out.lastPathComponent)", jobs: [.init(source: src, sink: sink, deleteSource: false)],
                                region: region, zooms: zooms, outputs: [out], afterFinish: after)
            StitchProgressController.open(task: t, main: main)
        } catch { NSAlert(error: error).runModal(); return false }
        return true
    }

    private func buildGenerate() -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Generate Lower Zooms for Selection", width: tabW))
        let colW = tabW - 120
        v.addSubview(UI.label("Map/Overlay layer:", NSRect(x: 4, y: 30, width: colW, height: 17)))
        genMap = makeMapPopup(NSRect(x: 2, y: 49, width: colW - 100, height: 24), selected: Config.shared.mainMapId)
        v.addSubview(genMap)
        v.addSubview(UI.label("From zoom:", NSRect(x: colW - 92, y: 30, width: 90, height: 17)))
        genFrom = NSPopUpButton(frame: NSRect(x: colW - 94, y: 49, width: 90, height: 24), pullsDown: false)
        for z in 1...24 { genFrom.addItem(withTitle: "\(z)") }
        genFrom.target = self; genFrom.action = #selector(statsChanged(_:))
        v.addSubview(genFrom)
        genStat = UI.label("_", NSRect(x: 4, y: 80, width: colW, height: 17))
        v.addSubview(genStat)
        v.addSubview(UI.label("Resize algorithm:", NSRect(x: 4, y: 110, width: 120, height: 17)))
        genResampler = NSPopUpButton(frame: NSRect(x: 124, y: 105, width: 150, height: 24), pullsDown: false)
        genResampler.addItems(withTitles: ["Box", "Linear", "Cosine", "Spline", "Mitchell", "Cubic", "Hermite", "Lanczos", "Gaussian", "Blackman", "Hann", "Hamming", "Sinsh"])
        genResampler.selectItem(withTitle: "Lanczos")
        v.addSubview(genResampler)
        genReplace = UI.check("Overwrite existing tiles", NSRect(x: 6, y: 142, width: 300, height: 18), nil, nil)
        genFullOnly = UI.check("Save only complete tiles", NSRect(x: 6, y: 164, width: 300, height: 18), nil, nil)
        genCascade = UI.check("Generate each zoom from previous one", NSRect(x: 6, y: 186, width: 300, height: 18), nil, nil, on: true)
        let prev = UI.check("Use tile from lower zoom if tile not available", NSRect(x: 26, y: 208, width: 320, height: 18), nil, nil)
        prev.isEnabled = false
        [genReplace, genFullOnly, genCascade, prev].forEach { v.addSubview($0!) }
        genZooms = ZoomsSelectView(frame: NSRect(x: tabW - 110, y: 30, width: 104, height: 350))
        genZooms.onChange = { [weak self] in self?.updateStats() }
        v.addSubview(genZooms)
        return v
    }

    private func buildCopy() -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Copy tiles from selection to folder", width: tabW))
        let colW = tabW - 120
        v.addSubview(UI.label("Save to:", NSRect(x: 4, y: 33, width: 60, height: 17)))
        cpPath = NSTextField(frame: NSRect(x: 62, y: 30, width: colW - 108, height: 22))
        cpPath.font = .systemFont(ofSize: 12)
        cpPath.stringValue = Config.defaults.string(forKey: "cp.dir")
            ?? Config.shared.cacheURL.deletingLastPathComponent().appendingPathComponent("copy").path
        v.addSubview(cpPath)
        let browse = NSButton(title: "...", target: self, action: #selector(chooseCopyFolder(_:)))
        browse.frame = NSRect(x: colW - 44, y: 28, width: 40, height: 26)
        v.addSubview(browse)
        v.addSubview(UI.label("Output format", NSRect(x: 4, y: 63, width: 100, height: 17)))
        cpFormat = NSPopUpButton(frame: NSRect(x: 104, y: 58, width: colW - 108, height: 24), pullsDown: false)
        cpFormat.addItems(withTitles: CacheFormat.allCases.map(\.rawValue))
        for k in ["OsmAnd (SQLite)", "Locus (SQLite)", "RMaps (SQLite)"] { cpFormat.addItem(withTitle: k) }
        v.addSubview(cpFormat)
        cpReplace = UI.check("Overwrite if equal", NSRect(x: 6, y: 90, width: 200, height: 18), nil, nil)
        cpMove = UI.check("Move", NSRect(x: 210, y: 90, width: 80, height: 18), nil, nil)
        cpMove.toolTip = "Delete the tiles from this cache after copying"
        cpSubfolder = UI.check("Make subfolder with map path name", NSRect(x: 6, y: 112, width: 300, height: 18), nil, nil, on: true)
        [cpReplace, cpMove, cpSubfolder].forEach { v.addSubview($0!) }
        cpStat = UI.label("_", NSRect(x: 4, y: 136, width: colW, height: 17))
        v.addSubview(cpStat)
        v.addSubview(UI.label("Maps:", NSRect(x: 4, y: 158, width: 100, height: 17)))
        let scroll = NSScrollView(frame: NSRect(x: 2, y: 176, width: colW - 6, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let all = MapRegistry.all
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: colW - 24, height: CGFloat(all.count) * 19 + 4))
        for (i, m) in all.enumerated() {
            let b = UI.check(m.name + (m.isLayer ? " (layer)" : ""), NSRect(x: 4, y: 2 + CGFloat(i) * 19, width: colW - 34, height: 18), nil, nil)
            b.identifier = NSUserInterfaceItemIdentifier(m.id)
            doc.addSubview(b)
            cpMaps.append(b)
        }
        scroll.documentView = doc
        v.addSubview(scroll)
        cpAllMaps = UI.check("All", NSRect(x: 4, y: 360, width: 80, height: 18), self, #selector(copyAllMaps(_:)))
        v.addSubview(cpAllMaps)
        cpZooms = ZoomsSelectView(frame: NSRect(x: tabW - 110, y: 30, width: 104, height: 350))
        cpZooms.onChange = { [weak self] in self?.updateStats() }
        v.addSubview(cpZooms)
        return v
    }

    @objc private func copyAllMaps(_ s: Any?) {
        let on = cpAllMaps.state == .on
        cpMaps.forEach { $0.state = on ? .on : .off }
    }

    @objc private func chooseCopyFolder(_ s: Any?) {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"
        p.beginSheetModal(for: w) { [weak self] r in if r == .OK, let u = p.url { self?.cpPath.stringValue = u.path } }
    }

    private func startGenerate() -> Bool {
        guard let m = selectedMap(genMap), !genZooms.selected.isEmpty, !region.polygon.isEmpty else { NSSound.beep(); return false }
        let from = genFrom.indexOfSelectedItem
        let targets = genZooms.selected.filter { $0 < from }
        guard !targets.isEmpty else {
            let a = NSAlert(); a.messageText = "Pick target zooms lower than the source zoom (z\(from + 1))."; a.runModal(); return false
        }
        let q: CGInterpolationQuality = ["Box": .none, "Linear": .low, "Cosine": .low, "Hermite": .medium, "Spline": .medium][genResampler.titleOfSelectedItem ?? ""] ?? .high
        let t = GenerateTask(map: m, fromZoom: from, toZooms: targets, region: region, replace: genReplace.state == .on,
                             fullOnly: genFullOnly.state == .on, cascade: genCascade.state == .on, quality: q)
        StitchProgressController.open(task: t, main: main)
        return true
    }

    private func startCopy() -> Bool {
        let maps = cpMaps.filter { $0.state == .on }.compactMap { $0.identifier.flatMap { MapRegistry.byId($0.rawValue) } }
        guard !maps.isEmpty, !cpZooms.selected.isEmpty, !region.polygon.isEmpty else {
            let a = NSAlert(); a.messageText = "Pick at least one map and one zoom to copy."; a.runModal(); return false
        }
        let root = URL(fileURLWithPath: (cpPath.stringValue as NSString).expandingTildeInPath, isDirectory: true)
        Config.defaults.set(root.path, forKey: "cp.dir")
        let fmtTitle = cpFormat.titleOfSelectedItem ?? CacheFormat.sas.rawValue
        let replace = cpReplace.state == .on
        if cpMove.state == .on {
            let a = NSAlert()
            a.messageText = "Move tiles?"
            a.informativeText = "After copying, the tiles will be permanently deleted from \(Config.shared.cacheURL.path)."
            a.addButton(withTitle: "Move"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return false }
        }
        var jobs: [TileJobTask.Job] = []
        var outs: [URL] = []
        let b = region.bbox
        do {
            for m in maps {
                let src = TileSource(map: m, layer: nil, usePrevZoom: false, jpegQuality: 90)
                let dir = cpSubfolder.state == .on ? root.appendingPathComponent(m.folder, isDirectory: true) : root
                let sink: TileSink
                if let f = CacheFormat(rawValue: fmtTitle) {
                    sink = FolderSink(root: dir, format: f, replace: replace)
                    outs.append(dir)
                } else {
                    let kind: SQLiteSink.Kind = fmtTitle.hasPrefix("OsmAnd") ? .osmand : fmtTitle.hasPrefix("Locus") ? .locus : .rmaps
                    let u = root.appendingPathComponent("\(m.folder).sqlitedb")
                    sink = try SQLiteSink(url: u, kind: kind, replace: replace, center: LonLat(lon: (b.w + b.e) / 2, lat: (b.s + b.n) / 2))
                    outs.append(u)
                }
                jobs.append(.init(source: src, sink: sink, deleteSource: cpMove.state == .on))
            }
        } catch { NSAlert(error: error).runModal(); return false }
        let t = TileJobTask(name: "Copy to \(root.lastPathComponent)", jobs: jobs, region: region, zooms: cpZooms.selected, outputs: outs)
        StitchProgressController.open(task: t, main: main)
        return true
    }

    private func buildDelete() -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: tabW, height: 390))
        v.addSubview(UI.header("Delete Tiles", width: tabW))
        let colW = tabW - 120
        v.addSubview(UI.label("Map/Overlay layer:", NSRect(x: 4, y: 30, width: colW, height: 17)))
        delMap = makeMapPopup(NSRect(x: 2, y: 49, width: colW - 4, height: 24), selected: Config.shared.mainMapId)
        delMap.target = self; delMap.action = #selector(statsChanged(_:))
        v.addSubview(delMap)
        delStat = UI.label("_", NSRect(x: 4, y: 78, width: colW, height: 17))
        v.addSubview(delStat)
        delTiles = UI.check("Delete tiles", NSRect(x: 6, y: 108, width: 300, height: 18), nil, nil, on: true)
        delTNE = UI.check("Delete tne (\"tile not exists\" markers)", NSRect(x: 6, y: 130, width: 300, height: 18), nil, nil, on: true)
        v.addSubview(delTiles)
        v.addSubview(delTNE)
        delZooms = ZoomsSelectView(frame: NSRect(x: tabW - 110, y: 30, width: 104, height: 350))
        delZooms.onChange = { [weak self] in self?.updateStats() }
        v.addSubview(delZooms)
        return v
    }

    @objc private func enableSubs(_ s: Any?) {
        dlTneBefore.isEnabled = dlTryTNE.state == .on
        dlTneDate.isEnabled = dlTryTNE.state == .on && dlTneBefore.state == .on
        dlOnlyDifferent.isEnabled = dlOverwrite.state == .on
        dlOverwriteBefore.isEnabled = dlOverwrite.state == .on
        dlOverwriteDate.isEnabled = dlOverwrite.state == .on && dlOverwriteBefore.state == .on
        dlAutosaveMin.isEnabled = dlAutosave.state == .on
        dlPrefixCheck.isEnabled = dlAutosave.state == .on
        dlPrefix.isEnabled = dlAutosave.state == .on && dlPrefixCheck.state == .on
        dlParts.isEnabled = dlSplit.state == .on
    }

    @objc private func statsChanged(_ s: Any?) { updateStats() }

    private func statText(_ zooms: [Int]) -> String {
        guard !region.polygon.isEmpty, let zMax = zooms.max() else { return "Please select at least one zoom" }
        let t = region.tileBounds(zMax)
        let count = region.tileCount(zMax)
        let px = region.pixelBounds(zMax)
        var s = "Number of tiles: \(t.x1 - t.x0 + 1)x\(t.y1 - t.y0 + 1)(\(count)), size: \(Int(px.width.rounded()))x\(Int(px.height.rounded())) pix"
        if zooms.count > 1 {
            let total = zooms.reduce(0) { $0 + region.tileCount($1) }
            s += " — total for \(zooms.count) zooms: \(total)"
        }
        return s
    }

    private func updateStats() {
        dlStat?.stringValue = statText(dlZooms?.selected ?? [])
        delStat?.stringValue = statText(delZooms?.selected ?? [])
        exStat?.stringValue = statText(exZooms?.selected ?? [])
        genStat?.stringValue = statText(genZooms?.selected ?? [])
        cpStat?.stringValue = statText(cpZooms?.selected ?? [])
        if let st = stStat, let z = stZoom?.indexOfSelectedItem, z >= 0 {
            st.stringValue = statText([z])
            updateCoverage()
        }
    }

    // MARK: actions

    @objc private func cancelPressed(_ s: Any?) { close() }

    @objc private func startPressed(_ s: Any?) {
        switch tabs.selectedTabViewItem?.identifier as? String {
        case "Download": startDownload()
        case "Stitch": if !startStitch() { return }
        case "Export": if !startExport() { return }
        case "Generate": if !startGenerate() { return }
        case "Copy": if !startCopy() { return }
        case "Delete": startDelete()
        default:
            NSSound.beep()
            return
        }
        if !dontClose.isChecked { close() }
    }

    private func selectedMap(_ p: NSPopUpButton) -> MapType? {
        (p.selectedItem?.representedObject as? String).flatMap(MapRegistry.byId)
    }

    private func startDownload() {
        guard let m = selectedMap(dlMap), !dlZooms.selected.isEmpty, !region.polygon.isEmpty else { NSSound.beep(); return }
        let d = Config.defaults
        d.set(dlStartPaused.state == .on, forKey: "dl.startPaused")
        d.set(dlCloseWhenDone.state == .on, forKey: "dl.closeWhenDone")
        d.set(dlTryTNE.state == .on, forKey: "dl.tryTNE")
        d.set(dlOverwrite.state == .on, forKey: "dl.overwrite")
        var o = DownloadOptions()
        o.startPaused = dlStartPaused.state == .on
        o.closeWhenFinished = dlCloseWhenDone.state == .on
        o.tryIfTNE = dlTryTNE.state == .on
        o.tneOnlyBefore = dlTryTNE.state == .on && dlTneBefore.state == .on ? dlTneDate.dateValue : nil
        o.overwrite = dlOverwrite.state == .on
        o.overwriteOnlyIfDifferent = o.overwrite && dlOnlyDifferent.state == .on
        o.overwriteOnlyBefore = o.overwrite && dlOverwriteBefore.state == .on ? dlOverwriteDate.dateValue : nil
        o.autosaveMinutes = dlAutosave.state == .on ? max(1, dlAutosaveMin.integerValue) : nil
        o.autosavePrefix = dlAutosave.state == .on && dlPrefixCheck.state == .on ? dlPrefix.stringValue : ""
        o.parts = dlSplit.state == .on ? max(2, dlParts.integerValue) : 1
        if let limit = m.bulkLimit {
            let n = dlZooms.selected.reduce(0) { $0 + region.tileCount($1) }
            if n > limit {
                let a = NSAlert()
                a.messageText = "Bulk download not allowed for \(m.name)"
                a.informativeText = (m.policyNote ?? "") + " This selection has \(n) tiles (limit \(limit)). Choose a smaller area, or another map such as Humanitarian (OSM), CyclOSM or OpenTopoMap."
                a.runModal()
                return
            }
        }
        let s = DownloadSession(map: m, region: region, zooms: dlZooms.selected, options: o)
        DownloadProgressController.open(session: s, main: main)
    }

    private func startDelete() {
        guard let m = selectedMap(delMap), !delZooms.selected.isEmpty, !region.polygon.isEmpty,
              delTiles.state == .on || delTNE.state == .on, let w = window else { NSSound.beep(); return }
        let zooms = delZooms.selected.sorted()
        let total = zooms.reduce(0) { $0 + region.tileCount($1) }
        let a = NSAlert()
        a.messageText = "Delete tiles from the cache?"
        a.informativeText = "\(m.name), zoom \(zooms.map { "z\($0 + 1)" }.joined(separator: ", ")): up to \(total) tiles in the selection will be permanently deleted from \(Config.shared.cacheURL.appendingPathComponent(m.folder).path). This cannot be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        let reg = self.region, tiles = delTiles.state == .on, tne = delTNE.state == .on
        a.beginSheetModal(for: main?.window ?? w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let it = RegionIterator(region: reg, zooms: zooms)
                var n = 0
                var keys: [TileKey] = []
                while let t = it.next() {
                    if TileStorage.shared.delete(m, t.x, t.y, t.z, tiles: tiles, tne: tne) {
                        n += 1
                        keys.append(TileKey(mapId: m.id, x: t.x, y: t.y, z: t.z))
                    }
                }
                DispatchQueue.main.async {
                    keys.forEach(TileProvider.shared.invalidate)
                    FillMapLayer.shared.invalidate()
                    let done = NSAlert()
                    done.messageText = "The task is completed!"
                    done.informativeText = "Deleted \(n) tile\(n == 1 ? "" : "s")."
                    if let w = self?.main?.window { done.beginSheetModal(for: w) } else { done.runModal() }
                }
            }
        }
    }

    private func copyBBox() {
        let b = region.bbox
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(format: "%.8f,%.8f,%.8f,%.8f", b.w, b.s, b.e, b.n), forType: .string)
    }

    func fitToScreen() {
        guard let map = main?.map, !region.polygon.isEmpty else { return }
        let b = region.bbox
        let size = map.bounds.size
        var z = 23
        while z > 0 {
            let a = Geo.pixel(LonLat(lon: b.w, lat: b.n), z), c = Geo.pixel(LonLat(lon: b.e, lat: b.s), z)
            if c.x - a.x <= size.width * 0.9 && c.y - a.y <= size.height * 0.9 { break }
            z -= 1
        }
        map.setCenter(LonLat(lon: (b.w + b.e) / 2, lat: (Geo.lonLat(CGPoint(x: 0, y: (Geo.pixel(LonLat(lon: 0, lat: b.n), z).y + Geo.pixel(LonLat(lon: 0, lat: b.s), z).y) / 2), z)).lat), zoom: z)
    }

    private func saveSelection() {
        guard let w = window, !region.polygon.isEmpty else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "selection.hlg"
        p.allowExtensions(["hlg"])
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url, let self = self else { return }
            try? HLG.write(self.region.polygon, zoom: self.main?.map.zoom ?? 0, to: u)
        }
    }

    func windowWillClose(_ notification: Notification) {}

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === stPath { stPathEdited = true }
        if (obj.object as? NSTextField) === exPath { exPathEdited = true }
    }

    func refreshCoverage() { if window?.isVisible == true { updateStats() } }
}

enum HLG {
    static func write(_ poly: [LonLat], zoom: Int, to url: URL) throws {
        var lines = ["[HIGHLIGHTING]", "Zoom=\(zoom)"]
        for (i, p) in poly.enumerated() {
            lines.append("PointLon_\(i + 1)=\(p.lon)")
            lines.append("PointLat_\(i + 1)=\(p.lat)")
        }
        try (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(_ url: URL) -> [LonLat]? {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1251)) else { return nil }
        var lon: [Int: Double] = [:], lat: [Int: Double] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[..<eq]).lowercased(), v = String(l[l.index(after: eq)...]).replacingOccurrences(of: ",", with: ".")
            if k.hasPrefix("pointlon_"), let i = Int(k.dropFirst(9)) { lon[i] = Double(v) ?? .nan }
            if k.hasPrefix("pointlat_"), let i = Int(k.dropFirst(9)) { lat[i] = Double(v) ?? .nan }
        }
        var out: [LonLat] = []
        for i in lon.keys.sorted() {
            guard let a = lon[i], let b = lat[i] else { continue }
            if a.isNaN || b.isNaN { if !out.isEmpty { break } else { continue } }
            out.append(LonLat(lon: a, lat: b))
        }
        return out.count >= 3 ? out : nil
    }
}
