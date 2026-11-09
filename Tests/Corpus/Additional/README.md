# Additional multilingual fixtures

`AdditionalCorpusTests` uses the files listed in `manifest.json` when they exist in
`.build/epub-corpus-extra` (override with `WASHI_EXTRA_CORPUS_DIR`). The base
corpus is independent of these additional fixtures.

- Traditional Chinese: *Dream of the Red Chamber* (紅樓夢), from Project
  Gutenberg ebook 24264. Download the EPUB 3 images variant as
  `zh-hant-dream-red-chamber.epub`.
- English: *The Art of War*, translated by Lionel Giles, from Standard Ebooks.
  Download the EPUB with `?source=download` as `en-art-of-war.epub`.
- Korean: *Seonjo's letter* (宣祖国文遺書), from Korean Wikisource. The public
  domain text is downloaded and repackaged as a valid OCF/OPF/XHTML EPUB named
  `ko-seonjo-letter.epub`. The original Wikisource EPUB special endpoint may
  return 404; repackaging uses only the public text and its source URL.

All three formats are standard EPUB containers with UTF-8 text. These are test
inputs only and are not redistributed with Washi.
