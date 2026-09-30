"""小さな entities.json の見本で、HTML 実体表の生成・並び順・--check の判定を確かめる。"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


# 検証対象の Scripts/ へ __pycache__ を作らない
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "generate-html-entities.py"
_spec = importlib.util.spec_from_file_location("generate_html_entities", SCRIPT)
generate_html_entities = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(generate_html_entities)

# 公式ファイルと同じ形。セミコロンなしの旧名、XML 定義済みの名前、複数コードポイント、
# 名前順と生のキー順が食い違う emsp / emsp13 を含める。
FIXTURE = {
    "&AMP": {"codepoints": [38], "characters": "&"},
    "&AMP;": {"codepoints": [38], "characters": "&"},
    "&amp;": {"codepoints": [38], "characters": "&"},
    "&lt;": {"codepoints": [60], "characters": "<"},
    "&gt;": {"codepoints": [62], "characters": ">"},
    "&quot;": {"codepoints": [34], "characters": "\""},
    "&apos;": {"codepoints": [39], "characters": "'"},
    "&emsp13;": {"codepoints": [8196], "characters": " "},
    "&emsp;": {"codepoints": [8195], "characters": " "},
    "&NotEqualTilde;": {"codepoints": [8770, 824], "characters": "≂̸"},
    "&zwnj;": {"codepoints": [8204], "characters": "‌"},
}

EXPECTED_BODY = (
    "enum HTMLEntities {\n"
    "    static let table: [String: String] = [\n"
    '        "AMP": "&#38;",\n'
    '        "NotEqualTilde": "&#8770;&#824;",\n'
    '        "emsp": "&#8195;",\n'
    '        "emsp13": "&#8196;",\n'
    '        "zwnj": "&#8204;",\n'
    "    ]\n"
    "}\n"
)


class GenerateHTMLEntitiesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="washi-html-entities-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.input = self.root / "entities.json"
        self.input.write_text(json.dumps(FIXTURE), encoding="utf-8")
        self.output = self.root / "HTMLEntities.swift"

    def run_script(self, *arguments):
        # リポジトリ外のディレクトリから、Sources/ に触れない出力先で実行する。
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--input", str(self.input), "--output", str(self.output), *arguments],
            cwd=self.root, capture_output=True, text=True,
        )

    def test_rows_keep_semicolon_names_only_and_sort_by_name(self):
        rows = generate_html_entities.entity_rows(FIXTURE)
        self.assertEqual([name for name, _ in rows], ["AMP", "NotEqualTilde", "emsp", "emsp13", "zwnj"])
        self.assertEqual(dict(rows)["NotEqualTilde"], [8770, 824])

    def test_render_writes_header_and_table(self):
        text = generate_html_entities.render(FIXTURE, "2026-09-05")
        header, table = text.split(generate_html_entities.BODY_START, 1)
        self.assertIn("// 自動生成: Scripts/generate-html-entities.py で再生成する。手で編集しない。", header)
        self.assertIn(generate_html_entities.SOURCE_URL, header)
        self.assertIn("2026-09-05 取得", header)
        self.assertIn("5 名", header)
        self.assertEqual(generate_html_entities.BODY_START + table, EXPECTED_BODY)
        self.assertEqual(generate_html_entities.body(text), EXPECTED_BODY)

    def test_generate_then_check_from_another_directory(self):
        result = self.run_script("--date", "2026-09-05")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(generate_html_entities.body(self.output.read_text(encoding="utf-8")), EXPECTED_BODY)
        self.assertIn("2026-09-05 取得", self.output.read_text(encoding="utf-8"))
        # 取得日が違ってもヘッダーより下が同じなら一致とみなす。
        result = self.run_script("--check", "--date", "2026-09-30")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("一致", result.stdout)
        self.assertEqual(generate_html_entities.body(self.output.read_text(encoding="utf-8")), EXPECTED_BODY)

    def test_check_reports_stale_table(self):
        self.assertEqual(self.run_script().returncode, 0)
        stale = self.output.read_text(encoding="utf-8").replace('"zwnj": "&#8204;",\n', "")
        self.output.write_text(stale, encoding="utf-8")
        result = self.run_script("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("一致しません", result.stderr)
        # --check は書き換えない。
        self.assertEqual(self.output.read_text(encoding="utf-8"), stale)

    def test_check_rejects_file_without_enum(self):
        self.output.write_text("import Foundation\n", encoding="utf-8")
        result = self.run_script("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enum", result.stderr)

    def test_unreadable_input_fails(self):
        self.input.write_text("{", encoding="utf-8")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("失敗", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
