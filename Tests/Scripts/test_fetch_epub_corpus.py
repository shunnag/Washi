"""公開 EPUB コーパスの取得で、付帯情報と並び順だけの変化は受け入れ、中身や OCF の構造の変化は拒否する。"""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
import zlib


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


def build(path, entries=ENTRIES, date_time=(2026, 1, 1, 0, 0, 0), extra=None):
    with warnings.catch_warnings():
        # 同名エントリの検査で zipfile が出す UserWarning を抑える
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(path, "w") as archive:
            for name, data, method in entries:
                info = zipfile.ZipInfo(name, date_time=date_time)
                info.compress_type = method
                if extra and name in extra:
                    info.extra = extra[name]
                archive.writestr(info, data)
    return path


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def reorder_central_directory(path, order):
    """ローカルヘッダの物理順はそのままに、central directory の並びだけを order に変える。"""
    data = Path(path).read_bytes()
    end = data.rfind(b"PK\x05\x06")
    size, offset = struct.unpack_from("<II", data, end + 12)
    records, position = [], offset
    while position < offset + size:
        name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, position + 28)
        record_end = position + 46 + name_length + extra_length + comment_length
        records.append(data[position:record_end])
        position = record_end
    Path(path).write_bytes(
        data[:offset] + b"".join(records[index] for index in order) + data[offset + size:])
    return path


def corrupt_deflate(path, name="OEBPS/text.xhtml"):
    """deflate の先頭バイトを 0xFF にする。BTYPE=11(予約)で伸長は必ず zlib.error になる。"""
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo(name)
    data = bytearray(Path(path).read_bytes())
    name_length, extra_length = struct.unpack_from("<HH", data, info.header_offset + 26)
    data[info.header_offset + 30 + name_length + extra_length] = 0xFF
    Path(path).write_bytes(bytes(data))
    return path


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

    def assert_accepted_by_contents(self, served, destination="corpus"):
        result = self.run_fetch(served, destination=destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 EPUBs matched by ZIP contents only", result.stdout)
        provenance = json.loads((self.root / destination / "provenance.json").read_text())
        self.assertEqual(provenance["books"][0]["sha256"], sha256(served))
        self.assertEqual(provenance["books"][0]["matchedBy"], "contents")

    def test_identical_file_is_verified_by_sha256(self):
        result = self.run_fetch(self.original)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("matched by ZIP contents", result.stdout)

    def test_repacked_file_with_same_contents_is_accepted(self):
        repacked = build(self.root / "repacked.epub", date_time=(2026, 9, 25, 3, 0, 0))
        self.assertNotEqual(sha256(repacked), self.book["sha256"])
        self.assert_accepted_by_contents(repacked)

    def test_reordered_entries_after_mimetype_are_accepted(self):
        # W3C の再生成と同じく、mimetype より後ろの並びだけが変わる
        reordered = build(self.root / "reordered.epub", [ENTRIES[0], ENTRIES[2], ENTRIES[1]],
                          date_time=(2026, 9, 25, 3, 0, 0))
        self.assert_accepted_by_contents(reordered, "physical")
        # central directory の並びだけが物理順と違う場合も同じ
        directory_only = reorder_central_directory(
            build(self.root / "directory.epub"), [0, 2, 1])
        self.assertNotEqual(sha256(directory_only), self.book["sha256"])
        self.assert_accepted_by_contents(directory_only, "directory")

    def test_cached_repacked_file_is_not_downloaded_again(self):
        target = self.root / "corpus" / "sample" / "book.epub"
        target.parent.mkdir(parents=True)
        build(target, date_time=(2026, 9, 25, 3, 0, 0))
        result = self.run_fetch(self.root / "missing.epub")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cached_reordered_file_is_not_downloaded_again(self):
        target = self.root / "corpus" / "sample" / "book.epub"
        target.parent.mkdir(parents=True)
        build(target, [ENTRIES[0], ENTRIES[2], ENTRIES[1]])
        result = self.run_fetch(self.root / "missing.epub")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 EPUBs matched by ZIP contents only", result.stdout)

    def test_corrupted_cached_file_is_downloaded_again(self):
        target = self.root / "corpus" / "sample" / "book.epub"
        target.parent.mkdir(parents=True)
        target.write_bytes(self.original.read_bytes())
        corrupt_deflate(target)
        # 前提: キャッシュの読み出しが伸長エラーになること
        with zipfile.ZipFile(target) as archive, self.assertRaises(zlib.error):
            archive.read("OEBPS/text.xhtml")
        result = self.run_fetch(self.original)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("matched by ZIP contents", result.stdout)
        self.assertEqual(sha256(target), self.book["sha256"])

    def assert_rejected(self, served, book=None, destination="corpus"):
        result = self.run_fetch(served, book, destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stderr)
        self.assertFalse((self.root / destination / "sample" / "book.epub").exists())
        self.assertFalse((self.root / destination / "sample" / "book.download").exists())

    def test_corrupted_download_is_rejected(self):
        corrupted = corrupt_deflate(build(self.root / "corrupted.epub"))
        self.assert_rejected(corrupted)

    def test_changed_contents_are_rejected(self):
        changed = [*ENTRIES[:2], ("OEBPS/text.xhtml", b"<html>changed</html>",
                                  zipfile.ZIP_DEFLATED)]
        self.assert_rejected(build(self.root / "changed.epub", changed))

    def test_changed_names_and_methods_are_rejected(self):
        cases = {
            "renamed": [*ENTRIES[:2], ("OEBPS/renamed.xhtml", ENTRIES[2][1], zipfile.ZIP_DEFLATED)],
            "stored": [ENTRIES[0], ("META-INF/container.xml", ENTRIES[1][1], zipfile.ZIP_STORED),
                       ENTRIES[2]],
        }
        for label, entries in cases.items():
            with self.subTest(label):
                self.assert_rejected(build(self.root / f"{label}.epub", entries), destination=label)

    def test_compressed_mimetype_is_rejected(self):
        compressed = [("mimetype", ENTRIES[0][1], zipfile.ZIP_DEFLATED), *ENTRIES[1:]]
        self.assert_rejected(build(self.root / "compressed.epub", compressed))

    def test_mimetype_not_first_is_rejected(self):
        # 物理順・central directory とも2番目
        with self.subTest("both"):
            moved = build(self.root / "moved.epub", [ENTRIES[1], ENTRIES[0], ENTRIES[2]])
            self.assertEqual(fetch_epub_corpus.content_digest(moved), self.book["contentSHA256"])
            self.assert_rejected(moved, destination="both")
        # 物理的には先頭だが、central directory では2番目
        with self.subTest("directory"):
            directory = reorder_central_directory(build(self.root / "directory.epub"), [1, 0, 2])
            self.assertEqual(fetch_epub_corpus.content_digest(directory),
                             self.book["contentSHA256"])
            self.assert_rejected(directory, destination="directory")
        # central directory では先頭だが、ファイルの先頭(オフセット 0)にない
        with self.subTest("offset"):
            prefixed = self.root / "prefixed.epub"
            prefixed.write_bytes(b"JUNK" + self.original.read_bytes())
            self.assertEqual(fetch_epub_corpus.content_digest(prefixed),
                             self.book["contentSHA256"])
            self.assert_rejected(prefixed, destination="offset")

    def test_mimetype_header_must_be_plain(self):
        # ローカルヘッダだけが圧縮を名乗る
        with self.subTest("local method"):
            local = self.root / "local.epub"
            data = bytearray(self.original.read_bytes())
            struct.pack_into("<H", data, 8, zipfile.ZIP_DEFLATED)
            local.write_bytes(bytes(data))
            self.assertEqual(fetch_epub_corpus.content_digest(local), self.book["contentSHA256"])
            self.assert_rejected(local, destination="local")
        # 拡張フィールドは内容ダイジェストに入らないが、OCF は mimetype に禁じる
        with self.subTest("extra field"):
            extended = build(self.root / "extra.epub",
                             extra={"mimetype": b"\x55\x54\x05\x00\x01\x00\x00\x00\x00"})
            self.assertEqual(fetch_epub_corpus.content_digest(extended),
                             self.book["contentSHA256"])
            self.assert_rejected(extended, destination="extra")
        with self.subTest("content"):
            newline = [("mimetype", b"application/epub+zip\n", zipfile.ZIP_STORED), *ENTRIES[1:]]
            self.assert_rejected(build(self.root / "newline.epub", newline), destination="newline")

    def test_ocf_mimetype_allows_utf8_name_flag(self):
        # IDPF の 45 件は mimetype にも UTF-8 名のフラグ(0x800)が立つ。暗号化のビットだけを見る
        flagged = self.root / "flagged.epub"
        data = bytearray(self.original.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        directory, = struct.unpack_from("<I", data, end + 16)
        for position in (6, directory + 8):
            flags, = struct.unpack_from("<H", data, position)
            struct.pack_into("<H", data, position, flags | 0x800)
        flagged.write_bytes(bytes(data))
        self.assertTrue(fetch_epub_corpus.has_ocf_mimetype(self.original))
        self.assertTrue(fetch_epub_corpus.has_ocf_mimetype(flagged))
        self.assert_accepted_by_contents(flagged)

    def test_without_content_digest_any_change_is_rejected(self):
        repacked = build(self.root / "repacked.epub", date_time=(2026, 9, 25, 3, 0, 0))
        book = {key: value for key, value in self.book.items() if key != "contentSHA256"}
        self.assert_rejected(repacked, book)

    def test_duplicate_names_have_no_content_digest(self):
        duplicated = build(self.root / "duplicated.epub", [*ENTRIES, ENTRIES[2]])
        self.assertIsNone(fetch_epub_corpus.content_digest(duplicated))

    def test_unreadable_zip_has_no_content_digest(self):
        broken = self.root / "broken.epub"
        broken.write_bytes(b"not a zip")
        # 伸長エラー(zlib.error)
        corrupted = corrupt_deflate(build(self.root / "corrupted.epub"))
        # UTF-8 名のフラグ付きで名前が不正な UTF-8(UnicodeDecodeError)
        misnamed = self.root / "misnamed.epub"
        data = bytearray(self.original.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        directory, = struct.unpack_from("<I", data, end + 16)
        flags, = struct.unpack_from("<H", data, directory + 8)
        struct.pack_into("<H", data, directory + 8, flags | 0x800)
        data[directory + 46] = 0xFF
        misnamed.write_bytes(bytes(data))
        for path in (broken, corrupted, misnamed):
            with self.subTest(path.name):
                self.assertIsNone(fetch_epub_corpus.content_digest(path))
        # LZMA の設定値が壊れている(lzma.LZMAError)
        with self.subTest("lzma.epub"):
            if zipfile.lzma is None:
                self.skipTest("lzma がない")
            lzma_entries = [ENTRIES[0], ("OEBPS/text.xhtml", ENTRIES[2][1], zipfile.ZIP_LZMA)]
            compressed = build(self.root / "lzma.epub", lzma_entries)
            with zipfile.ZipFile(compressed) as archive:
                info = archive.getinfo("OEBPS/text.xhtml")
            data = bytearray(compressed.read_bytes())
            name_length, extra_length = struct.unpack_from("<HH", data, info.header_offset + 26)
            data[info.header_offset + 30 + name_length + extra_length + 4] = 0xFF
            compressed.write_bytes(bytes(data))
            self.assertIsNone(fetch_epub_corpus.content_digest(compressed))
        self.assertFalse(fetch_epub_corpus.has_ocf_mimetype(broken))


if __name__ == "__main__":
    unittest.main()
