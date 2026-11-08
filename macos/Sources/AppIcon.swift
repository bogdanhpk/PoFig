import AppKit

enum AppIcon {
    static let image: NSImage? = {
        for ext in ["icns", "png"] {
            if let url = Bundle.main.url(forResource: "PoFig", withExtension: ext),
               let image = NSImage(contentsOf: url), image.isValid { return image }
        }
        return nil
    }()

    static func apply() {
        if let image { NSApplication.shared.applicationIconImage = image }
    }

    static func alert(style: NSAlert.Style? = nil) -> NSAlert {
        let alert = NSAlert()
        if let style { alert.alertStyle = style }
        if let image = image?.copy() as? NSImage { alert.icon = image }
        return alert
    }

    static func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "PoFig-status", withExtension: "svg"),
           let icon = NSImage(contentsOf: url), icon.isValid {
            icon.size = NSSize(width: 16, height: 18)
            icon.isTemplate = true
            return icon
        }
        let icon = image?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        return icon
    }
}
