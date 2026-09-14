# Washi の課題管理

Washi 本体の課題は、このリポジトリの beads で管理する。`bd` 1.2.2 で初期化済み。
新規課題の ID は `Washi-*`。cooViewer から移行した課題は、既存の参照を壊さないよう
`cooViewer-*` の ID を維持している。

## 開始と日常作業

```sh
bd bootstrap --yes
bd prime
bd ready
bd show <id>
bd update <id> --claim
```

初期化済みのチェックアウトで `bd init` を再実行しない。
`bd init` は Git コミットを自動作成する場合があり、`--dolt-auto-commit off` では
その Git コミットを抑止できない。

完了した課題は検証結果を記録して `bd close <id> --reason '検証結果'` で閉じる。
残る課題は beads に記録する。

## 保存と同期

正本は `.beads/embeddeddolt/` の Dolt DB であり、Git で直接追跡しない。
コード用の Git commit・push と、次の課題データの同期は別の操作になる。

```sh
bd dolt pull
bd dolt commit -m '課題の更新内容'
bd dolt push
```

同期先は `git+https://github.com/shunnag/Washi.git` の `refs/dolt/data`。
commit・push はそのセッションのユーザーの許可に従って実行する。

`.beads/issues.jsonl` は閲覧・移行用の自動エクスポートであり、DB の完全なバックアップや
通常の同期手段ではない。既存 DB に対して日常的に `bd import` を実行しない。
新しいチェックアウトの DB 構築には `bd bootstrap --yes` を使う。

`bd` 1.2.2 の `bd config validate` は従来の `federation.remote` を要求するため、
この Git 同期構成では警告する。同期先は `bd dolt remote list` で確認し、
実際の push と新しいチェックアウトでの bootstrap により検証する。

## cooViewer からの移行

2026-09-14 に Washi 本体の154件を、本文・状態・日時・内部依存関係・コメントを
保って移行した。移行対象と照合結果は `migrations/cooviewer-2026-09-14.json` に記録した。

cooViewer 側の元課題には `moved-to-washi` ラベルと移行先を残してある。
元で未完了だった課題のクローズ理由は「作業完了」ではなく「管理先の移行」。
元の履歴と、cooViewer 側に残る課題からの参照は削除していない。

cooViewer の UI・アプリ配布・framework 組み立てだけに関わる課題は移していない。
例えば `cooViewer-vz3k` の Info.plist 版番号は cooViewer のビルドスクリプトで管理する。
