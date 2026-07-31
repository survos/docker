# survos/docker

Shared infrastructure for Survos/Museado development. One clone, all services.

## Setup

```bash
# Set required env vars (add to ~/.bashrc)
export DOCKER_DATA_ROOT=/mnt/data/docker-volumes   # Linux
export DOCKER_DATA_ROOT="$HOME/docker-volumes"     # macOS
export MEILI_API_KEY=<your-secret-key>
export IMGPROXY_LICENSE_KEY=<your-imgproxy-license-key>
mkdir -p "$DOCKER_DATA_ROOT"

git clone git@github.com:survos/docker && cd docker
docker compose up -d
```

Alternatively, put the secret values in a local `.env` file in this repo. Compose reads it automatically, and `.env` is ignored by git.

## Services

| Service | Port | Credentials |
|---------|------|-------------|
| Postgres | 5434 | `postgres` / `docker` |
| Postgres (messenger) | 5435 | `messenger` / `messenger` |
| Meilisearch | 7700 | key: `$MEILI_API_KEY` (required, set in environment) |
| imgproxy | 8080 | license: `$IMGPROXY_LICENSE_KEY` (required, set in environment) |
| Redis | 6379 | — |
| Mercure | 3000 | — |
| Mailpit (SMTP) | 1025 / 8025 | — |
| RabbitMQ (AMQP) | 5672 | `guest` / `guest` |
| RabbitMQ (management UI) | 15672 | `guest` / `guest`, http://localhost:15672 |

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

Postgres, Meilisearch, Redis, Mercure, and RabbitMQ all mount their data directory under
`$DOCKER_DATA_ROOT`, so `docker compose down` / host reboots don't lose queues, vhosts,
indexes, or rows. Only `docker compose down -v` (which removes volumes) or manually
clearing `$DOCKER_DATA_ROOT` wipes them.
