"""事前検証と GitHub 公開で共用する、確定版番号と変更履歴の検証。"""

from datetime import date
import re


def stable_version(tag):
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    return tuple(map(int, match.groups())) if match else None


def release_entry(changelog, tag):
    if stable_version(tag) is None:
        raise ValueError("タグは X.Y.Z または vX.Y.Z の確定版で指定してください")
    version = re.escape(tag.removeprefix("v"))
    headings = list(re.finditer(rf"^## \[{version}\].*$", changelog, re.MULTILINE))
    if len(headings) != 1:
        raise ValueError("CHANGELOG の対象バージョンの確定見出しはちょうど1件必要です")
    heading = headings[0]
    match = re.fullmatch(rf"## \[{version}\] - ([0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}})[ \t]*", heading[0])
    if not match:
        raise ValueError("CHANGELOG に YYYY-MM-DD を含む確定見出しが必要です")
    try:
        released = date.fromisoformat(match[1])
    except ValueError as error:
        raise ValueError("CHANGELOG のリリース日が実在する日付ではありません") from error
    notes = re.split(r"^## ", changelog[heading.end():], maxsplit=1, flags=re.MULTILINE)[0].strip()
    if not notes:
        raise ValueError("CHANGELOG の対象バージョンのリリースノートが空です")
    return released, notes + "\n"
