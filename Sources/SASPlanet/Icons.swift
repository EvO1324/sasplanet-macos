import AppKit

enum Icons {
    static func resource(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: nil) { return u }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            let u = dir.appendingPathComponent("Resources").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func image(_ name: String) -> NSImage? {
        guard let u = resource(name) else { return nil }
        return NSImage(contentsOf: u)
    }

    static func cgImage(_ name: String) -> CGImage? {
        guard let u = resource(name), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func strip(_ name: String, size: Int) -> [NSImage] {
        guard let cg = cgImage(name) else { return [] }
        return (0..<(cg.height / size)).compactMap { i in
            cg.cropping(to: CGRect(x: 0, y: i * size, width: size, height: size))
                .map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
        }
    }

    static let panels: [NSImage] = strip("PanelsImageList.png", size: 24)
    static let menus: [NSImage] = strip("MenusImageList.png", size: 18)

    static func panel(_ i: Int) -> NSImage? { panels.indices.contains(i) ? panels[i] : nil }
    static func menu(_ i: Int, size: CGFloat = 16) -> NSImage? {
        guard menus.indices.contains(i) else { return nil }
        let img = menus[i].copy() as! NSImage
        img.size = NSSize(width: size, height: size)
        return img
    }

    static let ruler = image("VRULLER.png")
    static let tumbler = image("VTUMBLER.png")
    static let foundPoint = image("FOUNDPNT.png")
    static let mapIcon = image("MAINMAP.png")
}
