"""SwiftPM resources required by the native UI's bundled fonts."""
from pathlib import Path
import shutil

UI_BUNDLE = "SaaSMakerUI_SaaSMakerUI.bundle"


def ui_resource_bundle(binary: Path) -> Path:
    bundle = binary.parent / UI_BUNDLE
    if not bundle.is_dir():
        raise SystemExit(f"Missing SwiftPM resource bundle: {bundle}. Build StorageDaddy with its SaaSMakerUI resources before packaging.")
    return bundle


def embed_ui_resources(binary: Path, app: Path) -> None:
    bundle = ui_resource_bundle(binary)
    shutil.copytree(bundle, app / "Contents/Resources" / UI_BUNDLE, dirs_exist_ok=True)
