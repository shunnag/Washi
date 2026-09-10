# EPUB audit — September 2026

Status: in progress; sanitizer, consumer compatibility, and memory measurement
gates have been run. Release remains pending.
The release gate includes the rendering/lifetime audit,
consumer compatibility, sanitizer/stress results, and a published Washi release.

## Baseline and reproducibility

- Starting revision: `bd9f8a2` on `main`; worktree was initially clean.
- Environment: arm64 macOS, Xcode 27.0 (`27A266a`), Swift 6.4, macOS 14 deployment target.
- Baseline: `swift test`, 416 tests, 0 failures, 2 corpus tests skipped.
- Public corpus: 251 downloaded EPUBs. Original URLs, SHA-256, sizes, and license
  sources are in [the corpus manifest](../Tests/Corpus/manifest.json) and
  [instructions](../Tests/Corpus/README.md).
- After the ZIP/cache/CSS and media-overlay changes: 450 tests with corpus enabled,
  0 failures, 0 skips;
  all 251 books completed the core smoke pass, including all seven Japanese samples.
  This is a parser/resource smoke result, not a claim of complete EPUB conformance.

## Confirmed defects and repairs

### Deflate output accepted as a valid prefix

`compression_decode_buffer` could fill the declared output buffer while the
stream still contained more output. A ZIP whose size and CRC described only
that prefix was accepted. A zero-length declaration bypassed decompression
entirely, also accepting invalid or nonempty deflate input.

The decoder now requires an end-of-stream status and an exact decoded size.
It allocates output as data arrives, using a 64 KiB scratch buffer, and destroys
the decoder on every success/error path. The absolute entry limit and CRC check
remain in place. Padding after a completed stream remains tolerated, consistent
with zlib readers; Compression can read ahead, so its input cursor is not an
exact end-offset validator.

`ZipIntegrityTests` reproduced acceptance of forged prefixes and empty entries
before the repair, and covers valid empty blocks, missing end markers, short
output, large output across chunks, and trailing padding. The ZIP/Hardening
selection passed 51 tests after the repair. The test ZIP writer was corrected
to emit a real deflate end marker even for empty entries.

### Text cache did not bound stored bytes

The eight-million-character cache limit counted extended graphemes. One
grapheme can contain many combining scalars, so retained text could grow far
beyond that apparent memory budget. Empty chapters also had no entry-count cap.

The cache now limits UTF-8 payload to 32 MiB and entries to 512. Synchronization
and shared extraction/search/page-estimate caching are preserved. Tests cover
combining sequences, multibyte eviction, empty chapters, duplicate insertion,
and concurrent access; the cache/navigation selection passed all 12 tests.

### Truncated CSS crashed the host process

A stylesheet ending in `-epub-line-break` followed by spaces advanced a Swift
string cursor to `endIndex` and then indexed it. The reproduction terminated
the test process with signal 5 and `String index is out of bounds`.

The replacement scanner uses bounded byte indices and recognizes comments,
quoted strings, brackets/functions, custom-property values, and declaration
boundaries. It preserves quoted or commented examples instead of turning them
into declarations. CSS whitespace/comments before colons and ASCII uppercase
property names now work. The 12 CSS unit/delivery tests passed, including actual
WebKit computed-style verification for vertical text combination.

### Recursive media-overlay skipping exhausted the stack

Skipping an EPUB `par` called `advancePar()` and `startCurrentPar()` recursively.
A SMIL document with 20,000 skipped entries terminated the test process with
signal 11. The same recursion crossed publication items too: 5,000 distinct
skipped overlays also terminated with signal 11. The transition now scans clips
and following overlays iteratively, keeping candidate state local until it finds
a playable clip. Empty or unparseable intermediate overlays no longer hide a
later valid one, and a run that reaches the end does not expose the position of
a chapter that was never displayed.

Skippability now includes `epub:type` tokens inherited from ancestor `seq`
elements and applies to every same-audio transition. A fake audio player makes
the contiguous-clip tests independent of audio hardware. Non-finite playback
rates fall back to 1× before reaching AVFoundation.

Two related asynchronous state errors were repaired. Starting a shared SMIL
from its second content document now selects that document's first `par`, and
duplicate fragment identifiers in earlier documents cannot win current-page
selection. A command and document generation check discards a delayed WebKit
answer after stop, another play command, navigation, or publication replacement.
Automatic navigation also verifies its actual destination after synchronous
delegate callbacks before starting audio.

The 5,000-overlay and 20,000-par reproductions, shared-document starts, empty
overlay traversal, delayed Promise, reentrant navigation, and playback-state
tests pass. The media-overlay/state selection passed 30 tests under Address
Sanitizer, with no sanitizer report.

## External implementations and active consumers

The following sources were fetched for independent comparison. No third-party
implementation has been added as a dependency or copied into Washi.

| Project | Inspected revision | License / comparison scope |
| --- | --- | --- |
| [Readium Swift Toolkit](https://github.com/readium/swift-toolkit/tree/dcca0e9c2b51ecfff178d9c87ba8c57705fbadd4) | `dcca0e9` | BSD-3-Clause; streamed ZIP resources, cancellation, range/cache design, WebKit lifecycle |
| [epub.js](https://github.com/futurepress/epub.js/tree/eee359d0790002115a1156a9833c54f4bcd44c1d) | `eee359d` | BSD-2-Clause text in LICENSE; view destruction, event cleanup, layout |
| [StackNest](https://github.com/shelfsmith/stacknest/tree/79837f48ce8cbf4897191f28cae270958226c89f) | `79837f4` | MIT; Washi adapter contracts and integration |
| [cooViewer](https://github.com/shunnag/cooViewer/tree/76a9281496addc2c40ce1f903277d402e292a257) | `76a9281` | Active consumer; framework integration and owner lifetime |

StackNest isolates Washi behind `WashiEPUBAdapter` and explicitly uses
`.alwaysCopy` for publications to avoid mapped-file failures on NAS storage.
Its pinned dependency is `7829f940aa810d28a8dcf61e67f49ae3e5cdc73b`.
Consumer compatibility will be tested against the revised Washi implementation
while preserving those adapter contracts.

## Sanitizer verification

- AddressSanitizer: `swift test --sanitize=address`, with `WASHI_CORPUS_DIR`
  pointing to the corpus, passed all 450 tests with 0 failures and 0 skips.
  There were no sanitizer reports.
- ThreadSanitizer: `swift test --sanitize=thread` passed all 450 tests with
  0 failures and 0 warnings.

## Consumer compatibility verification

### StackNest

In a clone of StackNest at revision `79837f4`, the Washi dependency in
`Package.swift` was changed from pinned revision `7829f940` to local Washi HEAD.
`swift build --target WashiEPUBAdapter` succeeded with 0 warnings and 0 errors.
`swift build --target WashiEPUBAdapterTests` also succeeded.

The full StackNest test suite could not be run. StackNest's own
`Sources/LibraryStore/LibraryImporter.swift` declares a `ProgressReporter`
protocol that is ambiguous with a same-named Foundation type in the macOS 27
SDK, causing the build of `Sources/AppCore` to fail. The dependencies of
`AppCore` are `LibraryStore`, `ArchiveAdapter`, `Carchive`, `LibraryServerAPI`,
`StackroomFormat`, and `EPUBAdapter`; `AppCore` was confirmed not to depend on
Washi. This build failure is independent of Washi.

### cooViewer

After rebuilding `Frameworks/Washi.framework`, cooViewer's Debug build succeeded
and 629 tests passed.

## Memory measurement

A validation harness outside the repository repeatedly opened and parsed the
251-book public corpus, recording RSS, malloc statistics, and `vmmap` output.

### Observations

- Across 12 passes over all 251 books, RSS grew linearly without reaching a
  plateau: +98.9 MiB, approximately 8.6 MiB per pass.
- `leaks` reported only one 112-byte item. No unreachable leaks were found.
- The bytes in use reported by `malloc_zone_statistics` stayed flat at
  1.0–1.4 MiB.
- Calling `malloc_zone_pressure_relief` on each pass did not return a single
  byte of RSS.
- `vmmap --summary` showed the number of `Malloc Large (empty)` regions
  increasing across passes: 10 → 13 → 18 → 22. The regions remained dirty.

### Isolation results

Two proposed primary causes were ruled out:

- Capped preallocation of the ZIP decompression output buffer (commit
  `977ce44`) reduced RSS growth over 12 passes from 98.9 MiB to 89.0 MiB.
  This was an improvement, but output-buffer growth was not the primary cause.
- The read strategy did not affect the result. With `.mappedIfSafe`, RSS grew
  by 57.2 MiB over 8 passes; `.alwaysCopy` was equivalent. Holding the entire
  archive in one `Data` was not the primary cause.

The decisive observation was that opening the same book 251 times per
pass kept RSS flat at 15.2 MiB across 6 passes, with an increase of only
0.6 MiB. Growth depended on opening distinct files, not on the number of opens.

### Conclusion

The observed RSS growth was allocator fragmentation caused by different
allocation sizes for different books, not a failure to free allocations.
In these measurements, macOS malloc retained freed large blocks and did not
release them in response to `malloc_zone_pressure_relief`. Completely
eliminating this behavior within Washi is difficult. The capped preallocation
change in `977ce44` is retained.
