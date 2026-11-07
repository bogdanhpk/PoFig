import AppKit

enum AppIcon {
    static let image = Bundle.main.url(forResource: "PoFig", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    static func apply() {
        if let image { NSApplication.shared.applicationIconImage = image }
    }
}
