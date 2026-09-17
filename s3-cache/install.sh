#!/usr/bin/env bash
# Local caching S3 proxies (rclone serve s3), no FUSE.
#
#   s3-cache/install.sh
#
# Each instance exposes an rclone remote's buckets under the same names. First read fetches from
# the origin and keeps a copy in the VFS cache; least-recently-used objects are evicted past the
# size cap or when the disk drops below S3_CACHE_MIN_FREE (40G). Writes go through to the origin.
#
#   :9100  hetzner:  cache ~/platform/cache/s3     100G   rclone remote s3cache:
#   :9101  wd:       cache ~/platform/cache/s3-wd   60G   rclone remote s3cache-wd:   (RustFS on the WD)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KEYS="$HOME/.config/s3-cache"
INSTANCES=(
  "org.survos.s3-cache    hetzner: 127.0.0.1:9100 $HOME/platform/cache/s3    100G s3cache"
  "org.survos.s3-cache-wd wd:      127.0.0.1:9101 $HOME/platform/cache/s3-wd 60G  s3cache-wd"
)

command -v rclone >/dev/null || { echo "brew install rclone"; exit 1; }
mkdir -p -m 700 "$KEYS"
[[ -f "$KEYS/access_key" ]] || { umask 077; openssl rand -hex 10 | tr -d '\n' > "$KEYS/access_key"; }
[[ -f "$KEYS/secret_key" ]] || { umask 077; openssl rand -hex 20 | tr -d '\n' > "$KEYS/secret_key"; }

for spec in "${INSTANCES[@]}"; do
  read -r LABEL REMOTE ADDR CACHE MAX RC <<<"$spec"
  rclone listremotes | grep -qx "$REMOTE" || { echo "skip $LABEL: rclone remote $REMOTE missing"; continue; }
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  sed -e "s#__LABEL__#$LABEL#g" -e "s#__RUN__#$HERE/run.sh#" -e "s#__REMOTE__#$REMOTE#" \
      -e "s#__ADDR__#$ADDR#" -e "s#__CACHE__#$CACHE#" -e "s#__MAX__#$MAX#" -e "s#__HOME__#$HOME#g" \
      "$HERE/org.survos.s3-cache.plist.template" > "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # bootout is asynchronous; bootstrap fails with "5: Input/output error" until it finishes
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null
  rclone config create "$RC" s3 provider=Other endpoint="http://$ADDR" \
    access_key_id="$(cat "$KEYS/access_key")" secret_access_key="$(cat "$KEYS/secret_key")" \
    force_path_style=true >/dev/null
  echo "$LABEL: $REMOTE on http://$ADDR, cache $CACHE ($MAX), rclone remote $RC:, log ~/Library/Logs/$LABEL.log"
done
