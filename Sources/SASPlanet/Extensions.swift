import AppKit
import UniformTypeIdentifiers

extension NSSavePanel {
    func allowExtensions(_ exts: [String]) {
        allowedContentTypes = exts.map { UTType(filenameExtension: $0) ?? .data }
    }
}
