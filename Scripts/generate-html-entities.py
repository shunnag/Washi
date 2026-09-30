#!/usr/bin/env python3
"""WHATWG の entities.json から Sources/WashiCore/Util/HTMLEntities.swift を生成する。

Generate HTMLEntities.swift from the WHATWG entities.json.

セミコロン付きの名前だけを採り、XML が定義済みの amp / lt / gt / quot / apos を
除く。表は名前順に並べ、値は数値文字参照(&#n;)で書く。既定では公式 URL から
取得し、--input でローカルの JSON を使える。--check は生成結果と既存ファイルの
表(ヘッダーコメントより下)を比べ、違いがあれば非ゼロで終わる。
"""

import argparse
import datetime
import json
from pathlib import Path
import sys
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = "https://html.spec.whatwg.org/entities.json"
OUTPUT = ROOT / "Sources/WashiCore/Util/HTMLEntities.swift"
# XML 1.0 が定義済みの 5 名。XMLDocument が解決するので表には入れない。
XML_PREDEFINED = {"amp", "lt", "gt", "quot", "apos"}
# ヘッダーコメントの終わり。--check はこの行から下だけを比べる。
BODY_START = "enum HTMLEntities {\n"


def entity_rows(entities):
    """entities.json の辞書から (名前, [コードポイント]) を名前順に返す。"""
    rows = []
    for key, value in entities.items():
        if not key.startswith("&") or not key.endswith(";"):
            continue
        name = key[1:-1]
        if name in XML_PREDEFINED:
            continue
        rows.append((name, list(value["codepoints"])))
    # 生の "&emsp13;" ではなく名前で並べる("emsp" が "emsp13" より前に来る)。
    return sorted(rows)


def render(entities, fetched):
    """Swift ソース全体(ヘッダーコメント + 表)を文字列で返す。"""
    rows = entity_rows(entities)
    lines = [
        "import Foundation",
        "",
        "// 自動生成: Scripts/generate-html-entities.py で再生成する。手で編集しない。",
        f"// 出典: {SOURCE_URL}({fetched} 取得)",
        "// セミコロン付きの名前から XML 定義済みの amp / lt / gt / quot / apos を除いた",
        f"// {len(rows):,} 名。値は数値文字参照。経緯は cooViewer-oxr.10/13 を参照。",
        BODY_START.rstrip("\n"),
        "    static let table: [String: String] = [",
    ]
    for name, codepoints in rows:
        value = "".join(f"&#{codepoint};" for codepoint in codepoints)
        lines.append(f'        "{name}": "{value}",')
    lines += ["    ]", "}"]
    return "\n".join(lines) + "\n"


def body(text):
    """ヘッダーコメントを除いた表の部分(BODY_START から末尾まで)。"""
    index = text.find(BODY_START)
    if index < 0:
        raise ValueError("HTMLEntities.swift の enum 宣言が見つかりません")
    return text[index:]


def load_entities(path, timeout):
    if path is not None:
        return json.loads(Path(path).read_bytes())
    with urllib.request.urlopen(SOURCE_URL, timeout=timeout) as response:
        return json.loads(response.read())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, help="ローカルの entities.json(既定は公式 URL から取得)")
    parser.add_argument("--output", type=Path, default=OUTPUT, help=f"生成先(既定: {OUTPUT.relative_to(ROOT)})")
    parser.add_argument("--check", action="store_true", help="書き込まず、既存ファイルの表と一致するか確かめる")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="ヘッダーに記す取得日(既定: 今日)")
    parser.add_argument("--timeout", type=float, default=60, help="取得のタイムアウト秒(既定: 60)")
    arguments = parser.parse_args(argv)
    try:
        entities = load_entities(arguments.input, arguments.timeout)
        generated = render(entities, arguments.date)
        output = arguments.output.resolve()
        if arguments.check:
            current = output.read_text(encoding="utf-8")
            if body(current) != body(generated):
                print(f"error: {output} の表が生成結果と一致しません。再生成してください。", file=sys.stderr)
                return 1
            print(f"一致: {output}({len(entity_rows(entities)):,} 名)")
            return 0
        output.write_text(generated, encoding="utf-8", newline="\n")
        print(f"生成: {output}({len(entity_rows(entities)):,} 名)")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: HTML 実体表の生成に失敗しました: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
