using System.Diagnostics;
using System.Text.Json;

namespace PoFig;

internal static class UpdateInstaller
{
    internal sealed record Pending(string Workspace, int Pid);
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PoFig", "Updates");
    public static readonly string Marker = Path.Combine(Root, "pending.json");
    public static void Write(string path, object value)
    {
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value)); File.Move(path + ".tmp", path, true);
    }
    public static bool Resume()
    {
        if (!File.Exists(Marker)) return false;
        var pending = JsonSerializer.Deserialize<Pending>(File.ReadAllText(Marker)) ?? throw new InvalidDataException("Missing update record");
        string workspace = Path.GetFullPath(pending.Workspace);
        if (!string.Equals(Path.GetDirectoryName(workspace), Root, StringComparison.OrdinalIgnoreCase) || !Guid.TryParse(Path.GetFileName(workspace), out _)) throw new InvalidDataException("Invalid update record");
        string result = Path.Combine(workspace, "result.json");
        if (File.Exists(result))
        {
            using var json = JsonDocument.Parse(File.ReadAllText(result));
            File.Delete(Marker);
            if (json.RootElement.GetProperty("status").GetString() == "recovery_failed") throw new InvalidOperationException("Не удалось завершить обновление. Скачайте PoFig заново. Ваши прокси и пароли сохранены.");
            if (json.RootElement.GetProperty("status").GetString() != "installed") MessageBox.Show("Обновление не установлено. Предыдущая версия восстановлена. Повторите попытку позже.", "PoFig");
            else _ = Task.Run(async () => { await Task.Delay(5000); try { Directory.Delete(workspace, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } });
            return false;
        }
        if (pending.Pid > 0)
        {
            try { using var old = Process.GetProcessById(pending.Pid); if (!old.HasExited) return true; }
            catch (ArgumentException) { }
        }
        var info = new ProcessStartInfo(Path.Combine(workspace, "pofig-updater.exe")) { UseShellExecute = false, CreateNoWindow = true };
        info.ArgumentList.Add("recover"); info.ArgumentList.Add(Path.Combine(workspace, "install.json")); info.ArgumentList.Add(Environment.ProcessId.ToString());
        using var worker = Process.Start(info) ?? throw new InvalidOperationException("Не удалось восстановить обновление. Скачайте PoFig заново.");
        Write(Marker, new Pending(workspace, worker.Id)); return true;
    }
    public static async Task<JsonElement> Helper(string executable, bool ready, params string[] args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (string arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Не удалось запустить обновление.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        try
        {
            string? text = await process.StandardOutput.ReadLineAsync(timeout.Token);
            if (!ready) await process.WaitForExitAsync(timeout.Token);
            using var value = JsonDocument.Parse(text ?? "{}");
            if (!value.RootElement.TryGetProperty("event", out var kind) || kind.GetString() != (ready ? "ready" : "prepared"))
            {
                throw new InvalidOperationException("Не удалось подготовить обновление. Текущая версия сохранена. Попробуйте скачать новую версию со страницы PoFig.");
            }
            return value.RootElement.Clone();
        }
        catch
        {
            if (!process.HasExited) process.Kill();
            throw;
        }
    }
}

internal sealed class UpdateController : IDisposable
{
    private readonly Form owner;
    private readonly Func<bool> canInstall;
    private readonly Action install;
    private readonly UpdateTransport transport = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 3600000 };
    private bool checking, busy;
    private UpdateRelease? release;
    private string? dismissed;
    public event Action<string, bool>? Changed;
    public event Action<bool>? Busy;
    private CancellationTokenSource? download;
    public UpdateController(Form owner, Func<bool> canInstall, Action install)
    {
        this.owner = owner; this.canInstall = canInstall; this.install = install;
        timer.Tick += async (_, _) => await Check(false);
    }
    public void Start() { timer.Start(); _ = Check(false); }
    public async void Selected() { if (busy) return; if (release != null) Offer(true); else await Check(true); }
    private async Task Check(bool manual)
    {
        if (checking || busy) return;
        checking = true; Changed?.Invoke("Проверяем…", false);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            string data = await transport.Catalog(timeout.Token);
            release = UpdateRelease.Latest(data, typeof(UpdateController).Assembly.GetName().Version!.ToString(3));
            if (release != null) Offer(manual);
            else if (manual) MessageBox.Show(owner, "У вас последняя версия PoFig.", "Обновления", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch { if (manual) MessageBox.Show(owner, "Не удалось проверить обновления. Проверьте подключение к интернету и повторите попытку.", "PoFig"); }
        finally { checking = false; Changed?.Invoke(release == null ? "Обновления" : "Обновить", true); }
    }
    public async void Offer(bool manual = false)
    {
        if (busy || release == null || !owner.Enabled || owner.OwnedForms.Length > 0) return;
        if (!manual && (!owner.Visible || !canInstall() || dismissed == release.Version)) return;
        if (!canInstall()) { MessageBox.Show(owner, "Сначала закройте Figma, затем нажмите «Обновить» ещё раз.", "PoFig"); return; }
        var candidate = release; dismissed = candidate.Version;
        if (MessageBox.Show(owner, $"Установить PoFig {candidate.Version} и перезапустить приложение?\n\nВаши прокси и пароли сохранятся.", "Обновление PoFig", MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes) await Install(candidate);
    }
    private async Task Install(UpdateRelease candidate)
    {
        if (busy || !canInstall()) return;
        busy = true; Busy?.Invoke(true);
        string id = Guid.NewGuid().ToString(), workspace = Path.Combine(UpdateInstaller.Root, id);
        bool handedOff = false;
        int workerPid = 0;
        using var dialog = new Form { Text = "Обновление PoFig", ClientSize = new Size(380, 124), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, ControlBox = false, ShowInTaskbar = false };
        var text = new Label { Text = "Скачиваем обновление…", Location = new Point(20, 18), AutoSize = true };
        var progress = new ProgressBar { Location = new Point(20, 48), Size = new Size(340, 18) };
        var cancel = new Button { Text = "Отмена", Location = new Point(260, 82), AutoSize = true };
        dialog.Controls.AddRange([text, progress, cancel]);
        download = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        cancel.Click += (_, _) => { cancel.Enabled = false; download.Cancel(); };
        dialog.Show(owner);
        try
        {
            string target = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
            // A portable Windows install updates only files recorded in its package manifest.
            if (!File.Exists(Path.Combine(target, "PoFig-update.json"))) throw new InvalidOperationException("Установите эту версию из архива один раз. Следующие обновления можно будет устанавливать из PoFig.");
            Directory.CreateDirectory(workspace);
            string archive = Path.Combine(workspace, "update.zip");
            await transport.Download(candidate, archive, new Progress<int>(n => { if (!dialog.IsDisposed) progress.Value = n; }), download.Token);
            cancel.Enabled = false; text.Text = "Проверяем и устанавливаем…";
            string helper = Path.Combine(workspace, "pofig-updater.exe"); File.Copy(Path.Combine(target, "pofig-updater.exe"), helper);
            string prepare = Path.Combine(workspace, "prepare.json");
            UpdateInstaller.Write(prepare, new { archive, destination = Path.Combine(workspace, "package"), sha256 = candidate.Sha256, version = candidate.Version, platform = "windows" });
            var prepared = await UpdateInstaller.Helper(helper, false, "prepare", prepare);
            if (!canInstall()) throw new InvalidOperationException("Figma была открыта во время загрузки. Закройте её и повторите обновление.");
            string job = Path.Combine(workspace, "install.json");
            UpdateInstaller.Write(job, new { id, target, stage = prepared.GetProperty("root").GetString(), manifest = prepared.GetProperty("manifest").GetString(),
                manifest_sha256 = prepared.GetProperty("manifest_sha256").GetString(), backup = Path.Combine(workspace, "backup"), parent_pid = Environment.ProcessId, version = candidate.Version, platform = "windows" });
            UpdateInstaller.Write(UpdateInstaller.Marker, new UpdateInstaller.Pending(workspace, 0));
            var ready = await UpdateInstaller.Helper(helper, true, "install", job);
            workerPid = ready.GetProperty("pid").GetInt32();
            UpdateInstaller.Write(UpdateInstaller.Marker, new UpdateInstaller.Pending(workspace, workerPid));
            handedOff = true; dialog.Close(); install();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { dialog.Close(); MessageBox.Show(owner, ex is InvalidOperationException ? ex.Message : "Не удалось скачать или установить обновление. Проверьте подключение и права на папку PoFig, затем повторите попытку. Текущая версия сохранена.", "Обновление не установлено", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally
        {
            dialog.Close(); download.Dispose(); download = null;
            if (!handedOff) { if (workerPid > 0) { try { using var worker = Process.GetProcessById(workerPid); worker.Kill(); } catch (ArgumentException) { } catch (InvalidOperationException) { } }; File.Delete(UpdateInstaller.Marker); try { Directory.Delete(workspace, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
            busy = false; if (!handedOff) Busy?.Invoke(false);
        }
    }
    public void Dispose() { timer.Dispose(); download?.Cancel(); transport.Dispose(); }
}
