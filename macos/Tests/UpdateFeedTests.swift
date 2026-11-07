import AppKit

@main
struct UpdateTests {
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "tests/update-feed.json"))
        let latest = try UpdateRelease.latest(in: data, current: "0.2.0")
        precondition(latest?.version == "0.10.0", "Numeric ordering and published prereleases")
        let upToDate = try UpdateRelease.latest(in: data, current: "0.10.0"); precondition(upToDate == nil)
        let altered = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "/bogdanhpk/PoFig/", with: "/someone/PoFig/")
        let foreign = try UpdateRelease.latest(in: Data(altered.utf8), current: "0.2.0"); precondition(foreign == nil)
        for version in ["0.2", "-1.2.3", "1.2.3.4", "1.2.3-beta", "1.2.4294967296"] { precondition(ReleaseVersion(version) == nil) }
        for url in ["http://github.com/file", "https://github.com.attacker.test/file", "https://user@github.com/file", "https://github.com:444/file"] { precondition(!UpdateTransport.allowed(URL(string: url)!)) }
        if CommandLine.arguments.contains("--live") {
            let transport = UpdateTransport(); defer { transport.close() }
            let response = try await transport.catalog()
            _ = try UpdateRelease.latest(in: response, current: "0.0.0")
            print("GitHub public feed: reachable and valid")
        }
        print("Mac updates: numeric versions, prereleases, drafts, downgrade protection and download origins verified")
    }
}
