using System.Diagnostics;

namespace PoFig;

internal sealed class FigmaLauncher : IDisposable
{
    private ProxyBridge? bridge;
    private readonly System.Windows.Forms.Timer monitor = new() { Interval = 1000 };
    private bool seenProcess;
    private int startupTicks;
    private bool launchAnnounced;
    private string runningDescription = "";
    public bool Active { get; private set; }
    public event Action<string>? Status;
    public event Action<Exception>? Error;
    public event Action? Launched;

    public static bool Running()
    {
        var processes = Process.GetProcessesByName("Figma");
        try { return processes.Any(p => !p.HasExited); }
        finally { foreach (var process in processes) process.Dispose(); }
    }
    public static string? Locate(string? savedPath)
    {
        if (savedPath != null && File.Exists(savedPath)) return savedPath;
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Figma");
        if (Directory.Exists(root))
        {
            var versioned = Directory.EnumerateDirectories(root, "app-*").OrderByDescending(Directory.GetLastWriteTimeUtc)
                .Select(p => Path.Combine(p, "Figma.exe")).FirstOrDefault(File.Exists);
            if (versioned != null) return versioned;
        }
        return new[] { Path.Combine(root, "Figma.exe"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Figma", "Figma.exe") }.FirstOrDefault(File.Exists);
    }
    public FigmaLauncher()
    {
        monitor.Tick += (_, _) =>
        {
            try
            {
                bool running = Running();
                if (running) seenProcess = true;
                if (seenProcess && !running) { Dispose(); return; }
                if (Active && !launchAnnounced && HasWindow())
                {
                    launchAnnounced = true;
                    Status?.Invoke(runningDescription);
                    Launched?.Invoke();
                }
                else if (Active && !launchAnnounced && ++startupTicks > 20)
                    Fail(new InvalidOperationException("Окно Figma не открылось за 20 секунд. Проверьте путь к Figma.exe."));
            }
            catch (Exception ex) { Fail(ex); }
        };
    }
    private static bool HasWindow()
    {
        var processes = Process.GetProcessesByName("Figma");
        try
        {
            foreach (var process in processes)
            {
                try { if (!process.HasExited && process.MainWindowHandle != IntPtr.Zero) return true; }
                catch (InvalidOperationException) { }
            }
            return false;
        }
        finally { foreach (var process in processes) process.Dispose(); }
    }
    public void Launch(ProxyProfile profile, string password, string executable)
    {
        if (Active || Running()) throw new InvalidOperationException("Закройте Figma и запустите её из PoFig, чтобы применить прокси.");
        profile.Validate(password);
        launchAnnounced = false;
        runningDescription = $"Figma запущена через {profile.Name}";
        bridge = new ProxyBridge();
        bridge.Event += value =>
        {
            string? kind = value.GetProperty("event").GetString();
            if (kind == "error") { Fail(new InvalidOperationException(value.GetProperty("message").GetString())); return; }
            if (kind != "ready") return;
            try
            {
                if (Running()) throw new InvalidOperationException("Закройте уже открытую Figma и повторите запуск из PoFig.");
                int port = value.GetProperty("port").GetInt32();
                var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! };
                start.ArgumentList.Add($"--proxy-server=http://127.0.0.1:{port}");
                start.ArgumentList.Add("--proxy-bypass-list=localhost;127.0.0.1;[::1]");
                using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить Figma.");
                seenProcess = false; startupTicks = 0; monitor.Start();
                Status?.Invoke("Открываем окно Figma…");
            }
            catch (Exception ex) { Fail(ex); }
        };
        bridge.Exited += () => { if (Active) Fail(new InvalidOperationException("Сетевой модуль завершил работу. Закройте Figma и запустите её снова из PoFig.")); };
        Active = true;
        try { bridge.Start(profile, password, "serve"); Status?.Invoke("Подключаем прокси…"); }
        catch { Dispose(); throw; }
    }
    private void Fail(Exception error) { Dispose(); Error?.Invoke(error); }
    public void Dispose()
    {
        monitor.Stop(); bridge?.Dispose(); bridge = null; Active = false;
        Status?.Invoke("Figma не запущена через PoFig");
    }
}
