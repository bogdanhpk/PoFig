import Foundation

final class ProxyBridge {
    private var process: Process?
    private var input: Pipe?
    private var generation = UUID()
    private var buffer = Data()
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?

    func start(profile: ProxyProfile, password: String, command: String) throws {
        guard process == nil else { throw PoFigError("Соединение уже запущено.") }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "pofig-proxy"), FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw PoFigError("Не найден сетевой модуль PoFig. Соберите приложение заново.")
        }
        let request: [String: Any] = ["command": command, "protocol": profile.type.rawValue, "host": profile.host,
                                      "port": profile.port, "username": profile.username, "password": password]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = helper
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let ticket = UUID()
        generation = ticket
        buffer.removeAll()
        try child.run()
        process = child
        input = stdin
        do { try stdin.fileHandleForWriting.write(contentsOf: data) }
        catch { stop(); throw PoFigError("Не удалось передать настройки сетевому модулю.") }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                // read(upToCount:) may wait to fill the requested buffer on a pipe.
                // availableData returns the short ready record while the helper stays alive.
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.buffer.append(chunk)
                    while let end = self.buffer.firstIndex(of: 10) {
                        let line = self.buffer.prefix(upTo: end)
                        self.buffer.removeSubrange(...end)
                        if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.onEvent?(value) }
                    }
                }
            }
            child.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket else { return }
                self.process = nil
                self.input = nil
                self.onExit?()
            }
        }
    }

    func stop() {
        generation = UUID()
        try? input?.fileHandleForWriting.close()
        if let child = process, child.isRunning { child.terminate() }
        process = nil
        input = nil
        buffer.removeAll()
    }
    deinit { stop() }
}
