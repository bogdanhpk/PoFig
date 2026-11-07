import AppKit

private final class TestSession: FigmaSession {
    var active = false
    var onStatus: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onLaunched: (() -> Void)?
    var onClosed: (() -> Void)?
    var launches = 0
    func recover() throws {}
    func locate(savedPath: String?) -> URL? { nil }
    func launch(profile: ProxyProfile, password: String, appURL: URL) throws { launches += 1 }
    func finish() {}
}

@main
struct ProfileManagementTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PoFig-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let first = ProxyProfile(name: "First", host: "first.example.com")
        let second = ProxyProfile(name: "Second", host: "second.example.com")
        try store.write(SavedSettings(profiles: [first, second], selectedID: second.id))

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let session = TestSession()
        let delegate = AppDelegate(store: store, launcher: session)
        app.delegate = delegate
        Task { @MainActor in
            do {
                try await verify(app: app, session: session, store: store, directory: directory, first: first, second: second)
                try? FileManager.default.removeItem(at: directory)
                session.active = false
                app.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                fatalError("Profile management failed: \(error)")
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    private static func verify(app: NSApplication, session: TestSession, store: ProfileStore, directory: URL,
                               first: ProxyProfile, second: ProxyProfile) async throws {
        try await waitUntil("The settings window must appear") { app.windows.contains { $0.title == "PoFig" && $0.isVisible } }
        let window = app.windows.first { $0.title == "PoFig" }!
        let content = window.contentView!
        let table: NSTableView = view("proxyProfiles", in: content)
        let edit: NSButton = view("editProxy", in: content)
        let remove: NSButton = view("removeProxy", in: content)
        precondition(table.selectedRow == 1 && edit.isEnabled && remove.isEnabled)

        // Actions remain visible in the smallest supported window.
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        content.layoutSubtreeIfNeeded()
        for button in [edit, remove] {
            precondition(content.bounds.contains(button.convert(button.bounds, to: content)))
        }

        session.active = true
        session.onStatus?("Figma запущена через Second", true)
        session.onLaunched?()
        try await waitUntil("Launching Figma must hide settings") { !window.isVisible && app.activationPolicy() == .accessory }
        session.active = false
        session.onStatus?("Figma не запущена через PoFig", false)
        precondition(!window.isVisible, "Status updates alone must not show a manually hidden window")
        session.onClosed?()
        try await waitUntil("Closing Figma must restore settings and Dock visibility") {
            window.isVisible && app.activationPolicy() == .regular
        }
        let launch: NSButton = view("launchFigma", in: content)
        precondition(launch.isEnabled && table.selectedRow == 1, "Closing Figma must enable relaunch and preserve the selected proxy")

        session.active = true
        session.onStatus?("Figma запущена через Second", true)
        precondition(edit.isEnabled && remove.isEnabled, "A running session must not lock saved profiles")
        precondition(!launch.isEnabled, "Editing profiles must not allow a second Figma launch")

        edit.performClick(nil)
        try await waitUntil("The editor must open during an active session") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let name: NSTextField = view("proxyName", in: sheet.contentView!)
        let host: NSTextField = view("proxyHost", in: sheet.contentView!)
        let port: NSTextField = view("proxyPort", in: sheet.contentView!)
        precondition(name.stringValue == "Second" && host.stringValue == "second.example.com")
        name.stringValue = "Edited second"
        port.stringValue = "1080"
        button("Сохранить", in: sheet.contentView!).performClick(nil)
        try await waitUntil("Saving must close the editor") { window.attachedSheet == nil }
        let updated = try ProfileStore(directory: directory).settings
        precondition(updated.profiles.count == 2 && updated.profiles[1].id == second.id)
        precondition(updated.profiles[1].name == "Edited second" && updated.profiles[1].port == 1080)
        precondition(updated.selectedID == second.id && table.selectedRow == 1, "Saving must preserve the edited selection")

        edit.performClick(nil)
        try await waitUntil("The editor must reopen") { window.attachedSheet != nil }
        let cancelledSheet = window.attachedSheet!
        let cancelledName: NSTextField = view("proxyName", in: cancelledSheet.contentView!)
        cancelledName.stringValue = "Discard this change"
        button("Отмена", in: cancelledSheet.contentView!).performClick(nil)
        try await waitUntil("Cancelling must close the editor") { window.attachedSheet == nil }
        let afterCancel = try ProfileStore(directory: directory).settings
        precondition(afterCancel.profiles[1].name == "Edited second")

        remove.performClick(nil)
        try await waitUntil("Deletion must request confirmation") { window.attachedSheet != nil }
        button("Отмена", in: window.attachedSheet!.contentView!).performClick(nil)
        try await waitUntil("Cancelling must close the confirmation") { window.attachedSheet == nil }
        let afterDeleteCancel = try ProfileStore(directory: directory).settings
        precondition(afterDeleteCancel.profiles.count == 2)

        remove.performClick(nil)
        try await waitUntil("Deletion must request confirmation again") { window.attachedSheet != nil }
        button("Удалить прокси", in: window.attachedSheet!.contentView!).performClick(nil)
        try await waitUntil("Confirmed deletion must close the confirmation") { window.attachedSheet == nil && store.settings.profiles.count == 1 }
        let remaining = try ProfileStore(directory: directory).settings
        precondition(remaining.profiles.map(\.id) == [first.id] && remaining.selectedID == first.id)
        precondition(table.selectedRow == 0 && edit.isEnabled && remove.isEnabled)
        precondition(session.active && session.launches == 0, "Profile changes must not restart the running session")

        remove.performClick(nil)
        try await waitUntil("Deleting the last profile must request confirmation") { window.attachedSheet != nil }
        button("Удалить прокси", in: window.attachedSheet!.contentView!).performClick(nil)
        try await waitUntil("Deleting the last profile must close the confirmation") { window.attachedSheet == nil && store.settings.profiles.isEmpty }
        let empty = try ProfileStore(directory: directory).settings
        precondition(empty.profiles.isEmpty)
        precondition(table.selectedRow == -1 && !edit.isEnabled && !remove.isEnabled)
        window.orderOut(nil)
        app.setActivationPolicy(.accessory)
        print("Profile management: auto-hide on launch, auto-restore on Figma exit, relaunch, edit, selection, cancel and deletion verified")
    }

    @MainActor
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat { try await Task.sleep(nanoseconds: 20_000_000) }
        while !condition() && Date() < deadline
        precondition(condition(), message)
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func view<T: NSView>(_ id: String, in root: NSView) -> T {
        descendants(root).first { $0.accessibilityIdentifier() == id } as! T
    }
    private static func button(_ title: String, in root: NSView) -> NSButton {
        descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
}
