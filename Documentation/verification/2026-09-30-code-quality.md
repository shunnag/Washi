# コード品質整理の統合検証 (2026-09-30)

`Washi-z74` の WP1–10 と、第二回レビューの package A (`refactor/r2a` の `ba4d338`) を
`refactor/code-quality` に統合した作業ツリーを検証した。比較の出発点は `489a099`。
package A の統合では、WP9 で別ファイルへ移した `MediaOverlayUXTests` と旧ファイルに残る修正が
競合した。移動後のテストを保持し、現在の controller の `parIndex` を照合するようにした。

## 責務と所有

WashiCore はコンテナ、OPF、navigation、publication、encryption、SMIL の解析を話題別に置く。
Washi は Reader、WebContent、Pagination、Offscreen、MediaOverlay、Util を分ける。
Reader の状態は `EPUBReaderView` が所有し、loading/navigation/layout/input/selection/cover などの操作は
対応する extension に置く。公開 model・設定・delegate と注入 script の契約は専用の型で表す。

package A では行き先を `PendingTarget` で表し、読み込み時の準備と項目状態の更新を分けた。
オフスクリーンの FIFO queue、WebView host、navigation 待機と timeout/cancel の責務を整理した。
ドキュメント/項目/着地/表示の世代は、それぞれ異なる失効範囲を守るため維持した。
SMIL の `a#` は空の fragment を nil に統一する。公開宣言・プロダクト名・通常のページ割り契約は維持する。

README の構成表、DocC、テストの補助、Python スクリプトの入口も整理した。
[読み込みと終了](../../Sources/Washi/Washi.docc/ReaderLifecycle.md)はホストのタスクと reader の寿命を説明する。

## 最終ゲート

Xcode 27.0 (27A266a)、Swift 6.4、macOS arm64 の GUI セッションで実行した。

| 対象 | 結果 |
| --- | --- |
| `swift test`、統合後 1 回目 | WashiTests 632 + public API 2、0 failure、3 skip |
| `swift test`、統合後 2 回目 | WashiTests 632 + public API 2、0 failure、3 skip |
| baseline の実行 method 一覧 | 623件をすべて保持、11件追加、126 method はクラス/ファイルを移動 |
| release `WashiDynamic`、library evolution、interface の verify | 成功 |
| 正規化した公開 interface 宣言の multiset | Washi 365、WashiCore 457、baseline と一致 |
| inherited convenience initializer / SPI | Washi の継承 initializer 表記を保持、SPI/package の漏出なし |
| Python (`Tests/Scripts`、リポジトリ外 cwd) | 50件、0 failure |
| DocC・README/guide の Swift 例 | warnings-as-errors で成功、14例を型検査 |
| 公開 EPUB corpus (`WASHI_CORPUS_DIR`) | 251冊すべて解析成功、日本語サンプル7冊も存在、2 tests/0 skip/0 failure |
| Samples の build/test | AppKit/SwiftUI 両方、5 tests/0 failure |
| stacknest の既存 EPUB adapter とテストの一時コピー | Washi adapter 64 + 共通 adapter 15、0 failure |
| cooViewer の framework 組み立てと全テスト | 745件、0 failure、1件の既存 skip |

通常 suite の3 skipは公開 corpus の2件と opt-in の撮影コスト計測1件。
これらも上表の専用実行で確認した。追加11件は JavaScript 契約7件、実イベント3件、
計測中の census invalidate 1件。method の追加/移動の全対応は
[テスト一覧比較](2026-09-30-test-inventory.json)に残す。

stacknest は元 checkout を変更せず、4つの source target と2つの test target を一時 package にコピーし、
依存をこの Washi checkout に置き換えた。リポジトリ全体の import 配置を検査する `ImportBoundaryTests` は
その部分コピーに含めず、アダプターの契約・復元・表示設定・キー転送・終了を検証した。
stacknest の全アプリ/他の依存パッケージを検証したものではない。

公開宣言の比較では両方を同じ順序に正規化して multiset を比較する。
最初の比較が不一致になったのは Python とシェルの locale sort の順序差だけであり、
追加/削除宣言は両モジュールとも0件だった。

## 再実行

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift build -c release --product WashiDynamic \
  -Xswiftc -enable-library-evolution -Xswiftc -emit-module-interface \
  -Xswiftc -verify-emitted-module-interface
DEVELOPER_DIR=/Applications/Xcode.app swift test --package-path Samples
```

Python と文書のコマンドは [README](../../README.md) の開発/文書ビルド節に従う。
ログ、xcresult、interface、DocC site と一時 consumer は `/tmp/cooviewer-quality-20260930/`。
個人の読書状態、パスワード保管庫、本番の設定ドメインはこの検証に使用しない。

## WebKit の撮影コスト比較

同じ既存 `PageCoverCaptureCostTests` を `489a099` の一時 checkout と統合後の checkout で実行した。
本の生成・初期表示・3回の warm-up を計測から除外し、各本20回の `WKWebView.takeSnapshot` を測った。
前/後を交互に4 round実行し、各実行の中央値をさらに中央値で比較した。
同じ toolchain の Debug test runnerを使い、計測中に他の build/test は走らせていない。

| 本 | 前の中央値 (ms) | 後の中央値 (ms) | 比 |
| --- | ---: | ---: | ---: |
| reflowable | 1.55 | 1.50 | 0.968 |
| fxl-detail | 1.25 | 1.20 | 0.960 |

全実行は1440×900 pt、画面倍率2、thermal state 0。撮影画像の寸法は各本で前後一致した。
**ウインドウの occlusion は全実行で不可視と判定された**。テストの on-screen override と画面内配置は同じで、
比較はその条件での WebKit 撮影だけを対象とする。表示されている実ウインドウのフレーム時間や、
UI 全体のページ送り性能を保証する値ではない。この範囲では大きな低下は観測しなかった。
[全実行の統計と条件](2026-09-30-page-cover-comparison.json)を併記した。

## English

Integrated the responsibility reorganization and the second review's rendering package. Two full test runs passed,
with 634 tests including public-API tests. All 623 baseline methods remain, with 11 additions and documented suite moves.
Normalized public interface declarations match; release/library-evolution, documentation/examples, 251-book corpus,
Python, sample apps, stacknest's EPUB adapters and cooViewer passed their scoped checks.
The alternating WebKit snapshot comparison showed no substantial regression in the measured occluded-window condition.
It does not measure visible-window frame timing or overall application performance.
