#!/bin/sh
# 公開前の検証を行う。タグの作成や push は、このスクリプトでは行わない。
# 本体は同じディレクトリの release.py。引数と終了コードはそのまま引き継ぐ。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 -B "$script_dir/release.py" "$@"
