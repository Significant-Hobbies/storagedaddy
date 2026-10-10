#!/usr/bin/env python3
"""Prepare the pinned local FinderSearch adapter and bundled dependency notices."""
import argparse
import json
from pathlib import Path
import subprocess
from importlib import import_module

support_utils = import_module("prepare-memory-pack")
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Vendor/FinderSearch/adapter"
SUPPORT = ROOT / "artifacts/FinderSearchSupport"


def validate_support():
    required = [SUPPORT / name for name in ["storage-search", "THIRD_PARTY_NOTICES.txt", "provenance.json"]]
    if not all(path.is_file() for path in required):
        raise SystemExit("Prepare FinderSearch support first: python3 scripts/prepare-finder-search.py --build")
    provenance = json.loads((SUPPORT / "provenance.json").read_text())
    if support_utils.sha256_file(SUPPORT / "storage-search") != provenance.get("binarySha256"):
        raise SystemExit("FinderSearch helper does not match its provenance; prepare it again")
    if provenance.get("sourceTreeSha256") != support_utils.source_tree_hash(ROOT / "Vendor/FinderSearch"):
        raise SystemExit("FinderSearch helper source changed; prepare it again")
    if (SUPPORT / "storage-search").stat().st_mode & 0o111 == 0:
        raise SystemExit("FinderSearch helper is not executable")
    return SUPPORT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    if not args.build:
        print(validate_support())
        return
    subprocess.run(["cargo", "build", "--release", "--locked", "--manifest-path", str(SOURCE / "Cargo.toml"),
                    "--target-dir", str(SOURCE / "target")], check=True)
    binary = SOURCE / "target/release/storage-search"
    if not binary.is_file():
        raise SystemExit("Build the helper first: python3 scripts/prepare-finder-search.py --build")
    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--format-version", "1",
                                                  "--manifest-path", str(SOURCE / "Cargo.toml")], text=True))
    notices = ["FinderSearch bundled dependency notices", (ROOT / "Vendor/FinderSearch/UPSTREAM.md").read_text(),
               (ROOT / "Vendor/FinderSearch/LICENSE").read_text()]
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        notices += [f"\n--- {package['name']} {package['version']} ---", support_utils.license_text(package)]
    provenance = {"format": "finder-search-support/1", "binarySha256": support_utils.sha256_file(binary),
                  "sourceTreeSha256": support_utils.source_tree_hash(ROOT / "Vendor/FinderSearch"),
                  "cargoLockSha256": support_utils.sha256_file(SOURCE / "Cargo.lock"),
                  "finderSearchCommit": "44eb8c30583270a93fb64146c8d2d1a2f296053b"}
    support_utils.write_atomic(SUPPORT / "storage-search", binary.read_bytes(), 0o755)
    support_utils.write_atomic(SUPPORT / "THIRD_PARTY_NOTICES.txt", ("\n".join(notices) + "\n").encode())
    support_utils.write_atomic(SUPPORT / "provenance.json", (json.dumps(provenance, indent=2) + "\n").encode())
    print(validate_support())


if __name__ == "__main__":
    main()
