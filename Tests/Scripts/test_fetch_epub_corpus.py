"""公開 EPUB コーパスの取得で、付帯情報だけの変化は受け入れ、中身や構造の変化は拒否する。"""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


# 検証対象の Scripts/ へ __pycache__ を作らない
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "fetch-epub-corpus.py"
_spec = importlib.util.spec_from_file_location("fetch_epub_corpus", SCRIPT)
fetch_epub_corpus = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fetch_epub_corpus)

ENTRIES = [
    ("mimetype", b"application/epub+zip", zipfile.ZIP_STORED),
    ("META-INF/container.xml", b"<container/>", zipfile.ZIP_DEFLATED),
    ("OEBPS/text.xhtml", b"<html>" + b"text " * 200 + b"</html>", zipfile.ZIP_DEFLATED),
]


def build(path, entries=ENTRIES, date_time=(2026, 1, 1, 0, 0, 0)):
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, method in entries:
            info = zipfile.ZipInfo(name, date_time=date_time)
            info.compress_type = method
            archive.writestr(info, data)
    return path


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class FetchEPUBCorpusTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.original = build(self.root / "original.epub")
        self.book = {
            "path": "sample/book.epub",
            "sha256": sha256(self.original),
            "contentSHA256": fetch_epub_corpus.content_digest(self.original),
            "bytes": self.original.stat().st_size,
        }

    def tearDown(self):
        self.directory.cleanup()

    def run_fetch(self, served, book=None, destination="corpus"):
        book = {**(book or self.book), "url": Path(served).as_uri()}
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"sources": {}, "books": [book]}))
        # リポジトリ外のカレントディレクトリでも動くこと
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), str(self.root / destination),
             "--manifest", str(manifest)],
            cwd=self.root, capture_output=True, text=True)

    def test_identical_file_is_verified_by_sha256(self):
        result = self.run_fetch(self.original)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("matched by ZIP contents", result.stdout)

    def test_repacked_file_with_same_contents_is_accepted(self):
        repacked = build(self.root / "repacked.epub", date_time=(2026, 9, 25, 3, 0, 0))
        self.assertNotEqual(sha256(repacked), self.book["sha256"])
        result = self.run_fetch(repacked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 EPUBs matched by ZIP contents only", result.stdout)
        provenance = json.loads((self.root / "corpus" / "provenance.json").read_text())
        self.assertEqual(provenance["books"][0]["sha256"], sha256(repacked))
        self.assertEqual(provenance["books"][0]["matchedBy"], "contents")

    def test_cached_repacked_file_is_not_downloaded_again(self):
        target = self.root / "corpus" / "sample" / "book.epub"
        target.parent.mkdir(parents=True)
        build(target, date_time=(2026, 9, 25, 3, 0, 0))
        result = self.run_fetch(self.root / "missing.epub")
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_rejected(self, served, book=None):
        result = self.run_fetch(served, book)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stderr)
        self.assertFalse((self.root / "corpus" / "sample" / "book.epub").exists())

    def test_changed_contents_are_rejected(self):
        changed = [*ENTRIES[:2], ("OEBPS/text.xhtml", b"<html>changed</html>",
                                  zipfile.ZIP_DEFLATED)]
        self.assert_rejected(build(self.root / "changed.epub", changed))

    def test_compressed_mimetype_is_rejected(self):
        compressed = [("mimetype", ENTRIES[0][1], zipfile.ZIP_DEFLATED), *ENTRIES[1:]]
        self.assert_rejected(build(self.root / "compressed.epub", compressed))

    def test_reordered_entries_are_rejected(self):
        reordered = [ENTRIES[1], ENTRIES[0], ENTRIES[2]]
        self.assert_rejected(build(self.root / "reordered.epub", reordered))

    def test_without_content_digest_any_change_is_rejected(self):
        repacked = build(self.root / "repacked.epub", date_time=(2026, 9, 25, 3, 0, 0))
        book = {key: value for key, value in self.book.items() if key != "contentSHA256"}
        self.assert_rejected(repacked, book)

    def test_unreadable_zip_has_no_content_digest(self):
        broken = self.root / "broken.epub"
        broken.write_bytes(b"not a zip")
        self.assertIsNone(fetch_epub_corpus.content_digest(broken))


if __name__ == "__main__":
    unittest.main()
