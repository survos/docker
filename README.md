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
docker compose up -d
```

Alternatively, put the secret values in a local `.env` file in this repo. Compose reads it automatically, and `.env` is ignored by git.

### After a reboot

Every service here has `restart: unless-stopped`, so a running Docker daemon
brings them all back on its own — but on machines with the (optional)
`apparmor-profiles` package installed, php-fpm gets blocked by a reset
AppArmor profile on every boot regardless of this stack. Run this once per
boot to cover both:

```bash
bin/start.sh
```

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
| Elasticsearch | 9200 | —, http://localhost:9200 |
| Grist | 8484 | no auth, http://localhost:8484 |
| Kibana | 5601 | —, http://localhost:5601 |

## Elasticsearch

Elasticsearch and Kibana are shared development services. Start only this pair
with:

```bash
docker compose up -d elasticsearch kibana
curl http://localhost:9200
```

Elasticsearch runs as a single node with security disabled and ports bound to
localhost. This is a development configuration, not a production deployment.
Its index data is persisted in the `elasticsearch_data` Docker volume.

Linux hosts need `vm.max_map_count` of at least `262144`:

```bash
sysctl vm.max_map_count
```

## Grist

Grist is a spreadsheet/database hybrid, here to evaluate as a home for small
shared datasets. http://localhost:8484

```bash
docker compose up -d grist
```

**It runs with authentication turned off**, so the port is bound to
`127.0.0.1` and it must stay that way. Anyone who can reach 8484 is
`tacman@gmail.com` (`GRIST_DEFAULT_EMAIL`) with owner rights on everything.
Don't expose this container without configuring a real auth provider first --
the admin panel at `/admin` has OIDC, SAML, and forwarded-headers options, the
first two behind an activation key.

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
Markdown text widget passes `![alt](url)` through as literal text. Images mean
an `Attachments` column with the bytes uploaded to `POST /api/docs/{id}/attachments`,
which is a meaningful difference if your dataset points at images you already
host elsewhere.

Formulas run in the gVisor sandbox (`GRIST_SANDBOX_FLAVOR`), which the image
supports out of the box. `pyodide` is the WASM fallback if gVisor ever fails.

## Meilisearch

Meilisearch now lives in its own public repository so local development builds
the exact Dockerfile deployed to production. Start it separately:

```bash
cd ~/sites/meilisearch && bin/run.sh
```

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

Postgres and Elasticsearch use named Docker volumes. Redis, Mercure, and
RabbitMQ mount data below `$DOCKER_DATA_ROOT`. A normal `docker compose down`
or host reboot preserves queues, vhosts, indexes, and rows. `docker compose
down -v` removes named volumes; manually clearing `$DOCKER_DATA_ROOT` removes
the bind-mounted service data.
