# Elasticsearch on fsn1

Small standalone test service, separate from app deployments. Elasticsearch 9.5.3, one node, 2 GiB container cap, 1 GiB JVM heap, locked memory, persistent named volume `survos-es-data`, and `unless-stopped` restart policy. This is a single-node service: restarts temporarily interrupt search.

## Deployment

Tracked source: `survos/docker/elasticsearch/`. Installed on fsn1 at `/opt/elasticsearch`.

Copy `compose.yaml`, `heap.options`, `bootstrap.sh`, `provision.py`, and `verify.py` to that directory, then run as root:

```sh
cd /opt/elasticsearch
./bootstrap.sh
python3 provision.py
```

The host requires Docker Compose, Python 3 and OpenSSL. fsn1 already has `vm.max_map_count=1048576`; bootstrap does not change global kernel settings or other services. Bootstrap preserves existing credentials, certificates and data. A CA and server certificate are generated locally; the server certificate expires after 825 days and must be renewed before then. Keep `secrets/ca.key` private when issuing a replacement certificate signed by the same CA.

## Access

- From fsn1 itself: `https://localhost:9200` (bound only to IPv4 loopback).
- From an explicitly attached app container: `https://elasticsearch:9200` on Docker network `survos-es-private`.
- No public DNS, proxy route, or public port is configured. Port 9300 is not published.
- TLS trust: `/opt/elasticsearch/certs/ca.crt`. Mount the CA into consuming app containers and configure their HTTP client to trust it. Never disable certificate validation.
- Private key files: `secrets/<app>-search.json` and `secrets/<app>-indexer.json`, one pair per app in `provision.py`'s `APPS` (global-giving → `gg_compare_*`, packages → `packages_*`). The `encoded` field is used as an `Authorization: ApiKey …` header, or as `api_key=` in a search-bundle DSN. Each key reaches only its app's prefix. Search credentials cannot write; indexing credentials can manage those indexes. No cluster administration privilege is granted.
- Bootstrap administrator password: `secrets/elastic-password`; used only for provisioning/health operations, not app configuration.

The service uses a dedicated bridge network; its published port is bound only to loopback. Attach an app as an additional network while preserving its existing network for other dependencies. No existing app has been attached by this deployment. The GlobalGiving lab needs its production authentication and remote query-embedding service configured separately before publishing.

## Operations

```sh
cd /opt/elasticsearch
docker compose ps
docker compose logs --tail=100 elasticsearch
docker compose stop elasticsearch
docker compose up -d --wait
docker compose restart elasticsearch
```

`stop` intentionally keeps the service stopped across daemon restarts until started again. Ordinary container recreation preserves `survos-es-data`. Do not use `down -v` unless intentionally discarding indexes. Log rotation is limited to three 10 MB files.

`provision.py` creates missing application keys, verifies authenticated indexing/search, and checks that the search key receives HTTP 403 on writes. It leaves `gg_compare_deployment_probe` for restart verification; run `docker compose restart elasticsearch`, `docker compose up -d --wait`, then `python3 verify.py` to check persistence and remove the probe. Existing keys are not rotated automatically.

Source snapshots, cached vectors and research judgments are application data, outside this ES volume, and should be preserved independently. The indexes can be rebuilt. No scheduled ES backup is configured for this testing service; use Elasticsearch's snapshot API if index backups become necessary, not copies of the running data directory.

## Verified deployment — 2026-09-15

On fsn1: cluster green; authenticated indexing/search passed; search key denied writes and cluster administration; unauthenticated requests returned 401; the probe survived a container restart and was removed afterward. Runtime inspection confirmed the 2 GiB container cap, 1 GiB JVM heap, locked memory, `unless-stopped` policy, localhost-only 9200 binding and unpublished 9300. No app backend was switched.
