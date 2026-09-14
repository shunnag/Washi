#!/bin/sh
# 公開前の検証を行う。タグの作成や push は、このスクリプトでは行わない。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$script_dir/.." "$@" <<'PY'
import argparse
from datetime import date
import os
from pathlib import Path
import re
import subprocess
import sys


class ValidationError(Exception):
    pass


repository = Path(sys.argv.pop(1)).resolve()
parser = argparse.ArgumentParser(
    prog="Scripts/release.sh",
    description="Washi のリリース前検証。タグの作成・push は行いません。",
)
parser.add_argument("version", help="公開する確定版の番号（例: 1.18.2）")
parser.add_argument("--remote", default="origin", help="公開先の Git remote（既定: origin）")
arguments = parser.parse_args()
version_pattern = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def git(*args):
    # 認証入力待ちや応答しない接続で検証が止まらないようにする。
    try:
        result = subprocess.run(
            ["git", *args], cwd=repository, text=True, capture_output=True,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValidationError("Git の応答が30秒以内に返りませんでした。") from error
    if result.returncode:
        raise ValidationError(f"Git の確認に失敗しました: {result.stderr.strip()}")
    return result.stdout


try:
    version = re.fullmatch(version_pattern, arguments.version)
    if version is None:
        raise ValidationError("版番号は先頭ゼロのない X.Y.Z 形式で指定してください。")
    requested = tuple(map(int, version.groups()))
    if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != repository:
        raise ValidationError("Washi リポジトリの Scripts/release.sh を実行してください。")
    if git("status", "--porcelain=v1", "--untracked-files=all").strip():
        raise ValidationError("作業ツリーがクリーンではありません（未追跡ファイルも含む）。")

    changelog = (repository / "CHANGELOG.md").read_text(encoding="utf-8")
    headings = re.findall(
        rf"^## \[{re.escape(arguments.version)}\] - ([0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}})$",
        changelog, re.MULTILINE,
    )
    if len(headings) != 1:
        raise ValidationError(
            f"CHANGELOG.md に確定見出し「## [{arguments.version}] - YYYY-MM-DD」が"
            "ちょうど1件必要です。"
        )
    try:
        date.fromisoformat(headings[0])
    except ValueError as error:
        raise ValidationError("CHANGELOG.md のリリース日が実在する日付ではありません。") from error

    # ローカルのタグ一覧は古い場合があるため、公開先を直接問い合わせる。
    tags = []
    for line in git("ls-remote", "--tags", "--refs", "--", arguments.remote).splitlines():
        fields = line.split()
        if len(fields) != 2:
            raise ValidationError("公開先から不正なタグ一覧が返りました。")
        match = re.fullmatch(rf"refs/tags/v?{version_pattern}", fields[1])
        if match:
            tags.append((tuple(map(int, match.groups())), fields[1].removeprefix("refs/tags/")))
    latest = max(tags) if tags else None
    if latest is not None and requested <= latest[0]:
        raise ValidationError(f"版番号 {arguments.version} は公開済み最新タグ {latest[1]} より新しくありません。")

    print(f"リリース前検証に成功: {arguments.version} ({headings[0]})")
    print(f"公開済み最新タグ: {latest[1] if latest else 'なし'}")
    print("作業ツリー: クリーン")
except (ValidationError, OSError) as error:
    print(f"error: {error}", file=sys.stderr)
    sys.exit(1)
PY
