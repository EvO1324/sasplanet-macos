import AppKit

/// A message from the app's author, shown on first launch and from Help.
/// Edit `title` and `body` below, then run ./build.sh. Bump `version` to show it again to everyone once.
enum DeveloperMessage {
    static let version = 2
    static let title = "SASPlanet for MacOS"
    static let body = """
    Welcome to sasplanet on Mac. This is a port of the existing sasplanet, if you encounter any issues please send @alexev a DM on the IFC or discord.

    Thanks!

    Based on SAS.Planet © the SAS.Planet development team, released under the GNU GPL v3.
    """

    private static let shownKey = "developerMessageShownVersion"

    static func showIfNeeded(over window: NSWindow?) {
        if Config.defaults.integer(forKey: shownKey) >= version { return }
        show(over: window)
    }

    static func show(over window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        if let i = Icons.image("AppIcon.png") ?? Icons.image("icon64.png") { a.icon = i }
        a.addButton(withTitle: "OK")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't show this again"
        a.suppressionButton?.state = .on
        let done: (NSApplication.ModalResponse) -> Void = { _ in
            if a.suppressionButton?.state == .on { Config.defaults.set(version, forKey: shownKey) }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }
}
