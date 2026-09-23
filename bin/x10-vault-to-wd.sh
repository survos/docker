#!/usr/bin/env bash
# Stage the lemur's x10a vault on the WD so the X10 can be reformatted for the Mac.
#
#   bin/x10-vault-to-wd.sh copy     # rsync lemur:x10a/v2/vault -> WD-001/x10a-vault (resumable)
#   bin/x10-vault-to-wd.sh verify   # file count + bytes, then a checksum dry-run (lists diffs)
#   bin/x10-vault-to-wd.sh restore         # WD-001/x10a-vault -> X10 (now APFS on the Mac)/vault
#   bin/x10-vault-to-wd.sh verify-restore  # same checks, WD vs X10
#
# Transport is the Thunderbolt cable, not WiFi. macOS routes 169.254/16 out en0 (WiFi,
# ~22 MB/s), so we address the lemur's thunderbolt0 by its IPv6 link-local scoped to
# bridge0 (~1.2 GB/s, no sudo, no static IPs). If the lemur's fe80 address changes,
# get it with: ssh lemur 'ip -6 -br addr show thunderbolt0'
set -euo pipefail

LEMUR_TB="${LEMUR_TB:-fe80::9eac:9951:8a50:e950%bridge0}"
SRC="/media/tac/x10a/v2/vault/"
DEST="/Volumes/WD-001/x10a-vault/"
LOG="/Volumes/WD-001/x10a-vault.log"
RSYNC=/opt/homebrew/bin/rsync          # 3.x; /usr/bin/rsync is openrsync
SSH="ssh -o BatchMode=yes -c aes128-gcm@openssh.com"

[ -d /Volumes/WD-001 ] || { echo "WD-001 not mounted" >&2; exit 1; }
mkdir -p "$DEST"

case "${1:-copy}" in
  copy)
    "$RSYNC" -a --partial --info=progress2,stats2 --log-file="$LOG" \
      -e "$SSH" "tac@[$LEMUR_TB]:$SRC" "$DEST"
    ;;
  verify)
    echo "source:"; $SSH "tac@$LEMUR_TB" "cd $SRC && find . -type f | wc -l && du -sb --apparent-size . | cut -f1"
    echo "dest:";   (cd "$DEST" && find . -type f | wc -l && find . -type f -print0 | xargs -0 stat -f %z | awk '{s+=$1} END {print s}')
    echo "checksum dry-run (any file listed below differs):"
    "$RSYNC" -a --checksum --dry-run --itemize-changes -e "$SSH" "tac@[$LEMUR_TB]:$SRC" "$DEST"
    ;;
  restore)
    # after the X10 is reformatted APFS on the Mac: WD staging copy -> X10/vault
    [ -d /Volumes/X10 ] || { echo "X10 not mounted" >&2; exit 1; }
    "$RSYNC" -a --whole-file --info=progress2,stats2 --log-file="/Volumes/X10/vault-restore.log" \
      "$DEST" /Volumes/X10/vault/
    ;;
  verify-restore)
    for d in "$DEST" /Volumes/X10/vault/; do
      echo "$d"; (cd "$d" && find . -type f | wc -l && find . -type f -print0 | xargs -0 stat -f %z | awk '{s+=$1} END {print s}')
    done
    echo "checksum dry-run (any file listed below differs):"
    "$RSYNC" -a --checksum --dry-run --itemize-changes "$DEST" /Volumes/X10/vault/
    ;;
  *) echo "usage: $0 copy|verify|restore|verify-restore" >&2; exit 2 ;;
esac
