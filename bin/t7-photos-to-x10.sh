#!/usr/bin/env bash
# Save the personal photo folders from the blue T7 Shield (exFAT `t7-1`, mounted on the lemur)
# to the X10 before the Shield is reformatted. The lemur reads the exFAT (Linux handles accented
# names; macOS FSKit does not), the Mac pulls over the Thunderbolt link. See x10-vault-to-wd.sh.
#
#   bin/t7-photos-to-x10.sh copy|verify
set -euo pipefail

LEMUR_TB="${LEMUR_TB:-fe80::9eac:9951:8a50:e950%bridge0}"
SRC="/media/tac/t7-1"
DEST="/Volumes/X10/t7-photos"
DIRS=(DCIM Camera S24-Tac)
RSYNC=/opt/homebrew/bin/rsync
SSH="ssh -o BatchMode=yes -c aes128-gcm@openssh.com"

[ -d /Volumes/X10 ] || { echo "X10 not mounted" >&2; exit 1; }
mkdir -p "$DEST"

case "${1:-copy}" in
  copy)
    for d in "${DIRS[@]}"; do
      "$RSYNC" -a --info=progress2,stats1 --log-file="$DEST.log" -e "$SSH" "tac@[$LEMUR_TB]:$SRC/$d" "$DEST/"
    done
    ;;
  verify)
    for d in "${DIRS[@]}"; do
      echo "$d source: $($SSH "tac@$LEMUR_TB" "cd '$SRC' && find '$d' -type f | wc -l") files"
      echo "$d dest:   $(find "$DEST/$d" -type f | wc -l | tr -d ' ') files"
      "$RSYNC" -a --checksum --dry-run --itemize-changes -e "$SSH" "tac@[$LEMUR_TB]:$SRC/$d" "$DEST/"
    done
    ;;
  *) echo "usage: $0 copy|verify" >&2; exit 2 ;;
esac
