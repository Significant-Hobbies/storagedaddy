"""Package an already-built local executable and prepared local helper support."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sparkle_support
from importlib import import_module
import swiftpm_resources
finder_search = import_module("prepare-finder-search")

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("binary", nargs="?", type=Path, default=root / ".build/release/StorageDaddy")
parser.add_argument("--output", type=Path, default=root / "artifacts/StorageDaddy.app", help="Local development app bundle destination")
parser.add_argument("--check", action="store_true", help="validate prepared support without changing the app bundle")
parser.add_argument("--version", help="Explicit release version")
parser.add_argument("--build", type=int, help="Explicit release build number")
args = parser.parse_args()
if (args.version is None) != (args.build is None):
    parser.error("--version and --build must be passed together")
if args.version is not None and (not all(part.isdigit() for part in args.version.split(".")) or args.build < 1):
    parser.error("Version must be numeric and build must be positive")
binary = args.binary
update_configuration = sparkle_support.configuration()
if not binary.is_file():
    raise SystemExit(f"Build the executable first: {binary}")
swiftpm_resources.ui_resource_bundle(binary)
support = root / "artifacts/MemoryPackSupport"
required_support = [support / "memory-pack", support / "THIRD_PARTY_NOTICES.txt", support / "provenance.json", support / "cargo-metadata.json"]
missing = [path for path in required_support if not path.is_file()]
if missing:
    raise SystemExit("Prepare Memory Pack support first: python3 scripts/prepare-memory-pack.py --source ../chatgpt-memory-insights/packer [--build]")
provenance = json.loads((support / "provenance.json").read_text())
digest = hashlib.sha256((support / "memory-pack").read_bytes()).hexdigest()
if digest != provenance.get("binarySha256"):
    raise SystemExit("Prepared memory-pack binary does not match provenance.json; rerun scripts/prepare-memory-pack.py")
if (support / "memory-pack").stat().st_mode & 0o111 == 0:
    raise SystemExit("Prepared memory-pack helper is not executable")
icon_provenance_path = root / "Assets/ProviderIcons-provenance.json"
if not icon_provenance_path.is_file():
    raise SystemExit("Missing AI provider icon provenance")
icon_provenance = json.loads(icon_provenance_path.read_text())
for asset in icon_provenance.get("assets", []):
    name = asset.get("file", "")
    path = root / "Assets" / name
    if not name or Path(name).name != name or not path.is_file():
        raise SystemExit(f"Missing AI provider icon: {name}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != asset.get("sha256"):
        raise SystemExit(f"AI provider icon does not match provenance: {name}")
finder_support = finder_search.validate_support()
if args.check:
    print(f"ready: {binary}")
    print(f"ready: {support}")
    raise SystemExit(0)
bundle = args.output
contents = bundle / "Contents"
previous_plist = contents / "Info.plist"
build_number = 1
if args.build is not None:
    build_number = args.build
elif previous_plist.is_file():
    previous = plistlib.loads(previous_plist.read_bytes())
    build_number = int(previous.get("CFBundleVersion", "0")) + 1
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Helpers").mkdir(parents=True, exist_ok=True)
# Replace the inode rather than truncating an executable a local scan may still use.
pending_binary = contents / "MacOS/StorageDaddy.pending"
shutil.copy2(binary, pending_binary)
pending_binary.replace(contents / "MacOS/StorageDaddy")
pending_helper = contents / "Helpers/memory-pack.pending"
shutil.copy2(support / "memory-pack", pending_helper)
pending_helper.chmod(0o755)
pending_helper.replace(contents / "Helpers/memory-pack")
pending_search = contents / "Helpers/storage-search.pending"
shutil.copy2(finder_support / "storage-search", pending_search)
pending_search.chmod(0o755)
pending_search.replace(contents / "Helpers/storage-search")
(contents / "Resources").mkdir(exist_ok=True)
for source, name in [("THIRD_PARTY_NOTICES.txt", "FinderSearch-THIRD_PARTY_NOTICES.txt"), ("provenance.json", "FinderSearch-provenance.json")]:
    shutil.copy2(finder_support / source, contents / "Resources" / name)
swiftpm_resources.embed_ui_resources(binary, bundle)
mac_tools_notices = "\n\n".join((root / "Vendor/RemoveMacAI" / name).read_text() for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "UPSTREAM.md"])
(contents / "Resources" / "RemoveMacAI-THIRD_PARTY_NOTICES.txt").write_text(mac_tools_notices)
for name in ["StorageDaddy.png", "StorageDaddy.icns", "Welcome.png", "PageDoodles.png",
             "ClaudeOfficial.png", "ChatGPTOfficial.png", "ProviderIcons-provenance.json"]:
    shutil.copy2(root / "Assets" / name, contents / "Resources" / name)
shutil.copy2(root / "Assets" / "AppHealth-LICENSE.txt", contents / "Resources" / "AppHealth-LICENSE.txt")
shutil.copy2(support / "THIRD_PARTY_NOTICES.txt", contents / "Resources" / "MemoryPack-THIRD_PARTY_NOTICES.txt")
shutil.copy2(support / "provenance.json", contents / "Resources" / "MemoryPack-provenance.json")
sparkle_support.embed(bundle)
with (contents / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleExecutable": "StorageDaddy", "CFBundleIdentifier": "local.fleet.storagedaddy",
        "CFBundleName": "storagedaddy", "CFBundleDisplayName": "storagedaddy",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version or "0.1.3",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "CFBundleVersion": str(build_number), "CFBundleIconFile": "StorageDaddy.icns", "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication", **update_configuration
    }, f)
sparkle_support.sign(bundle, "-", timestamp=False)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(contents / "Helpers/memory-pack")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(contents / "Helpers/storage-search")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
subprocess.run([
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    "-f", str(bundle)
], check=True)
print(bundle)
