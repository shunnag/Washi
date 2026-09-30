#!/usr/bin/env python3
"""公開前の検証を行う。タグの作成や push は、このスクリプトでは行わない。

Scripts/release.sh はこのファイルを呼ぶだけの薄い入口で、引数と終了コードは同じ。
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

# 検証した作業ツリーへ __pycache__ を作らない(クリーンな作業ツリーの確認より前に必要)。
sys.dont_write_bytecode = True
from release_support import release_entry, stable_version


REPOSITORY = Path(__file__).resolve().parents[1]


class ValidationError(Exception):
    pass


def git(*args):
    # 認証入力待ちや応答しない接続で検証が止まらないようにする。
    try:
        result = subprocess.run(
            ["git", *args], cwd=REPOSITORY, text=True, capture_output=True,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValidationError("Git の応答が30秒以内に返りませんでした。") from error
    if result.returncode:
        raise ValidationError(f"Git の確認に失敗しました: {result.stderr.strip()}")
    return result.stdout


def validate(arguments):
    requested = stable_version(arguments.version)
    if requested is None or arguments.version.startswith("v"):
        raise ValidationError("版番号は先頭ゼロのない X.Y.Z 形式で指定してください。")
    if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != REPOSITORY:
        raise ValidationError("Washi リポジトリの Scripts/release.sh を実行してください。")
    if git("status", "--porcelain=v1", "--untracked-files=all").strip():
        raise ValidationError("作業ツリーがクリーンではありません（未追跡ファイルも含む）。")

    # 公開処理と同じコミット・同じ条件で、空の本文や未確定の重複も拒否する。
    released, _ = release_entry(git("show", "HEAD:CHANGELOG.md"), arguments.version)
    reading_system = git("show", "HEAD:Sources/Washi/Reader/EPUBReadingSystem.swift")
    declared_versions = re.findall(
        r'^\s*public\s+static\s+let\s+version\s*=\s*"([^"\n]+)"\s*$',
        reading_system, re.MULTILINE,
    )
    if declared_versions != [arguments.version]:
        raise ValidationError("EPUBReadingSystem.version を公開する版番号に合わせてください。")
    # 導入ガイドの from: の例は唯一の版番号の固定箇所なので、公開する版と揃える。
    installation = git("show", "HEAD:Sources/Washi/Washi.docc/Installation.md")
    pinned_versions = re.findall(r'\bfrom:\s*"([^"\n]+)"', installation)
    if pinned_versions != [arguments.version]:
        raise ValidationError("Installation.md の from: の版番号を公開する版番号に合わせてください。")

    # ローカルのタグ一覧は古い場合があるため、公開先を直接問い合わせる。
    tags = []
    for line in git("ls-remote", "--tags", "--refs", "--", arguments.remote).splitlines():
        fields = line.split()
        if len(fields) != 2:
            raise ValidationError("公開先から不正なタグ一覧が返りました。")
        if not fields[1].startswith("refs/tags/"):
            raise ValidationError("公開先から不正なタグ参照が返りました。")
        tag = fields[1].removeprefix("refs/tags/")
        version = stable_version(tag)
        if version is not None:
            tags.append((version, tag))
    latest = max(tags) if tags else None
    if latest is not None and requested <= latest[0]:
        raise ValidationError(f"版番号 {arguments.version} は公開済み最新タグ {latest[1]} より新しくありません。")

    print(f"リリース前検証に成功: {arguments.version} ({released.isoformat()})")
    print(f"公開済み最新タグ: {latest[1] if latest else 'なし'}")
    print("作業ツリー: クリーン")


def main():
    parser = argparse.ArgumentParser(
        prog="Scripts/release.sh",
        description="Washi のリリース前検証。タグの作成・push は行いません。",
    )
    parser.add_argument("version", help="公開する確定版の番号（例: 1.18.2）")
    parser.add_argument("--remote", default="origin", help="公開先の Git remote（既定: origin）")
    arguments = parser.parse_args()
    try:
        validate(arguments)
    except (ValidationError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
