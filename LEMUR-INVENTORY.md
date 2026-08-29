# Lemur inventory — what runs here, and what it takes to work from the Mac

Taken 2026-08-29 while switching machines. Companion to `DEV-SERVICES.md` (what to run
and when) and `PARKING-APPS.md` (the same idea on dokku). Open blockers are tracked in
survos/docker#9.

Machine: `tac-Lemur-Pro`, Ubuntu 24.04, 14 cores, 38 GB RAM.

## Read this first: what does NOT move

| | why |
|---|---|
| `/platform` (3.6 TB, 1.3 TB used) | ext4 on the x10a USB drive. macOS cannot mount ext4. |
| `/platform` as a symlink | macOS `/` is read-only; needs `/etc/synthetic.conf`, not `ln -s`. |
| FF-680W scanner | physically attached; `depot-scan-worker.service` drives it. depot has no dokku remote and is local-only by design. |
| cloudflared ingress | six hostnames pinned to `127.0.0.1:PORT` **on this box**. |

Only `folio`, `folio-archive` and `vault` exist in S3 (`survos-platform`). `datasets.db`,
`work`, `mediary`, `places` and `geonames-*` live **only** on the x10a. Decide what needs
to survive before treating the Mac as primary.

## Starts automatically at login

systemd **user** units (`systemctl --user`), all `enabled`:

| unit | what |
|---|---|
| `dev-docker-stack.service` | `docker compose up -d postgres postgres_messenger meilisearch redis mailer rabbitmq` |
| `symfony-proxy.service` | the `.wip` proxy on :7080 |
| `rclone-platform-s3.service` | `hetzner-museado:survos-platform` → `~/platform-s3` (cached) |
| `rclone-platform-s3-zips.service` | same bucket → `~/platform-s3-zips` (streaming) |
| `depot-scan-worker.service` | scan_jobs consumer, drives the scanner |
| `cloudflared-depot-lemur-pro.service` | tunnel for the scan station |

Deliberately **disabled** 2026-08-29: `ssai-depot-events.service`. It was `Restart=always`
with a hard Redis dependency and no start limit, so stopping Docker *created* load — 252
restarts an hour. Re-enable only alongside a `StartLimitBurst` or a `BindsTo` on the stack.

## Hard-pinned ports

`.symfony.local.yaml` pins these because cloudflared ingress targets them by number. The
Symfony CLI's dynamic pool starts at 8000 and climbs past 8007 with ~44 registered
projects, so 8010–8024 is the reserved band.

| app | port | public hostname |
|---|---|---|
| mediary | 8010 | — |
| harvest | 8011 | laptop-harvest.scanstationai.work |
| lingua | 8012 | — |
| priceit | 8013 | laptop-priceit.scanstationai.work |
| ddys | 8014 | laptop-ddys.scanstationai.work |
| depot | 8020 | laptop-depot.scanstationai.work |
| ssai | 8021 | laptop-ssai.scanstationai.work |

The ingress targets **https://**. A server started without TLS answers http on the same
port and the tunnel silently fails. Check after any restart:

    for p in 8010 8011 8012 8013 8014 8020 8021; do
      printf "%s %s\n" "$p" "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:$p/)"
    done

`000` means no TLS — fix with `symfony server:stop && symfony server:start -d` in that
project. Harvest was in exactly this state on 2026-08-29, which broke both
`https://harvest.wip` and lingua's production `translation.completed` webhook.

## Environment the stack needs

Exported from `~/.bashrc` — **not in any repo**, so the Mac needs its own copy:

    DOCKER_DATA_ROOT       # bind-mount root for postgres/redis/rabbitmq/mercure data
    IMGPROXY_KEY
    IMGPROXY_SALT
    IMGPROXY_LICENSE_KEY

`APP_DATA_DIR` is **not** exported here — the two `export APP_DATA_DIR=` lines in
`~/.bashrc` are commented out. The live value comes from each app's committed `.env`
(`/platform`). A real env var does override `.env` if you ever want it to; on macOS put it
in `~/.zshenv`, not `~/.zshrc`, or non-interactive processes (launchd, IDE-started
servers) will not see it.

## Bringing a Mac up

1. Clone what you need — 70 repos here have remotes, all pushed as of 2026-08-29 except
   the two noted below.
2. Create `/platform`:

       printf 'platform\t/Users/tac/platform\n' | sudo tee -a /etc/synthetic.conf
       mkdir -p ~/platform && sudo reboot

   Point it at a **local** directory. Mount S3 underneath at `folio-archive/` if needed —
   do not make the whole tree an S3 FUSE mount, because `doctrine.yaml` puts a SQLite file
   at `APP_DATA_DIR/folio/_bootstrap.folio`.
3. Export the four vars above in `~/.zshenv`.
4. Start the shared stack: `docker compose -f ~/sites/docker/docker-compose.yaml up -d`.
   Grist and Mattermost are `ondemand` — use grist.survos.com and chat.survos.com instead.
5. Verify with `bin/console dataset:diag`, which prints the resolved `APP_DATA_DIR` and
   what it found. Empty aggregator list = the symlink is wrong or the data is not there.

## Repos that could not be pushed

| repo | reason |
|---|---|
| `rappcal` | archived on GitHub (read-only). One local commit is stranded; the work looks like it belongs in `ccal`. |
| `aqi-desktop` | remote is `breadthe/aqi-desktop` — third party, no write access. |

## Deliberately left uncommitted

`git add -u` was used, so no untracked file could be swept in. Still on disk here only:

- **Credentials — never commit:** `ddys/.env.local.prod-backup`, `ssai/.env.local.bak-20260819`
- **Data dumps:** `harvest/*.jsonl`, `harvest/auck.zip`, `harvest/Sample13-pages.pdf`,
  `kpa/data/*.csv`, `kpa/*.jsonl` — these belong on `/platform` or S3, not in git
- **Generated:** `.phpunit.cache/`, `rut/public/{idb,pwa,workbox}/`, `*.jsonl.db`
- **Scratch:** `showcase/*.png` (13 screenshots), `showcase/.codex/`,
  `harvest/{dedup-check,terms-check}.md`

If any of those matter, copy them off before wiping this machine.

## Known-good state, 2026-08-29

mono, zm, harvest, mediary and ssai all pass `cache:clear` **and** `lint:container`.
Load settled at ~3.5 after the healthcheck fixes in this repo (peak was 35.7).
