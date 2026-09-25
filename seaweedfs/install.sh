#!/usr/bin/env bash
# Install (or upgrade) SeaweedFS natively on the Mac, backed by the OWC Mercury Elite Pro Quad.
#
#   seaweedfs/install.sh        # binary, credentials, launchd agent, rclone remote "owc"
#
# One `weed server` process: master :9333, volume :18080 (8080 is taken), filer :8888,
# S3 :8333, WebDAV :7333 (Iceberg and Lance catalogs off; Lance defaults to :9101, the WD cache) -- all bound to 127.0.0.1. S3 and WebDAV are two views of the
# same filer tree (Finder: Cmd-K http://127.0.0.1:7333). Data files are SeaweedFS volumes,
# not plain files; browse through WebDAV or S3, never the raw disk.
#
# The binary is copied to ~/.local/bin/weed so its path survives `brew upgrade`.
# One manual step: System Settings > Privacy & Security > Full Disk Access > add ~/.local/bin/weed
# (launchd-started processes are otherwise denied access to external volumes).
# More bays: add each drive's dir to -dir as a comma list, e.g. /Volumes/OWC-A/seaweed,/Volumes/OWC-B/seaweed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/weed"
DATA="${SEAWEED_DATA:-/Volumes/OWC-A/seaweed}"
CONF="$HOME/.config/seaweedfs"
LABEL="org.survos.seaweedfs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. Binary, from Homebrew
command -v weed >/dev/null || brew install seaweedfs
mkdir -p "$(dirname "$BIN")"
install -m 0755 "$(brew --prefix seaweedfs)/bin/weed" "$BIN"
"$BIN" version | head -1

# 2. S3 credentials, generated once, outside any repo
mkdir -p -m 700 "$CONF"
[[ -f "$CONF/access_key" ]] || { umask 077; openssl rand -hex 10 | tr -d '\n' > "$CONF/access_key"; }
[[ -f "$CONF/secret_key" ]] || { umask 077; openssl rand -hex 20 | tr -d '\n' > "$CONF/secret_key"; }
( umask 077; cat > "$CONF/s3.json" <<JSON
{"identities":[{"name":"admin",
  "credentials":[{"accessKey":"$(cat "$CONF/access_key")","secretKey":"$(cat "$CONF/secret_key")"}],
  "actions":["Admin","Read","Write","List","Tagging"]}]}
JSON
)

# 3. Data dir (created from this interactive shell, which may touch /Volumes)
mkdir -p "$DATA"

# 4. launchd agent
sed -e "s#__HOME__#$HOME#g" -e "s#__DATA__#$DATA#g" "$HERE/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
while launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; do sleep 1; done  # bootout is async
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "launchd agent $LABEL loaded; log: ~/Library/Logs/seaweedfs.log"

# 5. rclone remote "owc"
rclone config create owc s3 provider=SeaweedFS endpoint=http://127.0.0.1:8333 \
  access_key_id="$(cat "$CONF/access_key")" secret_access_key="$(cat "$CONF/secret_key")" \
  force_path_style=true >/dev/null
echo "rclone remote owc: configured"
