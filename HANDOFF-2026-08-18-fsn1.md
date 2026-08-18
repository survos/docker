# Handoff — Ashburn → Falkenstein migration, 2026-08-18

Companion to `FSN1-MIGRATION-RUNBOOK.md` (the plan). This is what actually happened,
what is live, and the traps that cost real time — recorded because every one of them
presented as a different problem than it was.

## The new host

    fsn1-survos   46.225.149.37   cpx32 (4 shared vCPU / 8 GB / 160 GB)   Falkenstein
    fsn1.survos.com  → A record, grey-clouded (ssh + git push target)
    ssh fsn1         → configured in ~/.ssh/config

    volume  fsn1-platform  100 GB  ext4  → /platform   (by-id + nofail in fstab)
            vault/ work/ folio/ folio-archive/ images/     94 GB free
    system  150 GB, ~30 GB used → Meilisearch indexes live HERE, not the volume
    firewall fsn1-survos-fw: 22 + 5432 from Tac only, 80/443 public, icmp

Sizing rationale: the volume is for **durable** data (vault raw, folios); the system
disk takes **derived** data (Meili indexes, docker images). Meili at 19 GB would not
fit alongside the projected ~83 GB of platform tiers.

## Done and verified

**Postgres is now primary on fsn1.** Restored from the encrypted pgBackRest repo2
(6.5 GB / 17,313 files in ~4 min, intra-datacentre), promoted, archiving re-enabled,
first full backup taken on timeline 2, nightly cron installed. 47 databases.
`pg.survos.com` → 46.225.149.37. Query latency from a container: **0.24 ms**.

  - ash's Postgres is **stopped, not destroyed** (rollback).
  - Insurance dump: `/root/ash-final-20260818-1520.sql.gz` (1.1 GB) on the ash pg box.
  - ash's pgbackrest cron is **commented out** — re-enabling it would archive
    timeline-1 WAL into the stanza fsn1 now owns.

**imgproxy migrated** — the biggest latency win. Its source bucket and S3 result cache
were already in fsn1 while imgproxy ran in Ashburn, so every cache miss crossed the
Atlantic twice. Now all local. Proxied, Let's Encrypt cert, `cf-cache-status: HIT`.
ash's copy is stopped (also frees a Pro licence seat).

**`*.survos.com` wildcard deleted** — after pinning all 65 dependent vhosts to explicit
records. Unknown names now NXDOMAIN instead of 520.

**FrankenPHP conversions committed**: mediary (`689a476`), lingua (`4c652cc`).
harvest was already FrankenPHP.

**Cache: redis → apcu** in both mediary and harvest, because in both cases redis was
vestigial — see "Findings" below.

## Live on fsn1

| app | state | notes |
|---|---|---|
| mediary | **running, HTTPS** | mediary.survos.com + ry.survos.com + mediary-fsn1 |
| imgproxy | **running, production** | imgproxy.survos.com, proxied |
| meilisearch | **running** | 1.53.0, `ms-fsn1.survos.com`, **indexes empty** |
| harvest | running | ports just added; **no real vhost or cert yet** |
| zm | running | `zm-fsn1.survos.com`; no cert |
| fotostory | running | auto vhost only |
| lingua | configured, not deployed | 19 keys, ports, DNS, LE email ready |
| packages | configured, not deployed | 15 keys, `MEILI_SERVER=ms-fsn1` |
| ssai | configured, not deployed | 13 keys, `/platform` mount |
| ai-tools | configured, not deployed | 9 keys, shares `/platform/images` with ssai |
| libretranslate | created only | needs storage + `LT_LOAD_ONLY` decision |
| imgproxy-free | deployed, unrouted | nothing consumes it yet |

## Traps that cost time — check these first on every remaining app

**1. Missing `ports:add` = infinite redirect loop.** dokku deploys happily with no port
mapping. nginx generates a complete `:443` block with a valid cert, but the upstream has
**no members**, so every HTTPS request falls through to the `:80` block's
`return 301 https://$host:443$request_uri` — forever. The `:443` in the Location header
is the tell. Cost ~an hour on mediary, misdiagnosed twice (first as Cloudflare Flexible
SSL, then as trusted_proxies). harvest/zm/fotostory had the same gap; fixed 2026-08-18.

**2. `docker-options` are per-phase.** `build`, `deploy` and `run` are separate. Predeploy
runs in the **run** phase, so `--add-host=host.docker.internal:host-gateway` must be set on
all three or migrations fail with
`could not translate host name "host.docker.internal"`.

**3. `&&` in app.json predeploy fails under the dockerfile builder.** dokku runs it without
a shell, so `&&` arrives as a console argument:
`No arguments expected for "X" command, got "&&"`. Wrap in `sh -c '...'`. Hit by packages,
mediary, harvest. **ssai still has this unfixed.**

**4. `app.json` env `generator` entries are ignored by dokku 0.38.27.** Deploy aborts at
release with `required env var WEB_CONCURRENCY has no value, no default, and no TTY`,
*after* a successful build. 0.38.16 ran them. **ssai still has this unfixed.**

**5. Before `letsencrypt:enable`, every vhost must resolve directly to that host and be
grey-clouded.** LE fails the whole order if any one name fails. Killed two cert attempts:
a staging vhost shadowed by the wildcard's AAAA (redirect loop via Cloudflare), and
`mediary.survos.com` while it still pointed at ash.

**6. Copying "just the host-specific" config vars is not enough.** mediary booted fine and
then failed on first real use because `MEILI_*` was missing and it fell back to a `.env`
default (`dokku.survos.com:7700`, closed port). Copy everything, then override.

## Findings worth keeping

- **Redis was dead config in both apps.** mediary's `cache.yaml` read `REDIS_URL` while the
  vault defined `REDIS`; the live value fell through to `redis://localhost:6379` with
  nothing listening. harvest's only `RedisAdapter` sits behind
  `if (false) // this whole section is wrong`, and its heavy pools were already filesystem.
  If redis is ever wanted: `dokku redis:create` + `redis:link` (injects `REDIS_URL`).
- **harvest's `APP_SECRET` was `aladkjfajdfoai`** (14 chars). Regenerated to 32 hex on fsn1.
  Existing sessions invalidated.
- **NARA (233 GB) + Euro (271 GB) are 98% of the vault.** Everything else is ~9 GB. This is
  what makes a 100 GB volume viable — they go to S3, not fsn1.
- **zm's 174% CPU is bot traffic**, ~98% of requests from two spoofed Chrome UAs crawling
  the same object across every locale (`/en/f/smith/…`, `/hu/…`, `/hi/…`). Not fixed.
- **`media_record` is NOT legacy** — 72,377 rows, written today, referenced by
  `AssetRegistry`, `BatchController`, `Asset` and two workflows.
- **pgBackRest restores with `recovery.signal`, so a restored cluster AUTO-PROMOTES** when it
  exhausts WAL. fsn1 had been an independent primary on timeline 2 for hours before the
  formal cutover. For a true warm standby, use `--type=standby`.
- **mediary was down for ~2 hours unnoticed.** A FrankenPHP push to ash retired the old
  container, then predeploy's migration hit `pg.survos.com` exactly as it moved to fsn1.
  Lesson: when moving an app, verify the **production hostname**, not just the new one.

## Open decisions

- **`ry`/`mediary.survos.com` are grey-clouded**, so ~700–950 ms from the US (4–5 Atlantic
  round trips). Proxying fixes it — `imgproxy` gets 212 ms that way — but proxying `ry`
  produced a redirect loop, so this zone's SSL mode must be **Full/strict** for that
  hostname. `imgproxy` evidently has such an override. The Cloudflare token in `~/.bashrc`
  has DNS edit but **not** Zone Settings, so `/settings/ssl` is unreadable. The
  `http_config_settings` ruleset IS readable and is probably where the override lives.
- **Meilisearch on fsn1 is empty.** `ms.survos.com` still points at ash, so every app keeps
  using the old instance. Don't flip that record until the indexes that matter are rebuilt
  on fsn1. `packages` is already pointed at `ms-fsn1` as the test case.
- **ssai / ai-tools / S3 strategy has evolved and is not settled.** Both mount `/platform`
  and exchange files via `AI_TOOLS_SHARED_DIR=/platform/images` (~699 MB on ash, under 1 GB,
  nothing in flight). Don't copy it until the strategy is decided.
- **libretranslate**: needs a storage mount for ~8.7 GB of models (system disk, since they're
  re-downloadable), and a decision on `LT_LOAD_ONLY=en,es,hu,nl,fr,de,hi,da` to cut that
  down. Also currently an unauthenticated, unlimited translation API on the public
  internet — `LT_API_KEYS=true` requires a persistent `/app/db` mount.
- **`babel.survos.com` → `libretranslate.survos.com`** rename: only two consumers
  (`lingua/.env:75`, `harvest/.env.local:55`, both `LIBRE_HOST`).
- **`*.pgsc.survos.com`** wildcard still exists, pointed at ash, unexamined.
- **Stale vhost cleanup**: 72 vhosts, only ~6 production. Names like `dummy`, `php-test`,
  `custom-nginx`, `bootstrap-demo` read as dead experiments.

## Remote conventions (settled this session)

    dokku   → wherever the app CURRENTLY deploys (the dokku CLI resolves the host from this)
    ash     → dokku@ssh.survos.com:<app>
    fsn1    → dokku@fsn1.survos.com:<app>
    origin  → GitHub

Moving an app = deploy to `fsn1`, verify, then `git remote set-url dokku dokku@fsn1…`.
All 29 repos have `ash` + `fsn1`; `dokku` still points at ash except for mediary.

`deployment-bundle`'s `dokku:init` gained two checks this session (buildpack detection,
app.json generators — mono `c4a9cbc1`). It should also learn: missing `ports`, `&&` in
predeploy, and per-phase `docker-options`.
