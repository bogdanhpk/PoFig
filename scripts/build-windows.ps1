param([ValidateSet("win-x64", "win-arm64")][string]$Runtime = "win-x64")
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$target = if ($Runtime -eq "win-arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
rustup target add $target
if ($LASTEXITCODE -ne 0) { throw "Could not install Rust target" }
cargo test --locked
if ($LASTEXITCODE -ne 0) { throw "Proxy tests failed" }
$previousRustFlags = $env:RUSTFLAGS
try {
    # Ship a self-contained helper instead of requiring a separate VC++ runtime.
    $env:RUSTFLAGS = "$previousRustFlags -C target-feature=+crt-static".Trim()
    cargo build --release --locked --target $target
    if ($LASTEXITCODE -ne 0) { throw "Proxy build failed" }
}
finally {
    $env:RUSTFLAGS = $previousRustFlags
}
$destination = Join-Path $PWD "build/PoFig-$Runtime"
dotnet publish windows/PoFig/PoFig.csproj -c Release -r $Runtime --self-contained true -o $destination
if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }
Copy-Item "target/$target/release/pofig-proxy.exe", "target/$target/release/pofig-updater.exe" $destination
python scripts/collect-rust-licenses.py
if ($LASTEXITCODE -ne 0) { throw "Could not collect dependency notices" }
Copy-Item README.md, LICENSE, build/RustThirdPartyNotices.txt $destination
python scripts/update-manifest.py $destination windows "$destination/PoFig-update.json"
if ($LASTEXITCODE -ne 0) { throw "Could not create update manifest" }
Compress-Archive -Path "$destination/*" -DestinationPath "build/PoFig-$Runtime.zip" -Force
