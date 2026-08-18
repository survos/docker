# fsn1 migration runbook

Moving Survos infrastructure from Ashburn to Falkenstein, app by app, starting
with the two anchors (**mediary**, **lingua**) and the Postgres cluster.

Drafted 2026-08-18. All figures below were measured, not assumed.

## Why

| | |
|---|---|
| mediary's S3 bucket (`museado`) is already in fsn1 | every image upload crosses the Atlantic today — **110 ms** per connection |
| the new CPX/CX generation is **not sold in `ash` or `hil`** | staying put means staying on retired hardware with no upgrade path |
| EU included traffic | **3 TB → 30 TB** on the same CCX33, for €2.50/mo less |
| `dokku-ash` load average | **19.71 on 8 cores** (87 containers) |

## The ordering constraint that drives everything

Measured from `dokku-ash`:

| to | connect |
|---|---|
| current Postgres (ash) | **2.3 ms** |
| fsn1 | **108 ms** |

47× per round trip. A Symfony request making 30 queries goes from ~70 ms of
database wait to ~3.2 s. So **apps and their database must land in the same
datacentre in the same window.** Moving either one alone is worse than doing
nothing.

The database splits conveniently:

| database | size |
|---|---|
| mediary | 4,089 MB |
| lingua | 2,025 MB |
| all 45 others | ~860 MB |

The two anchors are **90% of the cluster**. Move them together with Postgres,
and the apps left paying 108 ms are demos with tiny databases — by design.

## Inventory

| resource | id | address | notes |
|---|---|---|---|
| `dokku-ash` | 30263761 | 5.161.107.103 | CCX33, 71 apps, 87 containers |
| `pg-survos` (ash) | 162360797 | 178.156.255.32 | CPX31, PG 18.4, 47 dbs / 6.8 GB |
| `fsn1-survos` | 162595219 | 46.225.149.37 | CPX32, **created, empty** |
| `volume-ash-1` | 100223066 | — | 2 TB, 850 G used, cannot cross locations |
| `pg-survos-fw` | 11473346 | — | template for the new firewall |

Postgres image is pinned: `timescale/timescaledb-ha:pg18.4-ts2.29.1-all`.
Never use the floating `pg18-all` tag.

---

## Phase 0 — DNS and naming (Tac only; no Cloudflare access from here)

Naming: one A record per **machine**, service names as CNAMEs onto it, so moving
a service later is one CNAME change.

Everything below carries raw TCP (ssh 22, Postgres 5432) and **must be
grey-clouded** (`proxied: false`). The orange cloud only carries HTTP/HTTPS;
proxied records answer 520 for anything else.

1. Create **`fsn1-pg.survos.com`** → `46.225.149.37`, grey-clouded.
2. Create **`fsn1-dokku.survos.com`** → (Phase 2 host), grey-clouded.
3. Leave `pg.survos.com` pointing at ash until Phase 3 cutover. TTL is **120 s**,
   so the switch propagates fast — do not raise it.
4. **Remove the wildcard `*.survos.com`.** It is proxied at a dead origin, so
   every typo and retired demo answers 520 instead of NXDOMAIN. Before removing,
   confirm no app still relies on a wildcard subdomain:

       ssh dokku@ssh.survos.com domains:report

Then update `~/.ssh/config`: switch `Host fsn1` from the IP to
`fsn1-pg.survos.com` (the TODO is already in the file).

---

## Phase 1 — Postgres on fsn1

`fsn1-survos` exists and is reachable (`ssh fsn1`) but is otherwise bare.

### 1.0 Host limits — inotify, not inodes

Set on fsn1 in `/etc/sysctl.d/60-survos-file-limits.conf`:

    fs.inotify.max_user_watches  = 1048576   (stock 60132)
    fs.inotify.max_user_instances = 1024     (stock 128)

**This is deliberately not an inode change.** Inodes came up as the suspected
limit; measurement says otherwise, and the knob does not exist anyway:

| filesystem | inode use |
|---|---|
| fsn1 `/` | 334,560 / 9,888,528 — **4%** |
| ash `/` | 257,305 / 2,427,136 — 11% |
| ash `/mnt/volume-1` | 6,170,914 / 131,072,000 — **5%** |

Even 6.2M files on the 2 TB volume is 5%. And on ext4 the inode count is fixed at
`mkfs` time — it cannot be raised on a live filesystem, only by recreating it.

The real constraint is **inotify watches**: Meilisearch (LMDB), Symfony's cache
tree and dockerd all register many, and stock 60132 is easy to exhaust on a
multi-app host. Worth knowing because the failure is disguised — inotify returns
`ENOSPC`, which surfaces as **"no space left on device" on a disk that is nearly
empty**, sending you to `df` (fine) instead of `sysctl` (exhausted). Ashburn has
run 1048576 for years; fsn1 now matches.

Also note `ulimit -n` is 1024 for login shells on fsn1. Systemd services get their
own `LimitNOFILE`, so this has not bitten yet — but Meilisearch documents needing
a high open-files limit, and it should be set explicitly when Meili moves here.

### 1.1 Firewall first

It currently has **no firewall** — Postgres must never listen before this
exists. Mirror `pg-survos-fw` (id 11473346):

| rule | port | source |
|---|---|---|
| SSH | 22 | Tac's IP `/32` |
| Postgres | 5432 | fsn1 dokku host `/32`, Tac's IP `/32` |
| ICMP | — | any |

During the transition `dokku-ash` (5.161.107.103) also needs 5432 — remove that
rule once the last app leaves ash.

### 1.2 Docker + the pinned image

    ssh fsn1
    # install docker engine, then:
    git clone <survos/postgres> /root/postgres && cd /root/postgres
    # .env: POSTGRES_PASSWORD, POSTGRES_STORAGE_ROOT
    docker compose up -d --build

Keep pgdata off the root filesystem. Ownership requirements on this image
previously forced a named-volume workaround — see survos/docker#1 before
choosing a bind mount. On ash it resolved to the docker volume `root_pgdata`.

### 1.3 pgBackRest — the restore IS the migration

repo2 is already S3 **in fsn1**, so the restore is intra-datacentre: ~1 GB
compressed rather than 22 GB of PGDATA across the Atlantic. It is a *physical*
restore, so roles, passwords and settings all come across — which matters,
because one shared superuser password is currently reused across ~40
`DATABASE_URL`s.

Current state (verified): stanza `survos`, status ok, full backups 2026-08-17
plus daily diffs, continuous WAL archiving, `aes-256-cbc` on repo2.

⚠️ **Without `/root/.pgbackrest-cipher-pass` repo2 is unrecoverable.** Copy it
from the ash pg node (a copy also exists on dokku-ash) *before* touching
anything. Verify it decrypts by running `pgbackrest --stanza=survos info`
against repo2 from fsn1 while ash is still serving.

Copy `/var/lib/docker/volumes/root_pgdata/_data/backup/pgbackrest.conf`, keeping
repo2 and dropping repo1 (repo1 is the old host's local disk).

### 1.4 Pre-seed with zero downtime

Restore the latest backup while ash is still live. Nothing has cut over; this is
a rehearsal that also satisfies the standing "verify a restore, not just a
backup" requirement.

    pgbackrest --stanza=survos --repo=2 --delta --archive-mode=off restore

**`--archive-mode=off` is not optional.** ash is still the primary and is still
pushing WAL to this stanza. A restored cluster with archiving on would push to
the same repo, and two primaries writing one backup chain corrupts it — taking
out the backup you are in the middle of relying on.

#### ⚠️ The restore_command path trap (hit for real, 2026-08-18)

pgBackRest bakes the `--config=<path>` you used **into the generated
`restore_command`** in `postgresql.auto.conf`. Restore from a throwaway
container with the config bind-mounted at `/tmp/pgb.conf` and the *running*
Postgres inherits a path that does not exist in its own container. WAL fetch
then fails and startup dies with:

    FATAL: could not locate required checkpoint record at 3/A3000080
    HINT:  If you are restoring from a backup, touch ".../recovery.signal"

which is misleading — `recovery.signal` is present and correct; the real fault
is an unreachable `restore_command`.

So: **put pgbackrest.conf somewhere both containers can read, before restoring.**
Inside the pgdata volume is the right answer, and is why the Ashburn node keeps
its config at `/home/postgres/pgdata/backup/pgbackrest.conf` with
`/etc/pgbackrest.conf` symlinked to it, rather than at `/etc`. On fsn1 it lives
at `/home/postgres/pgdata/pgbackrest.conf`.

To repair a cluster already restored with a bad path, rewrite it in place:

    sed -i 's#--config=/tmp/pgb.conf#--config=/home/postgres/pgdata/pgbackrest.conf#' \
      /home/postgres/pgdata/data/postgresql.auto.conf

#### Result, 2026-08-18

Verified end to end on fsn1: 6.5 GB / 17,313 files restored in **~4 minutes**
(intra-datacentre from repo2), 47 databases present, sizes matching ash within
the writes ash took after the 01:00 backup. The cluster stays in
`pg_is_in_recovery() = t` — a warm standby replaying from repo2, **not** a second
primary. Promotion is a cutover step, not a rehearsal step.

---

## Phase 2 — dokku host on fsn1

Create a **CCX33 in fsn1** (€138.49/mo, 30 TB traffic, dedicated cores).
Both hosts run in parallel during the transition.

Install **dokku 0.38.27**, not 0.38.16. Eleven patch releases, no major jump.
Worth having:

- **#8848** — prevent command injection via docker options eval *(security)*
- **#8833** — parse cert CN/subject on OpenSSL 3.x *(you run Let's Encrypt)*
- **#8907 / #8930** — ENV file migration; a fresh install starts on the new
  format instead of migrating into it
- **#8906** — match docker options by shell word when removing
- **#8920** — storage directory mode/removal flags

A clean install skips the in-place upgrade risk on a box at load 19.71.

### 2.1 Plugins

Core plugins ship with dokku. These are community and need explicit install —
versions currently on ash:

| plugin | version |
|---|---|
| letsencrypt | 0.20.4 |
| postgres | 1.36.0 |
| redis | 1.42.2 |
| rabbitmq | 1.38.11 |
| mysql | 1.40.0 |
| mongo | 1.36.11 |

Install only what the migrated apps actually need. `rabbitmq` is worth having
early given the planned jwage/phpamqplib + RabbitMQ standardisation.

### 2.2 Service policy — deliberate, not inherited

- **Use dokku plugin services** (`redis:create` + `redis:link`). Dokku owns the
  lifecycle, `link` injects the URL, and the dependency is visible in
  `redis:info`.
- **No system services.** Shared apt-installed daemons are invisible to dokku
  and are how the current shared-password situation arose.
- **Postgres stays on its own node** (Phase 1), not a dokku service. This is
  survos/docker#5 option B, and `dokku-ash` at load 19.71 is the argument.
- Share a service across apps only via an explicit `link`, never implicitly.

### 2.3 Deploys are `git push dokku`

No pre-baked images, no rsync of `/home/dokku` or `/var/lib/dokku`. Each app is
deployed deliberately from its own repo, which is the whole point of moving one
at a time.

---

## Phase 3 — cutover: mediary + lingua + Postgres

One window. Order matters.

1. **Freeze writes.** Scale mediary and lingua to 0 on ash
   (`ps:scale <app> web=0 …`). Their workers are already at 0.
2. **Final backup on ash:** `/root/pgbackrest-backup.sh diff`, and confirm the
   final WAL segment archived to repo2.
3. **Stop Postgres on ash.** Everything still on ash that uses the database now
   fails — expected, and the reason the leftovers are demos.
4. **Restore + replay on fsn1** from repo2 to the latest WAL. Zero data loss.
5. **Per-app roles.** Before pointing apps at it, give mediary and lingua their
   own database users instead of the shared superuser. You are editing every
   `DATABASE_URL` anyway; doing it now avoids a second coordinated outage. The
   45 apps still on ash keep the old credentials until their own move.
6. **DNS:** repoint `pg.survos.com` → `46.225.149.37`, still grey-clouded
   (120 s TTL). Apps left on ash follow it automatically and get the 108 ms
   penalty — accepted.
7. **Deploy** mediary and lingua to fsn1-dokku via `git push dokku`, with
   `MEDIARY_ENDPOINT` / callback URLs updated to the new host.
8. **Point app domains** at fsn1-dokku and let Let's Encrypt issue.

### Verify before declaring done

- All 47 databases present with matching sizes (`mediary` 4,089 MB,
  `lingua` 2,025 MB)
- mediary `/health` 200; a batch POST round-trips
- **mediary → S3 connect time** should collapse from ~110 ms to
  intra-datacentre — this is the whole point, so measure it
- harvest (still on ash) can still reach mediary and its callbacks arrive

---

## Phase 4 — the volume, deferred deliberately

The 2 TB volume is **€114.40/mo** and holds 850 G. It cannot cross locations, so
it must be copied — which is why it is worth shrinking *first*:

1. Run `lsof +L1 /mnt/volume-1` as root. `du` reports 595 G while `df` reports
   850 G; part of that gap is `/mnt/volume-1/docker-data`, but deleted-but-open
   handles from the recent purge are likely too. Restarting the holders reclaims
   that for free.
2. Move the **NARA and Euro archives** to a bucket — roughly half the space, and
   already identified as good S3 candidates.
3. Only then create a 1 TB volume in fsn1 and copy. Volumes can be **grown**
   later but never shrunk, so 1 TB is a floor, not a commitment.

Copying 850 G transatlantic before doing (1) and (2) is the expensive mistake
this phase exists to avoid.

## Open questions

- Does `fsn1-survos` (CPX32, 4 shared vCPU / 8 GB) stay the database node, or
  does Postgres want dedicated cores (CCX23, €85.99)? Current load is low and
  the README says the DB is not hit hard, so CPX32 is defensible — revisit if
  query latency shows CPU steal.
- Which of the 71 apps are never moving? Each one left on ash keeps `dokku-ash`
  and its 2 TB volume alive, so the list determines when Ashburn can be retired
  entirely.
- Consolidating the "Storage Box Migrated" project into `museado` — object
  storage is no longer beta-separate. Check whether buckets can move between
  projects or need recreation; if the latter, it forces a credential rotation
  across mediary, harvest and ssai, which should be planned rather than
  discovered.
