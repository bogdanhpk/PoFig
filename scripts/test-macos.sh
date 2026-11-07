#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/swift-cache build/BridgeLifecycle.app/Contents/MacOS
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/swift-cache" -framework Security \
  macos/Sources/Profiles.swift macos/Sources/Bridge.swift macos/Tests/BridgeLifecycle.swift \
  -o build/BridgeLifecycle.app/Contents/MacOS/BridgeLifecycle
cp build/PoFig.app/Contents/MacOS/pofig-proxy build/BridgeLifecycle.app/Contents/MacOS/
python3 - <<'PY'
from pathlib import Path
import plistlib
Path('build/BridgeLifecycle.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.pofig.tests.bridge',
    'CFBundleExecutable': 'BridgeLifecycle',
    'CFBundlePackageType': 'APPL',
}))
PY
build/BridgeLifecycle.app/Contents/MacOS/BridgeLifecycle
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -framework AppKit -framework Security macos/Sources/Profiles.swift macos/Sources/Bridge.swift \
  macos/Sources/FigmaLauncher.swift macos/Tests/PreferenceRecovery.swift -o build/test-preference-recovery
build/test-preference-recovery "$PWD/build/preference-tests"
mkdir -p build/TrayLifecycle.app/Contents/MacOS build/TrayLifecycle.app/Contents/Resources
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -framework AppKit -framework Security macos/Sources/Profiles.swift macos/Sources/Bridge.swift \
  macos/Sources/AppIcon.swift macos/Sources/TrayController.swift macos/Tests/TrayLifecycle.swift -o build/TrayLifecycle.app/Contents/MacOS/TrayLifecycle
cp build/PoFig.app/Contents/MacOS/pofig-proxy build/TrayLifecycle.app/Contents/MacOS/
cp assets/PoFig-status.svg assets/PoFig.icns build/TrayLifecycle.app/Contents/Resources/
python3 - <<'PY'
from pathlib import Path
import plistlib
Path('build/TrayLifecycle.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.pofig.tests.tray',
    'CFBundleExecutable': 'TrayLifecycle',
    'CFBundlePackageType': 'APPL',
}))
PY
build/TrayLifecycle.app/Contents/MacOS/TrayLifecycle
mkdir -p build/ProfileManagement.app/Contents/MacOS build/ProfileManagement.app/Contents/Resources
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -framework AppKit -framework Security -framework UniformTypeIdentifiers \
  macos/Sources/App.swift macos/Sources/AppIcon.swift macos/Sources/Profiles.swift macos/Sources/Bridge.swift \
  macos/Sources/FigmaLauncher.swift macos/Sources/ProxyEditor.swift macos/Sources/TrayController.swift \
  macos/Tests/ProfileManagement.swift -o build/ProfileManagement.app/Contents/MacOS/ProfileManagement
cp assets/PoFig-status.svg assets/PoFig.icns build/ProfileManagement.app/Contents/Resources/
python3 - <<'PY'
from pathlib import Path
import plistlib
Path('build/ProfileManagement.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.pofig.tests.profiles',
    'CFBundleExecutable': 'ProfileManagement',
    'CFBundlePackageType': 'APPL',
}))
PY
build/ProfileManagement.app/Contents/MacOS/ProfileManagement
