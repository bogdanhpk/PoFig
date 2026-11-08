using System.Diagnostics;

namespace PoFig;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var showSettings = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\PoFig.ShowSettings");
        using var mutex = new Mutex(true, @"Local\PoFig.Desktop", out bool first);
        if (!first) { showSettings.Set(); return; }
        try { if (!UpdateInstaller.Resume()) Application.Run(new MainForm(showSettings)); }
        catch (Exception ex) { AppDialog.Show(ex.Message); }
    }
}

internal sealed class MainForm : Form
{
    private readonly ProfileStore store = new();
    private readonly FigmaLauncher launcher = new();
    private readonly ListBox profiles = new() { Dock = DockStyle.Fill, IntegralHeight = false, ItemHeight = 28 };
    private readonly Label status = new() { AutoSize = true, Text = "Figma не запущена через PoFig", MaximumSize = new Size(700, 60) };
    private readonly Label appPath = new() { AutoSize = true, AutoEllipsis = true, MaximumSize = new Size(680, 40), ForeColor = SystemColors.GrayText };
    private readonly Button edit = new() { Text = "Изменить", AutoSize = true }, remove = new() { Text = "Удалить", AutoSize = true },
        test = new() { Text = "Проверить соединение", AutoSize = true }, launch = new() { Text = "Запустить Figma", AutoSize = true };
    private readonly Label profileHint = new() { Text = "Изменения профилей применятся при следующем запуске Figma.", AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(680, 60) };
    private ProxyBridge? checker;
    private bool refreshing;
    private bool exitRequested;
    private bool updateBusy, updateExit;
    private readonly Button updates = new() { Text = "Обновить", AutoSize = true, Visible = false };
    private readonly UpdateController updater;
    private readonly NotifyIcon tray = new();
    private readonly ToolStripMenuItem trayStatus = new("Figma не запущена через PoFig") { Enabled = false };
    private RegisteredWaitHandle? reopenListener;
    private ProxyProfile? Selected => profiles.SelectedItem as ProxyProfile;

    public MainForm(EventWaitHandle showSettings)
    {
        updater = new UpdateController(this, () => !launcher.Active && !FigmaLauncher.Running(), () => { updateExit = true; exitRequested = true; Close(); });
        AppIcon.Apply(this);
        Text = "PoFig"; ClientSize = new Size(600, 440); MinimumSize = SizeFromClientSize(ClientSize);
        AutoScaleMode = AutoScaleMode.Dpi; StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 9, AutoScroll = true };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        for (int i = 3; i < 9; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(new Label { Text = "Figma с вашим прокси", AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 20, FontStyle.Bold) }, 0, 0);
        var subtitle = new Label { Text = "Запускайте официальную Figma через выбранный proxy-сервер.", AutoSize = true, ForeColor = SystemColors.GrayText };
        layout.Controls.Add(subtitle, 0, 1);
        profiles.AccessibleName = "Сохранённые прокси";
        profiles.MinimumSize = new Size(0, 88);
        layout.Controls.Add(profiles, 0, 2);
        var add = new Button { Text = "Добавить прокси", AutoSize = true };
        var tools = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(0, 8, 0, 4) };
        tools.Controls.AddRange([add, edit, remove]); layout.Controls.Add(tools, 0, 3);
        layout.Controls.Add(profileHint, 0, 4);
        status.Padding = new Padding(0, 4, 0, 6); status.AccessibleName = "Состояние соединения";
        layout.Controls.Add(status, 0, 5);
        var appRow = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
        appRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        appRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var choose = new Button { Text = "Выбрать Figma…", AutoSize = true };
        appPath.AutoSize = false; appPath.Dock = DockStyle.Fill; appPath.MaximumSize = Size.Empty;
        appPath.TextAlign = ContentAlignment.MiddleLeft; appPath.Margin = new Padding(8, 0, 0, 0);
        appRow.Controls.Add(choose, 0, 0); appRow.Controls.Add(appPath, 1, 0); layout.Controls.Add(appRow, 0, 6);
        var note = new Label { Text = "После запуска Figma PoFig работает в трее.\nПароли хранятся в Диспетчере учётных данных Windows.", AutoSize = true, ForeColor = SystemColors.GrayText, Padding = new Padding(0, 6, 0, 8) };
        layout.Controls.Add(note, 0, 7);
        layout.SizeChanged += (_, _) =>
        {
            int width = Math.Max(1, layout.ClientSize.Width - layout.Padding.Horizontal - 6);
            foreach (var label in new[] { subtitle, profileHint, status, note }) label.MaximumSize = new Size(width, 0);
        };
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
        actions.Controls.AddRange([launch, test, updates]); layout.Controls.Add(actions, 0, 8);
        Controls.Add(layout); AcceptButton = launch;
        add.Click += (_, _) => Edit(new ProxyProfile());
        edit.Click += (_, _) => { if (Selected is { } profile) Edit(profile); };
        profiles.MouseDoubleClick += (_, e) =>
        {
            int index = profiles.IndexFromPoint(e.Location);
            if (e.Button != MouseButtons.Left || index < 0) return;
            profiles.SelectedIndex = index;
            if (Selected is { } profile) Edit(profile);
        };
        remove.Click += (_, _) => RemoveSelected();
        profiles.SelectedIndexChanged += (_, _) =>
        {
            if (refreshing) return;
            CancelCheck(); Try(() => store.Write(store.Settings with { SelectedId = Selected?.Id })); RefreshControls();
        };
        choose.Click += (_, _) => ChooseFigma(); test.Click += (_, _) => Check(); launch.Click += (_, _) => Launch();
        launcher.Status += text => { status.Text = text; trayStatus.Text = text; RefreshControls(); };
        launcher.Launched += HideToTray;
        launcher.Closed += ShowSettings;
        launcher.Error += Error;
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add(trayStatus);
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("Показать PoFig", null, (_, _) => ShowSettings());
        var updateItem = new ToolStripMenuItem("Проверить обновления…", null, (_, _) => { ShowSettings(); updater.Selected(); });
        trayMenu.Items.Add(updateItem);
        updates.Click += (_, _) => updater.Selected();
        updater.Changed += (title, enabled) => { updates.Text = title; updates.Enabled = enabled; updates.Visible = title == "Обновить"; updateItem.Text = title == "Обновить" ? "Обновить PoFig…" : "Проверить обновления…"; updateItem.Enabled = enabled; };
        updater.Busy += busy => { updateBusy = busy; RefreshControls(); };
        trayMenu.Items.Add("О PoFig", null, (_, _) => ShowAbout());
        trayMenu.Items.Add("Завершить PoFig", null, (_, _) => { exitRequested = true; Close(); });
        tray.Icon = AppIcon.Image;
        tray.Text = "PoFig — настройки прокси";
        tray.ContextMenuStrip = trayMenu;
        tray.DoubleClick += (_, _) => ShowSettings();
        tray.Visible = true;
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) HideToTray(); };
        Shown += (_, _) =>
        {
            updater.Start();
            reopenListener ??= ThreadPool.RegisterWaitForSingleObject(showSettings, (_, _) =>
            {
                try { if (!IsDisposed && IsHandleCreated) BeginInvoke(new Action(() => { if (!IsDisposed) ShowSettings(); })); }
                catch (InvalidOperationException) { }
            }, null, Timeout.Infinite, false);
        };
        FormClosing += (_, e) =>
        {
            if (updateBusy && !updateExit) { e.Cancel = true; return; }
            if (e.CloseReason == CloseReason.UserClosing && !exitRequested) { e.Cancel = true; HideToTray(); return; }
            if (launcher.Active && e.CloseReason != CloseReason.WindowsShutDown)
            {
                e.Cancel = true; exitRequested = false; ShowSettings();
                AppDialog.Show("Сначала закройте Figma. Пока она открыта, PoFig поддерживает её соединение с прокси.", owner: this);
                return;
            }
            updater.Dispose(); checker?.Dispose(); launcher.Dispose();
            reopenListener?.Unregister(null);
            tray.Visible = false; tray.Dispose(); trayMenu.Dispose();
        };
        Reload();
    }
    private void HideToTray() { Hide(); ShowInTaskbar = false; }
    private void ShowSettings()
    {
        WindowState = FormWindowState.Normal;
        ShowInTaskbar = true;
        Show(); Activate();
    }
    private void ShowAbout()
    {
        ShowSettings();
        string version = typeof(MainForm).Assembly.GetName().Version?.ToString(3) ?? "";
        AppDialog.Show($"PoFig {version}\n\nРазработчик и создатель\nБогдан Хтоминский\n\nPoFig — независимое приложение. Figma — товарный знак Figma, Inc.", "О PoFig", this);
    }
    private void Reload()
    {
        refreshing = true; profiles.Items.Clear();
        foreach (var profile in store.Settings.Profiles) profiles.Items.Add(profile);
        profiles.SelectedIndex = store.Settings.Profiles.FindIndex(p => p.Id == store.Settings.SelectedId);
        if (profiles.SelectedIndex < 0 && profiles.Items.Count > 0) profiles.SelectedIndex = 0;
        refreshing = false; RefreshControls();
    }
    private void RefreshControls()
    {
        bool selected = Selected != null;
        edit.Enabled = remove.Enabled = selected;
        test.Enabled = selected && !launcher.Active && !updateBusy;
        profileHint.Visible = launcher.Active;
        launch.Enabled = selected && !launcher.Active && checker == null && !updateBusy;
        appPath.Text = FigmaLauncher.Locate(store.Settings.FigmaPath) ?? "Figma не найдена. Установите официальный клиент.";
    }
    private void Edit(ProxyProfile profile)
    {
        CancelCheck();
        Try(() => { using var dialog = new ProxyEditor(profile, Secrets.Read(profile.Id), (value, password) => store.Save(value, password));
            if (dialog.ShowDialog(this) == DialogResult.OK) Reload(); });
    }
    private void RemoveSelected()
    {
        if (Selected is not { } profile) return;
        if (!AppDialog.Confirm($"Удалить прокси «{profile.Name}» и его сохранённый пароль?\n\nОткрытая Figma продолжит работу с текущими настройками.",
            "Удалить прокси", this, defaultAccept: false)) return;
        Try(() => { CancelCheck(); store.Remove(profile); Reload(); });
    }
    private void ChooseFigma()
    {
        using var dialog = new OpenFileDialog { Filter = "Figma|Figma.exe", Title = "Выберите официальный Figma.exe" };
        if (dialog.ShowDialog(this) == DialogResult.OK) Try(() =>
        {
            if (!string.Equals(Path.GetFileName(dialog.FileName), "Figma.exe", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Выберите официальный Figma.exe.");
            store.Write(store.Settings with { FigmaPath = dialog.FileName }); RefreshControls();
        });
    }
    private void CancelCheck()
    {
        if (checker == null) return;
        checker.Dispose(); checker = null; test.Text = "Проверить соединение"; status.Text = "Проверка отменена."; RefreshControls();
    }
    private void Check()
    {
        if (checker != null) { CancelCheck(); return; }
        if (Selected is not { } profile) return;
        Try(() =>
        {
            string password = Secrets.Read(profile.Id);
            checker = new ProxyBridge();
            bool receivedResult = false;
            checker.Event += value =>
            {
                string? kind = value.GetProperty("event").GetString();
                if (kind == "checked") { receivedResult = true; status.Text = $"figma.com доступен через прокси · {value.GetProperty("latency_ms").GetInt64()} мс"; }
                if (kind == "error") { receivedResult = true; status.Text = value.GetProperty("message").GetString(); }
            };
            checker.Exited += () => { if (!receivedResult) status.Text = "Проверка завершилась без ответа. Повторите попытку."; checker = null; test.Text = "Проверить соединение"; RefreshControls(); };
            try { checker.Start(profile, password, "check"); }
            catch { checker.Dispose(); checker = null; throw; }
            test.Text = "Отменить проверку"; status.Text = "Проверяем доступ к figma.com…"; RefreshControls();
        });
    }
    private void Launch()
    {
        if (updateBusy) return;
        if (Selected is not { } profile) return;
        string? executable = FigmaLauncher.Locate(store.Settings.FigmaPath);
        if (executable == null)
        {
            if (AppDialog.Confirm("PoFig запускает официальный клиент Figma. Открыть страницу загрузки?", "Установите Figma", this))
                Process.Start(new ProcessStartInfo("https://www.figma.com/downloads/") { UseShellExecute = true });
            return;
        }
        Try(() => launcher.Launch(profile, Secrets.Read(profile.Id), executable));
    }
    private void Try(Action action) { try { action(); } catch (Exception ex) { Error(ex); } }
    private void Error(Exception error)
    {
        ShowSettings();
        AppDialog.Show(error.Message, owner: this);
    }
}
