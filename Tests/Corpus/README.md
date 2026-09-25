# Public EPUB corpus

`manifest.json` records 251 public EPUB files: 45 IDPF samples and 206 W3C
reading-system tests. Each entry records its download URL, size, SHA-256, and a
ZIP content digest (`contentSHA256`).
The EPUB contents are not redistributed with Washi. Their original notices and
licenses remain inside the downloaded publications.

```sh
python3 Scripts/fetch-epub-corpus.py
WASHI_CORPUS_DIR="$PWD/.build/epub-corpus" swift test --filter CorpusSmokeTests
```

The downloader verifies existing files as well as new downloads. The W3C site
rebuilds its EPUB files on every deployment, which changes ZIP metadata such as
timestamps (and therefore the SHA-256) without changing the publications. The
content digest covers each entry's order, name, compression method, and bytes,
but not timestamps or other metadata. A file whose SHA-256 differs but whose
content digest matches is accepted and reported in a note; update its `sha256`
when convenient. Any other change fails the check; review the upstream change
before updating the manifest. No account, third-party Python package, or
application dependency is needed. The default destination is ignored by git.

## Provenance and licensing

- [IDPF samples, release 20230704](https://github.com/IDPF/epub3-samples/releases/tag/20230704).
  The project [licensing statement](https://github.com/IDPF/epub3-samples#licensing)
  specifies CC-BY-SA 3.0 except where the
  [sample table](https://idpf.github.io/epub3-samples/30/samples.html) states otherwise.
  Publication-specific notices, including font, image, and audio licenses, are
  retained in the original EPUBs. These are test inputs, not library assets.
- [W3C EPUB tests](https://github.com/w3c/epub-tests/tree/2d3b96756423189c0008eff95f0e98beda7cc5fe),
  under the [W3C Software and Document License](https://github.com/w3c/epub-tests/blob/2d3b96756423189c0008eff95f0e98beda7cc5fe/LICENSE.md).
  Sources were inspected at the recorded revision; EPUB binaries were downloaded
  from the project's official site and are independently pinned by their hashes.
  Duplicate OPDS entries were removed, `ocf-font_obfuscation-bis` was corrected
  to the upstream filename `ocf-font_obfuscation_bis`, and additional published
  test files found in the source tree were included. Authoring templates were
  excluded.

## What the smoke test proves

The test opens publications, reads metadata and navigation, extracts/searches
text, decodes covers, inspects a fixed-layout page, and reads every container
resource. Japanese fixtures receive additional direction/layout/overlay checks.
Passing this test does **not** assert that all W3C visual or interactive
conformance criteria pass. In particular, upstream `ocf-zip-mult.epub` currently
has a single-volume ZIP structure; its successful opening does not exercise
multi-volume rejection. Synthetic ZIP tests cover malformed structures separately.
