import AppKit

final class TrayController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    let statusItem: NSStatusItem
    private let statusLine = NSMenuItem(title: "Figma не запущена через PoFig", action: nil, keyEquivalent: "")

    init(window: NSWindow) {
        self.window = window
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        window.delegate = self
        let icon = Bundle.main.url(forResource: "PoFig-status", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "PoFig")
        icon?.size = NSSize(width: 16, height: 18)
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "PoFig — настройки прокси"
        statusItem.button?.setAccessibilityLabel("PoFig — настройки прокси")
        statusItem.button?.setAccessibilityIdentifier("pofigStatusItem")

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Показать PoFig", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(title: "Завершить PoFig", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func updateStatus(_ text: String) { statusLine.title = text }

    @objc func hideToTray() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        AppIcon.apply()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hideToTray(); return false }
    func windowDidMiniaturize(_ notification: Notification) { hideToTray() }

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }
}
