from pathlib import Path
from contextlib import redirect_stdout
import hashlib
import io
import json
import runpy
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support
import swiftpm_resources
from importlib import import_module
finder_search = import_module("prepare-finder-search")


class SwiftPMResourcesTests(unittest.TestCase):
    def test_missing_bundle_blocks_packaging_with_build_guidance(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "StorageDaddy"
            binary.touch()
            with self.assertRaisesRegex(SystemExit, "Missing SwiftPM resource bundle:.*SaaSMakerUI.*Build StorageDaddy"):
                swiftpm_resources.embed_ui_resources(binary, Path(folder) / "StorageDaddy.app")
            self.assertFalse((Path(folder) / "StorageDaddy.app").exists())

    def test_bundle_is_copied_beside_existing_resources_and_refreshed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "products/StorageDaddy"
            fonts = binary.parent / swiftpm_resources.UI_BUNDLE / "Contents/Resources/Fonts"
            fonts.mkdir(parents=True)
            (fonts / "Figtree.ttf").write_bytes(b"fixture font")
            app = root / "StorageDaddy.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "StorageDaddy.icns").write_bytes(b"existing icon")
            swiftpm_resources.embed_ui_resources(binary, app)
            copied = resources / swiftpm_resources.UI_BUNDLE / "Contents/Resources/Fonts/Figtree.ttf"
            self.assertEqual(copied.read_bytes(), b"fixture font")
            self.assertEqual((resources / "StorageDaddy.icns").read_bytes(), b"existing icon")
            (fonts / "Figtree.ttf").write_bytes(b"updated fixture")
            swiftpm_resources.embed_ui_resources(binary, app)
            self.assertEqual(copied.read_bytes(), b"updated fixture")

    def test_both_assemblers_include_fonts_without_signing_or_releasing(self):
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            binary = root / ".build/release/StorageDaddy"
            fonts = binary.parent / swiftpm_resources.UI_BUNDLE / "Contents/Resources/Fonts"
            fonts.mkdir(parents=True)
            binary.write_bytes(b"fixture executable")
            (fonts / "Figtree.ttf").write_bytes(b"fixture font")
            support = root / "artifacts/MemoryPackSupport"
            support.mkdir(parents=True)
            helper = support / "memory-pack"
            helper.write_bytes(b"fixture helper"); helper.chmod(0o755)
            (support / "provenance.json").write_text(json.dumps({"binarySha256": hashlib.sha256(helper.read_bytes()).hexdigest()}))
            (support / "cargo-metadata.json").write_text("{}")
            (support / "THIRD_PARTY_NOTICES.txt").write_text("fixture notices")
            search_support = root / "artifacts/FinderSearchSupport"
            search_support.mkdir(parents=True)
            (search_support / "storage-search").write_bytes(b"fixture search helper")
            (search_support / "storage-search").chmod(0o755)
            (search_support / "provenance.json").write_text("{}")
            (search_support / "THIRD_PARTY_NOTICES.txt").write_text("fixture search notices")
            assets = root / "Assets"; assets.mkdir()
            for name in ["StorageDaddy.png", "StorageDaddy.icns", "Welcome.png", "PageDoodles.png",
                         "ClaudeOfficial.png", "ChatGPTOfficial.png", "AppHealth-LICENSE.txt"]:
                (assets / name).write_bytes(b"fixture asset")
            (assets / "ProviderIcons-provenance.json").write_text(json.dumps({"assets": [{
                "file": "ClaudeOfficial.png", "sha256": hashlib.sha256(b"fixture asset").hexdigest()
            }]}))
            (root / "DISTRIBUTION.md").write_text("fixture distribution")
            for name in ["package-app.py", "release-dmg.py"]:
                script = root / "scripts" / name
                script.write_text((scripts / name).read_text())
                output = root / "candidate"
                arguments = [str(script)] if name == "package-app.py" else [
                    str(script), "--identity", "fixture", "--output", str(output),
                    "--version", "0.1.3", "--build", "1", "--source-sha", "a" * 40
                ]
                def fake_run(command, **kwargs):
                    # Simulate hdiutil's output for checksum validation; execute no external tools.
                    if command[0] == "hdiutil" and command[1] == "create":
                        Path(command[-1]).write_bytes(b"fixture disk image")
                with redirect_stdout(io.StringIO()), patch("sys.argv", arguments), patch.object(sparkle_support, "configuration", return_value={}), \
                     patch.object(sparkle_support, "embed"), patch.object(sparkle_support, "sign"), \
                     patch.object(finder_search, "validate_support", return_value=search_support), \
                     patch("subprocess.run", side_effect=fake_run), patch("subprocess.check_output", return_value="a" * 40):
                    runpy.run_path(str(script), run_name="__main__")
                app = root / "artifacts/StorageDaddy.app" if name == "package-app.py" else output / "image-contents/storagedaddy.app"
                copied = app / "Contents/Resources" / swiftpm_resources.UI_BUNDLE / "Contents/Resources/Fonts/Figtree.ttf"
                self.assertEqual(copied.read_bytes(), b"fixture font")
                self.assertEqual((app / "Contents/Resources/StorageDaddy.icns").read_bytes(), b"fixture asset")
                if name == "package-app.py":
                    bundle = binary.parent / swiftpm_resources.UI_BUNDLE
                    bundle.rename(binary.parent / "held-bundle")
                    with patch("sys.argv", [str(script), "--check"]), \
                         patch.object(sparkle_support, "configuration", return_value={}), \
                         patch.object(finder_search, "validate_support", return_value=search_support), \
                         self.assertRaisesRegex(SystemExit, "Missing SwiftPM resource bundle"):
                        runpy.run_path(str(script), run_name="__main__")
                    (binary.parent / "held-bundle").rename(bundle)


if __name__ == "__main__":
    unittest.main()
