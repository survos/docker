#!/usr/bin/env bash
# Merge the Mac's ~/platform/vault into the X10's vault (the lemur's vault, restored), so the X10
# holds the one complete vault. On 2026-09-19 every overlapping file was newer on the Mac, so the
# Mac wins -- but the X10's version is moved aside to $REPLACED rather than overwritten.
#
#   bin/vault-merge-mac-to-x10.sh merge    # copy (resumable)
#   bin/vault-merge-mac-to-x10.sh verify   # checksum dry-run; nothing listed = every Mac file is on the X10
set -euo pipefail

SRC="$HOME/platform/vault/"
DEST="/Volumes/X10/vault/"
REPLACED="/Volumes/X10/vault-merge-replaced-2026-09-19"
RSYNC=/opt/homebrew/bin/rsync

[ -d "$DEST" ] || { echo "X10 vault not mounted" >&2; exit 1; }

case "${1:-merge}" in
  merge)
    "$RSYNC" -a --whole-file --backup --backup-dir="$REPLACED" --info=progress2,stats2 \
      --log-file="/Volumes/X10/vault-merge.log" "$SRC" "$DEST"
    ;;
  verify)
    echo "checksum dry-run (any file listed below differs or is missing on the X10):"
    "$RSYNC" -a --checksum --dry-run --itemize-changes "$SRC" "$DEST"
    ;;
  *) echo "usage: $0 merge|verify" >&2; exit 2 ;;
esac
