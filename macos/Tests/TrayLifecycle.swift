import AppKit
import Darwin

@main
struct TrayLifecycleTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        guard let product = AppIcon.image, let expectedIcon = product.tiffRepresentation else { fatalError("Missing product icon") }
        // Alerts must not inherit the cached system icon reported in update dialogs.
        app.applicationIconImage = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        for style: NSAlert.Style? in [nil, .informational, .warning, .critical] {
            let alert = AppIcon.alert(style: style)
            precondition(alert.icon.tiffRepresentation == expectedIcon, "Every alert style must show the bundled product icon")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PoFig tray test"
        window.isReleasedWhenClosed = false
        let tray = TrayController(window: window)
        tray.showWindow()
        pump()
        precondition(window.isVisible && app.activationPolicy() == .regular)
        precondition(isProductIcon(app.applicationIconImage), "Restoring the window must restore the product Dock icon")
        precondition(tray.statusItem.button?.image?.isTemplate == true, "The menu bar must use the product's native template icon")

        let bridge = ProxyBridge()
        var port: UInt16?
        bridge.onEvent = { event in
            if event["event"] as? String == "ready", let value = event["port"] as? Int { port = UInt16(value) }
        }
        try bridge.start(profile: ProxyProfile(name: "Tray test", host: "127.0.0.1", port: 9), password: "", command: "serve")
        let deadline = Date().addingTimeInterval(3)
        while port == nil && Date() < deadline { pump() }
        guard let port else { fatalError("Proxy helper did not start") }

        window.performClose(nil)
        pump()
        precondition(!window.isVisible, "The settings window must be hidden")
        precondition(app.activationPolicy() == .accessory, "PoFig must be absent from Dock and the app switcher")
        precondition(tray.statusItem.isVisible && tray.statusItem.button?.image != nil, "The menu-bar item must remain available")
        precondition(listenerIsAlive(port), "Hiding must not stop the proxy helper")

        tray.updateStatus("Figma запущена")
        precondition(tray.statusItem.menu?.item(at: 0)?.title == "Figma запущена")
        tray.statusItem.menu?.performActionForItem(at: 2)
        pump()
        precondition(window.isVisible && app.activationPolicy() == .regular, "The menu action must restore settings and Dock visibility")
        precondition(listenerIsAlive(port), "Restoring settings must preserve the proxy helper")

        bridge.stop()
        window.orderOut(nil)
        app.setActivationPolicy(.accessory)
        print("Branding: bundled icon in all alert styles, Dock and menu bar verified")
        print("Tray lifecycle: close-to-tray, Dock policy, menu access, restore and live proxy verified")
    }

    private static func isProductIcon(_ image: NSImage?) -> Bool {
        guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        var red = 0
        for y in 0..<32 { for x in 0..<32 {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.alphaComponent > 0.5, color.redComponent > color.greenComponent * 1.2,
               color.redComponent > color.blueComponent * 1.2 { red += 1 }
        } }
        return red > 50
    }

    private static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private static func listenerIsAlive(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
