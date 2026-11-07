import AppKit

/// Only the documented ProxyUrl preference is changed, with a crash-recovery journal.
final class FigmaProxyPreference {
    private let domain: CFString
    private let key = "ProxyUrl" as CFString
    private let journalURL: URL
    private struct Journal: Codable { var previous: String?; var applied: String }

    init(directory: URL, domain: String = "com.figma.Desktop") {
        journalURL = directory.appendingPathComponent("proxy-recovery.json")
        self.domain = domain as CFString
    }

    private var current: String? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }
    private func set(_ value: String?) throws {
        CFPreferencesSetValue(key, value as CFString?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw PoFigError("Не удалось сохранить настройку прокси Figma.")
        }
    }
    func apply(port: Int) throws {
        guard !CFPreferencesAppValueIsForced(key, domain) else {
            throw PoFigError("Прокси Figma задан администратором компьютера. Обратитесь к нему, чтобы изменить настройку.")
        }
        try restore()
        let journal = Journal(previous: current, applied: "http://127.0.0.1:\(port)")
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try set(journal.applied)
    }
    func restore() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        // Preserve an administrator's or user's newer setting.
        if current == journal.applied { try set(journal.previous) }
        try FileManager.default.removeItem(at: journalURL)
    }
}

protocol FigmaSession: AnyObject {
    var active: Bool { get }
    var onStatus: ((String, Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onLaunched: (() -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func recover() throws
    func locate(savedPath: String?) -> URL?
    func launch(profile: ProxyProfile, password: String, appURL: URL) throws
    func finish()
}

final class FigmaLauncher: FigmaSession {
    private let preference: FigmaProxyPreference
    private var bridge: ProxyBridge?
    private var application: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var startupTimeout: DispatchWorkItem?
    private var readinessTimer: Timer?
    private var launchAnnounced = false
    private(set) var active = false
    var onStatus: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onLaunched: (() -> Void)?
    var onClosed: (() -> Void)?

    init(directory: URL) { preference = FigmaProxyPreference(directory: directory) }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.figma.Desktop").isEmpty }

    func recover() throws {
        guard !Self.running else { return }
        try preference.restore()
    }

    func locate(savedPath: String?) -> URL? {
        let candidates = [savedPath.map { URL(fileURLWithPath: $0) },
                          NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.figma.Desktop"),
                          URL(fileURLWithPath: "/Applications/Figma.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Figma.app")]
        return candidates.compactMap { $0 }.first { Bundle(url: $0)?.bundleIdentifier == "com.figma.Desktop" }
    }

    func launch(profile: ProxyProfile, password: String, appURL: URL) throws {
        guard !active, !Self.running else { throw PoFigError("Закройте Figma через ⌘Q и запустите её из PoFig, чтобы применить прокси.") }
        guard Bundle(url: appURL)?.bundleIdentifier == "com.figma.Desktop" else { throw PoFigError("Выберите официальное приложение Figma.app.") }
        try profile.validate(password: password)
        let bridge = ProxyBridge()
        self.bridge = bridge
        active = true
        launchAnnounced = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.launchAnnounced else { return }
            self.fail(PoFigError("Figma не запустилась за 20 секунд. Повторите запуск из PoFig."))
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        onStatus?("Подключаем прокси…", true)
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            if event["event"] as? String == "ready", let port = event["port"] as? Int {
                do {
                    try self.preference.apply(port: port)
                    let config = NSWorkspace.OpenConfiguration()
                    config.arguments = ["--proxy-server=http://127.0.0.1:\(port)", "--proxy-bypass-list=localhost;127.0.0.1;[::1]"]
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
                        DispatchQueue.main.async {
                            guard let self, self.active else { return }
                            if let error { self.fail(error); return }
                            guard let app else { self.fail(PoFigError("Не удалось запустить Figma.")); return }
                            self.application = app
                            self.observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                                guard let self, let exited = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                                      exited.processIdentifier == self.application?.processIdentifier else { return }
                                self.figmaDidClose()
                            }
                            self.observeReadiness(app, profileName: profile.name)
                        }
                    }
                } catch { self.fail(error) }
            } else if event["event"] as? String == "error" {
                self.fail(PoFigError(event["message"] as? String ?? "Не удалось подключить прокси."))
            }
        }
        bridge.onExit = { [weak self] in
            guard let self, self.active else { return }
            self.fail(PoFigError("Сетевой модуль завершил работу. Закройте Figma и запустите её снова из PoFig."))
        }
        do { try bridge.start(profile: profile, password: password, command: "serve") }
        catch { finish(); throw error }
    }

    private func fail(_ error: Error) {
        finish()
        onError?(error)
    }
    private func observeReadiness(_ app: NSRunningApplication, profileName: String) {
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.announceReadiness(app, profileName: profileName)
        }
        announceReadiness(app, profileName: profileName)
    }
    private func announceReadiness(_ app: NSRunningApplication, profileName: String) {
        guard active, !launchAnnounced else { return }
        if app.isTerminated { figmaDidClose(); return }
        guard app.isFinishedLaunching else { return }
        launchAnnounced = true
        readinessTimer?.invalidate(); readinessTimer = nil
        startupTimeout?.cancel(); startupTimeout = nil
        onStatus?("Figma запущена через \(profileName)", true)
        onLaunched?()
    }
    private func figmaDidClose() {
        guard active else { return }
        finish()
        onClosed?()
    }
    func finish() {
        active = false
        readinessTimer?.invalidate(); readinessTimer = nil
        launchAnnounced = false
        startupTimeout?.cancel(); startupTimeout = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        bridge?.stop(); bridge = nil
        application = nil
        do { try preference.restore() } catch { onError?(error) }
        onStatus?("Figma не запущена через PoFig", false)
    }
}
