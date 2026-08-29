# Handoff — Ashburn → Falkenstein, 2026-08-18 (session 2)

Continues `HANDOFF-2026-08-18-fsn1.md`. Same day, later session. That document's
"Traps that cost time" list is still correct; this one adds five more and records
one hard blocker that needs a credential decision before certs can proceed.

## Done and verified

**fotostory was broken on fsn1 and is now serving.** It returned 502 through the
proxy. Not the missing-ports trap — the map existed but was *wrong*:
`http:80:80` while the container listens on **5000** (still herokuish, so
`$PORT=5000`; only the FrankenPHP apps listen on 80). Fixed with
`dokku ports:set fotostory http:80:5000`. Now HTTP 200, "FotoStory — Photo Archives".

  - `fotostory.survos.com` created: A → 46.225.149.37, **grey**, TTL 120.
  - No cert yet (deliberate — see the SSL blocker below).
  - Push path verified: `dokku@fsn1.survos.com`, dokku 0.38.27, deployed `GIT_REV`
    matches local HEAD.

**Beszel monitoring is live** at `https://beszel.survos.com` (hub 0.18.8).
Deployed as a dokku app via `git:from-image`, so it inherits the same nginx / LE /
DNS conventions as everything else.

  - Hub on :8090, persistent `/beszel_data` (PocketBase db + keypair survive redeploys).
  - LE cert issued; **`letsencrypt:cron-job --add` was never run on this host** — it
    is now, which also covers imgproxy and mediary.
  - Agent is a plain container: `--network host`, docker.sock ro,
    `/platform` mounted at `/extra-filesystems/platform` so both disks are tracked.
    Port 45876 is not in `fsn1-survos-fw`, so it is host-only.
  - Cost: 12 MiB total (hub 9.6 + agent 2.6).
  - **The admin account is still unclaimed** (`/api/collections/users/records` →
    `totalItems: 0`). Beszel makes the *first visitor* superuser. Claim it.
  - Add the system as host `172.17.0.1`, port `45876` (bridge→host verified reachable).

**ssai is staged but NOT deployed.** Three commits on `main`, none pushed to fsn1:

    e7b9eb8  app.json: WEB_CONCURRENCY generator -> value; wrap && predeploy in sh -c
    3bd785c  (Tac) update libraries, fix migration
    c6e10b2  composer stability tightened; php-qrcode dev-main -> 6.0.1

Next step is literally one command:

    cd ~/sites/ssai && git push fsn1 main

fsn1 state confirmed ready: ports `http:80:5000`, docker-options on **all three**
phases, `/platform` mounted, 13 config keys matching ash (`DATABASE_URL` correctly
`host.docker.internal`), `ssai` database present, `SYMFONY_DECRYPTION_SECRET` set,
`/health` is a real route (`survos_tabler_health`), DNS `ssai-fsn1.survos.com` resolves.

Migration state on fsn1: last applied is `Version20260813101245`. **`depot` table
does not exist**; `Version20260815150748` is the only pending migration and has not
yet run against a real deploy.

## The blocker: certificates cannot proceed without a Cloudflare permission

Every remaining app needs a cert, and none can get one until this is resolved.

The token in `~/.bashrc` is **DNS-only**. Measured, not assumed:

| endpoint | result |
|---|---|
| DNS records read/write | works |
| `/rulesets` (list) | works |
| ruleset **contents** | `request is not authorized` |
| `/zones/{id}/settings/ssl` | `9109 Unauthorized` |

The previous handoff assumed `http_config_settings` was readable. It is not — only
the *list* is. So imgproxy's per-hostname override can be seen to exist but not read
or copied. The Cloudflare MCP server is also unavailable in a non-interactive session.

**Zone SSL modes differ, and this matters more than it looks:**

| zone | `http_config_settings` ruleset | SSL mode | evidence |
|---|---|---|---|
| `survos.com` | **yes** (`8d7e4ef7…`) | mixed | imgproxy works proxied; `ry` looped |
| `museado.org` | **none** | **Flexible** | zm has no origin cert, origin `:443` → `000`, yet edge serves 200 |
| `fotostory.org` | not checked | **Full** | ash origin `:80` → 301 to https, proxied, and it does *not* loop |

Consequence: `letsencrypt:enable zm` **will take museado.org down.** Installing a cert
makes dokku add `return 301 https://…` on :80; Cloudflare Flexible then loops it
forever. This is the same failure that cost an hour on `ry` and was misdiagnosed twice.

Tac chose "flip SSL mode to Full (strict) first". Note the deadlock that creates:
under Full (strict) with no origin cert, Cloudflare cannot reach the origin at all,
so **HTTP-01 validation cannot complete** — the cert can never be issued that way.
The escape is DNS-01, which the plugin does support (`letsencrypt:report` shows a
`dns provider` property, currently empty) and the DNS-only token is sufficient for.

To unblock, one of:
  - a token with **Zone Settings:Edit** (+ Rulesets:Edit for per-hostname overrides), or
  - Tac flips both zones to Full (strict) in the dashboard.

Correction to something said in-session: grey-clouding first is *not* zero-downtime
either. A grey-clouded hostname with no origin cert means `https://` hits a server
with no TLS listener for that name — a real outage until LE completes (~30s).
Both orders have a window; DNS-01 is the only path with none.

## zm — three independent blockers, none fixed

1. `zm.fsn1-survos` is in the vhost list and is **NXDOMAIN**. LE fails the whole
   order if any one name fails (trap 5). Drop it before attempting a cert.
2. `*.museado.org` is a **wildcard** — HTTP-01 cannot issue wildcards, ever. Needs
   DNS-01. It is live: `tobacco.museado.org` returns 302.
3. museado.org is proxied on Flexible — see above.

zm's vhosts today: `zm.fsn1-survos zm-fsn1.survos.com museado.org www.museado.org *.museado.org`

Also worth watching: **zm's RSS grew 252 MiB → 422 MiB in ~10 minutes.** It is the
largest PHP consumer on the box and the app the previous handoff flags as taking
sustained bot traffic. Beszel is now recording this; check it before assuming a leak.

## fotostory.org — move is planned, NOT executed

Deferred to another session at Tac's request. What's established:

  - **`openfoto.org` is not ours** — resolves to `15.197.225.128 / 3.33.251.168`
    (parking) and is not in the Cloudflare account. The live domain is `fotostory.org`.
  - ash's `openfoto` app already serves `openfoto.survos.com fotostory.org
    www.fotostory.org *.fotostory.org`.
  - All three `fotostory.org` records → `5.161.107.103` (ash), **proxied**, TTL auto.
  - Zone is **Full**, so fsn1 needs a valid cert on `:443` *before* the DNS switch,
    or it will 526 / refuse.

Safe order (do not reverse — this is exactly how `harvest.survos.com` broke):

    1. dokku domains:add fotostory fotostory.org www.fotostory.org '*.fotostory.org'
    2. issue the cert on fsn1 via DNS-01 (wildcard requires it) while DNS still → ash
    3. verify fsn1 origin :443 serves a valid cert for the name
    4. only then repoint the three A records to 46.225.149.37, keeping proxied=True

## Still open from the earlier list

  - **harvest**: `harvest.survos.com` already points at **fsn1** and is **proxied**,
    contradicting the previous handoff's "still resolves to ash". harvest has no vhost
    for that name, so mediary's `MEDIA_CALLBACK_URL` / `LINGUA_CALLBACK_URL` are
    landing on dokku-errors, not ash. Likely a live breakage, not a pending move.
  - **lingua**: untouched this session.
  - **ssai on ash serves `scanstation.ai`** (`scanstation.ai www.scanstation.ai
    *.scanstation.ai scanstation.survos.com`). fsn1 has only `ssai-fsn1.survos.com`.
    Another wildcard, so another DNS-01 case. Do not turn ash off before moving these.
  - ash's ssai is already degraded: `Running: mixed`, `messenger_image_enrich` 1/2/3
    `missing`, and **0 messenger containers actually running**. Three scaled proctypes
    (`messenger_async`, `messenger_intake_enrich`, `messenger_intake_processing`) no
    longer exist in the Procfile and will silently drop on the next deploy.

## Capacity note

fsn1 is at **3.9 GiB available of 7.6 GiB, with no swap at all**. `survos_pg` alone
is 2.06 GiB (27%). All web apps together are ~800 MiB.

ash's ssai is *scaled* to 25 messenger workers at `-d memory_limit=512M`. None are
running, so the move carries no worker load today — but scaling them up on fsn1 would
consume the entire remaining headroom, and an OOM here now kills the Postgres primary
for all 49 databases. Add swap or resize before scaling workers.

FrankenPHP will not help this. Measured baseline RSS on fsn1:

| app | builder | RSS |
|---|---|---|
| fotostory | herokuish | **20.4 MiB** |
| harvest | FrankenPHP | 83.7 MiB |
| mediary | FrankenPHP | 185.4 MiB |
| zm | FrankenPHP | 421.9 MiB |

FrankenPHP worker mode keeps a booted Symfony kernel resident per worker — that is
why it is fast and why its baseline is high and flat. It buys latency and CPU, and
costs steady-state RAM. Messenger consumers are CLI processes and are unaffected
either way.

## Traps to add to the list

**7. A ports map can be WRONG, not just missing.** `ports:report` showing a map is not
enough — compare `Ports map:` against `Ports map detected:`. When they disagree, dokku
detected the truth and the configured value is stale (usually copied from a FrankenPHP
app, which listens on 80, onto a herokuish app, which listens on 5000). Symptom is a
502, not the infinite redirect of trap 1.

**8. letsencrypt 0.25.1 ignores `DOKKU_LETSENCRYPT_EMAIL`.** It requires
`dokku letsencrypt:set <app> email <addr>`. The config var silently does nothing and
`letsencrypt:enable` fails with "Cannot request a certificate without an e-mail address".

**9. Trap 3 (`&&` in predeploy) is dockerfile-only.** Under herokuish, dokku runs
predeploy through a shell and `&&` is fine. fotostory and ssai both build with
herokuish, so their `&&` chains were never the problem. Wrapping in `sh -c` is still
worth doing pre-emptively so a later FrankenPHP conversion doesn't reintroduce it.

**10. SQLite-flavored migrations keep landing in ssai.** `Version20260815150748` had
`BOOLEAN NOT NULL DEFAULT 0` (Postgres: "column is of type boolean but default
expression is of type integer") and a `__temp__`/`CLOB`/`DATETIME` rebuild in `down()`.
`Version20260730020140` already exists as a "postgres-correct replacement" for an
earlier batch, so this is recurring. Scan before deploying:

    grep -lE "__temp__|CLOB|\bDATETIME\b|BOOLEAN NOT NULL DEFAULT [01]\b" migrations/*.php

That same migration also assumed a `depot` table that **no migration has ever created**
— it only existed where `doctrine:schema:update` built it. Rewritten to create the
table and add the column, both verified against the live database in a rolled-back
transaction.

**11. Verify destructive migrations against real row counts first.**
`Version20260813101245` drops 4 tables and a column from 5 more. Only `ai_task_run`
held data (239 rows, 188 done / 51 failed, all 2026-05-19) — dumped to
`/root/ssai-ai_task_run-20260818.sql.gz` on fsn1 before the fact. It is a log/cache
table; the real AI data lives in `claims`. `pending_steps` was `[]` in every row of
all five tables, so no loss there.

## Findings worth keeping

  - **`survos/meili-bundle` requires `meilisearch/meilisearch-php dev-main as 2.0.0`.**
    That, not an experiment in ssai, is why ssai needed `minimum-stability`. The root
    `dev-main` constraint is what satisfies the transitive requirement; removing it
    breaks resolution. The fix belongs in meili-bundle. ssai is now
    `minimum-stability: stable` + `prefer-stable: true` with that one exception,
    down from "any transitive dep may be a pre-release".
  - `survos/tabler-bundle` at 2.24.14 is **current**, despite mono being tagged 2.24.21.
    No commit has touched `bu/tabler-bundle` since 2.24.14, so monorepo-builder never
    cut it a newer split tag. GitHub and Packagist agree. lingua is the outlier at 2.7.23.

---

# Session 2b — four apps moved (fotostory, pgsc, vt, mattermost)

## The method that works: DNS-01 before the DNS flip

Zero-downtime moves, repeatable per app:

    1. dokku domains:set <app> <real names>     # drop the *.fsn1-survos auto vhost (NXDOMAIN kills the LE order)
    2. dokku letsencrypt:set <app> dns-provider cloudflare
       dokku letsencrypt:set <app> dns-provider-CLOUDFLARE_DNS_API_TOKEN <token from ~/.bashrc>
       dokku letsencrypt:set <app> email <addr>
    3. dokku letsencrypt:enable <app>           # DNS-01 never touches nginx, so ash keeps serving
    4. verify: openssl s_client -connect 46.225.149.37:443 -servername <name>
       verify: curl --resolve <name>:443:46.225.149.37 https://<name>/
    5. only then repoint the A record

This dissolves the blocker recorded above. The DNS-only token is **sufficient** for
DNS-01 — Zone Settings is only needed to change SSL mode, which this approach avoids.

## Proxied vs grey, settled empirically

| zone | mode | evidence | after cert |
|---|---|---|---|
| `fotostory.org` | Full | ash origin :80 → 301, proxied, no loop | **keep proxied** |
| `chijal.org` | Full | ash has a real cert, proxied, no loop | **keep proxied** |
| `survos.com` | **Flexible** | cert-less apps 200; `searchbench` (has cert) **loops**; `openfoto.survos.com` looped the moment I issued its cert | **must go grey** |
| `museado.org` | **Flexible** | zm has no cert, origin :443 refuses, edge serves 200 | must go grey |

Rule: **a `survos.com` hostname that gains an origin cert must be grey-clouded**, unless
someone adds a per-hostname override (imgproxy has one; the token cannot read or write them).

## Moved and verified live

| app | names | notes |
|---|---|---|
| **fotostory** | `fotostory.org`, `www`, `*.fotostory.org`, `openfoto.survos.com` | wildcard cert via DNS-01; `openfoto.survos.com` went **grey** after looping |
| **pgsc** | `chijal.org`, `www.chijal.org` | db `chijal` already on fsn1; 308 K uploads copied to `/platform/pgsc` |
| **vt** | `vt.survos.com` | grey. `/es/chijal` verified 200 |
| **mattermost** | `chat.survos.com` | grey (already was). See below |

ash still runs all four — stop them once you're satisfied (`dokku ps:stop <app>`).

`*.survos.com` was **recreated** → ash, proxied, TTL 300, as a catch-all for everything not
yet moved. Explicit records still win. Note this re-introduces the trap-5 hazard: a proxied
wildcard hands out AAAA records for unmatched names, which is what caused the earlier
"staging vhost shadowed by the wildcard's AAAA" misdiagnosis.

## mattermost specifics

  - DB was a **dokku-postgres service**, not the shared cluster and not in the container.
    Installed the `postgres` plugin on fsn1 (1.48.0), created `mattermost-db` pinned to
    **postgres:16.0** to match ash — Mattermost 11.9 does not list PG18 as supported, so the
    shared timescale/pg18 cluster was deliberately not used.
  - Migrated via `postgres:export | postgres:import`. Verified identical: **10 users,
    160 posts, 17 channels** on both hosts.
  - **ash had no storage mount**, so 1.4 MB of uploads in `/mattermost/data` lived only in the
    container and would have been lost on any redeploy — on ash too. Copied to
    `/platform/mattermost/data` and **mounted**, so fsn1 is strictly better than ash here.
  - Plugin errors at boot are normal Team Edition noise: playbooks needs a professional
    licence, ffmpeg is absent, calls can't determine a public IP.

## Build failures worth remembering

**vt: dev-only bundle with an unscoped config file.** `config/bundles.php` registers
`SurvosCommandBundle` and `SurvosCrawlerBundle` for dev+test, but their
`config/packages/*.yaml` were unscoped, so prod boot died with "There is no extension able
to load the configuration for …". That fails `cache:clear`, which composer runs as
post-install-cmd, so the build aborts with **"Dependency installation failed"** — an error
that reads like a composer/network fault. Reproduce locally with
`bin/console cache:clear --env=prod`; dev is the default, which is why it hid. Fixed by
scoping both files `when@dev` / `when@test` (commit `257d1dc`).

**vt: missing `ext-imagick`.** `pwa.yaml` pins `image_processor: pwa.image_processor.imagick`,
and that service only exists when the extension is present, so the container build failed with
"non-existent service pwa.image_processor.imagick". Not switchable to gd — the favicon source
is an **SVG** and gd cannot rasterize SVG. Declared `ext-imagick` in composer.json
(commit `639b982`), matching what ssai already does.

**Transient, retry rather than debug:** a GitHub 504 on a composer zipball, and a jsDelivr
503 ("first byte timeout") during `importmap:install` — vt pulls 42 packages plus a large
flag-icons set, so this will recur.

**LE rejects `www.X` alongside `*.X`** in one order ("redundant with a wildcard domain").
Drop the `www` vhost; the wildcard covers it for nginx too. Cost one failed issuance.

**A locally-timed-out `git push` keeps building server-side.** The 2-minute tool timeout
killed the client while dokku carried on; the follow-up push then hit
"pgsc currently has a deploy lock". Check `docker ps` before running `apps:unlock` — the
first deploy had in fact succeeded.

## Remaining

**87 records still on ash.** Categories unchanged from above: 7 infra (never move
`ssh.survos.com` until ash is retired), `ms.survos.com` pending a Meili reindex, the real-app
queue (ssai, lingua, packages, ai-tools, libretranslate, kpa, news, searchbench, ccal,
rutado, ff), and ~55 dead demos/orphans that should be deleted rather than migrated.

`searchbench.survos.com` currently **loops** and is broken independently of this migration —
it has an origin cert on a Flexible zone. Grey-clouding it would fix it in place.
