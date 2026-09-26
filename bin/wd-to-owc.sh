#!/usr/bin/env bash
# Duplicate everything on the WD (portable S3 drive) onto the OWC (stationary SeaweedFS store).
# The OWC ends up a faithful copy, laid out so the WD can later be rebuilt as SeaweedFS from it:
#
#   wd:survos-platform (RustFS bucket)    -> owc:survos-platform
#   /Volumes/WD-001/<folder> (plain files) -> owc:wd-001/<folder>
#
#   bin/wd-to-owc.sh list        # RustFS key list, walked from disk (see below); copy runs it if missing
#   bin/wd-to-owc.sh copy        # resumable; plain folders first, then the bucket
#   bin/wd-to-owc.sh verify      # sizes for the plain folders, md5 (ETags) for the bucket
#   bin/wd-to-owc.sh verify-sum  # also md5 the plain folders (re-reads every byte on the WD)
#
# Run detached, it takes most of a day (the WD reads ~50-100 MB/s):
#   nohup caffeinate -is bin/wd-to-owc.sh copy > ~/Library/Logs/wd-to-owc/run.log 2>&1 &
#
# Plain folders copy 1 file at a time: the WD reads ~55 MB/s for one stream and falls apart with more
# (4 transfers: ~15 MB/s total; 2: ~28). Each file is read twice -- md5 first, then the upload from page
# cache -- so the WD idles ~25% of the time (~43 MB/s net). Measured 2026-09-25.
# --s3-disable-checksum drops that md5 pre-read for multipart files (>200 MB): one read each, but those
# objects carry no md5 on the OWC, so verify-sum can only size-check them.
# Multi-thread uploads are off too: rclone otherwise reads 4 offsets of one big file at once (same seeking).
# Never ask RustFS to list the bucket: big prefixes time out and abort the march (rustfs-wd memory).
# Each object is a directory named by its key holding an xl.meta, so the key list comes from `find`
# and every rclone call on the bucket uses --files-from --no-traverse.
set -euo pipefail

WD="/Volumes/WD-001"
BUCKET="survos-platform"
PLAIN="wd-001"
STATE="${STATE:-$HOME/Library/Logs/wd-to-owc}"
KEYS="$STATE/$BUCKET.keys"
EXCLUDES=(--exclude '/rustfs/**' --exclude '/.Spotlight-V100/**' --exclude '/.fseventsd/**'
          --exclude '/.Trashes/**' --exclude '/.TemporaryItems/**' --exclude '.DS_Store')

[ -d "$WD/rustfs/$BUCKET" ] || { echo "WD not mounted" >&2; exit 1; }
rclone lsd owc: >/dev/null || { echo "owc: (SeaweedFS) not answering on :8333" >&2; exit 1; }
rclone lsd wd: >/dev/null  || { echo "wd: (RustFS) not answering on :9000" >&2; exit 1; }
mkdir -p "$STATE"

list_keys() {
  echo "$(date '+%F %T') walking $WD/rustfs/$BUCKET for xl.meta ..."
  (cd "$WD/rustfs/$BUCKET" && find . -name xl.meta -type f) \
    | sed -e 's#^\./##' -e 's#/xl\.meta$##' | LC_ALL=C sort > "$KEYS.tmp"
  mv "$KEYS.tmp" "$KEYS"
  echo "$(date '+%F %T') $(wc -l < "$KEYS" | tr -d ' ') keys -> $KEYS"
}

case "${1:-copy}" in
  list) list_keys ;;
  copy)
    rclone mkdir "owc:$PLAIN"; rclone mkdir "owc:$BUCKET"
    echo "$(date '+%F %T') plain folders -> owc:$PLAIN"
    rclone copy "$WD" "owc:$PLAIN" "${EXCLUDES[@]}" --transfers 1 --checkers 16 --s3-chunk-size 64M \
      --multi-thread-streams 0 --s3-upload-concurrency 2 --s3-disable-checksum \
      --stats 1m --stats-log-level NOTICE --log-level NOTICE --log-file "$STATE/plain.log"
    [ -s "$KEYS" ] || list_keys
    echo "$(date '+%F %T') wd:$BUCKET -> owc:$BUCKET"
    rclone copy "wd:$BUCKET" "owc:$BUCKET" --files-from "$KEYS" --no-traverse --transfers 8 --checkers 32 \
      --stats 1m --stats-log-level NOTICE --log-level NOTICE --log-file "$STATE/bucket.log"
    echo "$(date '+%F %T') copy done"
    ;;
  verify|verify-sum)
    sum=(--size-only); [ "$1" = verify-sum ] && sum=()
    echo "== plain folders ($([ ${#sum[@]} -gt 0 ] && echo sizes || echo md5)) =="
    rclone check "$WD" "owc:$PLAIN" "${EXCLUDES[@]}" "${sum[@]}" --one-way --checkers 16 \
      --missing-on-dst "$STATE/plain.missing" --differ "$STATE/plain.differ" || true
    echo "== bucket (md5 from ETags) =="
    rclone check "wd:$BUCKET" "owc:$BUCKET" --files-from "$KEYS" --no-traverse --one-way --checkers 32 \
      --missing-on-dst "$STATE/bucket.missing" --differ "$STATE/bucket.differ" || true
    wc -l "$STATE"/*.missing "$STATE"/*.differ
    ;;
  *) echo "usage: $0 list|copy|verify|verify-sum" >&2; exit 2 ;;
esac
