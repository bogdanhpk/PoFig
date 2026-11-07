import Foundation
import Security
import Darwin

enum ProxyProtocol: String, Codable, CaseIterable {
    case http, https, socks5
    var label: String { rawValue.uppercased() }
}

struct ProxyProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var type: ProxyProtocol = .http
    var host = ""
    var port = 8080
    var username = ""

    var endpoint: String { "\(type.rawValue)://\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    func validate(password: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else { throw PoFigError("Укажите название прокси длиной до 128 символов.") }
        guard (1...65535).contains(port) else { throw PoFigError("Введите порт от 1 до 65535.") }
        var ipv6Address = in6_addr()
        let isIPv6 = host.withCString { inet_pton(AF_INET6, $0, &ipv6Address) == 1 }
        let isDNS = !host.isEmpty && host.utf8.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        guard isIPv6 || isDNS else {
            throw PoFigError("Введите адрес сервера без протокола, пути и порта.")
        }
        guard !username.isEmpty || password.isEmpty else { throw PoFigError("Укажите имя пользователя для этого пароля.") }
        guard password.utf8.count <= 2048 else { throw PoFigError("Пароль должен занимать не больше 2048 байт.") }
        if type == .socks5 && (username.utf8.count > 255 || password.utf8.count > 255) {
            throw PoFigError("Для SOCKS5 логин и пароль должны занимать не больше 255 байт каждый.")
        }
        if type != .socks5 && username.contains(":") { throw PoFigError("Имя пользователя HTTP-прокси не должно содержать двоеточие.") }
    }
}

struct PoFigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SavedSettings: Codable {
    var profiles: [ProxyProfile] = []
    var selectedID: String?
    var figmaPath: String?
}

final class ProfileStore {
    private(set) var settings = SavedSettings()
    let directory: URL
    private var file: URL { directory.appendingPathComponent("profiles.json") }

    init(directory: URL? = nil) throws {
        let override = ProcessInfo.processInfo.environment["POFIG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PoFig", isDirectory: true)
        if FileManager.default.fileExists(atPath: file.path) {
            settings = try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: file))
        }
    }

    func write(_ value: SavedSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        settings = value
    }

    func save(_ profile: ProxyProfile, password: String) throws {
        try profile.validate(password: password)
        let old = try Secrets.read(profile.id)
        try Secrets.write(profile.id, password: password)
        var value = settings
        if let index = value.profiles.firstIndex(where: { $0.id == profile.id }) { value.profiles[index] = profile }
        else { value.profiles.append(profile) }
        value.selectedID = profile.id
        do { try write(value) }
        catch { try? Secrets.write(profile.id, password: old); throw error }
    }

    func remove(_ profile: ProxyProfile) throws {
        var value = settings
        value.profiles.removeAll { $0.id == profile.id }
        if value.selectedID == profile.id { value.selectedID = value.profiles.first?.id }
        try write(value)
        try Secrets.delete(profile.id)
    }
}

enum Secrets {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.pofig.proxy",
         kSecAttrAccount as String: id]
    }
    static func read(_ id: String) throws -> String {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw PoFigError("Не удалось прочитать пароль из Связки ключей (\(status)).")
        }
        return value
    }
    static func write(_ id: String, password: String) throws {
        if password.isEmpty { try delete(id); return }
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id).merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PoFigError("Не удалось сохранить пароль в Связке ключей (\(status)).") }
    }
    static func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PoFigError("Не удалось удалить пароль из Связки ключей (\(status)).")
        }
    }
}
