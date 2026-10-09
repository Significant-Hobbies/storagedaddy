#!/usr/bin/env python3
"""Read-only local foundation gate; works without another app's checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import re

APPS = {"storagedaddy": "StorageDaddy", "performancedaddy": "PerformanceDaddy",
        "browserdaddy": "BrowserDaddy", "contextdaddy": "ContextDaddy"}


def check(app: str, root: Path) -> None:
    if app not in APPS:
        raise ValueError("Unknown Daddy app")
    manifest = json.loads((root / "scripts/daddy-foundation.json").read_text())
    if set(manifest) != {"schemaVersion", "sparkleVersion", "copies"} or manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported foundation contract")
    expected = manifest["copies"]
    required = {"DaddyAppUpdates.swift", "DaddyAppUpdatesTests.swift", "DaddyVisualCore.swift",
                "DaddyLifecycle.swift", "sparkle_core.py", "appcast_core.py", "check-daddy-foundation.py"}
    if set(expected) != required:
        raise ValueError("Foundation copy allowlist changed")
    for name, digest in expected.items():
        if Path(name).name != name or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid foundation copy entry")
        if name == "DaddyLifecycle.swift" and app == "contextdaddy":
            continue
        relative = (f"Tests/{APPS[app]}Tests/{name}" if name.endswith("Tests.swift") else
                    f"Sources/{APPS[app]}/{name}" if name.endswith(".swift") else f"scripts/{name}")
        path = root / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Shared Daddy foundation drift: {relative}")
    package = (root / "Package.swift").read_text()
    if not re.search(r'\.package\(url: "https://github.com/sparkle-project/Sparkle", exact: "' + re.escape(manifest["sparkleVersion"]) + r'"\)', package):
        raise ValueError("Sparkle dependency differs from the shared foundation")
    ci = (root / ".github/workflows/ci.yml").read_text()
    pins = re.findall(r'daddy-macos-candidate.yml@([0-9a-f]+)', ci)
    if len(pins) != 1 or not re.fullmatch(r"[0-9a-f]{40}", pins[0]):
        raise ValueError("Foundation tooling revision must be immutable")
    revision = pins[0]
    if re.findall(r'tooling-ref: ([0-9a-f]+)', ci) != [revision]:
        raise ValueError("Candidate workflow/tooling pins differ from the foundation")
    release = (root / ".github/workflows/release.yml").read_text()
    if not re.search(r'repository: sass-maker/saas-maker\s+ref: ' + revision + r'\b', release):
        raise ValueError("Release validation tooling differs from the foundation")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, choices=tuple(APPS))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        check(args.app, args.root)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + "\n")
    print(f"{args.app}: shared native foundation and tooling pins match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
