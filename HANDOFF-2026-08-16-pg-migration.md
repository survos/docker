# Handoff — 2026-08-16 Postgres consolidation onto pg.survos.com

Continuation of [HANDOFF-2026-08-16.md](./HANDOFF-2026-08-16.md). That session built the new
cluster and moved `mediary` + `lingua`; this one moved **everything else** and rotated the
password. Same rule as before: measured, not assumed, and the things that turned out wrong are
recorded because they cost the most time.

---

## 1. What moved

**All 42 databases are now on `pg.survos.com` (PG 18.4).**

| Source | DBs | Verification |
|---|---|---|
| pg18 `178.156.199.185` | 9 — `rsun` `meili` `ssai` `zm` `kidpanalley` `openfoto` `apub` `bts` `rhs` | exact `COUNT(*)` per table + index/constraint parity, 0 restore errors |
| pg17 `5.161.107.103` | 33 — incl. `claims`, `musdig`, `bundles2`, `dt-demo`, `hh`, `ff`, `voxitour` | 1,039,809 rows, 33/33 identical |

Tooling left on dokku-ash:

* `/root/pg-migrate.sh <src_host|localhost> <db>` — dump, restore, verify. Never drops the source.
  Verification is exact `COUNT(*)` via `query_to_xml`, not `n_live_tup` estimates.
* `/root/pg-cutover.sh <app> <db> <VAR>...` — repoint an app, restart, and confirm **every running
  container** actually took the new env.
* `/root/pg-final-check.sh` — post-migration sweep for legacy host references and live connections.

**28 apps repointed.** `searchbench` also had `MESSENGER_DATABASE_URL`; `zm` also had
`MEDIARY_RO_DATABASE_URL`. Both were pointing at legacy hosts under names a `DATABASE_URL`-only
grep would miss — always inventory by *host*, not by variable name.

---

## 2. Password rotation

The `postgres` superuser password on **pg.survos.com only** was rotated to 48 hex chars.
Stored at `/root/.pg-new-password` (mode 600); `/root/.pgpass` updated for both
`pg.survos.com` and `178.156.255.32`. Old password is confirmed **rejected** on the new cluster.

Hex charset deliberately — it needs no URL-encoding inside a `DATABASE_URL` and no shell quoting.

Rotating *before* the bulk cutover meant each app got exactly one `config:set` instead of a
second sweep over 40 apps.

> The leaked password remains valid on pg17 and pg18 until those clusters are destroyed.
> **Rotation is not complete until decommission.** pg17 and pg18 turned out to have
> *different* passwords from each other — "the shared password" was really two.

---

## 3. Corrections — checked and wrong

**`dokku ps:restart` does not replace a crash-looping container.** After rotating, `lingua` served
500s. `dokku config:get` showed the new password, `lingua.web.1` had the new password, and `psql`
with that exact password connected fine — but `lingua.translator.1` sat in `restarting` with the
old env and never got swapped. `ps:stop` + `ps:start` fixes it. `pg-cutover.sh` now verifies every
container and falls back automatically; `chad` and `packages` hit the same path during the bulk run.
Symptom to recognise: "the new credential doesn't work" when it demonstrably does.

**A vaulted `DATABASE_URL` may or may not be overridden by `dokku config:set` — it depends on
whether the app decrypts the vault to disk.** `ssai` and `bts` keep theirs in the Symfony vault and
show nothing in `dokku config`; setting the var in Dokku moved them with no repo change, because
the vault is read at runtime and loses to a real environment variable. But apps whose `app.json`
predeploy runs `secrets:decrypt-to-local --force` materialise the vault into `.env.prod.local`
first, and that file then *wins* — see §4a. Do not generalise from the `ssai`/`bts` result.
Corollary: a per-container env check that skips containers lacking `DATABASE_URL` reports "0
containers" for vaulted apps and looks like success.

**`sudo -u postgres pg_dump -f /root/...` fails silently-ish.** The `postgres` user cannot write to
`/root`; all 33 pg17 dumps failed with `Permission denied`. Connecting over TCP as `postgres`
(`.pgpass` has a `localhost` entry) lets root own the output file. No partial state resulted —
the script exits before creating the target DB.

**imgproxy presets are `pr:<name>`, not `/<name>/`.** A bare `/thumb/<src>` returns 404 *with a
valid signature* ("Source is unreachable"), which reads like a preset failure and isn't.
Production traffic uses explicit options (`rs:fit:400:400/q:80/f:webp`) and never exercises the
presets at all.

**Byte-identical responses do not prove a config cutover worked** — S3 result caching returns the
same bytes regardless. Verify with a never-requested variant (forces a render) and check actual
pixel dimensions. Presets confirmed: 312×512 / 781×1280 / 1830×3000.

**`file(1)` will not give you WebP dimensions**, and a hand-rolled VP8 parser reading width at
`i+10` yields nonsense like `13x79617`. For lossy `VP8 `, width is at chunk offset +14, after the
3-byte frame tag and the 3-byte `9d 01 2a` sync code.

---

## 4. Pre-existing breakage found (NOT caused by this migration)

1. **`lingua.legacy_source` / `legacy_target` are dead.** Both are `postgres_fdw` foreign tables on
   server `legacy_trans` → `5.161.107.103/trans3`, and `trans3` was dropped in the previous
   session. Any query touching them errors. The real data is local (`target` = 3,133,943 rows), so
   these look like a consumed import aid — but confirm before dropping the server and mappings.
2. **`kpa` was pointing at an empty database.** pg17's `kidpanalley` had 15 tables and 1 migration
   row, all data tables at 0. pg18's had the real content — 2,521 songs, 448 videos — under an
   older 7-table schema with 7 migration rows. Per decision this session, `kpa` now points at the
   real data on the new cluster; **it may need `doctrine:migrations:migrate`** to reconcile the
   schema gap.
3. **`voxi-staging` returns 500** — its `voxi-staging` database does not exist on any cluster.
4. **`globalgiving`** references `global_giving`, which likewise exists nowhere (the app still
   returns 200; the homepage evidently does not touch the DB).
5. **Cloudflare "Flexible" SSL redirect loops** on `ssai`, `searchbench`, `openfoto.survos.com` —
   `Location` carries `:443`. Fixed in the Cloudflare dashboard, not the app.
6. **`openfoto.org` is not served by dokku-ash** (resolves to 3.33.251.168 / 15.197.225.128). The
   `openfoto` app serves `fotostory.org`.

---

## 4a. THE BLOCKER — `dokku config:set` is not the source of truth for 16 apps

pg17 was stopped as a live test. **16 apps immediately 500'd**, all with
`connection to server at "5.161.107.103" ... Connection refused` — while their
`dokku config` and their *container env* both correctly read `pg.survos.com`.
pg17 was restarted; total outage ~2 minutes, all 16 recovered.

**Why.** Symfony's `Dotenv::populate()` skips a variable only when
`isset($_SERVER[$name]) && !isset($_ENV[$name])`. In these containers `$_ENV` *is*
populated, so the guard fails and the `.env*` file **overwrites the real environment
variable**. A committed `.env` therefore beats `dokku config:set`, silently.

Two sources, measured per app inside the running containers:

| Source | Apps |
|---|---|
| legacy URL in committed **`.env`** | 15 — `ai-batch` `barcode-demo` `ccal` `dummy` `ff` `gist` `member-directory` `pgsc` `pwa-last-stack` `settings-bundle-demo` `show` `stimulus-tutorial` `ux-search-demo` `musdig` `kpa` |
| also **`.env.prod.local`** | `kpa` |
| also **`config/secrets/prod/prod.DATABASE_URL.*`** | `kpa`, `member-directory` |
| neither (cause not yet identified) | `ezt` |

`.env.prod.local` is not in git and not a Dokku artefact — it is generated at deploy
time by `app.json`:

```json
"predeploy": "... && bin/console secrets:decrypt-to-local --force && ..."
```

which writes the whole prod vault into `.env.prod.local`, where it then outranks
Dokku config. This is why "remove it from the production vault" is **required**, not
cleanup: while a vaulted `DATABASE_URL` exists, no `dokku config:set` can move the app.

**Fix per app:** drop `DATABASE_URL` from `.env` (and from the vault where present),
commit, redeploy, then re-test with pg17 stopped. Until then pg17 **cannot** be shut
down. Note the data is already fully migrated and verified — this is purely about
which URL the app reads.

---

## 5. DONE — both legacy clusters are retired

**§4a is resolved, and the diagnosis in it was wrong about the source.** The stale pg17 URL was
never a committed `.env` — `git show HEAD:.env` is clean in every repo checked. Dokku's
`builder-herokuish/pre-build` does this at **build** time:

```
config_export app "$APP" --format envfile --merged >> "$TMP_WORK_DIR/.env"
```

It appends the whole app config onto `.env` and bakes it into the image, so each image carries a
frozen snapshot of `dokku config` from its last build. `config:set` updates the runtime variable;
the stale baked line then outranks it. **The fix is `dokku ps:rebuild`** — no repo edits, no
`git push`. All 16 apps re-baked and verified.

`kpa` was the one exception: its `app.json` predeploy runs `secrets:decrypt-to-local --force`,
writing `.env.prod.local`, which outranks even a freshly baked `.env`. That needed the vault entry
dropped (`survos-sites/kpa`, commit *Drop DATABASE_URL from the prod vault*).

**pg17** — stopped, disabled and `systemctl mask`ed on dokku-ash. Verified by stopping it and
probing 30 apps: all healthy. The two that flagged were false positives — `stimulus-tutorial` (103,
Early Hints) and `voxitour` (500) return identical codes with pg17 *running*.

**pg18** — server `110012725` and volume `103620223` deleted 2026-08-17 after verifying no
connections, no config references, all 11 databases present on the new cluster, and a
`gzip -t`-clean 719 MB dump with all 11 `CREATE DATABASE` statements. Volume held only
`/pgdata/18/main` + `lost+found`; `archive_command` was still the `cd .` placeholder, so there was
no WAL archive to lose. **Saving: €62.49/mo + ~€5/mo.**

Retired alongside: `voxitour` and `stimulus-tutorial` (web=0, databases dropped, README notices
added). ⚠️ `voxitour` shared its database with **`vt`**, which is live — `vt` was given its own `vt`
database first. `vt` itself is an orphan: composer name `survos-sites/vt`, but no such repo exists
in any org, and `ps:rebuild` fails on the PHP buildpack, so it runs on an unreproducible image.

Backup crons: the pg17 and pg18 jobs are removed (`/root/crontab.bak-20260817`). Only
`0 3 * * * /root/.postgres-new.sh` remains → `pg.survos.com`.

## 6. Open

1. **pgBackRest — the real remaining gap.** `archive_mode=off`, `wal_level=replica`, single node,
   no standby, no replication slots. 47 databases / 6.7 GB now depend on **one nightly logical
   dump**, so worst-case loss is up to 24 hours. Enabling it needs a postgres **restart**
   (`archive_mode` is not SIGHUP-able), which now touches every app rather than the two it would
   have yesterday. pgBackRest ships inside the timescaledb-ha image.
2. **`claimsdb.survos.com` still points at the dead pg17 address.** Its three consumers
   (`mediary`, `musdig`, `zm`) were pointed straight at `pg.survos.com/claims`, since the rotation
   forced a URL rewrite anyway. Repoint the record to `178.156.255.32` or retire it — an alias
   aimed at a decommissioned host is the one landmine left.
3. **`/mnt/volume-1/postgresql` — 32 GB of dead pg17 data**, reclaimable. `docker-data` is 264 GB
   and likely holds prunable images. The volume is 1.2 T of 2 T used; `platform-data/vault` (687 G,
   md's media) is live data, not cruft — the pre-S3 `images` dir is only 699 M.
4. **`elastic-test` still billing** at €0.1931/hr.
5. `mediary_ro`, `pgbouncer`, `replicator` roles existed on pg18 and were **not** recreated on the
   new cluster — nothing in Dokku config referenced them (every app connects as `postgres`).
6. `kidpanalley_v2` (empty) still exists; a local `.env.local` points at it.
