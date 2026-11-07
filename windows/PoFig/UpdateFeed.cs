using System.Net;
using System.Text.Json;
using System.Runtime.InteropServices;

namespace PoFig;

internal sealed record UpdateRelease(string Version, Uri Url, long Size, string Sha256)
{
    public const string Page = "https://github.com/bogdanhpk/PoFig/releases";
    internal static Version? ParseVersion(string text)
    {
        if (text.StartsWith('v')) text = text[1..];
        var parts = text.Split('.');
        return parts.Length == 3 && parts.All(p => p.Length > 0 && p.All(char.IsAsciiDigit) && int.TryParse(p, out _)) ? new Version(text) : null;
    }
    public static UpdateRelease? Latest(string json, string current, string? architecture = null)
    {
        if (json.Length > 2_000_000) throw new InvalidDataException("Release list too large");
        var installed = ParseVersion(current) ?? throw new InvalidDataException("Invalid version");
        architecture ??= RuntimeInformation.ProcessArchitecture switch { Architecture.X64 => "x64", Architecture.Arm64 => "arm64", _ => throw new NotSupportedException("Unsupported architecture") };
        string name = $"PoFig-win-{architecture}.zip";
        using var document = JsonDocument.Parse(json);
        var candidates = new List<UpdateRelease>();
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean()) continue;
            string tag = release.GetProperty("tag_name").GetString() ?? "";
            var version = ParseVersion(tag);
            if (version == null || version <= installed) continue;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
            {
                if (asset.GetProperty("name").GetString() != name || asset.GetProperty("state").GetString() != "uploaded") continue;
                long size = asset.GetProperty("size").GetInt64();
                string? digest = asset.TryGetProperty("digest", out var d) ? d.GetString() : null;
                if (size <= 0 || size > 300 * 1024 * 1024 || digest == null || !digest.StartsWith("sha256:") || digest.Length != 71 || !digest[7..].All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f')) continue;
                if (!Uri.TryCreate(asset.GetProperty("browser_download_url").GetString(), UriKind.Absolute, out var url) || url.Scheme != "https" || url.Host != "github.com" || !url.IsDefaultPort || url.UserInfo != "" || url.Query != "" || url.Fragment != "" || Uri.UnescapeDataString(url.AbsolutePath) != $"/bogdanhpk/PoFig/releases/download/{tag}/{name}") continue;
                candidates.Add(new(tag.TrimStart('v'), url, size, digest[7..]));
            }
        }
        return candidates.MaxBy(r => ParseVersion(r.Version));
    }
}

internal sealed class UpdateTransport : IDisposable
{
    private readonly HttpClient client = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };
    public static bool Allowed(Uri url) => url.Scheme == "https" && url.IsDefaultPort && url.UserInfo == "" && (url.Host is "github.com" or "api.github.com" || url.Host.EndsWith(".githubusercontent.com", StringComparison.Ordinal));
    private async Task<HttpResponseMessage> Get(Uri url, CancellationToken token)
    {
        for (int attempt = 0; attempt < 6; attempt++)
        {
            if (!Allowed(url)) throw new InvalidDataException("Invalid update address");
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd("PoFig/" + typeof(UpdateTransport).Assembly.GetName().Version?.ToString(3));
            request.Headers.Add("X-GitHub-Api-Version", "2026-03-10");
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if (response.StatusCode is HttpStatusCode.Moved or HttpStatusCode.Redirect or HttpStatusCode.RedirectMethod or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
            {
                var location = response.Headers.Location; response.Dispose();
                if (location == null) throw new InvalidDataException("Missing redirect");
                url = new Uri(url, location); continue;
            }
            if (response.StatusCode != HttpStatusCode.OK) { response.Dispose(); throw new HttpRequestException("GitHub did not respond"); }
            return response;
        }
        throw new HttpRequestException("Too many redirects");
    }
    public async Task<string> Catalog(CancellationToken token)
    {
        using var response = await Get(new Uri("https://api.github.com/repos/bogdanhpk/PoFig/releases?per_page=20"), token);
        using var stream = await response.Content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        await Copy(stream, output, 2_000_000, null, token);
        return System.Text.Encoding.UTF8.GetString(output.ToArray());
    }
    public async Task Download(UpdateRelease release, string destination, IProgress<int> progress, CancellationToken token)
    {
        using var response = await Get(release.Url, token);
        using var stream = await response.Content.ReadAsStreamAsync(token);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
        long count = await Copy(stream, output, release.Size, progress, token);
        if (count != release.Size) throw new InvalidDataException("Incomplete download");
    }
    private static async Task<long> Copy(Stream source, Stream output, long limit, IProgress<int>? progress, CancellationToken token)
    {
        byte[] buffer = new byte[65536]; long total = 0;
        while (true)
        {
            int count = await source.ReadAsync(buffer, token); if (count == 0) break;
            total += count; if (total > limit) throw new InvalidDataException("Download is too large");
            await output.WriteAsync(buffer.AsMemory(0, count), token); progress?.Report((int)(total * 100 / limit));
        }
        return total;
    }
    public void Dispose() => client.Dispose();
}
