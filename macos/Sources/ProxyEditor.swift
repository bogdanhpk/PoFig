import AppKit

final class ProxyEditor: NSWindowController {
    private let original: ProxyProfile
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let protocolControl = NSSegmentedControl(labels: ProxyProtocol.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onSave: ((ProxyProfile, String) throws -> Void)?

    init(profile: ProxyProfile, password: String) {
        original = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = profile.name.isEmpty ? "Новый прокси" : "Изменить прокси"
        super.init(window: window)
        nameField.stringValue = profile.name
        hostField.stringValue = profile.host
        portField.stringValue = String(profile.port)
        userField.stringValue = profile.username
        passwordField.stringValue = password
        nameField.placeholderString = "Например, рабочий прокси"
        hostField.placeholderString = "proxy.example.com"
        userField.placeholderString = "Необязательно"
        passwordField.placeholderString = "Необязательно"
        protocolControl.selectedSegment = ProxyProtocol.allCases.firstIndex(of: profile.type) ?? 0
        protocolControl.segmentStyle = .rounded
        for index in 0..<3 { protocolControl.setWidth(126, forSegment: index) }
        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let grid = NSGridView(views: [
            [label("Название"), nameField], [label("Протокол"), protocolControl],
            [label("Сервер"), hostField], [label("Порт"), portField],
            [label("Пользователь"), userField], [label("Пароль"), passwordField]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 110
        for field in [nameField, hostField, portField, userField, passwordField] {
            field.font = .systemFont(ofSize: 14)
            field.heightAnchor.constraint(equalToConstant: 25).isActive = true
        }
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityIdentifier("proxyValidationError")
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Сохранить", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        let body = NSStackView(views: [title, grid, errorLabel])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 22
        let content = window.contentView!
        [body, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            grid.widthAnchor.constraint(equalTo: body.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 12)
        ])
        let controls: [(NSView, String)] = [(nameField, "proxyName"), (hostField, "proxyHost"), (portField, "proxyPort"), (userField, "proxyUsername"), (passwordField, "proxyPassword"), (protocolControl, "proxyProtocol")]
        controls.forEach { $0.0.setAccessibilityIdentifier($0.1) }
        let fields: [NSView] = [nameField, protocolControl, hostField, portField, userField, passwordField, save, cancel]
        for index in 0..<(fields.count - 1) { fields[index].nextKeyView = fields[index + 1] }
        window.initialFirstResponder = nameField
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    @objc private func cancel() { if let window { window.sheetParent?.endSheet(window) } }
    @objc private func save() {
        var profile = original
        profile.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.type = ProxyProtocol.allCases[max(0, protocolControl.selectedSegment)]
        profile.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        profile.port = Int(portField.stringValue) ?? 0
        profile.username = userField.stringValue
        do {
            try profile.validate(password: passwordField.stringValue)
            try onSave?(profile, passwordField.stringValue)
            cancel()
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
}
