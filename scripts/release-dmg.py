#!/usr/bin/env python3
"""Create an isolated Developer ID signed DMG; never publishes a download."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sparkle_support

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True)


def sha256(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Developer ID Application identity name or certificate hash")
    parser.add_argument("--output", type=Path, required=True, help="New output directory; existing paths are never overwritten")
    parser.add_argument("--notary-profile", help="Existing Keychain profile name; never pass credentials here")
    parser.add_argument("--notary-api-key", type=Path, help="Path to protected App Store Connect API key")
    parser.add_argument("--notary-key-id", help="App Store Connect API key identifier")
    parser.add_argument("--notary-issuer-id", help="App Store Connect issuer identifier")
    parser.add_argument("--version", required=True, help="Release version, for example 0.1.3")
    parser.add_argument("--build", type=int, required=True, help="Release build number")
    parser.add_argument("--source-sha", required=True, help="Exact tagged source commit")
    args = parser.parse_args()
    if not all(part.isdigit() for part in args.version.split(".")) or args.build < 1:
        parser.error("Version must be numeric and build must be positive")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        parser.error("--source-sha must be a full commit hash")
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if source_sha != args.source_sha:
        parser.error("--source-sha does not match the checked-out source")
    api_auth = [args.notary_api_key, args.notary_key_id, args.notary_issuer_id]
    if (args.notary_profile and any(api_auth)) or (any(api_auth) and not all(api_auth)):
        parser.error("Pass a Keychain profile or the complete API key, key ID, and issuer ID")
    run("python3", ROOT / "scripts" / "package-app.py", "--check")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    stage = output / "image-contents"
    app = stage / "storagedaddy.app"
    for name in ["MacOS", "Helpers", "Resources"]:
        (app / "Contents" / name).mkdir(parents=True, exist_ok=True)
    # Assemble only known public inputs, never the artifacts directory or logs.
    binary = ROOT / ".build/release/StorageDaddy"
    helper = ROOT / "artifacts/MemoryPackSupport/memory-pack"
    for source, destination in [(binary, app / "Contents/MacOS/StorageDaddy"),
                                (helper, app / "Contents/Helpers/memory-pack"),
                                (ROOT / "artifacts/FinderSearchSupport/storage-search", app / "Contents/Helpers/storage-search")]:
        shutil.copyfile(source, destination)
        destination.chmod(0o755)
    for name in ["StorageDaddy.png", "StorageDaddy.icns", "Welcome.png", "PageDoodles.png",
                 "ClaudeOfficial.png", "ChatGPTOfficial.png", "ProviderIcons-provenance.json"]:
        shutil.copyfile(ROOT / "Assets" / name, app / "Contents/Resources" / name)
    for source, name in [("THIRD_PARTY_NOTICES.txt", "MemoryPack-THIRD_PARTY_NOTICES.txt"),
                         ("provenance.json", "MemoryPack-provenance.json")]:
        shutil.copyfile(ROOT / "artifacts/MemoryPackSupport" / source, app / "Contents/Resources" / name)
    for source, name in [("THIRD_PARTY_NOTICES.txt", "FinderSearch-THIRD_PARTY_NOTICES.txt"),
                         ("provenance.json", "FinderSearch-provenance.json")]:
        shutil.copyfile(ROOT / "artifacts/FinderSearchSupport" / source, app / "Contents/Resources" / name)
    # The release must not inherit version/build from an untracked local app.
    info = {
        "CFBundleExecutable": "StorageDaddy", "CFBundleIdentifier": "local.fleet.storagedaddy",
        "CFBundleName": "storagedaddy", "CFBundleDisplayName": "storagedaddy",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version,
        "LSApplicationCategoryType": "public.app-category.utilities",
        "CFBundleVersion": str(args.build), "CFBundleIconFile": "StorageDaddy.icns",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication", **sparkle_support.configuration(),
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    sparkle_support.embed(app)
    sparkle_support.sign(app, args.identity)
    # Stable identity; a distribution signature replaces the local ad-hoc one.
    for target in [app / "Contents/Helpers/memory-pack", app / "Contents/Helpers/storage-search", app]:
        run("codesign", "--force", "--sign", args.identity, "--timestamp", "--options", "runtime", target)
    run("codesign", "--verify", "--deep", "--strict", app)
    (stage / "Applications").symlink_to("/Applications")
    shutil.copyfile(ROOT / "DISTRIBUTION.md", stage / "Start Here.txt")
    version = info["CFBundleShortVersionString"]
    dmg = output / f"storagedaddy-{version}-beta-arm64.dmg"
    run("hdiutil", "create", "-volname", "storagedaddy", "-srcfolder", stage,
        "-format", "UDZO", "-ov", dmg)
    run("codesign", "--force", "--sign", args.identity, "--timestamp", dmg)
    run("hdiutil", "verify", dmg)
    receipt = {
        "version": version, "build": info["CFBundleVersion"],
        "architecture": "arm64", "minimumMacOS": "14.0", "channel": "beta",
        "signed": True, "hardenedRuntime": True, "notarized": False,
        "stapled": False, "publicReady": False,
        "sourceBinarySha256": sha256(binary), "helperSha256": sha256(helper),
        "searchHelperSha256": sha256(ROOT / "artifacts/FinderSearchSupport/storage-search"),
        "dmgSha256": sha256(dmg), "dmgBytes": dmg.stat().st_size,
        "sourceSha": args.source_sha,
    }
    receipt_path = output / "release-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    if args.notary_profile or all(api_auth):
        auth = (["--keychain-profile", args.notary_profile] if args.notary_profile else
                ["--key", str(args.notary_api_key), "--key-id", args.notary_key_id,
                 "--issuer", args.notary_issuer_id])
        result = subprocess.run(["xcrun", "notarytool", "submit", str(dmg), *auth,
                                 "--wait", "--output-format", "json"], check=True, capture_output=True, text=True)
        notarization = json.loads(result.stdout)
        (output / "notarization.json").write_text(json.dumps(notarization, indent=2) + "\n")
        if notarization.get("status") != "Accepted":
            raise SystemExit("Apple has not accepted this candidate; see notarization.json")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
        receipt.update(notarized=True, stapled=True, dmgSha256=sha256(dmg), dmgBytes=dmg.stat().st_size)
        # Human/runtime qualification is a separate gate from Apple's malware check.
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    (output / "SHA256SUMS").write_text(f"{sha256(dmg)}  {dmg.name}\n")
    print(dmg)
    print("Signed candidate created. Check release-receipt.json before distribution.")


if __name__ == "__main__":
    main()
