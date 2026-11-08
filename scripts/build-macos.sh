#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=13.0
if [ -n "${POFIG_CARGO_HOME:-}" ]; then export CARGO_HOME="$POFIG_CARGO_HOME"; fi
mkdir -p build/PoFig.app/Contents/MacOS build/PoFig.app/Contents/Resources build/swift-cache
architectures=("$(uname -m)")
if [ "${1:-}" = "--universal" ]; then
  architectures=(arm64 x86_64)
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
elif [ -n "${1:-}" ]; then
  echo "Usage: bash scripts/build-macos.sh [--universal]" >&2
  exit 2
fi
app_binaries=()
proxy_binaries=()
updater_binaries=()
for architecture in "${architectures[@]}"; do
  rust_architecture="$architecture"
  if [ "$architecture" = "arm64" ]; then rust_architecture=aarch64; fi
  target="$rust_architecture-apple-darwin"
  cargo build --release --locked --target "$target"
  mkdir -p "build/macos-$architecture"
  swiftc -swift-version 5 -O -parse-as-library -target "$architecture-apple-macos13.0" -module-cache-path "$PWD/build/swift-cache" \
    -framework AppKit -framework Security -framework UniformTypeIdentifiers \
    macos/Sources/*.swift -o "build/macos-$architecture/PoFig"
  app_binaries+=("build/macos-$architecture/PoFig")
  proxy_binaries+=("target/$target/release/pofig-proxy")
  updater_binaries+=("target/$target/release/pofig-updater")
done
lipo -create "${app_binaries[@]}" -output build/PoFig.app/Contents/MacOS/PoFig
lipo -create "${proxy_binaries[@]}" -output build/PoFig.app/Contents/MacOS/pofig-proxy
lipo -create "${updater_binaries[@]}" -output build/PoFig.app/Contents/MacOS/pofig-updater
cp macos/Info.plist build/PoFig.app/Contents/Info.plist
cp assets/PoFig.icns assets/PoFig.png build/PoFig.app/Contents/Resources/
cp assets/PoFig-status.svg build/PoFig.app/Contents/Resources/
cp README.md LICENSE build/PoFig.app/Contents/Resources/
python3 scripts/collect-rust-licenses.py
cp build/RustThirdPartyNotices.txt build/PoFig.app/Contents/Resources/
codesign --force --sign - build/PoFig.app/Contents/MacOS/pofig-proxy
codesign --force --sign - build/PoFig.app/Contents/MacOS/pofig-updater
codesign --force --sign - build/PoFig.app
bash scripts/package-macos.sh
