#!/bin/bash
# One-shot: mirror the merged X10 vault to the WD, then checksum-verify it.
# Started by ~/Library/LaunchAgents/org.survos.vault-x10-to-wd.plist, which this removes when done.
LABEL=org.survos.vault-x10-to-wd
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/sites/docker/bin"

echo "== $(date) start sync"
if /usr/bin/caffeinate -i "$BIN/vault-x10-to-wd.sh" sync >/dev/null 2>&1; then
  echo "== $(date) sync done; verifying"
  /usr/bin/caffeinate -i "$BIN/vault-x10-to-wd.sh" verify > /Volumes/WD-001/vault-x10-to-wd-verify.log 2>&1
  echo "== $(date) verify done: $(($(wc -l < /Volumes/WD-001/vault-x10-to-wd-verify.log) - 1)) differing files (0 = good)"
else
  echo "== $(date) sync FAILED (see /Volumes/WD-001/vault-x10-to-wd.log)"
fi
rm -f "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
