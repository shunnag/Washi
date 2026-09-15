#!/usr/bin/env python3
"""DocC と全ガイドの Swift 例を検証し、静的公開用のサイトを作る。"""

import argparse
import html
from pathlib import Path
import platform
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def check_examples(derived_data):
    # ガイドの Swift ブロックは、暗黙の reader などを持たない完結した例にする。
    # Package.swift の例も SwiftPM の manifest として評価し、構文だけの検査にしない。
    count = 0
    with tempfile.TemporaryDirectory(prefix="washi-doc-examples-") as directory:
        scratch = Path(directory)
        for article in sorted((ROOT / "Sources").glob("**/*.docc/*.md")):
            blocks = re.findall(r"^```swift\s*\n(.*?)^```\s*$", article.read_text(), re.M | re.S)
            for index, code in enumerate(blocks, 1):
                count += 1
                name = f"{article.stem}-{index}"
                print(f"型検査 / Typecheck: {article.relative_to(ROOT)} #{index}", flush=True)
                if code.startswith("// swift-tools-version:"):
                    package = scratch / name
                    package.mkdir()
                    (package / "Package.swift").write_text(code)
                    subprocess.run(
                        ["swift", "package", "--package-path", str(package), "dump-package"],
                        cwd=ROOT, stdout=subprocess.DEVNULL, check=True,
                    )
                else:
                    source = scratch / f"{name}.swift"
                    source.write_text(code)
                    run("xcrun", "swiftc", "-swift-version", "6", "-typecheck",
                        "-warnings-as-errors", "-target", f"{platform.machine()}-apple-macosx14.0",
                        "-module-cache-path", derived_data / "ExampleModuleCache",
                        "-I", derived_data / "Build/Products/Debug", source)
    if count == 0:
        raise RuntimeError("Swift のコード例が見つかりません / No Swift examples found")
    print(f"検証済みのコード例 / Verified examples: {count}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="空の出力ディレクトリ / Empty output directory")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--base-path", default="/Washi", help="公開 URL の接頭辞 / Hosting URL prefix")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    derived = args.derived_data.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output-dir は空にしてください / output-dir must be empty")
    base = "/" + args.base_path.strip("/") if args.base_path.strip("/") else ""
    if not re.fullmatch(r"(?:/[A-Za-z0-9_.-]+)*", base):
        parser.error("base-path に使えない文字があります / Invalid base-path")
    run("xcodebuild", "docbuild", "-scheme", "Washi", "-destination", "platform=macOS",
        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO",
        "OTHER_DOCC_FLAGS=--warnings-as-errors")
    check_examples(derived)
    output.mkdir(parents=True, exist_ok=True)
    for module, path in [("Washi", "reader"), ("WashiCore", "core")]:
        archive = derived / "Build/Products/Debug" / f"{module}.doccarchive"
        run("xcrun", "docc", "process-archive", "transform-for-static-hosting", archive,
            "--output-path", output / path, "--hosting-base-path", f"{base}/{path}")
        if not (output / path / "documentation" / module.lower() / "index.html").is_file():
            raise RuntimeError(f"公開ページがありません / Missing page: {module}")
    # 両モジュールの資産を別ディレクトリに置き、index.json などの衝突を防ぐ。
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    (output / "index.html").write_text(f'''<!doctype html>
<html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Washi — Documentation</title>
<style>body{{font:18px/1.7 system-ui;max-width:46rem;margin:8vh auto;padding:0 1.5rem;color:#283329;background:#f8f7f2}}a{{color:#286547}}li{{margin:1rem 0}}small{{color:#596759}}</style>
<h1>Washi ドキュメント</h1>
<p>macOS の EPUB アプリを作るためのガイドと API リファレンス。<br>
Guides and API reference for building EPUB apps on macOS.</p>
<ul>
<li><a href="{base}/reader/documentation/washi/installation">導入と最初の表示 / Getting started</a></li>
<li><a href="{base}/reader/documentation/washi">Washi — 表示・SwiftUI・検索ガイド / Rendering and integration</a></li>
<li><a href="{base}/core/documentation/washicore">WashiCore — 解析・メタデータ / Parsing and metadata</a></li>
<li><a href="https://github.com/shunnag/Washi/tree/main/Samples">動くサンプル / Runnable samples</a></li>
</ul>
<p><small>main ブランチ / main branch · {html.escape(revision)}<br>
リリースの変更履歴は <a href="https://github.com/shunnag/Washi/releases">GitHub Releases</a> を参照。<br>
See GitHub Releases for versioned release notes.</small></p></html>''')
    (output / ".nojekyll").touch()
    print(f"公開用ドキュメント / Documentation site: {output}")


if __name__ == "__main__":
    main()
