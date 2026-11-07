import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var store: ProfileStore!
    private var launcher: FigmaSession!
    private var refreshingProfiles = false
    private var editor: ProxyEditor?
    private var checker: ProxyBridge?
    private var tray: TrayController?
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Figma не запущена через PoFig")
    private let appLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Проверить соединение", target: nil, action: nil)
    private let launchButton = NSButton(title: "Запустить Figma", target: nil, action: nil)
    private let editButton = NSButton(title: "Изменить", target: nil, action: nil)
    private let removeButton = NSButton(title: "Удалить", target: nil, action: nil)
    private let profileHint = NSTextField(wrappingLabelWithString: "Изменения профилей применятся при следующем запуске Figma.")

    init(store: ProfileStore? = nil, launcher: FigmaSession? = nil) {
        self.store = store
        self.launcher = launcher
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.apply()
        configureMenu()
        do {
            if store == nil { store = try ProfileStore() }
            if launcher == nil { launcher = FigmaLauncher(directory: store.directory) }
            try launcher.recover()
        } catch {
            showError(error)
            NSApp.terminate(nil)
            return
        }
        configureWindow()
        tray = TrayController(window: window)
        launcher.onStatus = { [weak self] text, _ in
            self?.statusLabel.stringValue = text
            self?.tray?.updateStatus(text)
            self?.refreshControls()
        }
        launcher.onLaunched = { [weak self] in self?.tray?.hideToTray() }
        launcher.onClosed = { [weak self] in self?.tray?.showWindow() }
        launcher.onError = { [weak self] error in self?.showError(error) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureMenu() {
        let menu = NSMenu(), appMenu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "О PoFig", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть в строку меню", action: #selector(hideToTray), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Завершить PoFig", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Правка"), editItem = NSMenuItem()
        editItem.submenu = editMenu
        menu.addItem(editItem)
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(), windowMenu = NSMenu(title: "Окно")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        windowMenu.addItem(withTitle: "Показать PoFig", action: #selector(showWindow), keyEquivalent: "0")
        NSApp.mainMenu = menu
    }

    @objc private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: "Разработчик и создатель\nБогдан Хтоминский", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func configureWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PoFig"
        window.contentMinSize = NSSize(width: 600, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let heading = NSTextField(labelWithString: "Figma с вашим прокси")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "Запускайте официальную Figma через выбранный сервер.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.title = "Сохранённые прокси"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(editProxy)
        table.setAccessibilityIdentifier("proxyProfiles")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = button("Добавить прокси", #selector(addProxy))
        add.setAccessibilityIdentifier("addProxy")
        editButton.target = self; editButton.action = #selector(editProxy)
        removeButton.target = self; removeButton.action = #selector(removeProxy)
        editButton.setAccessibilityIdentifier("editProxy")
        removeButton.setAccessibilityIdentifier("removeProxy")
        let tools = NSStackView(views: [add, editButton, removeButton])
        tools.spacing = 8
        profileHint.font = .systemFont(ofSize: 11)
        profileHint.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.setAccessibilityIdentifier("connectionStatus")
        let choose = button("Выбрать Figma…", #selector(chooseFigma))
        choose.setAccessibilityIdentifier("chooseFigma")
        appLabel.font = .systemFont(ofSize: 11)
        appLabel.textColor = .secondaryLabelColor
        appLabel.lineBreakMode = .byTruncatingMiddle
        let appRow = NSStackView(views: [appLabel, choose])
        appRow.distribution = .fill
        appLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let note = NSTextField(wrappingLabelWithString: "После запуска Figma PoFig работает в строке меню.\nПароли хранятся в Связке ключей.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        testButton.target = self; testButton.action = #selector(testProxy)
        testButton.setAccessibilityIdentifier("testProxy")
        launchButton.target = self; launchButton.action = #selector(launchFigma)
        launchButton.keyEquivalent = "\r"
        launchButton.setAccessibilityIdentifier("launchFigma")
        let actions = NSStackView(views: [testButton, launchButton])
        actions.spacing = 8
        let body = NSStackView(views: [heading, subtitle, scroll, tools, profileHint, statusLabel, appRow, note])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        [body, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            tools.widthAnchor.constraint(equalTo: body.widthAnchor),
            profileHint.widthAnchor.constraint(equalTo: body.widthAnchor),
            appRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: body.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            note.widthAnchor.constraint(equalTo: body.widthAnchor),
            actions.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 12),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        reloadProfiles()
    }
    private func reloadProfiles() {
        refreshingProfiles = true
        let selectedID = store.settings.selectedID
        table.reloadData()
        if let index = store.settings.profiles.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !store.settings.profiles.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        refreshingProfiles = false
        refreshControls()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private var selected: ProxyProfile? { store.settings.profiles.indices.contains(table.selectedRow) ? store.settings.profiles[table.selectedRow] : nil }
    private func refreshControls() {
        let hasProfile = selected != nil
        let active = launcher.active
        editButton.isEnabled = hasProfile
        removeButton.isEnabled = hasProfile
        profileHint.isHidden = !active
        testButton.isEnabled = hasProfile && !active
        launchButton.isEnabled = hasProfile && !active && checker == nil
        appLabel.stringValue = launcher.locate(savedPath: store.settings.figmaPath)?.path ?? "Figma не найдена. Установите официальный клиент."
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.settings.profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = store.settings.profiles[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: profile.name)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let subtitle = NSTextField(labelWithString: "\(profile.type.label)  \(profile.host):\(profile.port)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.textField = title
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingProfiles else { return }
        cancelCheck()
        var settings = store.settings
        settings.selectedID = selected?.id
        do { try store.write(settings) } catch { showError(error) }
        refreshControls()
    }
    @objc private func addProxy() { presentEditor(ProxyProfile()) }
    @objc private func editProxy(_ sender: Any?) {
        if let table = sender as? NSTableView, table.clickedRow < 0 { return }
        if let selected { presentEditor(selected) }
    }
    private func presentEditor(_ profile: ProxyProfile) {
        guard window.attachedSheet == nil else { return }
        cancelCheck()
        do {
            let editor = ProxyEditor(profile: profile, password: try Secrets.read(profile.id))
            self.editor = editor
            editor.onSave = { [weak self] profile, password in
                guard let self else { return }
                try self.store.save(profile, password: password)
                self.reloadProfiles()
            }
            window.beginSheet(editor.window!) { [weak self] _ in self?.editor = nil }
        } catch { showError(error) }
    }
    @objc private func removeProxy() {
        guard let selected, window.attachedSheet == nil else { return }
        cancelCheck()
        let alert = NSAlert()
        alert.messageText = "Удалить прокси «\(selected.name)»?"
        alert.informativeText = "Прокси и его сохранённый пароль будут удалены. Открытая Figma продолжит работу с текущими настройками."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Удалить прокси").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn else { return }
            do { try self.store.remove(selected); self.reloadProfiles() }
            catch { self.showError(error) }
        }
    }
    @objc private func chooseFigma() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.message = "Выберите официальное приложение Figma.app."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            guard Bundle(url: url)?.bundleIdentifier == "com.figma.Desktop" else { self.showError(PoFigError("Выберите официальное приложение Figma.app.")); return }
            var settings = self.store.settings; settings.figmaPath = url.path
            do { try self.store.write(settings); self.refreshControls() } catch { self.showError(error) }
        }
    }
    @objc private func testProxy() {
        if checker != nil { cancelCheck(); return }
        guard let selected else { return }
        do {
            let bridge = ProxyBridge()
            var receivedResult = false
            checker = bridge
            testButton.title = "Отменить проверку"
            statusLabel.stringValue = "Проверяем доступ к figma.com…"
            bridge.onEvent = { [weak self] event in
                guard let self else { return }
                if event["event"] as? String == "checked" {
                    receivedResult = true
                    self.statusLabel.stringValue = "figma.com доступен через прокси · \(event["latency_ms"] as? Int ?? 0) мс"
                } else if event["event"] as? String == "error" {
                    receivedResult = true
                    self.statusLabel.stringValue = event["message"] as? String ?? "Проверка не завершена."
                }
            }
            bridge.onExit = { [weak self] in
                guard let self else { return }
                if !receivedResult { self.statusLabel.stringValue = "Проверка завершилась без ответа. Повторите попытку." }
                self.checker = nil; self.testButton.title = "Проверить соединение"; self.refreshControls()
            }
            try bridge.start(profile: selected, password: try Secrets.read(selected.id), command: "check")
            refreshControls()
        } catch { cancelCheck(); showError(error) }
    }
    private func cancelCheck() {
        guard let checker else { return }
        checker.stop(); self.checker = nil
        testButton.title = "Проверить соединение"
        statusLabel.stringValue = "Проверка отменена."
        refreshControls()
    }
    @objc private func launchFigma() {
        guard let selected else { return }
        guard let url = launcher.locate(savedPath: store.settings.figmaPath) else {
            let alert = NSAlert()
            alert.messageText = "Установите Figma"
            alert.informativeText = "PoFig запускает официальный клиент Figma. Скачайте его с сайта Figma или выберите уже установленное приложение."
            alert.addButton(withTitle: "Скачать Figma"); alert.addButton(withTitle: "Отмена")
            alert.beginSheetModal(for: window) { result in if result == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.figma.com/downloads/")!) } }
            return
        }
        do { try launcher.launch(profile: selected, password: try Secrets.read(selected.id), appURL: url); refreshControls() }
        catch { showError(error) }
    }
    @objc private func hideToTray() { tray?.hideToTray() }
    @objc private func showWindow() { tray?.showWindow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if launcher?.active == true && FigmaLauncher.running {
            showWindow()
            showError(PoFigError("Сначала закройте Figma через ⌘Q. Пока Figma открыта, PoFig поддерживает её соединение с прокси."))
            return .terminateCancel
        }
        launcher?.finish()
        checker?.stop()
        return .terminateNow
    }
    private func showError(_ error: Error) {
        if window != nil { showWindow() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PoFig"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Понятно")
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
