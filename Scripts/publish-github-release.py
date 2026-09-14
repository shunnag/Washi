#!/usr/bin/env python3
"""タグの CI が成功した後、検証済みコミットの変更履歴を GitHub Release に公開する。"""

import argparse
from datetime import date
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def stable_version(tag):
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    return tuple(map(int, match.groups())) if match else None


def release_notes(changelog, tag):
    if stable_version(tag) is None:
        raise ValueError("タグは X.Y.Z または vX.Y.Z の確定版で指定してください")
    version = re.escape(tag.removeprefix("v"))
    headings = list(re.finditer(rf"^## \[{version}\].*$", changelog, re.MULTILINE))
    if len(headings) != 1:
        raise ValueError("CHANGELOG の対象バージョンの見出しはちょうど1件必要です")
    heading = headings[0]
    match = re.fullmatch(rf"## \[{version}\] - (\d{{4}}-\d{{2}}-\d{{2}})[ \t]*", heading[0])
    if not match:
        raise ValueError("CHANGELOG に YYYY-MM-DD を含む確定見出しが必要です")
    date.fromisoformat(match[1])
    notes = re.split(r"^## ", changelog[heading.end():], maxsplit=1, flags=re.MULTILINE)[0].strip()
    if not notes:
        raise ValueError("CHANGELOG の対象バージョンのリリースノートが空です")
    return notes + "\n"


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def github_items(repository, resource):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repository}/{resource}"))
    return [item for page in pages for item in page]


def publish(tag, repository):
    version = stable_version(tag)
    if version is None:
        raise ValueError("タグは X.Y.Z または vX.Y.Z の確定版で指定してください")
    tags = github_items(repository, "tags")
    if not any(item["name"] == tag for item in tags):
        raise ValueError("公開先に対象タグが存在しません")
    # 別コミットへのタグ移動後に、古い CI 結果で公開することを防ぐ。
    remote_sha = run("gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha")
    if remote_sha != run("git", "rev-parse", "HEAD"):
        raise ValueError("公開先のタグと検証対象コミットが一致しません")
    releases = github_items(repository, "releases")
    for release in releases:
        if release["tag_name"] == tag:
            if release["draft"]:
                raise ValueError("同じタグの下書きがあります。内容を確認して手動で公開してください")
            print(f"公開済みのため変更しません: {release['html_url']}")
            return
    # 作業ツリーではなく、CI が検証したコミットからノートを取得する。
    notes = release_notes(run("git", "show", "HEAD:CHANGELOG.md"), tag)
    versions = [stable_version(item["name"]) for item in tags]
    latest = version == max(value for value in versions if value is not None)
    with tempfile.TemporaryDirectory(prefix="washi-github-release-") as temporary:
        notes_file = Path(temporary) / "notes.md"
        notes_file.write_text(notes, encoding="utf-8")
        print(run(
            "gh", "release", "create", tag, "--repo", repository, "--verify-tag",
            "--title", f"Washi {tag}", "--notes-file", str(notes_file),
            "--latest" if latest else "--latest=false",
        ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--repo", required=True, help="公開先の OWNER/REPO")
    arguments = parser.parse_args()
    try:
        publish(arguments.tag, arguments.repo)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"GitHub Release の公開に失敗しました: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
