#!/bin/bash
# One-shot overnight pull of the bigger vision models (home link is ~2.6 MB/s, ~4 h for both).
# Started by ~/Library/LaunchAgents/org.survos.overnight-model-pull.plist, which this script
# removes when it finishes so it doesn't run again tomorrow night.
LABEL=org.survos.overnight-model-pull
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# don't compete with the WD vault mirror; start once its one-shot job has removed itself
while launchctl print "gui/$(id -u)/org.survos.vault-x10-to-wd" >/dev/null 2>&1; do sleep 60; done
echo "== $(date) start"
for m in qwen2.5vl:32b; do  # gemma3:27b dropped 2026-09-20 (slow T-Mobile link)
  /usr/bin/caffeinate -i /opt/homebrew/bin/ollama pull "$m" && echo "== $(date) done $m" || echo "== $(date) FAILED $m"
done
/opt/homebrew/bin/ollama list
rm -f "$PLIST"
echo "== $(date) finished; removed $PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
