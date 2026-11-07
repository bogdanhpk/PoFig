using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace PoFig;

internal sealed class ProxyBridge : IDisposable
{
    private Process? process;
    private Guid generation;
    public event Action<JsonElement>? Event;
    public event Action? Exited;
    private readonly SynchronizationContext context = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

    public void Start(ProxyProfile profile, string password, string command)
    {
        string helper = Path.Combine(AppContext.BaseDirectory, "pofig-proxy.exe");
        if (!File.Exists(helper)) throw new FileNotFoundException("Не найден сетевой модуль PoFig. Распакуйте приложение целиком.");
        var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8 };
        var child = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить сетевой модуль.");
        process = child;
        Guid ticket = generation = Guid.NewGuid();
        var request = new { command, protocol = profile.Protocol, host = profile.Host, port = profile.Port, username = profile.Username, password };
        try
        {
            child.StandardInput.WriteLine(JsonSerializer.Serialize(request));
            child.StandardInput.Flush();
        }
        catch { Dispose(); throw new InvalidOperationException("Не удалось передать настройки сетевому модулю."); }
        _ = Read(child, ticket);
    }
    private async Task Read(Process child, Guid ticket)
    {
        try
        {
            while (await child.StandardOutput.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var value = document.RootElement.Clone();
                context.Post(_ => { if (generation == ticket) Event?.Invoke(value); }, null);
            }
            await child.WaitForExitAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException or JsonException) { }
        finally
        {
            context.Post(_ => { if (generation == ticket) { process = null; Exited?.Invoke(); } child.Dispose(); }, null);
        }
    }
    public void Dispose()
    {
        generation = Guid.NewGuid();
        var child = process;
        process = null;
        if (child == null) return;
        try { child.StandardInput.Close(); if (!child.HasExited) child.Kill(true); }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or System.ComponentModel.Win32Exception) { }
    }
}
