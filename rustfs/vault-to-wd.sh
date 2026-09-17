#!/usr/bin/env bash
# Copy a local vault subtree into RustFS on the WD, under the same key it has on Hetzner
# (survos-platform/vault/<path>), then verify from a file list.
#
#   rustfs/vault-to-wd.sh mus/nabolom
#
# Verification is list-based on purpose. `rclone check` without --files-from walks the
# destination with ListObjects, and RustFS on a spinning disk times out on large prefixes
# (5xx "InternalError: timeout" after 5-120 s). That aborts the march and reports files as
# missing which a direct stat finds present. Feeding the local file list makes every
# comparison a HEAD on one key, so no big listings are needed.
set -euo pipefail

SUB="${1:?usage: vault-to-wd.sh <provider/dataset>}"
SRC="$HOME/platform/vault/$SUB"
DST="wd:survos-platform/vault/$SUB"
TAG="${SUB//\//-}"
LOG="$HOME/Library/Logs/vault-to-wd-$TAG.log"
LIST="$HOME/platform/work/vault-to-wd/$TAG.files"
[[ -d "$SRC" ]] || { echo "no such dir: $SRC"; exit 1; }

rclone mkdir wd:survos-platform
FILTER=(--exclude '.DS_Store' --exclude '._*' --exclude '.Spotlight-V100/**' --exclude '.Trashes/**')

echo "copy $SRC -> $DST (log: $LOG)"
rclone copy "$SRC" "$DST" "${FILTER[@]}" --transfers 16 --checkers 16 \
  --stats 1m --stats-one-line --log-file "$LOG" --log-level NOTICE

mkdir -p "$(dirname "$LIST")"
(cd "$SRC" && find . -type f ! -name '.DS_Store' ! -name '._*' | sed 's#^\./##') > "$LIST"
echo "verify $(wc -l < "$LIST" | tr -d ' ') files from $LIST"
rclone check "$SRC" "$DST" --files-from "$LIST" --no-traverse --checkers 32 \
  --log-file "$LOG" --log-level NOTICE
echo "verified"
