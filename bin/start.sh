#!/usr/bin/env bash
# Run this once after every reboot. Brings up the shared dev stack, then
# reapplies the AppArmor complain-mode override php-fpm needs on this
# machine -- the (optional, manually-installed) apparmor-profiles package
# resets /etc/apparmor.d/php-fpm to enforcing on every reboot, which blocks
# php-fpm from even reading app files ("Access denied." on every *.wip app,
# fixed here since it's a system-wide php-fpm block, not specific to this
# docker stack). If that package ever gets removed, the profile file won't
# exist and this step is skipped rather than failing the whole script.
#
# Needs sudo -- interactive password prompt is expected and normal.
set -euo pipefail
cd "$(dirname "$0")/.."

# On the Mac the daemon lives in the podman VM, which doesn't start at boot.
# "already running" exits non-zero, hence || true; a real failure still
# surfaces at compose below.
if [ "$(uname)" = Darwin ] && command -v podman >/dev/null; then
    podman machine start 2>/dev/null || true
    # .zshrc sets this, but non-interactive shells don't read it.
    : "${DOCKER_HOST:=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')}"
    export DOCKER_HOST
fi

docker compose up -d

if [ -f /etc/apparmor.d/php-fpm ]; then
    sudo apparmor_parser -C -r /etc/apparmor.d/php-fpm
fi
