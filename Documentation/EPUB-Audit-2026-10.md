# EPUB audit — October 2026

Status: the repairs below ship in Washi 1.25.0 (see the
[CHANGELOG](../CHANGELOG.md) for the behaviour changes they carry); what follows
is the audit record. It continues the September 2026 audit
([EPUB-Audit-2026-09.md](EPUB-Audit-2026-09.md)) and re-examines the same
surfaces after the cooViewer audit of 2026-10-26 raised three starting points
about the WebKit configuration. Open items are tracked in this repository's
beads database, not in this file.

## Baseline and reproducibility

- Starting revision: `bf3a097` on `main`; worktree was clean. Repairs are on
  `fix/security-audit-2026-10-27`.
- Environment: arm64 macOS 27.2, Xcode 27.0 (`27A266a`), macOS 14 deployment target.
- Baseline: `swift test`, 746 tests, 5 skipped, 0 failures, 230 s.
- Source size: 89 Swift files, 20,859 lines (`Sources/Washi` 59, `Sources/WashiCore` 30).
- Public corpus: the same 251 downloaded EPUBs as the September audit. Measured
  spine sizes, used below to choose limits: maximum 2,014 itemrefs
  (`mahabharata.epub`, 2,017 manifest items), then 159, 159, 144, 144, 94, 23,
  22, 22, 16, 16, 13; the 95th percentile is 13.

## Method, and what the method missed

Seven areas were read in parallel (WebKit configuration and isolation; scheme
handler response path; container reading; XML/OPF/NCX/CSS parsing; staging and
temporary files; resource limits and concurrency; public API contract, host
responsibilities and CI). Each area's confirmed findings were then attacked by
two adversarial reviewers with distinct lenses (reachability, arithmetic), and a
completeness critic looked for what nobody had read. 56 readers in total, 85
findings.

Three limits of that pass are worth recording, because they changed the result:

- **No reader built or ran anything.** Every finding arrived as `code-read` or
  `needs-measurement`. The measurements below were made afterwards and changed
  the severity of four findings, in both directions.
- **The highest-severity finding never reached the adversarial pass.** The
  parsing reader labelled its own entity-bomb finding `verdict: wrong` while its
  summary and evidence described a working bypass, so the selection step
  (which only forwards `correct`/`partial` findings) skipped it.
- **Only the four most severe findings per area were attacked.** Findings
  recorded as `needs-measurement` were never refuted either.

Of the 89 files, 42 (6,901 lines) were not read by any area reader; the critic
read 21 of them and 25 files (about 6,570 lines, 31%) remained unread.

## Confirmed defects and repairs

### Internal DTD entity-bomb guard bypassed by a quote-blind strip

`WashiXML.validateProlog` extracts the DOCTYPE with `internalDoctypeSlice`, a
single forward scan that correctly tracks quoted strings, comments, processing
instructions and the `[ ]` internal subset. It then counts the `<!ENTITY`
declarations in a **second** scan — `strippingCommentsAndPIs`, two quote-blind
regular expressions. Placing `<!--` or `<?` inside an entity value, or inside
the SYSTEM external identifier literal, forges a comment or PI across
declaration boundaries; everything between it and the first following `-->` or
`?>` is deleted before the count, so the bomb declarations disappear.

Three variants were confirmed by measurement, all accepted by the guard and all
expanded by libxml2:

- a comment-wrapped subset (`<!ENTITY open "<!-- ">` … `<!ENTITY close "-->">`),
- the same shape with `<?` … `?>`,
- `<!DOCTYPE r SYSTEM "<!--" [ … <!ENTITY z "-->"> ]>`, where the forged opener
  sits outside the internal subset.

A 420-byte document expanded to 64,000,000 characters in 0.214 s. Two more
declaration lines reach 6.4 GB.

The same function's UTF-16 normalisation was a second way in.
`normalizedXMLBytes` recognised UTF-16 and then returned the raw bytes when
decoding failed (`?? data`), so the ASCII DOCTYPE scanner found nothing and the
guard returned without checking. An odd trailing byte is not enough — Foundation
decodes it — but a lone surrogate is: a 744-byte UTF-16LE document was accepted
and expanded to 6,400,000 characters. The UTF-8 path already threw in the same
situation.

### Continuous-scroll setup re-expands the whole spine on the main actor

`EPUBScrollDocument.options` takes `publication.scrollGroup(containing:)` as its
range. `rendition:layout=roll` is a single package-wide `meta` that item-level
properties cannot override, so every item becomes `.scrolledContinuous` and the
group is the entire spine, with no count limit. For each roll item the range
calls `publication.fixedLayoutInfo(forSpineIndex:)`, which held no cache and
re-inflated the entry and re-parsed the XHTML on every call. The call site is
`setupOptionsJSON()` inside `runSetup`, which is synchronous on the main actor
and runs again on every repagination (resize, settings change).

Measured with an 11,832-byte crafted EPUB (200,000 itemrefs, a 1,048,830-byte
chapter, a 4,000,430-byte OPF — all within the existing ZIP limits):

| step | result |
|---|---|
| `EPUBPublication(url:)` | 3.25 s |
| `scrollGroup(containing: 0)` | `0..<200000`, 0.12 s |
| `fixedLayoutInfo`, same index ×3 | 0.030 / 0.027 / 0.029 s (no cache) |
| 200 items | 6.37 s → 0.0319 s per item |
| extrapolated to 200,000 items | **6,373 s (1 h 46 min), synchronous** |

The non-roll continuous path has the same unbounded count in JavaScript:
`ReaderScripts+ContinuousScroll.swift` loads every item of the group as an
iframe, four at a time, when `rollOnly` is false; only the roll path has the
viewport-local lazy loading.

### The on-screen configuration did not suppress autoplay

`mediaTypesRequiringUserActionForPlayback` appeared exactly once in `Sources`,
in the offscreen configuration. The on-screen reader did not set it, and the CSP
allows `media-src 'self' data:`, so `<audio autoplay>` and `<video autoplay>`
play as soon as a book opens — no scripting needed, default settings, a
malicious EPUB on its own. Of the three starting points carried over from the
cooViewer audit, this was the only one with a demonstrable effect.

The cause was structural: the on-screen and offscreen `WKWebViewConfiguration`
were built twice, so each had hardening the other lacked.

### Smaller defects in the response path

- `data.subdata(in:)` was given a zero-based range while `Data` slices keep the
  parent's index space. Every current supplier rebases to zero, so this was
  correct by invariant rather than by construction; a slice reaching `reply`
  would trap the host process on any Range request.
- The origin check compared scheme and host only, so `washi-epub://<uuid>:8080/`
  and `washi-epub://evil@<uuid>/` were accepted as the same book while WebKit
  treats them as separate origins.
- The manifest's `media-type` reached `Content-Type` unchecked. A character
  reference for CR/LF survives XML parsing, and Foundation then drops the whole
  header, moving type determination to WebKit's sniffing — the one thing the
  file's own documentation forbids.
- Type decisions ran on the raw string, case-sensitively and by prefix, so
  `TEXT/CSS` got neither the charset nor the `-epub-` polyfill while
  `text/csszzz` got the polyfill. `EPUBMediaType.normalized` already existed and
  was unused.
- No test asserted that the CSP header is present, so it could be dropped
  silently. (The audit said the policy had seven directives; it has eight.)

## Findings refuted by measurement

- **A FIFO in an unpacked directory does not hang the open.** The claim was that
  `FolderContainerReader.read` lacks a regular-file check, so `open(2)` on a
  named pipe blocks forever. POSIX `open` does block, but Foundation's
  `Data(contentsOf:)` refuses the pipe: with `mkfifo META-INF/container.xml`,
  `EPUBPublication(url:)` threw `NSCocoaErrorDomain` 257 within 4 s under both
  `.mappedIfSafe` and `.alwaysCopy`. What remains is that this error is not
  mapped to `EPUBError` and escapes the public API as a raw `NSError`.
- **`coverImage` is not an image-decoding bomb.** The claim was that
  `kCGImageSourceCreateThumbnailFromImageAlways` forces a full decode before
  downsampling. A valid 20000×20000 RGBA PNG (1,555,211 bytes, 1,526 MiB
  nominal) produced a 256×256 thumbnail in 1.01 s with RSS growing 24 MiB; a
  46000×46000 PNG (8,226,700 bytes, 8,072 MiB nominal) took 6.16 s and 35 MiB.
  ImageIO streams the downsample. `coverImage()` without a limit returns a lazy
  `CGImage` in 0.018 s and allocates nothing until drawn. Both consumers pass a
  pixel limit. What remains is CPU time proportional to the declared pixel count.
- **The missing content rule list is a documentation defect, not an exposure.**
  Both adversarial lenses rejected the two rule-list findings. The CSP is
  attached to every successful response by a single `reply` path, and navigation
  away from `washi-epub` is refused on-screen and offscreen; the `https?`/`wss?`
  patterns the rule list blocks are already inside that set. The candidates the
  CSP does not cover (`dns-prefetch`, `preconnect`) are not resource loads, so
  the rule list would not block them either. What remains is that README and
  `FileAccess.md` state the blocking as unconditional.

## Repairs in this change

Fixes for the defects above are on `fix/security-audit-2026-10-27`
(`Washi-yru`, `Washi-1nm`, `Washi-1mg`, `Washi-hgd`, `Washi-hyt`, `Washi-2s5`);
the [CHANGELOG](../CHANGELOG.md) lists the behaviour changes they carry.

- The internal-subset extraction now happens in the same single scan that
  finds the DOCTYPE, so there is no second, quote-blind pass to fool. Removed
  comments and PIs leave a space behind so that the two sides cannot be glued
  into a declaration token that the document never contained. A UTF-16
  signature whose bytes do not decode is now rejected rather than passed
  through, symmetrically with UTF-8.
- `fixedLayoutInfo(forSpineIndex:)` caches its result per spine index, bounded
  by the spine count, holding only the small value type and never the chapter
  data. Dimension lookups inside `EPUBScrollDocument.options` are limited to
  2,048 items and 28 MiB of inflation, with the ZIP central directory consulted
  before inflating; items beyond the budget use the default size. A
  continuous-flow group larger than 4,096 items degrades to chapter scrolling.
- The scheme handler keeps the handle of the detached extraction and cancels it
  on `stop`; the deflate loop checks for cancellation every output block (at
  most 64 KiB). Concurrent extractions are limited to four with a FIFO queue.
  The `-epub-` CSS polyfill moved into that background work and takes a 32 MiB
  input limit.
- The on-screen and offscreen `WKWebViewConfiguration` are built by one
  function, which sets `mediaTypesRequiringUserActionForPlayback = .all`.
- Declared media types are validated and normalised before they become a
  `Content-Type`; `Data` slices are indexed from `startIndex`; ports and
  userinfo are refused in the origin check; the CSP header is asserted on both
  200 and 206 responses.
- The five GitHub Actions are pinned by commit SHA with a `# vN` comment,
  `.github/dependabot.yml` matches the other four repositories, and the
  workflow declares `permissions: contents: read` by default.

## Verification

- `swift test`: 746 → 773 tests, 5 skipped, 0 failures, 224.6 s. The suite was
  run after each repair rather than once at the end — 758 after the XML guard
  and the WebKit/scheme-handler work, 763 after the extraction limits, 773 after
  the scroll budget — so a regression could be attributed to a single change.
- The crafted inputs that the measurements above were taken with were re-run
  against the repaired code: all three forged-comment variants and the
  lone-surrogate UTF-16 document are rejected, and the 420-byte document that
  expanded to 64,000,000 characters in 0.214 s is now refused in 0.0006 s. Five
  legitimate documents that had to keep working — a real comment inside the
  internal subset, a shim whose value uses `&lt;`, the `&nbsp;` compatibility
  shim with a leading comment, an external DTD reference, and Japanese body
  text — are still accepted.
- The autoplay policy was measured rather than assumed. The same book — one
  spine item with `<audio autoplay src="../audio/a.wav">` and a one-second
  silent WAV in the container — was loaded into two `WKWebView`s differing only
  in `mediaTypesRequiringUserActionForPlayback`, and the element was read 1.5 s
  after `didFinish`:

  | policy | `paused` | `currentTime` | `duration` |
  |---|---|---|---|
  | `[]` (the previous on-screen value) | true | **1** | 1 |
  | `.all` (this change) | true | **0** | 1 |

  Without the flag the audio had played to the end of the file by itself; with
  it, playback never started. This is WebKit's behaviour on macOS 27.2, so the
  defect and the repair are both confirmed.

## Open items

Tracked in this repository's beads database. The ones left open after this
change, with the severity the measurements support:

- `Washi-w9k` — the pagination census has no limit on how many spine items it
  measures, and its keyed stores bound entry counts but not retained bytes.
- `Washi-nrp` — `resourcePaths` returns raw ZIP entry names that `resource(at:)`
  cannot read back, entry names reach error strings untruncated, and folder-read
  errors other than "no such file" escape as raw `NSError` (confirmed by the
  FIFO measurement above).
- `Washi-6cn` — the documentation states the network blocking unconditionally,
  says nothing about what the library requires of its host, and does not
  mention that the default context menu can hand selected text to external
  services or write book bytes to disk. The content rule list also fails open
  without a log.
- `Washi-9eu` — search allocates roughly 40–48 bytes per character of extracted
  text before its first cancellation check; the amplification factor is not yet
  measured.
- `Washi-v8p` — SMIL clock values are checked for sign and finiteness but not
  for `clipEnd` greater than `clipBegin`, so a book can make the 25 ms ticker
  spin.
- `Washi-94p` — with `allowsScriptedContent` enabled (off by default), a
  synthesized DOM event can drive the injected listeners; nothing checks
  `isTrusted`.
- `Washi-6yx` — `coverImage` costs CPU time proportional to the declared pixel
  count, and `AVAudioPlayer(data:)` receives up to one entry's worth of bytes.
  Downgraded from the critic's severity by the measurement above.

The 25 files nobody read are the other open item. The most valuable of them,
by the critic's reading, are `EPUBReaderView+Layout.swift`,
`EPUBScreenMetrics.swift`, `EPUBReaderView+Census.swift`,
`EPUBScreenThumbnailRenderer.swift` and `EPUBModels.swift`: the paths where a
number the book declares becomes a layout or pixel budget.
