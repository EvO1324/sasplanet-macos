import AppKit
import CoreImage

enum MapTool {
    case move, distance, circle, selectRect, selectPolygon
}

/// The main map (SAS.Planet: frmMain.map + its layers).
final class MapView: NSView {
    let provider = TileProvider.shared
    let cfg = Config.shared

    private(set) var zoom = 0
    private(set) var center = CGPoint.zero  // world pixels at `zoom`

    var mainMap: MapType { didSet { needsDisplay = true; onViewChanged?() } }
    var layers: [MapType] = [] { didSet { needsDisplay = true } }

    var tool: MapTool = .move {
        didSet { cancelToolState(); window?.invalidateCursorRects(for: self); onToolChanged?() }
    }

    /// Finished selection polygon, shown as "previous selection"
    var selection: [LonLat]? { didSet { needsDisplay = true } }
    var showSelection = true { didSet { needsDisplay = true } }
    var searchMarker: LonLat? { didSet { needsDisplay = true } }
    /// Space reserved at the bottom by the status bar (for the scale legend)
    var bottomInset: CGFloat = 0 { didSet { needsDisplay = true } }

    var onViewChanged: (() -> Void)?
    var onMouseMoved: (() -> Void)?
    var onToolChanged: (() -> Void)?
    var onSelectionFinished: (([LonLat]) -> Void)?

    private(set) var mouseLocal: CGPoint?

    // zoom animation
    private var displayScale: CGFloat = 1
    private var animAnchor = CGPoint.zero
    private var animFrom: CGFloat = 1
    private var animStart: CFTimeInterval = 0
    private var animTimer: Timer?

    // dragging / inertia
    private var downPoint: CGPoint?
    private var downCenter = CGPoint.zero
    private var isPanning = false
    private var samples: [(CFTimeInterval, CGPoint)] = []
    private var inertiaTimer: Timer?
    private var velocity = CGPoint.zero
    private var wheelAccum: CGFloat = 0
    private var magnifyAccum: CGFloat = 0

    // tool state
    private var calcPoints: [LonLat] = []
    private var circleCenter: LonLat?
    private var circleEdge: LonLat?
    private var circleFixed = false
    private var selPoints: [LonLat] = []
    private var rectStart: LonLat?
    private var rectFirstDown = false

    // keys held on the map: 117 = forward Delete, 114 = Insert/Help; arrows for smooth moving
    private var heldKeys = Set<UInt16>()
    private var arrowTimer: Timer?
    private var arrowStart: CFTimeInterval = 0
    private var arrowLast: CFTimeInterval = 0

    init(map: MapType) {
        mainMap = map
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 14, *) { clipsToBounds = true }
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        provider.onUpdate.append { [weak self] in self?.needsDisplay = true }
        FillMapLayer.shared.onUpdate.append { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Coordinates

    var origin: CGPoint {
        CGPoint(x: (center.x - bounds.width / 2).rounded(), y: (center.y - bounds.height / 2).rounded())
    }

    func viewPoint(_ ll: LonLat) -> CGPoint {
        let p = Geo.pixel(ll, zoom), o = origin
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    func lonLat(_ p: CGPoint) -> LonLat {
        let o = origin
        return Geo.lonLat(CGPoint(x: o.x + p.x, y: o.y + p.y), zoom)
    }

    var centerLonLat: LonLat { Geo.lonLat(center, zoom) }

    /// Lon/lat under the mouse, or of the centre when the mouse is outside.
    var cursorLonLat: LonLat { mouseLocal.map(lonLat) ?? centerLonLat }

    /// Visible area as (west, south, east, north)
    var visibleLonLatRect: (w: Double, s: Double, e: Double, n: Double) {
        let a = lonLat(.zero), b = lonLat(CGPoint(x: bounds.width, y: bounds.height))
        return (a.lon, b.lat, b.lon, a.lat)
    }

    private func clampCenter() {
        let w = CGFloat(Geo.worldSize(zoom))
        center.x = min(max(center.x, 0), w)
        center.y = min(max(center.y, 0), w)
    }

    // MARK: - Navigation

    func setCenter(_ ll: LonLat, zoom z: Int? = nil) {
        stopAnimations()
        if let z = z { zoom = max(0, min(23, z)) }
        center = Geo.pixel(ll, zoom)
        clampCenter()
        viewChanged()
    }

    func setCenterPixel(_ p: CGPoint) {
        center = p
        clampCenter()
        viewChanged()
    }

    func setZoom(_ newZoom: Int, anchor a: CGPoint? = nil, animated: Bool = true) {
        let nz = max(0, min(23, newZoom))
        guard nz != zoom else { return }
        stopInertia()
        let anchor = a ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let world = CGPoint(x: center.x - bounds.width / 2 + anchor.x, y: center.y - bounds.height / 2 + anchor.y)
        let f = pow(2, CGFloat(nz - zoom))
        center = CGPoint(x: world.x * f - anchor.x + bounds.width / 2, y: world.y * f - anchor.y + bounds.height / 2)
        zoom = nz
        clampCenter()
        if animated && cfg.zoomAnimation && window != nil {
            animAnchor = anchor
            animFrom = displayScale / f
            displayScale = animFrom
            animStart = CACurrentMediaTime()
            if animTimer == nil {
                animTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.animTick() }
            }
        } else {
            displayScale = 1
        }
        viewChanged()
    }

    func zoomIn(at p: CGPoint? = nil) { setZoom(zoom + 1, anchor: p) }
    func zoomOut(at p: CGPoint? = nil) { setZoom(zoom - 1, anchor: p) }

    private func animTick() {
        let t = min(1, (CACurrentMediaTime() - animStart) / 0.2)
        let e = 1 - pow(1 - t, 3)
        displayScale = animFrom + (1 - animFrom) * CGFloat(e)
        if t >= 1 {
            displayScale = 1
            animTimer?.invalidate()
            animTimer = nil
        }
        needsDisplay = true
    }

    private func stopAnimations() {
        animTimer?.invalidate(); animTimer = nil; displayScale = 1
        stopInertia()
    }

    private func stopInertia() { inertiaTimer?.invalidate(); inertiaTimer = nil }

    private func viewChanged() {
        needsDisplay = true
        onViewChanged?()
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        center.x += dx
        center.y += dy
        clampCenter()
        viewChanged()
    }

    // MARK: - Drawing

    var nightMode = false {
        didSet {
            layerUsesCoreImageFilters = true
            layer?.filters = nightMode ? [CIFilter(name: "CIColorInvert")!] : []
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        ctx.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
        ctx.fill(bounds)

        ctx.saveGState()
        var vis = bounds
        if displayScale != 1 {
            ctx.translateBy(x: animAnchor.x, y: animAnchor.y)
            ctx.scaleBy(x: displayScale, y: displayScale)
            ctx.translateBy(x: -animAnchor.x, y: -animAnchor.y)
            vis = CGRect(x: animAnchor.x - animAnchor.x / displayScale,
                         y: animAnchor.y - animAnchor.y / displayScale,
                         width: bounds.width / displayScale, height: bounds.height / displayScale)
        }
        let o = origin
        var want = Set<TileKey>()
        // area outside the world
        let w = CGFloat(Geo.worldSize(zoom))
        ctx.setFillColor(NSColor(calibratedWhite: 0.80, alpha: 1).cgColor)
        ctx.fill(vis)
        ctx.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
        ctx.fill(CGRect(x: -o.x, y: -o.y, width: w, height: w).intersection(vis))

        TileRenderer.draw(mainMap, ctx: ctx, zoom: zoom, origin: o, vis: vis, usePrev: cfg.usePrevForMap, want: &want)
        for l in layers {
            TileRenderer.draw(l, ctx: ctx, zoom: zoom, origin: o, vis: vis, usePrev: cfg.usePrevForLayers, want: &want)
        }
        drawFillMap(ctx, vis: vis, origin: o)
        drawTileGrid(ctx, vis: vis, origin: o)
        drawLonLatGrid(ctx, vis: vis)
        if showSelection, let sel = selection { drawPolygon(ctx, sel, closed: true, editing: false) }
        drawToolOverlay(ctx)
        if let m = searchMarker, let img = Icons.foundPoint {
            let p = viewPoint(m)
            img.draw(in: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        ctx.restoreGState()

        if cfg.scaleLineVisible { drawScaleLegend(ctx) }
        provider.setWanted(want, client: "main")
    }

    private func drawFillMap(_ ctx: CGContext, vis: CGRect, origin o: CGPoint) {
        let fz = cfg.fillZoom
        guard fz >= 0, fz - zoom <= 7 else { return }
        let m = MapRegistry.byId(cfg.fillMapId) ?? mainMap
        let s = FillMapLayer.Settings(zoom: fz, mapId: cfg.fillMapId, mode: FillMapLayer.Mode(rawValue: cfg.fillMode) ?? .unexisting,
                                      filter: cfg.fillFilter, from: cfg.fillFrom, to: cfg.fillTo)
        let n = 1 << zoom
        let tx0 = max(0, Int(floor((o.x + vis.minX) / 256))), tx1 = min(n - 1, Int(floor((o.x + vis.maxX - 0.01) / 256)))
        let ty0 = max(0, Int(floor((o.y + vis.minY) / 256))), ty1 = min(n - 1, Int(floor((o.y + vis.maxY - 0.01) / 256)))
        guard tx0 <= tx1, ty0 <= ty1 else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        for ty in ty0...ty1 {
            for tx in tx0...tx1 {
                if let img = FillMapLayer.shared.image(map: m, z: zoom, tx: tx, ty: ty, s: s) {
                    TileRenderer.drawImage(ctx, img, CGRect(x: CGFloat(tx) * 256 - o.x, y: CGFloat(ty) * 256 - o.y, width: 256, height: 256))
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawTileGrid(_ ctx: CGContext, vis: CGRect, origin o: CGPoint) {
        let g = cfg.tileGridZoom
        guard g >= 0 else { return }
        let gz = g == 0 ? zoom : g - 1
        guard gz <= zoom + 6 else { return }
        let step = CGFloat(Geo.tileSize) * pow(2, CGFloat(zoom - gz))
        guard step >= 4 else { return }
        let w = CGFloat(Geo.worldSize(zoom))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.6).cgColor)
        ctx.setLineWidth(1)
        var x = floor((o.x + vis.minX) / step) * step
        while x <= min(w, o.x + vis.maxX) {
            let vx = x - o.x + 0.5
            ctx.move(to: CGPoint(x: vx, y: max(vis.minY, -o.y)))
            ctx.addLine(to: CGPoint(x: vx, y: min(vis.maxY, w - o.y)))
            x += step
        }
        var y = floor((o.y + vis.minY) / step) * step
        while y <= min(w, o.y + vis.maxY) {
            let vy = y - o.y + 0.5
            ctx.move(to: CGPoint(x: max(vis.minX, -o.x), y: vy))
            ctx.addLine(to: CGPoint(x: min(vis.maxX, w - o.x), y: vy))
            y += step
        }
        ctx.strokePath()
        if step >= 96 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.red]
            var ty = floor((o.y + vis.minY) / step)
            while ty * step <= min(w - 1, o.y + vis.maxY) {
                var tx = floor((o.x + vis.minX) / step)
                while tx * step <= min(w - 1, o.x + vis.maxX) {
                    if tx >= 0, ty >= 0 {
                        ("z\(gz + 1) x\(Int(tx)) y\(Int(ty))" as NSString)
                            .draw(at: CGPoint(x: tx * step - o.x + 4, y: ty * step - o.y + 3), withAttributes: attrs)
                    }
                    tx += 1
                }
                ty += 1
            }
        }
        ctx.restoreGState()
    }

    private func drawLonLatGrid(_ ctx: CGContext, vis: CGRect) {
        var step = cfg.lonLatGrid
        guard step != 0 else { return }
        if step < 0 {
            // auto: lines roughly 100+ px apart
            let degPerPx = 360 / Geo.worldSize(zoom)
            let candidates = [30, 20, 10, 5, 2, 1, 0.5, 0.25, 0.125, 1.0 / 16, 1.0 / 32, 1.0 / 60, 1.0 / 120, 1.0 / 240, 1.0 / 600, 1.0 / 1200, 1.0 / 3600]
            step = candidates.last { $0 / degPerPx >= 100 } ?? 30
        }
        let a = lonLat(vis.origin), b = lonLat(CGPoint(x: vis.maxX, y: vis.maxY))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.75).cgColor)
        ctx.setLineWidth(1)
        let font = NSFont.systemFont(ofSize: 10)
        var lon = floor(max(-180, a.lon) / step) * step
        var count = 0
        while lon <= min(180, b.lon) && count < 400 {
            let x = viewPoint(LonLat(lon: lon, lat: 0)).x.rounded() + 0.5
            ctx.move(to: CGPoint(x: x, y: vis.minY)); ctx.addLine(to: CGPoint(x: x, y: vis.maxY))
            drawOutlined(Self.gridLabel(lon, pos: "E", neg: "W"), at: CGPoint(x: x + 3, y: vis.minY + 2), font: font)
            lon += step; count += 1
        }
        var lat = floor(max(-85, b.lat) / step) * step
        count = 0
        while lat <= min(85, a.lat) && count < 400 {
            let y = viewPoint(LonLat(lon: 0, lat: lat)).y.rounded() + 0.5
            ctx.move(to: CGPoint(x: vis.minX, y: y)); ctx.addLine(to: CGPoint(x: vis.maxX, y: y))
            drawOutlined(Self.gridLabel(lat, pos: "N", neg: "S"), at: CGPoint(x: vis.minX + 32, y: y - 14), font: font)
            lat += step; count += 1
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func gridLabel(_ v: Double, pos: String, neg: String) -> String {
        let a = abs(v)
        let d = Int(a), m = Int(((a - Double(d)) * 60).rounded(.down)), s = ((a - Double(d)) * 3600 - Double(m) * 60).rounded()
        var t = "\(v < 0 ? neg : pos)\(d)°"
        if m != 0 || s != 0 { t += String(format: "%02d'", m) }
        if s != 0 { t += String(format: "%02d\"", Int(s)) }
        return t
    }

    func drawOutlined(_ s: String, at p: CGPoint, font: NSFont, color: NSColor = .black, outline: NSColor = .white) {
        let stroke: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: outline, .strokeColor: outline, .strokeWidth: 6]
        (s as NSString).draw(at: p, withAttributes: stroke)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawScaleLegend(_ ctx: CGContext) {
        let ll = centerLonLat
        let mpp = Geo.metersPerPixel(lat: ll.lat, z: zoom)
        // pick a "nice" length that fits in ~ 150 px, then mark half of it as well
        let target = 150 * mpp
        let p10 = pow(10, floor(log10(target)))
        let nice = [5, 2, 1].map { Double($0) * p10 }.first { $0 <= target } ?? p10
        let L = CGFloat(nice / mpp)
        let x0: CGFloat = 12
        let yBase = bounds.height - bottomInset - 14
        let font = NSFont(name: "Arial", size: 11) ?? .systemFont(ofSize: 11)

        func strokeBoth(_ path: CGPath) {
            ctx.addPath(path); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(3); ctx.strokePath()
            ctx.addPath(path); ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
        // horizontal
        let h = CGMutablePath()
        h.move(to: CGPoint(x: x0, y: yBase - 8)); h.addLine(to: CGPoint(x: x0, y: yBase))
        h.addLine(to: CGPoint(x: x0 + L, y: yBase)); h.addLine(to: CGPoint(x: x0 + L, y: yBase - 8))
        h.move(to: CGPoint(x: x0 + L / 2, y: yBase)); h.addLine(to: CGPoint(x: x0 + L / 2, y: yBase - 5))
        strokeBoth(h)
        drawOutlined(Geo.formatDistance(nice / 2), at: CGPoint(x: x0 + L / 2 - 14, y: yBase - 22), font: font)
        drawOutlined(Geo.formatDistance(nice), at: CGPoint(x: x0 + L - 14, y: yBase - 22), font: font)
        // vertical
        let yTop = yBase - 30 - L
        let v = CGMutablePath()
        v.move(to: CGPoint(x: x0 + 8, y: yTop)); v.addLine(to: CGPoint(x: x0, y: yTop))
        v.addLine(to: CGPoint(x: x0, y: yTop + L)); v.addLine(to: CGPoint(x: x0 + 8, y: yTop + L))
        v.move(to: CGPoint(x: x0, y: yTop + L / 2)); v.addLine(to: CGPoint(x: x0 + 5, y: yTop + L / 2))
        if yTop > 20 {
            strokeBoth(v)
            drawOutlined(Geo.formatDistance(nice), at: CGPoint(x: x0 + 4, y: yTop - 16), font: font)
            drawOutlined(Geo.formatDistance(nice / 2), at: CGPoint(x: x0 + 8, y: yTop + L / 2 - 8), font: font)
        }
    }

    // MARK: - Tool overlays

    private func drawPolygon(_ ctx: CGContext, _ pts: [LonLat], closed: Bool, editing: Bool) {
        guard !pts.isEmpty else { return }
        let path = CGMutablePath()
        path.addLines(between: pts.map(viewPoint))
        if closed { path.closeSubpath() }
        ctx.saveGState()
        if closed {
            ctx.addPath(path)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: editing ? 0.15 : 0.08).cgColor)
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(2)
        if editing { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawToolOverlay(_ ctx: CGContext) {
        let mouseLL = mouseLocal.map(lonLat)
        switch tool {
        case .distance:
            var pts = calcPoints
            if let m = mouseLL, !pts.isEmpty { pts.append(m) }
            guard !pts.isEmpty else { return }
            let vp = pts.map(viewPoint)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.85).cgColor)
            ctx.setLineWidth(2)
            ctx.addLines(between: vp)
            ctx.strokePath()
            var total = 0.0
            let font = NSFont.boldSystemFont(ofSize: 11)
            for i in 0..<vp.count {
                if i > 0 { total += Geo.distance(pts[i - 1], pts[i]) }
                let r = CGRect(x: vp[i].x - 3.5, y: vp[i].y - 3.5, width: 7, height: 7)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: r)
                ctx.setStrokeColor(NSColor.red.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
                if i > 0 {
                    let seg = Geo.distance(pts[i - 1], pts[i])
                    let txt = i == vp.count - 1 && vp.count > 2
                        ? "\(Geo.formatDistance(total)) (+\(Geo.formatDistance(seg)))"
                        : Geo.formatDistance(total)
                    drawLabelBox(txt, at: CGPoint(x: vp[i].x + 8, y: vp[i].y - 8), font: font)
                }
            }
            ctx.restoreGState()
        case .circle:
            guard let c = circleCenter, let e = circleFixed ? circleEdge : mouseLL else { return }
            let cp = viewPoint(c)
            let rM = Geo.distance(c, e)
            let rPx = CGFloat(rM / Geo.metersPerPixel(lat: c.lat, z: zoom))
            ctx.saveGState()
            ctx.setFillColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.12).cgColor)
            ctx.fillEllipse(in: CGRect(x: cp.x - rPx, y: cp.y - rPx, width: rPx * 2, height: rPx * 2))
            ctx.setStrokeColor(NSColor.red.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: cp.x - rPx, y: cp.y - rPx, width: rPx * 2, height: rPx * 2))
            ctx.move(to: cp); ctx.addLine(to: viewPoint(e)); ctx.strokePath()
            ctx.restoreGState()
            let area = Double.pi * rM * rM
            let areaTxt = area < 1_000_000 ? "\(Geo.fmt(area, 0)) m²" : "\(Geo.fmt(area / 1_000_000, 3)) km²"
            drawLabelBox("R = \(Geo.formatDistance(rM))   S = \(areaTxt)", at: CGPoint(x: cp.x + 8, y: cp.y + 6),
                         font: .boldSystemFont(ofSize: 11))
        case .selectRect:
            if let a = rectStart, let b = mouseLL {
                let bb = NSEvent.modifierFlags.contains(.shift) ? snapLL(b) : b
                drawPolygon(ctx, Self.rectPolygon(a, bb), closed: true, editing: true)
            }
        case .selectPolygon:
            var pts = selPoints
            if let m = mouseLL, !pts.isEmpty { pts.append(m) }
            drawPolygon(ctx, pts, closed: pts.count > 2, editing: true)
            ctx.saveGState()
            for p in selPoints.map(viewPoint) {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.stroke(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            }
            ctx.restoreGState()
        case .move:
            break
        }
    }

    private func drawLabelBox(_ s: String, at p: CGPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = (s as NSString).size(withAttributes: attrs)
        let r = CGRect(x: p.x, y: p.y, width: size.width + 8, height: size.height + 2)
        NSColor(calibratedRed: 1, green: 1, blue: 0.88, alpha: 0.9).setFill()
        NSBezierPath(rect: r).fill()
        NSColor.black.setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        (s as NSString).draw(at: CGPoint(x: p.x + 4, y: p.y + 1), withAttributes: attrs)
    }

    static func rectPolygon(_ a: LonLat, _ b: LonLat) -> [LonLat] {
        let w = min(a.lon, b.lon), e = max(a.lon, b.lon), s = min(a.lat, b.lat), n = max(a.lat, b.lat)
        return [LonLat(lon: w, lat: n), LonLat(lon: e, lat: n), LonLat(lon: e, lat: s), LonLat(lon: w, lat: s)]
    }

    // MARK: - Tool state

    func cancelToolState() {
        calcPoints = []
        circleCenter = nil; circleEdge = nil; circleFixed = false
        selPoints = []
        rectStart = nil; rectFirstDown = false
        needsDisplay = true
    }

    private func finishSelection(_ poly: [LonLat]) {
        selection = poly
        cancelToolState()
        onSelectionFinished?(poly)
    }

    func finishPolygon() {
        guard tool == .selectPolygon, selPoints.count >= 3 else { return }
        finishSelection(selPoints)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .move ? .arrow : .crosshair)
    }

    override func mouseMoved(with e: NSEvent) {
        mouseLocal = convert(e.locationInWindow, from: nil)
        if tool != .move { needsDisplay = true }
        onMouseMoved?()
    }

    override func mouseExited(with e: NSEvent) {
        mouseLocal = nil
        onMouseMoved?()
        if tool != .move { needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        stopInertia()
        downPoint = p
        downCenter = center
        isPanning = false
        samples = [(e.timestamp, p)]
        if heldKeys.contains(117) || heldKeys.contains(114) {
            tileKeyClick(p, delete: heldKeys.contains(117))
            downPoint = nil
            return
        }
        if tool == .move && e.clickCount == 2 {
            zoomIn(at: cfg.zoomToCursor ? p : nil)
            downPoint = nil
            return
        }
        if tool == .selectRect && rectStart == nil {
            rectStart = snapped(lonLat(p), e)
            rectFirstDown = true
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouseLocal = p
        onMouseMoved?()
        guard let d = downPoint else { return }
        if tool == .selectRect && rectFirstDown {
            needsDisplay = true
            return
        }
        if !isPanning && hypot(p.x - d.x, p.y - d.y) > 3 {
            isPanning = true
            NSCursor.closedHand.push()
        }
        if isPanning {
            center = CGPoint(x: downCenter.x - (p.x - d.x), y: downCenter.y - (p.y - d.y))
            clampCenter()
            samples.append((e.timestamp, p))
            if samples.count > 8 { samples.removeFirst() }
            viewChanged()
        }
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        defer { downPoint = nil }
        if isPanning {
            isPanning = false
            NSCursor.pop()
            startInertia(e.timestamp)
            return
        }
        guard let d = downPoint else { return }
        let ll = lonLat(p)
        switch tool {
        case .move:
            break
        case .distance:
            calcPoints.append(ll)
        case .circle:
            if circleCenter == nil || circleFixed {
                circleCenter = ll; circleFixed = false
            } else {
                circleEdge = ll; circleFixed = true
            }
        case .selectRect:
            let sll = snapped(ll, e)
            if rectFirstDown {
                rectFirstDown = false
                if hypot(p.x - d.x, p.y - d.y) > 3, let a = rectStart {
                    finishSelection(Self.rectPolygon(a, sll))
                }
            } else if let a = rectStart {
                finishSelection(Self.rectPolygon(a, sll))
            }
        case .selectPolygon:
            if e.clickCount >= 2 { finishPolygon() } else { selPoints.append(ll) }
        }
        needsDisplay = true
    }

    private func startInertia(_ t: TimeInterval) {
        guard cfg.inertialMovement, let first = samples.first, let last = samples.last else { return }
        let dt = last.0 - first.0
        guard dt > 0.01, t - last.0 < 0.08 else { return }
        velocity = CGPoint(x: (last.1.x - first.1.x) / CGFloat(dt), y: (last.1.y - first.1.y) / CGFloat(dt))
        guard hypot(velocity.x, velocity.y) > 250 else { return }
        var prev = CACurrentMediaTime()
        inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let now = CACurrentMediaTime(), dt = CGFloat(now - prev)
            prev = now
            self.center.x -= self.velocity.x * dt
            self.center.y -= self.velocity.y * dt
            self.clampCenter()
            let k = pow(0.04, dt)  // decay
            self.velocity.x *= k; self.velocity.y *= k
            self.viewChanged()
            if hypot(self.velocity.x, self.velocity.y) < 15 { self.stopInertia() }
        }
    }

    override func rightMouseDown(with e: NSEvent) { otherDown(e) }
    override func rightMouseDragged(with e: NSEvent) { otherDragged(e) }
    override func otherMouseDown(with e: NSEvent) { otherDown(e) }
    override func otherMouseDragged(with e: NSEvent) { otherDragged(e) }

    private var otherStart: (CGPoint, CGPoint)?
    private func otherDown(_ e: NSEvent) {
        stopInertia()
        otherStart = (convert(e.locationInWindow, from: nil), center)
    }
    private func otherDragged(_ e: NSEvent) {
        guard let (p0, c0) = otherStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        center = CGPoint(x: c0.x - (p.x - p0.x), y: c0.y - (p.y - p0.y))
        clampCenter()
        viewChanged()
    }

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let anchor = cfg.zoomToCursor ? p : nil
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // trackpad / Magic Mouse: two-finger scroll pans (hold ⌘ to zoom)
            stopInertia()
            pan(dx: -e.scrollingDeltaX, dy: -e.scrollingDeltaY)
            return
        }
        // mouse wheel: one notch = one zoom level (as in SAS.Planet)
        wheelAccum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 40 : e.scrollingDeltaY
        if wheelAccum >= 1 { wheelAccum = 0; zoomIn(at: anchor) }
        else if wheelAccum <= -1 { wheelAccum = 0; zoomOut(at: anchor) }
    }

    override func magnify(with e: NSEvent) {
        magnifyAccum += e.magnification
        let p = convert(e.locationInWindow, from: nil)
        if magnifyAccum > 0.3 { magnifyAccum = 0; zoomIn(at: cfg.zoomToCursor ? p : nil) }
        else if magnifyAccum < -0.25 { magnifyAccum = 0; zoomOut(at: cfg.zoomToCursor ? p : nil) }
        if e.phase == .ended || e.phase == .cancelled { magnifyAccum = 0 }
    }

    override func keyUp(with e: NSEvent) {
        heldKeys.remove(e.keyCode)
        if [123, 124, 125, 126].contains(e.keyCode) && !heldKeys.contains(where: { (123...126).contains($0) }) {
            arrowTimer?.invalidate(); arrowTimer = nil
        }
    }

    /// SAS key moving: 30 px on first press, then 20 -> 1024 px/s over 3 s while held (TKeyMovingConfig)
    private func arrowTick() {
        let now = CACurrentMediaTime(), dt = now - arrowLast
        arrowLast = now
        let held = now - arrowStart
        let speed = 20 + (1024 - 20) * min(1, held / 3)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if heldKeys.contains(123) { dx -= 1 }
        if heldKeys.contains(124) { dx += 1 }
        if heldKeys.contains(125) { dy += 1 }
        if heldKeys.contains(126) { dy -= 1 }
        if dx == 0 && dy == 0 { arrowTimer?.invalidate(); arrowTimer = nil; return }
        pan(dx: dx * CGFloat(speed * dt), dy: dy * CGFloat(speed * dt))
    }

    override func keyDown(with e: NSEvent) {
        let step: CGFloat = 30
        if [123, 124, 125, 126, 117, 114].contains(e.keyCode) {
            if e.isARepeat { return }
            heldKeys.insert(e.keyCode)
            if e.keyCode == 117 || e.keyCode == 114 { return }
            if arrowTimer == nil {
                arrowStart = CACurrentMediaTime(); arrowLast = arrowStart
                arrowTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.arrowTick() }
            }
        }
        switch e.keyCode {
        case 123: pan(dx: -step, dy: 0)       // left
        case 124: pan(dx: step, dy: 0)        // right
        case 125: pan(dx: 0, dy: step)        // down
        case 126: pan(dx: 0, dy: -step)       // up
        case 53:                               // Esc
            if tool != .move && (calcPoints.isEmpty && selPoints.isEmpty && rectStart == nil && circleCenter == nil) {
                tool = .move
            } else { cancelToolState() }
        case 36, 76: finishPolygon()          // Return / Enter
        case 51, 117:                          // Backspace / Delete
            if tool == .distance, !calcPoints.isEmpty { calcPoints.removeLast() }
            if tool == .selectPolygon, !selPoints.isEmpty { selPoints.removeLast() }
            needsDisplay = true
        default:
            switch e.charactersIgnoringModifiers {
            case "+", "=": zoomIn()
            case "-", "_": zoomOut()
            default: super.keyDown(with: e)
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        heldKeys.removeAll(); arrowTimer?.invalidate(); arrowTimer = nil
        return super.resignFirstResponder()
    }

    // MARK: - Delete / Insert + click (SAS: VK_DELETE / VK_INSERT held while clicking)

    private func tileKeyClick(_ p: CGPoint, delete: Bool) {
        let m = mainMap
        let z = min(zoom, m.maxZoom)
        let w = Geo.pixel(lonLat(p), z)
        let n = (1 << z) - 1
        let x = max(0, min(n, Int(w.x / 256))), y = max(0, min(n, Int(w.y / 256)))
        let key = TileKey(mapId: m.id, x: x, y: y, z: z)
        if delete {
            TileStorage.shared.delete(m, x, y, z)
            provider.invalidate(key)
            FillMapLayer.shared.invalidateSoon()
            return
        }
        TileFetcher.shared.fetch(m, x: x, y: y, z: z) { r in
            switch r {
            case .tile(let d, let ext): TileStorage.shared.write(d, ext: ext, m, x, y, z)
            case .notFound: TileStorage.shared.writeTNE(m, x, y, z)
            case .failed: break
            }
            DispatchQueue.main.async { TileProvider.shared.invalidate(key); FillMapLayer.shared.invalidateSoon() }
        }
    }

    // MARK: - Shift snapping (rectangle selection)

    private func snapped(_ ll: LonLat, _ e: NSEvent) -> LonLat {
        e.modifierFlags.contains(.shift) ? snapLL(ll) : ll
    }

    /// Snap to the visible tile boundaries, or to the lat/lon grid.
    func snapLL(_ ll: LonLat) -> LonLat {
        if cfg.tileGridZoom >= 0 {
            let gz = cfg.tileGridZoom == 0 ? zoom : cfg.tileGridZoom - 1
            let p = Geo.pixel(ll, gz)
            return Geo.lonLat(CGPoint(x: (p.x / 256).rounded() * 256, y: (p.y / 256).rounded() * 256), gz)
        }
        var step = cfg.lonLatGrid
        if step < 0 {
            let degPerPx = 360 / Geo.worldSize(zoom)
            step = [30, 20, 10, 5, 2, 1, 0.5, 0.25, 0.125, 1.0 / 16, 1.0 / 32, 1.0 / 60, 1.0 / 120, 1.0 / 240, 1.0 / 600, 1.0 / 1200, 1.0 / 3600].last { $0 / degPerPx >= 100 } ?? 30
        }
        guard step > 0 else { return ll }
        return LonLat(lon: (ll.lon / step).rounded() * step, lat: (ll.lat / step).rounded() * step)
    }

    // MARK: - Restore

    func restore(_ ll: LonLat, zoom z: Int) {
        zoom = max(0, min(23, z))
        center = Geo.pixel(ll, zoom)
        clampCenter()
    }
}
