import AppKit

// MARK: - Status bar (u_WindowLayerStatusBar.pas)

/// Semi-transparent bar drawn over the bottom of the map:
/// "z17 | N36°49'52.4036" W2°27'48.2969" | 1,91 m/pixel | Downloaded 2671 (33,4 MB) | Queue 0 | File …"
final class StatusBarView: NSView {
    static let height: CGFloat = 19
    var items: [String] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var filePath: String = "" { didSet { if filePath != oldValue { needsDisplay = true } } }

    private let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Arial", size: 12) ?? NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.white,
    ]

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the map

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0x50 / 255.0).setFill()
        bounds.fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var x: CGFloat = -10
        var prev = ""
        var all = items
        all.append("File " + filePath)
        for (i, s) in all.enumerated() {
            x += prev.isEmpty ? 20 : (prev as NSString).size(withAttributes: attrs).width + 20
            var text = s
            if i == all.count - 1 {
                // shorten the path from the middle like SAS does
                let avail = bounds.width - x - 10
                if (text as NSString).size(withAttributes: attrs).width > avail, avail > 60 {
                    var n = filePath.count
                    repeat {
                        n -= max(1, n / 12)
                        text = "File " + filePath.prefix(6) + "..." + filePath.suffix(max(0, n))
                    } while n > 0 && (text as NSString).size(withAttributes: attrs).width > avail
                }
            }
            if i > 0 {
                NSColor(calibratedWhite: 0, alpha: 125 / 255).setFill()
                NSRect(x: x - 10, y: 0, width: 1, height: bounds.height).fill()
            }
            (text as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: attrs)
            prev = text
        }
    }
}

// MARK: - Overview map (mini map)

final class MiniMapView: NSView {
    weak var main: MapView?
    let provider = TileProvider.shared
    private var dragOffset: CGPoint?
    static let size = NSSize(width: 160, height: 160)

    override var isFlipped: Bool { true }

    init(main: MapView) {
        self.main = main
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        if #available(macOS 14, *) { clipsToBounds = true }
        provider.onUpdate.append { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var delta: Int { Config.shared.miniMapZoomDelta }
    private var zoom: Int { max(0, (main?.zoom ?? 0) - delta) }
    private var factor: CGFloat { pow(2, CGFloat((main?.zoom ?? 0) - zoom)) }
    private var center: CGPoint {
        guard let m = main else { return .zero }
        return CGPoint(x: m.center.x / factor, y: m.center.y / factor)
    }
    private var origin: CGPoint {
        CGPoint(x: (center.x - bounds.width / 2).rounded(), y: (center.y - bounds.height / 2).rounded())
    }
    private var plusRect: CGRect { CGRect(x: 3, y: 3, width: 13, height: 13) }
    private var minusRect: CGRect { CGRect(x: 19, y: 3, width: 13, height: 13) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let m = main else { return }
        ctx.clip(to: bounds)
        ctx.setFillColor(NSColor(calibratedWhite: 0.85, alpha: 1).cgColor)
        ctx.fill(bounds)
        var want = Set<TileKey>()
        let o = origin
        TileRenderer.draw(m.mainMap, ctx: ctx, zoom: zoom, origin: o, vis: bounds, usePrev: true, want: &want)
        provider.setWanted(want, client: "mini")

        // main view rectangle
        let f = factor
        let r = CGRect(x: (m.center.x - m.bounds.width / 2) / f - o.x, y: (m.center.y - m.bounds.height / 2) / f - o.y,
                       width: m.bounds.width / f, height: m.bounds.height / f)
        ctx.setFillColor(NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 0.15).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor.blue.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))

        // +/- buttons
        for (rect, minus) in [(plusRect, false), (minusRect, true)] {
            ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.3, alpha: 0.9).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: rect.minX + 3.5, y: rect.midY)); ctx.addLine(to: CGPoint(x: rect.maxX - 3.5, y: rect.midY))
            if !minus { ctx.move(to: CGPoint(x: rect.midX, y: rect.minY + 3.5)); ctx.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3.5)) }
            ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.2, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // "+" shows more detail (smaller delta), "-" shows more area
        if plusRect.insetBy(dx: -2, dy: -2).contains(p) { Config.shared.miniMapZoomDelta = delta - 1; needsDisplay = true; return }
        if minusRect.insetBy(dx: -2, dy: -2).contains(p) { Config.shared.miniMapZoomDelta = delta + 1; needsDisplay = true; return }
        guard let m = main else { return }
        let f = factor, o = origin
        let viewRect = CGRect(x: (m.center.x - m.bounds.width / 2) / f - o.x, y: (m.center.y - m.bounds.height / 2) / f - o.y,
                              width: m.bounds.width / f, height: m.bounds.height / f)
        if viewRect.contains(p) {
            dragOffset = CGPoint(x: p.x - viewRect.midX, y: p.y - viewRect.midY)
        } else {
            dragOffset = .zero
            moveMain(to: p)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let off = dragOffset else { return }
        let p = convert(e.locationInWindow, from: nil)
        moveMain(to: CGPoint(x: p.x - off.x, y: p.y - off.y))
    }

    override func mouseUp(with e: NSEvent) { dragOffset = nil }

    private func moveMain(to p: CGPoint) {
        guard let m = main else { return }
        let o = origin, f = factor
        m.setCenterPixel(CGPoint(x: (o.x + p.x) * f, y: (o.y + p.y) * f))
    }
}

// MARK: - Zoom toolbar (left dock: zoom in, slider, zoom out, "z17")

final class ZoomBarView: NSView {
    var zoom = 0 { didSet { if !tracking { sliderZoom = zoom }; needsDisplay = true } }
    var onZoom: ((Int) -> Void)?
    private var sliderZoom = 0
    private var tracking = false
    private var hover: Int? // 0 = in, 1 = out

    static let width: CGFloat = 31
    override var isFlipped: Bool { true }

    private var inRect: CGRect { CGRect(x: 1, y: 4, width: 29, height: 29) }
    private var sliderRect: CGRect {
        let r = Icons.ruler?.size ?? NSSize(width: 19, height: 175)
        return CGRect(x: (bounds.width - r.width) / 2, y: inRect.maxY + 3, width: r.width, height: r.height)
    }
    private var outRect: CGRect { CGRect(x: 1, y: sliderRect.maxY + 3, width: 29, height: 29) }
    private var labelRect: CGRect { CGRect(x: 0, y: outRect.maxY + 4, width: bounds.width, height: 16) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        for (i, r) in [inRect, outRect].enumerated() {
            if hover == i { ToolButton.drawHot(r, pressed: false) }
            if let img = Icons.menu(i == 0 ? 23 : 24, size: 18) {
                img.draw(in: CGRect(x: r.midX - 9, y: r.midY - 9, width: 18, height: 18), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let s = sliderRect
        Icons.ruler?.draw(in: s, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let t = Icons.tumbler {
            // PaintZSlider: Y := H - (H div 24) * (zoom + 1) - (tumbler.H div 2)
            let H = s.height
            let y = s.minY + H - floor(H / 24) * CGFloat(sliderZoom + 1) - floor(t.size.height / 2)
            t.draw(in: CGRect(x: s.midX - t.size.width / 2, y: y, width: t.size.width, height: t.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        ("z\(sliderZoom + 1)" as NSString).draw(in: labelRect, withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedRed: 0, green: 0.4, blue: 0.8, alpha: 1),
            .paragraphStyle: style,
        ])
    }

    private func sliderZoom(at p: CGPoint) -> Int? {
        let s = sliderRect
        let h = floor(s.height / 24)
        let xy = s.maxY - p.y
        guard xy >= h, xy <= h * 24 + h - 1 else { return nil }
        return max(0, min(23, Int(xy / h) - 1))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h: Int? = inRect.contains(p) ? 0 : (outRect.contains(p) ? 1 : nil)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if inRect.contains(p) { onZoom?(zoom + 1); return }
        if outRect.contains(p) { onZoom?(zoom - 1); return }
        if sliderRect.insetBy(dx: -4, dy: 0).contains(p), let z = sliderZoom(at: p) {
            tracking = true; sliderZoom = z; needsDisplay = true
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard tracking, let z = sliderZoom(at: convert(e.locationInWindow, from: nil)) else { return }
        sliderZoom = z
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard tracking else { return }
        tracking = false
        onZoom?(sliderZoom)
    }
}
