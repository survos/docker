# survos/docker

Shared infrastructure for Survos/Museado development. One clone, all services.

## Setup

```bash
# Set required env vars (add to ~/.bashrc)
export DOCKER_DATA_ROOT=/mnt/data/docker-volumes   # Linux
export DOCKER_DATA_ROOT="$HOME/docker-volumes"     # macOS
export MEILI_API_KEY=<your-secret-key>
mkdir -p "$DOCKER_DATA_ROOT"

git clone git@github.com:survos/docker && cd docker
docker compose up -d
```

## Services

| Service | Port | Credentials |
|---------|------|-------------|
| Postgres | 5434 | `postgres` / `docker` |
| Postgres (messenger) | 5435 | `messenger` / `messenger` |
| Meilisearch | 7700 | key: `$MEILI_API_KEY` (required, set in environment) |
| Redis | 6379 | — |
| Mercure | 3000 | — |
| Mailpit (SMTP) | 1025 / 8025 | — |

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
```
