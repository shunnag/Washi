# Washi の開発

## 課題管理

課題と継続作業の記録には、このリポジトリの beads (`bd`) を使う。
作業開始時に `bd prime` と `bd ready` を実行し、対象を `bd show <id>` で確認する。
着手時は `bd update <id> --claim`、完了時は検証結果を記録して `bd close <id>` を使う。
未完了の作業を完了扱いにしない。追跡用の Markdown TODO や個人用メモを別に作らない。

cooViewer から移行した課題は、ソース内の参照と履歴を保つため `cooViewer-*` の
旧 ID を維持している。この接頭辞の課題も Washi 側で更新する。
cooViewer 本体の UI・統合・framework 組み立てに固有の課題は cooViewer 側で扱う。

新しいチェックアウトでは `bd bootstrap --yes` を実行する。
既存 DB を作り直す目的で `bd init` を再実行しない。
通常の同期は `bd dolt pull` / `bd dolt push` を使い、JSONL を再 import しない。
詳細は [.beads/README.md](.beads/README.md) を参照する。

## 実装と検証

SwiftPM パッケージとして、macOS 14 以降と既存の公開 API の互換性を維持する。
変更範囲に応じて `swift test`、必要なら release ビルドを確認する。
内部コメントは日本語で書き、公開 API の説明は既存方針に合わせて日本語を先に日英併記する。
シェルや Python のスクリプトは、リポジトリ外のカレントディレクトリでも動くようにする。

Git の commit・push と Dolt の同期は、そのセッションのユーザーの許可に従う。
完了時には差分・検証結果・残課題を確認し、許可があれば必要な commit・push を行う。
Git のコード履歴と Dolt の課題履歴は別々に同期する。
