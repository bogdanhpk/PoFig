using PoFig;
string data = File.ReadAllText("tests/update-feed.json");
void Check(bool condition) { if (!condition) throw new Exception("Update feed assertion failed"); }
foreach (string arch in new[] { "x64", "arm64" })
{
    var release = UpdateRelease.Latest(data, "0.2.0", arch);
    Check(release?.Version == "0.10.0" && release.Url.AbsolutePath.EndsWith($"PoFig-win-{arch}.zip"));
    Check(UpdateRelease.Latest(data, "0.10.0", arch) == null);
    Check(UpdateRelease.Latest(data.Replace("/bogdanhpk/PoFig/", "/someone/PoFig/"), "0.2.0", arch) == null);
}
foreach (string version in new[] { "0.2", "-1.2.3", "1.2.3.4", "1.2.3-beta", "1.2.4294967296" }) Check(UpdateRelease.ParseVersion(version) == null);
foreach (string url in new[] { "http://github.com/file", "https://github.com.attacker.test/file", "https://user@github.com/file", "https://github.com:444/file" }) Check(!UpdateTransport.Allowed(new Uri(url)));
Console.WriteLine("Windows updates: architectures, numeric versions, prereleases, drafts, downgrade protection and download origins verified");
