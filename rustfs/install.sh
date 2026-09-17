#!/usr/bin/env bash
# Install (or upgrade) RustFS natively on the Mac, backed by the WD Elements drive.
#
#   rustfs/install.sh            # pinned binary, credentials, launchd agent, rclone remote "wd"
#   RUSTFS_VERSION=1.0.1 rustfs/install.sh
#
# Native, not podman: the podman VM only shares /Users and /private, so it cannot see /Volumes.
# One manual step: System Settings > Privacy & Security > Full Disk Access > add ~/.local/bin/rustfs
# (launchd-started processes are otherwise denied access to external volumes).
set -euo pipefail

VERSION="${RUSTFS_VERSION:-1.0.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/rustfs"
DATA="${RUSTFS_DATA:-/Volumes/WD-001/rustfs}"
KEYS="$HOME/.config/rustfs"
LABEL="org.survos.rustfs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ASSET="rustfs-macos-aarch64-v$VERSION.zip"

# 1. Binary, checksum-verified against the release's SHA256SUMS
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh release download "$VERSION" -R rustfs/rustfs -p "$ASSET" -p SHA256SUMS -D "$tmp"
(cd "$tmp" && grep " $ASSET\$" SHA256SUMS | shasum -a 256 -c -)
unzip -o -q "$tmp/$ASSET" -d "$tmp"
mkdir -p "$(dirname "$BIN")"
install -m 0755 "$tmp/rustfs" "$BIN"
"$BIN" --version | head -1

# 2. Credentials, generated once, outside any repo
mkdir -p -m 700 "$KEYS"
[[ -f "$KEYS/access_key" ]] || { umask 077; openssl rand -hex 10 | tr -d '\n' > "$KEYS/access_key"; }
[[ -f "$KEYS/secret_key" ]] || { umask 077; openssl rand -hex 20 | tr -d '\n' > "$KEYS/secret_key"; }

# 3. Data dir (created from this interactive shell, which may touch /Volumes)
mkdir -p "$DATA"

# 4. launchd agent
sed -e "s#__HOME__#$HOME#g" -e "s#__DATA__#$DATA#g" "$HERE/$LABEL.plist.template" > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "launchd agent $LABEL loaded; log: ~/Library/Logs/rustfs.log"

# 5. rclone remote "wd" (path-style, local only)
rclone config create wd s3 provider=Other endpoint=http://127.0.0.1:9000 \
  access_key_id="$(cat "$KEYS/access_key")" secret_access_key="$(cat "$KEYS/secret_key")" \
  force_path_style=true >/dev/null
echo "rclone remote wd: configured"
