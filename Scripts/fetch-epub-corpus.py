#!/usr/bin/env python3
"""Fetch the public EPUB corpus recorded in Tests/Corpus/manifest.json.

Uses only Python's standard library. Books keep their original copyright and
license notices; no book contents are added to the Washi repository.
"""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile


def content_digest(path):
    """ZIP の付帯情報(時刻・属性・余白)に左右されない内容ダイジェスト。

    エントリの順序・名前・圧縮方式・中身を含めるので、中身の変化や、OCF に関わる
    構造(先頭に無圧縮の mimetype を置くこと)の変化は検出する。読めない ZIP は None。
    """
    digest = hashlib.sha256()
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                digest.update(f"{info.filename}\0{info.compress_type}\0".encode("utf-8"))
                digest.update(hashlib.sha256(archive.read(info)).digest())
    except (zipfile.BadZipFile, NotImplementedError, RuntimeError, EOFError, OSError):
        return None
    return digest.hexdigest()


def verify(book, path, actual):
    """記録と一致すれば照合方法("sha256" か "contents")、しなければ None。

    配布元が同じ中身の ZIP を作り直すと、時刻などの付帯情報だけが変わって SHA-256 が
    食い違う。記録した内容ダイジェストと一致すれば、同じ本として受け入れる。
    """
    expected = book.get("sha256")
    if not expected or actual == expected:
        return "sha256"
    expected_contents = book.get("contentSHA256")
    if expected_contents and content_digest(path) == expected_contents:
        return "contents"
    return None


def verified(book, path, actual, matched):
    result = {**book, "sha256": actual, "bytes": path.stat().st_size}
    if matched == "contents":
        result["matchedBy"] = "contents"
    return result


def fetch(book, root):
    relative = Path(book["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Invalid corpus path: {relative}")
    target = root / relative
    expected = book.get("sha256")
    if target.is_file() and expected:
        actual = hashlib.sha256(target.read_bytes()).hexdigest()
        if matched := verify(book, target, actual):
            return verified(book, target, actual, matched)
    target.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(book["url"], headers={"User-Agent": "Washi-corpus-audit"})
    temporary = target.with_suffix(".download")
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(request, timeout=45) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        actual = digest.hexdigest()
        matched = verify(book, temporary, actual)
        if matched is None:
            detail = " and ZIP contents" if book.get("contentSHA256") else ""
            raise ValueError(f"SHA-256{detail} mismatch for {relative}: "
                             f"expected {expected}, got {actual}")
        temporary.replace(target)
        return verified(book, target, actual, matched)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path, default=Path(".build/epub-corpus"))
    parser.add_argument("--manifest", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Tests/Corpus/manifest.json")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    books = manifest["books"]
    paths = [book["path"] for book in books]
    if len(paths) != len(set(paths)):
        raise ValueError("Duplicate corpus paths")
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fetch, book, args.destination): book for book in books}
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            print(f"[{len(results)}/{len(books)}] {result['path']}", flush=True)
    manifest["books"] = sorted(results, key=lambda book: book["path"])
    (args.destination / "provenance.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    repacked = sum(1 for book in results if book.get("matchedBy") == "contents")
    if repacked:
        print(f"Note: {repacked} EPUBs matched by ZIP contents only; upstream ZIP metadata "
              f"changed. Update their sha256 values in the manifest when convenient.")
    print(f"Verified {len(results)} EPUBs in {args.destination}")


if __name__ == "__main__":
    main()
