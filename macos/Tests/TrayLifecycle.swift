import AppKit
import Darwin

@main
struct TrayLifecycleTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PoFig tray test"
        window.isReleasedWhenClosed = false
        let tray = TrayController(window: window)
        tray.showWindow()
        pump()
        precondition(window.isVisible && app.activationPolicy() == .regular)

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
        print("Tray lifecycle: close-to-tray, Dock policy, menu access, restore and live proxy verified")
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
