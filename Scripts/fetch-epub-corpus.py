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


def fetch(book, root):
    relative = Path(book["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Invalid corpus path: {relative}")
    target = root / relative
    expected = book.get("sha256")
    if target.is_file() and expected:
        if hashlib.sha256(target.read_bytes()).hexdigest() == expected:
            return {**book, "sha256": expected, "bytes": target.stat().st_size}
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
        if expected and actual != expected:
            raise ValueError(f"SHA-256 mismatch for {relative}: expected {expected}, got {actual}")
        temporary.replace(target)
        return {**book, "sha256": actual, "bytes": target.stat().st_size}
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
    print(f"Verified {len(results)} EPUBs in {args.destination}")


if __name__ == "__main__":
    main()
