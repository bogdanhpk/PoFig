import AppKit

@main
struct PreferenceRecoveryTests {
    static func main() throws {
        let domain = "app.pofig.test.\(UUID().uuidString)"
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let key = "ProxyUrl" as CFString
        func read() -> String? { CFPreferencesCopyValue(key, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String }
        func write(_ value: String?) {
            CFPreferencesSetValue(key, value as CFString?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        defer { write(nil); try? FileManager.default.removeItem(at: directory) }
        let preference = FigmaProxyPreference(directory: directory, domain: domain)
        try preference.apply(port: 40000)
        precondition(read() == "http://127.0.0.1:40000", "Proxy must be applied")
        try preference.restore()
        precondition(read() == nil, "An originally absent preference must stay absent")
        write("https://existing.example:8080")
        try preference.apply(port: 40001)
        let afterCrash = FigmaProxyPreference(directory: directory, domain: domain)
        try afterCrash.restore()
        precondition(read() == "https://existing.example:8080", "Crash recovery must restore the previous value")
        try preference.apply(port: 40002)
        write("https://newer.example:8080")
        try preference.restore()
        precondition(read() == "https://newer.example:8080", "A newer external setting must be preserved")
        try preference.restore()
        precondition(read() == "https://newer.example:8080", "Recovery must be idempotent")
        print("Preference recovery: 5 assertions passed (isolated test domain)")
    }
}
