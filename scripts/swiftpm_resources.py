"""SwiftPM resources required by the native UI's bundled fonts."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

UI_BUNDLE = "SaaSMakerUI_SaaSMakerUI.bundle"


def build_app(root: Path) -> Path:
    # The native backend's Bundle.module searches the app root rather than
    # Contents/Resources. Swift Build emits the app-aware resource accessor.
    command = ["swift", "build", "--build-system", "swiftbuild", "-c", "release",
               "--product", "StorageDaddy", "--only-use-versions-from-resolved-file"]
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([*command[:-3], "--product", "storagedaddy-mcp", "--only-use-versions-from-resolved-file"], cwd=root, check=True)
    products = subprocess.check_output([*command, "--show-bin-path"], cwd=root, text=True).strip()
    return Path(products) / "StorageDaddy"


def ui_resource_bundle(binary: Path) -> Path:
    bundle = binary.parent / UI_BUNDLE
    if not bundle.is_dir():
        raise SystemExit(f"Missing SwiftPM resource bundle: {bundle}. Build StorageDaddy with its SaaSMakerUI resources before packaging.")
    return bundle


def embed_ui_resources(binary: Path, app: Path) -> None:
    bundle = ui_resource_bundle(binary)
    shutil.copytree(bundle, app / "Contents/Resources" / UI_BUNDLE, dirs_exist_ok=True)


def check_ui_resources(binary: Path, app: Path) -> None:
    # Prevent the generated accessor's absolute build-path fallback from hiding
    # a broken package on the machine that built it. Always restore the inputs.
    bundle = ui_resource_bundle(binary)
    held = bundle.with_name(f".{bundle.name}.startup-check-{uuid.uuid4().hex}")
    bundle.rename(held)
    try:
        executable = str(app.resolve() / "Contents/MacOS/StorageDaddy")
        run_probe(executable, ["--check-ui-resources"], "StorageDaddy UI resources loaded")
        run_probe(executable, ["--check-app-startup"], "StorageDaddy app startup verified")
        with tempfile.TemporaryDirectory(prefix="storagedaddy-startup-") as folder:
            project = Path(folder) / "project"
            dependencies = project / "node_modules"
            dependencies.mkdir(parents=True)
            (project / "package.json").write_text('{"private":true}')
            (dependencies / "fixture.js").write_bytes(b"synthetic dependency\n" * 1024)
            run_probe(executable, ["--check-app-startup", "--scan", folder],
                      "StorageDaddy app startup verified")
    finally:
        held.rename(bundle)


def run_probe(executable: str, arguments: list, marker: str) -> None:
    result = subprocess.run([executable, *arguments], check=True, timeout=30,
                            capture_output=True, text=True)
    if marker not in result.stdout.splitlines():
        raise RuntimeError(f"Packaged app did not complete {arguments[0]}")
    print(marker)
