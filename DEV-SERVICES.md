# Running dev services only when you need them

The local counterpart to `PARKING-APPS.md`. That file is about not paying for idle
apps *on dokku*; this one is about not paying for idle services *on the laptop*.

Established 2026-08-29, after load on the laptop climbed past 35 on 14 cores and the
working habit had become "stop Docker so I can keep working". Almost none of it was
real work — see [What idle actually cost](#what-idle-actually-cost).

The rule: **if a service runs remotely and you are not actively developing against it,
do not run it locally.** Point at production instead.

## What runs by default

`dev-docker-stack.service` (a systemd *user* unit, `WantedBy=default.target`) starts
exactly this list at login:

    postgres  postgres_messenger  meilisearch  redis  mailer  rabbitmq

That list is deliberate and short. These are shared infrastructure that nearly every
app needs, that has no remote equivalent you can point a dev app at, and that is cheap
to leave running.

    systemctl --user status  dev-docker-stack.service
    systemctl --user stop    dev-docker-stack.service     # stop the lot
    systemctl --user disable dev-docker-stack.service     # and stop it at next login

**The trap this unit does not protect you from:** a bare `docker compose up -d` in
`~/sites/docker` starts *every* service in the file, not the unit's list. That is how
Grist ended up running for weeks. Anything that should not start that way now carries
`profiles: ["ondemand"]`, which excludes it from a bare `up` — see below.

## On-demand services

| service | runs remotely at | start locally with |
|---|---|---|
| Satis registry | https://satis.survos.com | `docker-compose up -d satis` after publishing; see [setup](satis/README.md) |
| Grist | https://grist.survos.com | `docker compose up -d grist` (in `~/sites/docker`) |
| Mattermost | https://chat.survos.com | `docker compose -f ~/sites/mattermost/docker-compose.yml up -d` |
| Elasticsearch 9.5.3 | fsn1, private TLS test service ([operations](elasticsearch/README.md)) | `docker-compose up -d elasticsearch` (in `~/sites/docker`) |

Elasticsearch was removed on the Lemur, then restored for on-demand testing on the
48 GiB M4 Pro Mac on 2026-09-15. Its Podman VM has 8 GiB RAM; Elasticsearch is capped
at 2 GiB with a 1 GiB JVM heap. It uses a persistent named volume and listens only
on `127.0.0.1:9200`, without authentication. Stop with
`docker-compose stop elasticsearch`; it does not restart automatically.

Naming a profiled service explicitly on the command line enables its profile, so
`docker compose up -d grist` is all you need — no `--profile` flag.

Mattermost is a separate compose project, so a profile does not apply. It uses
`restart: "no"` instead, which is what keeps it from returning after a reboot or a
docker daemon restart. If you ever change that back to `unless-stopped`, it becomes
permanent again by accident.

When you are done, in both cases:

    docker compose stop <service>

Use `stop`, not `down`. `down` removes containers *and* the default network, and for
`~/sites/docker` it will happily take named volumes with `-v`. `stop` leaves all data
in place, so the next start is instant.

## The workflow: develop local, deploy, point back

The reason to run one of these locally is almost always "production is on an older
version and I need to fix something against a newer one". The shape:

1. **Start the service locally**, per the table above.
2. **Point the app at localhost** for the duration. Put it in the app's `.env.local`,
   never in `.env` — `.env` is committed and would follow you to production.

       # .env.local
       GRIST_URL=http://localhost:8484

3. **Make the fix.** If the fix is in a Survos bundle, it belongs in `mono/bu/*` — see
   CONVENTIONS.md; a local-only patch in the app will be overwritten.
4. **Deploy to production**, which for these is a dokku app like any other. A mono
   change also needs a release before production can see it: a symlinked `vendor/` makes
   a fix *look* deployed when it is not.
5. **Delete the `.env.local` override** so the app is back on the remote instance.
6. **Stop the local service** — `docker compose stop grist`. This is the step that gets
   skipped, and it is the whole reason this document exists.

Step 5 before step 6, not the other way around. Reversed, the app points at a localhost
port with nothing behind it and fails in a way that looks like a code bug.

## What idle actually cost

Measured on this laptop, 2026-08-29, with nothing being actively developed:

| what | cost while idle |
|---|---|
| `survos_rabbitmq` healthcheck | **385% CPU**, sustained — a full Erlang VM every 10s |
| `survos_grist` healthcheck | **105% CPU** — a full Node runtime every 10s |
| `ssai-depot-events.service` | **252 restarts/hour**, ~2s CPU each — ~14% of a core |
| `civic-app-1` | 76% CPU, `unhealthy` for 18 hours straight |

The healthchecks are fixed (see the compose file). The other two are the pattern this
document is trying to prevent: services left running long after the work that needed
them was finished.

### The crash-loop trap

`ssai-depot-events.service` was `Restart=always`, `RestartSec=3`, with a hard Redis
dependency and no start limit. So **stopping Docker did not reduce load, it created
load** — Redis vanished, the service began failing, and systemd rebooted a PHP kernel
every three seconds forever. That is the exact opposite of what "stop Docker to free up
the machine" is supposed to do, and it is why that habit never seemed to help much.

Any `Restart=always` unit that depends on a service you might legitimately stop needs
either a start limit, so it gives up:

    StartLimitIntervalSec=300
    StartLimitBurst=5

or an explicit dependency, so it stops with the thing it needs:

    [Unit]
    After=dev-docker-stack.service
    BindsTo=dev-docker-stack.service

Prefer `BindsTo` over `Requires` here: it also stops the unit when the stack stops,
rather than only refusing to start it.

## Checking what is up

    dstacks          # compose stacks, container count, CPU, unhealthy flags
    dstacks -x       # the same, plus the exact stop command for each stack
    whyload          # is load CPU, I/O, or a stalled mount

Both live in `bin/` here. Neither stops anything on its own. Symlink them onto PATH
on a new machine:

    ln -sf ~/sites/docker/bin/dstacks ~/sites/docker/bin/whyload ~/bin/

`whyload` is worth reading before reaching for `top`: it answers the one question that
changes what you do next, which is whether load is CPU, I/O, or a stalled FUSE mount.
High load with `iowait` above ~20 is a hung rclone/NFS/USB mount, and the process list
will look deceptively idle -- a completely different fix from anything in this file.
