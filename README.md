# survos/docker

Shared infrastructure for Survos/Museado development. One clone, all services.

## Setup

```bash
# Set required env vars (add to ~/.bashrc)
export DOCKER_DATA_ROOT=/mnt/data/docker-volumes   # Linux
export DOCKER_DATA_ROOT="$HOME/docker-volumes"     # macOS
export IMGPROXY_LICENSE_KEY=<your-imgproxy-license-key>
mkdir -p "$DOCKER_DATA_ROOT"

git clone git@github.com:survos/docker && cd docker
bin/start
```

Alternatively, put the secret values in a local `.env` file in this repo. Compose reads it automatically, and `.env` is ignored by git.

### Starting services

Run this once after every reboot (it also starts the podman VM on the Mac):

```bash
bin/start                 # everything: the whole shared stack, plus Elasticsearch + Kibana
bin/start core            # just postgres, elasticsearch, redis
bin/start rabbitmq        # only the services you name
```

`bin/start core` is for someone working only on a public-facing site, a designer
for example. It is what a site needs to render pages: postgres, elasticsearch and
redis (the cache/session store in nearly every site's `.env`). It leaves out
mariadb, rabbitmq, mercure, mailpit, the messenger postgres and Kibana.

RabbitMQ is not in core even though most sites list it: Symfony only connects when
a message is dispatched, so pages render without it. If a form submit fails with an
AMQP connection error, `bin/start rabbitmq`.

Grist is in neither set; use https://grist.survos.com, or `bin/start grist`.

The lists are at the top of [bin/start](bin/start).

```bash
bin/stop                  # every service in this stack, ondemand ones included
bin/stop kibana           # only the services you name
```

`bin/stop` stops, never downs: containers and volumes stay. It leaves containers
from other projects alone and does not stop the podman VM.

On the Mac, `docker compose` reaches podman only through `DOCKER_HOST`. `.zshrc`
sets it for interactive shells; scripts and agents do not read `.zshrc`, and a
`docker compose` run without it fails against `/var/run/docker.sock`. `bin/start`
and `bin/stop` set it themselves. Elsewhere:

```bash
export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
```

On Linux boxes with the optional `apparmor-profiles` package, `bin/start` also
re-applies the php-fpm complain-mode override that the package resets on every boot.

## Services

| Service | Port | Credentials |
|---------|------|-------------|
| Postgres | 5434 | `postgres` / `docker` |
| Postgres (messenger) | 5435 | `messenger` / `messenger` |
| imgproxy | 8080 | license: `$IMGPROXY_LICENSE_KEY` (required, set in environment) |
| Redis | 6379 | — |
| Mercure | 3000 | — |
| Mailpit (SMTP) | 1025 / 8025 | — |
| RabbitMQ (AMQP) | 5672 | `guest` / `guest` |
| RabbitMQ (management UI) | 15672 | `guest` / `guest`, http://localhost:15672 |
| Grist | 8484 | no auth, http://localhost:8484 |

## Grist

Grist is a spreadsheet/database hybrid, here to evaluate as a home for small
shared datasets. http://localhost:8484

```bash
docker compose up -d grist
```

**It runs with authentication turned off**, so the port is bound to
`127.0.0.1` and it must stay that way. Anyone who can reach 8484 is
`tacman@gmail.com` (`GRIST_DEFAULT_EMAIL`) with owner rights on everything.
Don't expose this container without configuring a real auth provider first.
OIDC, SAML, and forwarded-headers auth are all in the `-oss` image and are
configured with env vars (`GRIST_OIDC_IDP_ISSUER`, `GRIST_SAML_IDP_LOGIN`,
`GRIST_FORWARD_AUTH_HEADER`). The admin panel badges OIDC and SAML as
"requires activation key" -- that gates the point-and-click wizard, not the
capability.

Two env vars in `docker-compose.yaml` exist only to skip first-run clicking:

- `GRIST_BOOT_KEY` -- gates `/boot` and `/admin`. Pinned so it isn't a random
  value you have to dig out of the container logs.
- `GRIST_IN_SERVICE=true` -- Grist 2.x returns
  `{"error":"Grist is not yet configured"}` from *every* API route until the
  setup wizard has been completed. Setting this marks the install in-service so
  a fresh clone comes up with a working API.

### API access

The REST API wants a bearer token. Anonymous is a real (empty) identity, so log
in first -- with no auth provider configured, `/login` just hands you the
default account:

```bash
curl -s -c /tmp/grist.jar -L http://localhost:8484/login -o /dev/null
curl -s -b /tmp/grist.jar -X POST -H 'Content-Type: application/json' \
  http://localhost:8484/api/profile/apiKey
```

Then `curl -H "Authorization: Bearer <key>" http://localhost:8484/api/orgs`.
Org is `survos` (`GRIST_SINGLE_ORG`).

### Demo data

The `Pokedex` doc holds all 151 Gen-1 Pokemon pulled from
[PokeAPI](https://pokeapi.co), loaded through the REST API. It's there to
exercise the parts that matter for real datasets, not just to have rows:

- `Types` + `Pokemon` joined by real `Ref:` columns, not copied strings
- Python formula columns (`Total` = stat sum, `Types` = `$Type1.Name + ...`)
- reverse lookups on `Types` (`Pokemon.lookupRecords(Type1=$id)`) for per-type
  counts and averages
- an `Attachments` column with the actual sprite PNGs

Worth knowing: **Grist will not render an image from a URL in a cell.** The
Markdown text widget passes `![alt](url)` through as literal text. There are two
ways around it, and which one you want depends on who owns the bytes:

- **Attachments column** -- upload the bytes, Grist thumbnails them in the cell.
  What the Pokedex doc does.
- **Image viewer custom widget** -- a side panel that follows the cursor and
  renders whatever URL is in a mapped text column. Nothing is copied, so this is
  the one to use when the images already live somewhere else.

### Demo data: PGSC

The `PGSC` doc is the second option applied to a real case -- `~/sites/pgsc`
(chijal.org) keeps its content in a Google Sheet whose photo column holds Google
Drive *share* links, which are viewer pages, not images. Loaded from
`pgsc/data/*.csv`:

- `DriveUrl` stays exactly the link a human pasted -- it's also the identity
  pgsc's MediaBundle hashes (`ensureMedia()` -> xxh3), so nothing downstream cares
- `ImageUrl` is a **formula** column that regexes the file id out and rebuilds it
  as `https://drive.google.com/thumbnail?id=<id>&sz=w1000`, i.e. nobody maintains
  a second URL by hand
- the Image viewer widget is mapped to `ImageUrl` and follows the grid cursor

Wiring that widget from the API is undocumented and easy to get wrong. The
mapping lives *inside* `customDef`, and the value is a **scalar** colRef, not a
list, unless the widget declares `allowMultiple`:

```json
{"customView": "{\"url\": \"...viewer/index.html\", \"widgetId\": \"@gristlabs/widget-viewer\",
                 \"access\": \"read table\", \"columnsMapping\": {\"ImageUrl\": 23}}"}
```

The mapping key (`ImageUrl`) is whatever the widget passes to `grist.ready({columns})`
in its own source, not anything in the widget manifest.

Coverage is partial on purpose -- it reflects the CSVs, not a cleanup: 12/20 obras
have a photo link, and 15/20 resolve to an artist. The checked-in `artists.csv` is
a raw intake-form export with no `code` column, so it can't be joined on the
`artist_code` the live sheet's `@artists` tab uses; the demo bridges it on name
initials, which is a stand-in, not the real key.

Formulas run in the gVisor sandbox (`GRIST_SANDBOX_FLAVOR`), which the image
supports out of the box. `pyodide` is the WASM fallback if gVisor ever fails.

### "Applications"

Grist markets what you build as "applications," but there is no separate app
object -- no Baserow-style Application Builder. **A document is the app.** What
that actually amounts to:

- **pages + widget layouts** -- multiple widgets per page, cursor-linked, so
  selecting a row drives the panels beside it
- **forms** -- a native `form` widget you publish to a public URL, which anyone
  can fill in with no account. Works in Community Edition.
- **access rules** -- row/cell level, formula-driven; the free-tier feature
  Baserow charges for
- **custom widgets** -- HTML/JS in a sandboxed iframe against the plugin API,
  plus a "Custom widget builder" widget for writing them inside Grist
- **webhooks + REST API** for anything the document can't do itself

The `YardSale` doc is a published form end-to-end: an anonymous `POST` to
`/forms/<shareKey>/<sectionId>` lands a row in `Items`.

Publishing one from the API needs three things, and the third is easy to miss:

1. an `_grist_Shares` record with `options={"publish":true}` -- the server
   generates the share `key` (readable in `/persist/home.sqlite3`, not returned
   by the apply call)
2. the page's `shareRef` pointed at it, and the section's
   `shareOptions={"publish":true,"form":{}}`
3. a **`layoutSpec` on the form section**. `CreateViewSection` leaves it empty,
   and the Submit button is a node *in that spec* -- so the form renders its
   fields and is simply unsubmittable until you build one:
   `{"type":"Layout","children":[{"type":"Section","children":[{"type":"Field","leaf":<fieldRef>}]},{"type":"Submit"}]}`

## Kibana (local testing)

Kibana 9.5.3 connects to the local Elasticsearch service and is available at
http://localhost:5601. Start both with `bin/start kibana` and stop
Kibana with `docker-compose stop kibana`. It runs on demand with a 1.5 GiB
container limit and binds only to loopback, matching the local ES version.

The remote ES test service is on fsn1 at `/opt/elasticsearch`; it has no public
endpoint. Kibana has not been installed there. A remote Kibana should live
alongside that service, use its CA and authenticated connection, and initially
be accessed through an SSH tunnel rather than a public unauthenticated port.

## Elasticsearch (local testing)

A separate authenticated TLS service now runs on fsn1 under `/opt/elasticsearch`.
See [fsn1 deployment and operations](elasticsearch/README.md). The configuration
below remains the on-demand, unauthenticated local development node.

Elasticsearch is pinned to 9.5.3, runs on demand, and stores indexes in the
`elasticsearch_data` named volume. On the Mac, use the installed standalone Compose:

```bash
cd ~/sites/docker
bin/start elasticsearch
curl http://127.0.0.1:9200
docker-compose stop elasticsearch
```

For SearchBundle apps, configure `ELASTICSEARCH_DSN=elasticsearch://127.0.0.1:9200`
and select the ES adapter in that app. The node has no authentication and is bound
to loopback only. It has a 2 GiB container limit and a 1 GiB JVM heap; the Mac's
Podman VM has 8 GiB RAM. Existing app backends are not switched by starting it.

## Meilisearch (retired)

Not used any more: Elasticsearch replaced it (2026-09-15). The old standalone setup
is in `~/sites/meilisearch`.

## Per-app databases

Each app creates its own database on the shared Postgres instance:

```bash
# In the app directory
bin/console doctrine:database:create
```

Each app's `.env`:
```
DATABASE_URL=postgresql://postgres:docker@127.0.0.1:5434/<appname>?serverVersion=18&charset=utf8
MESSENGER_TRANSPORT_DSN=doctrine://messenger:messenger@127.0.0.1:5435/messenger?serverVersion=18&charset=utf8
MEILI_DSN=http://127.0.0.1:7700
MEILI_API_KEY=Y0urVery-S3cureAp1K3y
REDIS_URL=redis://127.0.0.1:6379
MERCURE_URL=http://127.0.0.1:3000/.well-known/mercure
MESSENGER_TRANSPORT_DSN=phpamqplib://guest:guest@127.0.0.1:5672/<appname>
```

## Per-app RabbitMQ vhosts

RabbitMQ isolates apps with vhosts, the AMQP equivalent of a per-app Postgres database.
`docker-compose.yaml` only auto-creates one extra vhost at first boot
(`RABBITMQ_DEFAULT_VHOST`, currently `packages`) — that's a limitation of the official
image's entrypoint, not something Compose can loop over. State survives container
restarts (see below), so this is a one-time step per new app:

```bash
docker compose exec rabbitmq rabbitmqctl add_vhost <appname>
docker compose exec rabbitmq rabbitmqctl set_permissions -p <appname> guest ".*" ".*" ".*"
```

## Data persistence

Postgres uses a named Docker volume. Redis, Mercure, and
RabbitMQ mount data below `$DOCKER_DATA_ROOT`. A normal `docker compose down`
or host reboot preserves queues, vhosts, and rows. `docker compose
down -v` removes named volumes; manually clearing `$DOCKER_DATA_ROOT` removes
the bind-mounted service data.

## Selective Composer registry pilot

The authenticated registry runs at https://satis.survos.com on the existing fsn1
host. See `~/sites/satis/README.md` for tagged publication, private-package
migration, credentials, and isolated Composer verification. A local on-demand
registry remains available for publisher development.
