"""Credential-free artifact and appcast checks; qualification/signing stay app-owned.

A syntactically valid Ed25519 signature is metadata, not cryptographic proof.
The app's Sparkle public key and installed-update acceptance remain separate gates.
"""

import base64
import binascii
import hashlib
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET


SIGNATURE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"


def select_dmg(release_directory: Path) -> Path:
    sources = list(release_directory.glob("*.dmg"))
    if len(sources) != 1 or not sources[0].is_file() or sources[0].is_symlink():
        raise ValueError("Expected exactly one regular release DMG")
    return sources[0]


def checksum_from_file(sums: Path, filename: str) -> str:
    """Read an unambiguous sha256sum record, rejecting malformed/duplicate rows."""
    if not sums.is_file():
        raise ValueError("Missing SHA256SUMS; expected the post-staple release checksum record")
    entries = {}
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
        if not match or match[2] in entries:
            raise ValueError("Malformed or duplicate SHA256SUMS entry")
        entries[match[2]] = match[1].lower()
    if filename not in entries:
        raise ValueError("Missing release DMG checksum entry")
    return entries[filename]


def validate_checksum(source: Path, expected: str) -> str:
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ValueError("Malformed release checksum")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != expected.lower():
        raise ValueError("Release checksum mismatch")
    return digest


def stage_dmg(source: Path, output: Path, filename: str, expected: str) -> Path:
    if not filename.endswith(".dmg") or Path(filename).name != filename:
        raise ValueError("Expected a plain staged DMG filename")
    digest = validate_checksum(source, expected)
    output.mkdir(parents=True, exist_ok=False)
    copied = output / filename
    shutil.copy2(source, copied)
    validate_checksum(copied, digest)
    return copied


def validate_appcast(feed: Path, staged_dmg: Path, download_url: str, expected: str) -> None:
    """Bind one signed enclosure to the exact staged bytes and app-owned URL."""
    validate_checksum(staged_dmg, expected)
    try:
        root = ET.parse(feed).getroot()
    except (ET.ParseError, OSError) as error:
        raise ValueError("Missing or malformed update feed") from error
    enclosures = root.findall("./channel/item/enclosure")
    if root.tag != "rss" or len(enclosures) != 1 or len(list(root.iter("enclosure"))) != 1:
        raise ValueError("Expected exactly one update feed enclosure")
    enclosure = enclosures[0]
    if enclosure.get("url") != download_url:
        raise ValueError("Update enclosure URL mismatch")
    if enclosure.get("length") != str(staged_dmg.stat().st_size):
        raise ValueError("Update enclosure length mismatch")
    try:
        signature = base64.b64decode(enclosure.get(SIGNATURE, ""), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Malformed update enclosure signature") from error
    if len(signature) != 64:
        raise ValueError("Unsigned or malformed update enclosure signature")
