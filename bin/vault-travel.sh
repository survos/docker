#!/usr/bin/env bash
# The travel vault: the small slice of the 1 TB vault needed to develop without the X10.
#
#   bin/vault-travel.sh sync     # X10 -> ~/platform/vault-travel   (needs the X10)
#   bin/vault-travel.sh push     # ~/platform/vault-travel -> $REMOTE   (needs the bucket)
#   bin/vault-travel.sh pull     # $REMOTE -> ~/platform/vault-travel   (any machine, no X10)
#   bin/vault-travel.sh use local|x10   # repoint ~/platform/vault
#   bin/vault-travel.sh status
#
# ~/platform/vault is a symlink (APP_DATA_DIR=~/platform, survos_dataset.zips_root=vault), so
# every app follows it with no config change. `use local` points it at the travel copy; `use x10`
# points it back at the full vault. Run `sync` while the X10 is attached, `pull` when it is not.
#
# The set is deliberately small: the datasets in daily use, minus page scans. Add a path and
# rerun sync+push. Whole papers (cron-america/sn83025182 is 24 GB, _imports 44 GB) stay home.
set -euo pipefail

X10="/Volumes/X10/vault"
LOCAL="${VAULT_TRAVEL:-$HOME/platform/vault-travel}"
LINK="$HOME/platform/vault"
REMOTE="${VAULT_TRAVEL_REMOTE:-hetzner:vault-travel}"
RSYNC=/opt/homebrew/bin/rsync

# Relative to the vault root. Keep in sync with docs/data-layout.md.
PATHS=(
  survey                          # us-newspapers: the title survey mastheads reads
  vnd                             # Virginia Newspaper Directory catalog + cached pages
  cron-america/_capture           # bulk inventory, title list, issue dates
  cron-america/sn85049816         # Hawk-Eye: a small chronam title, published in Ink
  cron-america/sn98068377-enhanced
  news/rappnews5254               # RappNews: the folio Ink serves at /rappnews
  news/rappnews5353
  news/rappnews5455
  news/rappnews-digital
  news/rappnews4909-enhanced      # stitched stories (not 4909 itself: 1.3 GB of page scans)
  mus/soviet-life
  mus/soviet-life-enhanced
  iai                             # two Goobi periodicals, small
)

usage() { sed -n '2,12p' "$0"; exit 1; }

case "${1:-status}" in
  sync)
    [ -d "$X10" ] || { echo "X10 not mounted" >&2; exit 1; }
    mkdir -p "$LOCAL"
    for p in "${PATHS[@]}"; do
      [ -e "$X10/$p" ] || { echo "skip (not in vault): $p"; continue; }
      mkdir -p "$LOCAL/$(dirname "$p")"
      "$RSYNC" -a --delete --info=progress2 "$X10/$p/" "$LOCAL/$p/"
    done
    du -sh "$LOCAL"
    ;;
  push)
    rclone copy --progress --s3-no-check-bucket "$LOCAL" "$REMOTE"
    ;;
  pull)
    mkdir -p "$LOCAL"
    rclone copy --progress "$REMOTE" "$LOCAL"
    du -sh "$LOCAL"
    ;;
  use)
    case "${2:-}" in
      local) target="$LOCAL" ;;
      x10)   target="$X10" ;;
      *) usage ;;
    esac
    [ -d "$target" ] || { echo "$target does not exist" >&2; exit 1; }
    [ -L "$LINK" ] || [ ! -e "$LINK" ] || { echo "$LINK is a real directory, not a symlink; not touching it" >&2; exit 1; }
    ln -sfn "$target" "$LINK"
    echo "vault -> $(readlink "$LINK")"
    ;;
  status)
    echo "vault      -> $(readlink "$LINK" 2>/dev/null || echo '(not a symlink)')"
    echo "X10        $([ -d "$X10" ] && echo mounted || echo 'not mounted')"
    printf 'travel     %s\n' "$([ -d "$LOCAL" ] && du -sh "$LOCAL" | cut -f1 || echo '(none)')"
    echo "remote     $REMOTE"
    ;;
  *) usage ;;
esac
