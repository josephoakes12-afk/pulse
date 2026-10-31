"""Release artifacts must ship complete notices for the resolved crypto code."""

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import stat
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).parents[2]
LEGAL = ROOT / "Resources/Legal"
spec = importlib.util.spec_from_file_location("legal_notices", ROOT / "scripts/copy-legal-notices.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LegalNoticeTests(unittest.TestCase):
    def setUp(self):
        self.entries = json.loads((LEGAL / "manifest.json").read_text())

    def fixtures(self, directory):
        checkouts = directory / "checkouts"
        for entry in self.entries:
            path = checkouts / entry["dependency"] / entry["revisionFile"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("This directory is derived from BoringSSL at revision " + entry["revision"] + "\n")
        return checkouts

    def test_complete_pinned_notices_and_provenance_are_present(self):
        self.assertEqual({entry["component"] for entry in self.entries}, {"CNIOBoringSSL", "CCryptoBoringSSL"})
        readme = (LEGAL / "README.md").read_text()
        for entry in self.entries:
            with self.subTest(component=entry["component"]):
                content = (LEGAL / entry["licenseFile"]).read_bytes()
                self.assertGreater(len(content), 10_000)
                self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
                self.assertIn(entry["revision"], readme)
                self.assertIn(entry["sourceURL"], readme)
                self.assertTrue(entry["sourceURL"].endswith("/" + entry["revision"] + "/LICENSE"))
        self.assertIn("OpenSSL License", (LEGAL / "CNIOBoringSSL-LICENSE.txt").read_text())
        self.assertIn("Apache License", (LEGAL / "CCryptoBoringSSL-LICENSE.txt").read_text())

    def test_bundle_copy_preserves_full_text_and_is_readable(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            destination = directory / "bundle/Licenses/BoringSSL"
            module.copy_notices(LEGAL, self.fixtures(directory), destination)
            self.assertEqual({p.name for p in destination.iterdir()}, {
                "CNIOBoringSSL-LICENSE.txt", "CCryptoBoringSSL-LICENSE.txt", "manifest.json", "README.md"})
            for entry in self.entries:
                copied = destination / entry["licenseFile"]
                self.assertEqual(copied.read_bytes(), (LEGAL / entry["licenseFile"]).read_bytes())
                self.assertTrue(stat.S_IMODE(copied.stat().st_mode) & stat.S_IROTH)

    def test_upstream_revision_change_blocks_packaging_before_any_copy(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            checkouts = self.fixtures(directory)
            entry = self.entries[0]
            (checkouts / entry["dependency"] / entry["revisionFile"]).write_text("at revision " + "f" * 40)
            destination = directory / "bundle"
            with self.assertRaisesRegex(ValueError, "revision changed"):
                module.copy_notices(LEGAL, checkouts, destination)
            self.assertFalse(destination.exists())

    def test_missing_or_truncated_notice_blocks_packaging(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            legal = directory / "legal"
            shutil.copytree(LEGAL, legal)
            (legal / self.entries[1]["licenseFile"]).write_text("Truncated license\n")
            destination = directory / "bundle"
            with self.assertRaisesRegex(ValueError, "missing or has changed"):
                module.copy_notices(legal, self.fixtures(directory), destination)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
