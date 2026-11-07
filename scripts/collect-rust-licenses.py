"""Collect cached Cargo dependency notices for binary distribution."""
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
cargo = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
sections = ["PoFig Rust dependencies — license notices\n"]
for package in (root / "Cargo.lock").read_text().split("[[package]]")[1:]:
    name = re.search(r'^name = "([^"]+)"', package, re.M)
    version = re.search(r'^version = "([^"]+)"', package, re.M)
    if not name or not version:
        continue
    identifier = f"{name[1]}-{version[1]}"
    for source in sorted((cargo / "registry" / "src").glob(f"*/{identifier}")):
        for file in sorted(source.iterdir()):
            if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")):
                sections.append(f"\n{'=' * 72}\n{identifier} / {file.name}\n\n{file.read_text(errors='replace')}\n")
output = root / "build" / "RustThirdPartyNotices.txt"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("".join(sections))
