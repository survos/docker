# Parking experimentation sites on dokku

For demo / proof-of-concept / experimentation apps that should stay *deployable* but not
consume RAM while nobody is looking at them. Established 2026-08-18 on `fsn1`, where the
box has ~2.8 GiB available and **no swap**, and an OOM would take down the Postgres
primary for all 49 databases.

## What a parked app costs vs a running one

Measured on `rsun` (a small Symfony app, herokuish, trivial traffic):

    running, idle   59.6 MiB   0.77% of host   0.01% CPU
    parked           0 MiB     no container

So parking reclaims the **whole** ~60 MiB. Tuning `WEB_CONCURRENCY` does not come close —
see below.

## Park it

    dokku ps:scale <app> web=0

## Bring it back

    dokku ps:scale <app> web=1

That is the whole procedure. Nothing else needs restoring: the app's config vars, domains,
TLS certificate, storage mounts and built image all survive, because scaling to zero only
stops containers.

## Why `ps:scale web=0` and not `ps:stop`

Both stop the containers, but they differ in durability:

| command | stops now | survives a later `git push` |
|---|---|---|
| `dokku ps:stop <app>` | yes | **no** — a deploy starts it again |
| `dokku ps:scale <app> web=0` | yes | **yes** — the scale is recorded and honoured on deploy |

For a parked app that is the point: you want it to *stay* parked until you deliberately
scale it back up, even if you push a commit to it in the meantime. Use `ps:stop` only for a
temporary stop you intend to reverse in the same sitting.

Verify either way with `docker ps --filter name=<app>` rather than the command's exit code —
a crash-looping container can survive `ps:restart`.

## Multi-process apps

Scale each process type you want down, e.g. for an app with workers:

    dokku ps:scale <app> web=0 worker=0

`dokku ps:scale <app>` with no arguments prints the current table.

## What happens to the URL

The vhost and certificate stay configured, so nginx keeps answering — with a **502**,
because the upstream has no members. That is honest ("this app is parked"), but if you would
rather it not look broken, point the DNS record elsewhere or remove the vhost.

Do **not** delete the DNS record on the assumption you will recreate it: for anything on
`survos.com` the record also has to be grey-clouded once the app has an origin certificate
(that zone is on Flexible SSL), and it is easy to forget that detail months later. See
`HANDOFF-2026-08-18-fsn1-part2.md`.

## Why WEB_CONCURRENCY is the wrong lever here

`WEB_CONCURRENCY` sets php-fpm's worker count — real OS processes. It looks like an obvious
saving, but measured on an idle app the workers are cheap:

    52780 KB  php-fpm   master (warmed)
    47140 KB  php-fpm   worker that has served requests
    32972 KB  php-fpm   worker that has served requests
     9484 KB  php-fpm   never served a request
     9484 KB  php-fpm   never served a request
     9484 KB  php-fpm   never served a request

An unused worker costs ~9.5 MiB, because it is almost entirely copy-on-write shared with the
master. It only grows to 30-50 MiB after it actually handles a request. So on a quiet demo,
dropping 5 → 1 saves maybe 10-30 MiB, while parking saves all ~60 MiB.

Where `WEB_CONCURRENCY` *does* matter is an app with real traffic, which warms every worker:
`searchbench` was running five workers at 108-123 MiB each. For those, consider **2** rather
than 1 — with a single worker one slow request blocks the whole site (head-of-line blocking).

Note that `dokku config:set <app> WEB_CONCURRENCY=2` does **not** stick: dokku re-applies
`app.json`'s `env` block on every release (`Setting 2 env var(s) from app.json`). Change the
value in `app.json` and commit it.
