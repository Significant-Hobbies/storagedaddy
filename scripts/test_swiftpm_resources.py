from pathlib import Path
from contextlib import redirect_stdout
import hashlib
import io
import json
import plistlib
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support
import swiftpm_resources
from importlib import import_module
finder_search = import_module("prepare-finder-search")


class SwiftPMResourcesTests(unittest.TestCase):
    def test_build_resolves_the_selected_backends_product_directory(self):
        root = Path("/fixture/source")
        with patch("subprocess.run") as build, patch("subprocess.check_output", return_value="/fixture/products/Release\n") as products:
            binary = swiftpm_resources.build_app(root)
        self.assertEqual(binary, Path("/fixture/products/Release/StorageDaddy"))
        command = build.call_args.args[0]
        self.assertEqual(command[command.index("--build-system") + 1], "swiftbuild")
        self.assertIn("--only-use-versions-from-resolved-file", command)
        self.assertEqual(products.call_args.args[0], [*command, "--show-bin-path"])

    def test_packaged_loader_runs_without_build_path_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "products/StorageDaddy"
            bundle = binary.parent / swiftpm_resources.UI_BUNDLE
            bundle.mkdir(parents=True)
            (bundle / "font.ttf").write_bytes(b"fixture font")
            app = root / "StorageDaddy.app"
            def check(command, **kwargs):
                self.assertFalse(bundle.exists())
                self.assertEqual(command, [str(app.resolve() / "Contents/MacOS/StorageDaddy"), "--check-ui-resources"])
                self.assertTrue(kwargs["check"])
                raise subprocess.CalledProcessError(5, command)
            with patch("subprocess.run", side_effect=check), self.assertRaises(subprocess.CalledProcessError):
                swiftpm_resources.check_ui_resources(binary, app)
            self.assertEqual((bundle / "font.ttf").read_bytes(), b"fixture font")

    def test_missing_bundle_blocks_packaging_with_build_guidance(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "StorageDaddy"
            binary.touch()
            with self.assertRaisesRegex(SystemExit, "Missing SwiftPM resource bundle:.*SaaSMakerUI.*Build StorageDaddy"):
                swiftpm_resources.embed_ui_resources(binary, Path(folder) / "StorageDaddy.app")
            self.assertFalse((Path(folder) / "StorageDaddy.app").exists())

    def test_window_probes_cover_dashboard_and_real_synthetic_scan(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "products/StorageDaddy"
            bundle = binary.parent / swiftpm_resources.UI_BUNDLE
            bundle.mkdir(parents=True)
            commands = []
            def check(command, **kwargs):
                self.assertFalse(bundle.exists())
                commands.append(command)
                if "--scan" in command:
                    scan_root = Path(command[-1])
                    self.assertTrue((scan_root / "project/package.json").is_file())
                    self.assertTrue((scan_root / "project/node_modules/fixture.js").is_file())
                marker = "StorageDaddy UI resources loaded" if "--check-ui-resources" in command else "StorageDaddy app startup verified"
                return subprocess.CompletedProcess(command, 0, stdout=marker + "\n", stderr="")
            with redirect_stdout(io.StringIO()), patch("subprocess.run", side_effect=check):
                swiftpm_resources.check_ui_resources(binary, Path(folder) / "StorageDaddy.app")
            self.assertEqual([command[1] for command in commands],
                             ["--check-ui-resources", "--check-app-startup", "--check-app-startup"])
            self.assertTrue(bundle.is_dir())

    def test_zero_exit_without_probe_acknowledgement_blocks_package(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "products/StorageDaddy"
            bundle = binary.parent / swiftpm_resources.UI_BUNDLE
            bundle.mkdir(parents=True)
            with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="")), \
                 self.assertRaisesRegex(RuntimeError, "did not complete"):
                swiftpm_resources.check_ui_resources(binary, Path(folder) / "StorageDaddy.app")
            self.assertTrue(bundle.is_dir())

    def test_window_crash_and_timeout_restore_build_resources(self):
        for error in [subprocess.CalledProcessError(5, ["fixture"]),
                      subprocess.TimeoutExpired(["fixture"], 30)]:
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as folder:
                binary = Path(folder) / "products/StorageDaddy"
                bundle = binary.parent / swiftpm_resources.UI_BUNDLE
                bundle.mkdir(parents=True)
                (bundle / "font.ttf").write_bytes(b"fixture font")
                font_probe = subprocess.CompletedProcess([], 0, stdout="StorageDaddy UI resources loaded\n", stderr="")
                with redirect_stdout(io.StringIO()), patch("subprocess.run", side_effect=[font_probe, error]), \
                     self.assertRaises(type(error)):
                    swiftpm_resources.check_ui_resources(binary, Path(folder) / "StorageDaddy.app")
                self.assertEqual((bundle / "font.ttf").read_bytes(), b"fixture font")

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
            mac_tools = root / "Vendor/RemoveMacAI"
            mac_tools.mkdir(parents=True)
            for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "UPSTREAM.md"]:
                (mac_tools / name).write_text("fixture Mac tools notices")
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
                arguments = [str(script), str(binary)] if name == "package-app.py" else [
                    str(script), "--identity", "fixture", "--output", str(output),
                    "--version", "0.1.3", "--build", "1", "--source-sha", "a" * 40
                ]
                def fake_run(command, **kwargs):
                    # Simulate hdiutil's output for checksum validation; execute no external tools.
                    if command[0] == "hdiutil" and command[1] == "create":
                        Path(command[-1]).write_bytes(b"fixture disk image")
                    return subprocess.CompletedProcess(command, 0, stdout="StorageDaddy UI resources loaded\nStorageDaddy app startup verified\n", stderr="")
                with redirect_stdout(io.StringIO()), patch("sys.argv", arguments), patch.object(swiftpm_resources, "build_app", return_value=binary), \
                     patch.object(sparkle_support, "configuration", return_value={"SUFeedURL": "https://example.com/appcast.xml"}), \
                     patch.object(sparkle_support, "embed"), patch.object(sparkle_support, "sign"), \
                     patch.object(finder_search, "validate_support", return_value=search_support), \
                     patch("subprocess.run", side_effect=fake_run), patch("subprocess.check_output", return_value="a" * 40):
                    runpy.run_path(str(script), run_name="__main__")
                app = root / "artifacts/StorageDaddy.app" if name == "package-app.py" else output / "image-contents/storagedaddy.app"
                copied = app / "Contents/Resources" / swiftpm_resources.UI_BUNDLE / "Contents/Resources/Fonts/Figtree.ttf"
                self.assertEqual(copied.read_bytes(), b"fixture font")
                self.assertEqual((app / "Contents/Resources/StorageDaddy.icns").read_bytes(), b"fixture asset")
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                if name == "package-app.py":
                    self.assertNotIn("SUFeedURL", info)
                else:
                    self.assertEqual(info["SUFeedURL"], "https://example.com/appcast.xml")
                if name == "package-app.py":
                    bundle = binary.parent / swiftpm_resources.UI_BUNDLE
                    bundle.rename(binary.parent / "held-bundle")
                    with patch("sys.argv", [str(script), str(binary), "--check"]), \
                         patch.object(sparkle_support, "configuration", return_value={}), \
                         patch.object(finder_search, "validate_support", return_value=search_support), \
                         self.assertRaisesRegex(SystemExit, "Missing SwiftPM resource bundle"):
                        runpy.run_path(str(script), run_name="__main__")
                    (binary.parent / "held-bundle").rename(bundle)


if __name__ == "__main__":
    unittest.main()
