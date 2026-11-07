import Foundation

@main
struct BridgeLifecycleTests {
    static func main() throws {
        let bridge = ProxyBridge()
        var received = false
        var failure: String?
        bridge.onEvent = { value in
            if value["event"] as? String == "ready", let port = value["port"] as? Int, port > 0 { received = true }
            if value["event"] as? String == "error" { failure = value["message"] as? String }
        }
        let profile = ProxyProfile(name: "Test", host: "127.0.0.1", port: 9)
        try bridge.start(profile: profile, password: "", command: "serve")
        let deadline = Date().addingTimeInterval(3)
        while !received && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        bridge.stop()
        precondition(received, "The native bridge must read a short ready event before the helper exits: \(failure ?? "timeout")")
        print("Native bridge: ready received while helper is running")
    }
}
