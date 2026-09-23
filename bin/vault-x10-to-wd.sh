#!/usr/bin/env bash
# Mirror the merged X10 vault (lemur vault + the Mac's ~/platform/vault, 2026-09-19) onto the WD,
# so every file exists on two drives. /Volumes/WD-001/x10a-vault started as the lemur-only staging
# copy; after this it is a full mirror of X10/vault. Files the X10 changed are moved aside, not lost.
#
#   bin/vault-x10-to-wd.sh sync     # resumable
#   bin/vault-x10-to-wd.sh verify   # checksum dry-run; nothing listed = WD matches X10
set -euo pipefail

SRC="/Volumes/X10/vault/"
DEST="/Volumes/WD-001/x10a-vault/"
REPLACED="/Volumes/WD-001/x10a-vault-replaced-2026-09-19"
RSYNC=/opt/homebrew/bin/rsync

[ -d "$SRC" ] && [ -d "$DEST" ] || { echo "X10 or WD not mounted" >&2; exit 1; }

case "${1:-sync}" in
  sync)
    "$RSYNC" -a --whole-file --backup --backup-dir="$REPLACED" --info=progress2,stats2 \
      --log-file="/Volumes/WD-001/vault-x10-to-wd.log" "$SRC" "$DEST"
    ;;
  verify)
    echo "checksum dry-run (any file listed below differs or is missing on the WD):"
    "$RSYNC" -a --checksum --dry-run --itemize-changes "$SRC" "$DEST"
    ;;
  *) echo "usage: $0 sync|verify" >&2; exit 2 ;;
esac
