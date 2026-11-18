import AppKit

/// A TBX-style toolbar button: icon (+ optional caption), hover highlight, checked state,
/// optional drop-down arrow (whole button) or split arrow (separate menu part).
final class ToolButton: NSView {
    enum Style { case button, dropdown, split }

    var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var title: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var style: Style
    var isChecked = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var hot = false
    private var pressed = false
    private static let arrowW: CGFloat = 12
    private let font = NSFont.systemFont(ofSize: 12)

    init(image: NSImage?, title: String? = nil, tooltip: String? = nil, style: Style = .button, action: (() -> Void)? = nil) {
        self.image = image
        self.title = title
        self.style = style
        self.action = action
        super.init(frame: .zero)
        toolTip = tooltip
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        var w: CGFloat = 6
        if let img = image { w += img.size.width }
        if let t = title { w += (image == nil ? 2 : 5) + (t as NSString).size(withAttributes: [.font: font]).width + 2 }
        if style != .button { w += Self.arrowW }
        return NSSize(width: max(w, 30), height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hot = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hot = false; needsDisplay = true }

    static let hotFill = NSColor(calibratedRed: 193 / 255, green: 210 / 255, blue: 238 / 255, alpha: 1)
    static let hotBorder = NSColor(calibratedRed: 49 / 255, green: 106 / 255, blue: 197 / 255, alpha: 1)
    static let pressedFill = NSColor(calibratedRed: 152 / 255, green: 181 / 255, blue: 226 / 255, alpha: 1)
    static let checkedFill = NSColor(calibratedRed: 225 / 255, green: 230 / 255, blue: 240 / 255, alpha: 1)

    static func drawHot(_ r: CGRect, pressed: Bool) {
        (pressed ? pressedFill : hotFill).setFill()
        r.fill()
        hotBorder.setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        if isEnabled {
            if pressed || (isChecked && hot) {
                Self.drawHot(r, pressed: true)
            } else if hot {
                Self.drawHot(r, pressed: false)
                if style == .split {
                    Self.hotBorder.setFill()
                    NSRect(x: r.maxX - Self.arrowW - 1, y: r.minY, width: 1, height: r.height).fill()
                }
            } else if isChecked {
                Self.checkedFill.setFill(); r.fill()
                Self.hotBorder.setStroke(); NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        var x: CGFloat = 3
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        if let img = image {
            img.draw(in: CGRect(x: x, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x += img.size.width + 5
        } else { x += 2 }
        if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor]
            let sz = (t as NSString).size(withAttributes: attrs)
            (t as NSString).draw(at: NSPoint(x: x, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        }
        if style != .button {
            let ax = bounds.maxX - Self.arrowW / 2 - 1, ay = bounds.midY
            let p = NSBezierPath()
            p.move(to: NSPoint(x: ax - 3, y: ay - 1.5)); p.line(to: NSPoint(x: ax + 3, y: ay - 1.5)); p.line(to: NSPoint(x: ax, y: ay + 1.5))
            p.close()
            (isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor).setFill()
            p.fill()
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        let p = convert(e.locationInWindow, from: nil)
        let onArrow = style == .split && p.x > bounds.maxX - Self.arrowW - 2
        if style == .dropdown || onArrow, let menu = menuProvider?() {
            pressed = true; needsDisplay = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
            pressed = false; hot = false; needsDisplay = true
            return
        }
        pressed = true; needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
    }
}

/// Vertical separator inside a toolbar.
final class ToolSeparator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 3, y: 3, width: 1, height: bounds.height - 6).fill()
    }
}

/// One toolbar (TTBXToolbar): a grip plus its items.
final class ToolbarGroup: NSStackView {
    let key: String
    init(key: String, title: String, items: [NSView]) {
        self.key = key
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 1
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        toolTip = title
        addArrangedSubview(Grip())
        items.forEach(addArrangedSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    final class Grip: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 24) }
        override func draw(_ dirtyRect: NSRect) {
            var y: CGFloat = 4
            while y < bounds.height - 4 {
                NSColor(calibratedWhite: 1, alpha: 1).setFill()
                NSRect(x: 3, y: y, width: 2, height: 2).fill()
                NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
                NSRect(x: 2, y: y + 1, width: 2, height: 2).fill()
                y += 4
            }
        }
    }
}

/// The toolbar dock above the map (TBDock): rows of toolbar groups.
final class ToolbarDock: NSView {
    private let stack = NSStackView()
    private var rows: [NSStackView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func addRow(_ groups: [ToolbarGroup]) {
        let row = NSStackView(views: groups)
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        rows.append(row)
        stack.addArrangedSubview(row)
    }

    func applyVisibility(hidden: Set<String>) {
        for row in rows {
            for case let g as ToolbarGroup in row.arrangedSubviews { g.isHidden = hidden.contains(g.key) }
            row.isHidden = row.arrangedSubviews.allSatisfy { $0.isHidden }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
