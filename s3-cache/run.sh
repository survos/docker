#!/usr/bin/env bash
# launchd entry point for one caching S3 proxy instance.
#
#   run.sh <remote> <addr> <cache-dir> <max-size>
#   run.sh hetzner: 127.0.0.1:9100 ~/platform/cache/s3     100G
#   run.sh wd:      127.0.0.1:9101 ~/platform/cache/s3-wd  60G
set -euo pipefail

REMOTE="$1" ADDR="$2" CACHE_DIR="$3" MAX_SIZE="$4"
KEYS="$HOME/.config/s3-cache"
mkdir -p "$CACHE_DIR"

exec rclone serve s3 "$REMOTE" \
  --addr "$ADDR" \
  --auth-key "$(cat "$KEYS/access_key"),$(cat "$KEYS/secret_key")" \
  --cache-dir "$CACHE_DIR" \
  --vfs-cache-mode full \
  --vfs-cache-max-size "$MAX_SIZE" \
  --vfs-cache-min-free-space "${S3_CACHE_MIN_FREE:-40G}" \
  --vfs-cache-max-age "${S3_CACHE_MAX_AGE:-720h}" \
  --dir-cache-time 5m \
  --log-level INFO
