import AppKit

struct ReleaseVersion: Comparable, Equatable {
    let parts: [UInt32]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ UInt32($0) != nil }) else { return nil }
        parts = pieces.map { UInt32($0)! }
    }
    static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

struct UpdateRelease {
    let version: String
    let url: URL
    let size: Int64
    let sha256: String
    static let page = URL(string: "https://github.com/bogdanhpk/PoFig/releases")!
    static func latest(in data: Data, current: String) throws -> UpdateRelease? {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64; let state: String; let digest: String? }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let assets: [Asset] }
        guard data.count <= 2_000_000, let installed = ReleaseVersion(current) else { throw PoFigError("Не удалось прочитать список обновлений.") }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> UpdateRelease? in
            guard !release.draft, let version = ReleaseVersion(release.tag_name), version > installed,
                  let asset = release.assets.first(where: { $0.name == "PoFig-macOS.zip" && $0.state == "uploaded" }),
                  asset.size > 0, asset.size <= 300 * 1024 * 1024,
                  let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
                  digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == "/bogdanhpk/PoFig/releases/download/\(release.tag_name)/PoFig-macOS.zip" else { return nil }
            return UpdateRelease(version: String(release.tag_name.dropFirst(release.tag_name.hasPrefix("v") ? 1 : 0)), url: url, size: asset.size, sha256: String(digest.dropFirst(7)))
        }.max { ReleaseVersion($0.version)! < ReleaseVersion($1.version)! }
    }
}

final class UpdateTransport: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var expected: Int64 = 0
    private var savedError: Error?
    private var savedURL: URL?
    private var task: URLSessionDownloadTask?
    var progress: ((Double) -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }
    func catalog() async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/bogdanhpk/PoFig/releases?per_page=20")!)
        request.setValue("PoFig/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let url = response.url, Self.allowed(url) else { throw PoFigError("GitHub не ответил. Повторите проверку позже.") }
        return data
    }
    func download(_ release: UpdateRelease, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; self.destination = destination; expected = release.size
            savedError = nil; savedURL = nil
            task = session.downloadTask(with: release.url); task?.resume()
        }
    }
    func cancel() { task?.cancel() }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expected { downloadTask.cancel(); return }
        let value = min(1, Double(totalBytesWritten) / Double(max(1, expected)))
        DispatchQueue.main.async { [weak self] in self?.progress?(value) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, Self.allowed(url), let destination,
                  (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(expected) else { throw PoFigError("Обновление загрузилось не полностью. Повторите попытку.") }
            try FileManager.default.moveItem(at: location, to: destination); savedURL = destination
        } catch { savedError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil; self.task = nil
        if let error = savedError ?? error { continuation.resume(throwing: error) }
        else if let savedURL { continuation.resume(returning: savedURL) }
        else { continuation.resume(throwing: PoFigError("Не удалось скачать обновление.")) }
    }
}

struct UpdateInstaller {
    struct Pending: Codable { let workspace: String; let pid: Int32 }
    static func helper(_ executable: URL, _ arguments: [String], ready: Bool = false) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process(), pipe = Pipe()
                    process.executableURL = executable; process.arguments = arguments
                    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: watchdog)
                    defer { watchdog.cancel() }
                    let data: Data
                    if ready {
                        var line = Data()
                        while !line.contains(10), line.count < 65536 {
                            let chunk = pipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }; line.append(chunk)
                        }
                        data = line
                    } else { data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit() }
                    guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
                          let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          value["event"] as? String == (ready ? "ready" : "prepared") else {
                        if process.isRunning { process.terminate() }
                        throw PoFigError("Не удалось подготовить обновление. Текущая версия сохранена. Попробуйте скачать новую версию со страницы PoFig.")
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func command(_ executable: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw PoFigError("Не удалось проверить приложение. Скачайте обновление со страницы PoFig.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    // Carry the system's download metadata across archive extraction.
    static func preserveQuarantine(from sources: [URL], to target: URL) throws {
        for source in sources {
            let size = getxattr(source.path, "com.apple.quarantine", nil, 0, 0, 0)
            if size < 0 {
                if errno == ENOATTR { continue }
                throw PoFigError("Не удалось перенести системные сведения об обновлении. Скачайте новую версию со страницы PoFig.")
            }
            guard size > 0, size < 65536 else { continue }
            var data = [UInt8](repeating: 0, count: size)
            guard getxattr(source.path, "com.apple.quarantine", &data, size, 0, 0) == size,
                  setxattr(target.path, "com.apple.quarantine", data, size, 0, 0) == 0 else {
                throw PoFigError("Не удалось подготовить приложение к открытию. Скачайте новую версию со страницы PoFig.")
            }
            return
        }
    }
    static func write(_ object: Any, to path: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic) }
    static func resume(directory: URL) throws -> Bool {
        let updates = directory.appendingPathComponent("Updates", isDirectory: true)
        let marker = updates.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker))
        let workspace = URL(fileURLWithPath: pending.workspace).standardizedFileURL
        guard workspace.deletingLastPathComponent() == updates.standardizedFileURL,
              UUID(uuidString: workspace.lastPathComponent) != nil else { throw PoFigError("Не удалось восстановить обновление. Скачайте PoFig заново.") }
        let result = workspace.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: result.path) {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any]
            try FileManager.default.removeItem(at: marker)
            if value?["status"] as? String == "recovery_failed" { throw PoFigError("Не удалось завершить обновление. Скачайте PoFig заново. Ваши прокси и пароли сохранены.") }
            if value?["status"] as? String != "installed" { throw PoFigError("Обновление не установлено. Предыдущая версия восстановлена. Повторите попытку позже.") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let id = workspace.lastPathComponent
                let parent = Bundle.main.bundleURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(".PoFig-backup-\(id).app"))
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(".PoFig-update-\(id).app"))
                try? FileManager.default.removeItem(at: workspace)
            }
            return false
        }
        if pending.pid > 0, kill(pending.pid, 0) == 0 { return true }
        let executable = workspace.appendingPathComponent("pofig-updater")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PoFigError("Обновление прервалось. Скачайте PoFig заново, чтобы восстановить приложение.") }
        let worker = Process(); worker.executableURL = executable
        worker.arguments = ["recover", workspace.appendingPathComponent("install.json").path, String(ProcessInfo.processInfo.processIdentifier)]
        worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        try JSONEncoder().encode(Pending(workspace: workspace.path, pid: worker.processIdentifier)).write(to: marker, options: .atomic)
        return true
    }
}

final class UpdateController: NSObject {
    private weak var window: NSWindow?
    private let directory: URL
    private let transport = UpdateTransport()
    private let canInstall: () -> Bool
    private var timer: Timer?
    private var checking = false
    private var installing = false
    private var release: UpdateRelease?
    private var dismissed: String?
    var onChange: ((String, Bool) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onInstall: (() -> Void)?
    private var progressPanel: NSPanel?
    private let progress = NSProgressIndicator()
    private let progressText = NSTextField(labelWithString: "Скачиваем обновление…")
    private var cancelButton: NSButton?
    init(window: NSWindow, directory: URL, canInstall: @escaping () -> Bool) {
        self.window = window; self.directory = directory; self.canInstall = canInstall
        super.init()
        transport.progress = { [weak self] value in self?.progress.doubleValue = value * 100 }
    }
    func start() {
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { await self?.check(manual: false) } }
    }
    func stop() { timer?.invalidate(); transport.close() }
    @objc func selected() {
        guard !installing else { return }
        if release != nil { offer(manual: true) } else { Task { await check(manual: true) } }
    }
    @MainActor private func check(manual: Bool) async {
        guard !checking, !installing else { return }
        checking = true; onChange?("Проверяем…", false)
        defer { checking = false; onChange?(release == nil ? "Обновления" : "Обновить", true) }
        do {
            let data = try await transport.catalog()
            release = try UpdateRelease.latest(in: data, current: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
            if release != nil { offer(manual: manual) }
            else if manual { message("У вас последняя версия PoFig", "Новых обновлений пока нет.") }
        } catch { if manual { message("Не удалось проверить обновления", "Проверьте подключение к интернету и повторите попытку.") } }
    }
    func offer(manual: Bool = false) {
        guard !installing, let release, let window, window.attachedSheet == nil else { return }
        if !manual && (!window.isVisible || !canInstall() || dismissed == release.version) { return }
        if !canInstall() { message("Сначала закройте Figma", "Затем нажмите «Обновить» ещё раз. Пока Figma открыта, PoFig поддерживает её соединение с прокси."); return }
        let alert = AppIcon.alert(); alert.messageText = "Доступен PoFig \(release.version)"
        alert.informativeText = "Установить обновление и перезапустить PoFig? Ваши прокси и пароли сохранятся."
        alert.addButton(withTitle: "Обновить"); alert.addButton(withTitle: "Позже")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            self.dismissed = release.version
            if result == .alertFirstButtonReturn { Task { await self.install(release) } }
        }
    }
    private func message(_ title: String, _ text: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = AppIcon.alert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "Понятно")
        alert.beginSheetModal(for: window)
    }
    @objc private func cancelDownload() { cancelButton?.isEnabled = false; transport.cancel() }
    private func showProgress() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 124), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Обновление PoFig"
        progress.frame = NSRect(x: 20, y: 51, width: 340, height: 18); progress.minValue = 0; progress.maxValue = 100; progress.isIndeterminate = false; progress.doubleValue = 0
        progressText.frame = NSRect(x: 20, y: 82, width: 340, height: 20); progressText.stringValue = "Скачиваем обновление…"
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelDownload)); cancel.frame = NSRect(x: 262, y: 12, width: 100, height: 28)
        for view in [progressText, progress, cancel] { panel.contentView?.addSubview(view) }
        cancelButton = cancel; progressPanel = panel; window?.beginSheet(panel)
    }
    @MainActor private func install(_ release: UpdateRelease) async {
        guard canInstall(), !installing else { return }
        installing = true; onBusy?(true); showProgress()
        let id = UUID().uuidString
        let updates = directory.appendingPathComponent("Updates", isDirectory: true)
        let workspace = updates.appendingPathComponent(id, isDirectory: true)
        let marker = updates.appendingPathComponent("pending.json")
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let stage = target.deletingLastPathComponent().appendingPathComponent(".PoFig-update-\(id).app")
        var handedOff = false
        var workerPID: Int32 = 0
        defer {
            if let panel = progressPanel { window?.endSheet(panel) }; progressPanel = nil
            if !handedOff { if workerPID > 0 { kill(workerPID, SIGTERM) }; try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: stage); try? FileManager.default.removeItem(at: workspace) }
            if !handedOff { installing = false; onBusy?(false) }
        }
        do {
            guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw PoFigError("Перенесите PoFig в папку «Программы» своего пользователя и повторите обновление. Также можно скачать новую версию со страницы PoFig на GitHub.") }
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let archive = try await transport.download(release, to: workspace.appendingPathComponent("update.zip"))
            cancelButton?.isEnabled = false; progressText.stringValue = "Проверяем и устанавливаем…"
            let executable = workspace.appendingPathComponent("pofig-updater")
            try FileManager.default.copyItem(at: target.appendingPathComponent("Contents/MacOS/pofig-updater"), to: executable)
            let prepare = workspace.appendingPathComponent("prepare.json")
            try UpdateInstaller.write(["archive": archive.path, "destination": workspace.appendingPathComponent("package").path, "sha256": release.sha256, "version": release.version, "platform": "macos"], to: prepare)
            let prepared = try await UpdateInstaller.helper(executable, ["prepare", prepare.path])
            guard let root = prepared["root"] as? String, let manifest = prepared["manifest"] as? String, let hash = prepared["manifest_sha256"] as? String,
                  let bundle = Bundle(path: root), bundle.bundleIdentifier == "app.pofig.desktop", bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else { throw PoFigError("Загружен неподходящий пакет обновления.") }
            try await UpdateInstaller.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", root])
            try FileManager.default.copyItem(at: URL(fileURLWithPath: root), to: stage)
            try UpdateInstaller.preserveQuarantine(from: [archive, target], to: stage)
            guard canInstall() else { throw PoFigError("Figma была открыта во время загрузки. Закройте её и повторите обновление.") }
            let job = workspace.appendingPathComponent("install.json")
            try UpdateInstaller.write(["id": id, "target": target.path, "stage": stage.path, "manifest": manifest, "manifest_sha256": hash,
                "backup": target.deletingLastPathComponent().appendingPathComponent(".PoFig-backup-\(id).app").path,
                "parent_pid": ProcessInfo.processInfo.processIdentifier, "version": release.version, "platform": "macos"], to: job)
            try JSONEncoder().encode(UpdateInstaller.Pending(workspace: workspace.path, pid: 0)).write(to: marker, options: .atomic)
            let ready = try await UpdateInstaller.helper(executable, ["install", job.path], ready: true)
            guard let pid = ready["pid"] as? Int32 else { throw PoFigError("Не удалось запустить обновление.") }
            workerPID = pid
            try JSONEncoder().encode(UpdateInstaller.Pending(workspace: workspace.path, pid: pid)).write(to: marker, options: .atomic)
            handedOff = true
            if let panel = progressPanel { window?.endSheet(panel); progressPanel = nil }
            DispatchQueue.main.async { [weak self] in self?.onInstall?() }
        } catch {
            if let panel = progressPanel { window?.endSheet(panel); progressPanel = nil }
            if (error as NSError).code != NSURLErrorCancelled { message("Обновление не установлено", (error as? PoFigError)?.message ?? "Не удалось скачать или установить обновление. Проверьте подключение и повторите попытку. Текущая версия сохранена.") }
        }
    }
}
