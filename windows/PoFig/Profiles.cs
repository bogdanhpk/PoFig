using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace PoFig;

internal sealed record ProxyProfile
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public string Name { get; init; } = "";
    public string Protocol { get; init; } = "http";
    public string Host { get; init; } = "";
    public int Port { get; init; } = 8080;
    public string Username { get; init; } = "";
    public override string ToString() => $"{Name}   ·   {Protocol.ToUpperInvariant()}   {Host}:{Port}";

    public void Validate(string password)
    {
        if (string.IsNullOrWhiteSpace(Name) || Name.Length > 128) throw new InvalidOperationException("Укажите название прокси длиной до 128 символов.");
        bool dns = Host.Length is > 0 and <= 253 && Host.Split('.').All(label =>
            label.Length is > 0 and <= 63 && !label.StartsWith('-') && !label.EndsWith('-') &&
            label.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'));
        if (!dns && !IPAddress.TryParse(Host, out _)) throw new InvalidOperationException("Введите адрес сервера без протокола, пути и порта.");
        if (Port is < 1 or > 65535) throw new InvalidOperationException("Введите порт от 1 до 65535.");
        if (Protocol is not ("http" or "https" or "socks5")) throw new InvalidOperationException("Выберите HTTP, HTTPS или SOCKS5.");
        if (Username.Length == 0 && password.Length > 0) throw new InvalidOperationException("Укажите имя пользователя для этого пароля.");
        if (Encoding.UTF8.GetByteCount(password) > 2048) throw new InvalidOperationException("Пароль должен занимать не больше 2048 байт.");
        if (Protocol == "socks5" && (Encoding.UTF8.GetByteCount(Username) > 255 || Encoding.UTF8.GetByteCount(password) > 255))
            throw new InvalidOperationException("Для SOCKS5 логин и пароль должны занимать не больше 255 байт каждый.");
        if (Protocol != "socks5" && Username.Contains(':')) throw new InvalidOperationException("Имя пользователя HTTP-прокси не должно содержать двоеточие.");
    }
}

internal sealed record SavedSettings
{
    public List<ProxyProfile> Profiles { get; init; } = [];
    public string? SelectedId { get; init; }
    public string? FigmaPath { get; init; }
}

internal sealed class ProfileStore
{
    private readonly string file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PoFig", "profiles.json");
    public SavedSettings Settings { get; private set; } = new();
    public ProfileStore()
    {
        if (File.Exists(file)) Settings = JsonSerializer.Deserialize<SavedSettings>(File.ReadAllText(file))
            ?? throw new InvalidOperationException("Не удалось прочитать сохранённые прокси.");
    }
    public void Write(SavedSettings value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        string temporary = file + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, file, true);
        Settings = value;
    }
    public void Save(ProxyProfile profile, string password)
    {
        profile.Validate(password);
        string previous = Secrets.Read(profile.Id);
        Secrets.Write(profile.Id, password);
        var profiles = Settings.Profiles.ToList();
        int index = profiles.FindIndex(p => p.Id == profile.Id);
        if (index >= 0) profiles[index] = profile; else profiles.Add(profile);
        try { Write(Settings with { Profiles = profiles, SelectedId = profile.Id }); }
        catch { Secrets.Write(profile.Id, previous); throw; }
    }
    public void Remove(ProxyProfile profile)
    {
        var profiles = Settings.Profiles.Where(p => p.Id != profile.Id).ToList();
        Write(Settings with { Profiles = profiles, SelectedId = profiles.FirstOrDefault()?.Id });
        Secrets.Delete(profile.Id);
    }
}

internal static class Secrets
{
    private const uint Generic = 1;
    private static string Target(string id) => "PoFig/Proxy/" + id;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr pointer);

    public static string Read(string id)
    {
        if (!CredRead(Target(id), Generic, 0, out var pointer))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 1168) return "";
            throw new Win32Exception(error, "Не удалось прочитать пароль из Диспетчера учётных данных.");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            byte[] data = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, data, 0, data.Length);
            return Encoding.UTF8.GetString(data);
        }
        finally { CredFree(pointer); }
    }
    public static void Write(string id, string password)
    {
        if (password.Length == 0) { Delete(id); return; }
        byte[] data = Encoding.UTF8.GetBytes(password);
        IntPtr blob = Marshal.AllocHGlobal(data.Length);
        try
        {
            Marshal.Copy(data, 0, blob, data.Length);
            var credential = new Credential { Type = Generic, TargetName = Target(id), CredentialBlobSize = (uint)data.Length,
                CredentialBlob = blob, Persist = 2, UserName = "PoFig" };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Не удалось сохранить пароль в Диспетчере учётных данных.");
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
            for (int i = 0; i < data.Length; i++) Marshal.WriteByte(blob, i, 0);
            Marshal.FreeHGlobal(blob);
        }
    }
    public static void Delete(string id)
    {
        if (CredDelete(Target(id), Generic, 0)) return;
        int error = Marshal.GetLastWin32Error();
        if (error != 1168) throw new Win32Exception(error, "Не удалось удалить пароль из Диспетчера учётных данных.");
    }
}
