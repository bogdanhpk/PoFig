"""Record the exact files owned by a packaged PoFig release."""
import hashlib
import json
import plistlib
import sys
from pathlib import Path

root, platform, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
if platform == 'macos':
    version = plistlib.loads((root / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
else:
    import xml.etree.ElementTree as ET
    version = ET.parse('windows/PoFig/PoFig.csproj').findtext('.//Version')
files = []
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        raise SystemExit(f'Symlinks are not supported: {path}')
    if path.is_file() and path.resolve() != output.resolve():
        files.append(dict(path=path.relative_to(root).as_posix(), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), mode=path.stat().st_mode & 0o777))
output.write_text(json.dumps(dict(product='PoFig', platform=platform, version=version, files=files), indent=2) + '\n')
