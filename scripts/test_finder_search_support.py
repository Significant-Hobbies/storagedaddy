import hashlib
from importlib import import_module
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

support = import_module("prepare-finder-search")


class FinderSearchPackagingTests(unittest.TestCase):
    def test_missing_support_blocks_packaging(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(support, "SUPPORT", Path(folder)):
            with self.assertRaises(SystemExit):
                support.validate_support()

    def test_binary_tampering_and_changed_source_block_packaging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "Vendor/FinderSearch"
            source.mkdir(parents=True)
            (source / "source.rs").write_text("original source")
            prepared = root / "support"
            prepared.mkdir()
            binary = prepared / "storage-search"
            binary.write_bytes(b"original helper")
            binary.chmod(0o755)
            (prepared / "THIRD_PARTY_NOTICES.txt").write_text("MIT notice")
            (prepared / "provenance.json").write_text(json.dumps({
                "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "sourceTreeSha256": support.support_utils.source_tree_hash(source),
            }))
            with patch.object(support, "SUPPORT", prepared), patch.object(support, "ROOT", root):
                self.assertEqual(support.validate_support(), prepared)
                binary.write_bytes(b"modified helper")
                with self.assertRaises(SystemExit):
                    support.validate_support()
                binary.write_bytes(b"original helper")
                (source / "source.rs").write_text("modified source")
                with self.assertRaises(SystemExit):
                    support.validate_support()


if __name__ == "__main__":
    unittest.main()
