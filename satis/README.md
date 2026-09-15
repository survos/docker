# Selective Satis pilot

Exports allowlisted packages from committed monorepo directories into versioned
ZIPs; Satis indexes the ZIPs and serves HTTP downloads. No split repositories,
Packagist wait, Git tags, source edits, or Composer path repositories are involved.
This is a local pilot, not an authenticated production registry.

## Start and publish

Run from `~/sites/docker` with Docker/Podman running. Use `docker-compose` instead
of `docker compose` if your installation provides the standalone command.

```sh
docker compose build satis satis-publisher
docker compose run --rm satis-publisher \
  --ref HEAD --version 0.0.1 --url http://127.0.0.1:8743
docker compose up -d satis
```

Open http://127.0.0.1:8743. Stop with `docker compose stop satis`.
Both services have profiles; neither starts with a bare `compose up`.
The server binds only to loopback. The publisher mounts `../mono` read-only.

`packages.json` is the explicit allowlist. Initially it contains
`survos/debug-utils` and `survos/kit-bundle`. To publish just one:

```sh
docker compose run --rm satis-publisher \
  --ref HEAD --version 0.0.2 --url http://127.0.0.1:8743 \
  --package survos/debug-utils
```

Only committed files are exported. Commit local changes first; pushing the commit
is not required for this local experiment. Use an exact commit or tag when recording
a release. Versions cannot be overwritten with a different commit or manifest.
These 0.0.x versions are pilot versions, not public release tags. Package dependency
constraints are preserved: publishing a group does not rewrite its internal constraints.

## Isolated Composer consumer

Add this to a disposable application's root composer.json:

```json
{
  "repositories": [
    {
      "type": "composer",
      "url": "http://127.0.0.1:8743",
      "only": ["survos/debug-utils", "survos/kit-bundle"]
    }
  ],
  "require": {
    "survos/debug-utils": "0.0.2",
    "survos/kit-bundle": "0.0.1"
  },
  "config": {"secure-http": false}
}
```

`secure-http: false` is only for this loopback HTTP test. Production uses HTTPS.
Composer 2 treats this repository as canonical by default: the selected names
must resolve here; other packages still resolve from Packagist. Do not broaden
`only` to `survos/*` until the selected versions and dependencies are available.
Dependencies use normal stability rules; this does not lower minimum-stability.

Run `composer update survos/debug-utils survos/kit-bundle`, commit the lockfile,
and deploy with `composer install`. No path symlinks are stored in the lockfile.
A localhost dist URL is still local-only: regenerate metadata at the eventual
HTTPS registry URL and update consumer lockfiles before any real deployment.

## Persistence and publication

Ignored `var/` contains input artifacts, release snapshots, and a `current` symlink.
The publisher builds and validates a complete snapshot, retains prior archives and
hash-addressed metadata, then switches `current` atomically. Existing versions and
old lockfiles remain downloadable. Publication is serialized with a file lock.
There is no automatic pruning; monitor disk use and back up artifacts. Container
publication may create host files owned by the container user on Linux.

The pinned Satis revision is in `Dockerfile`. Base image tags are currently floating;
resolve and pin them before production rollout. The final Dockerfile stage is the
static Caddy server, suitable for a later Dokku deployment. It requires persistent
storage mounted at `/srv`, with the same layout as `var/`.

Before deploying as packages.survos.com: configure HTTPS, authenticated access to
metadata AND ZIPs, Composer credentials via auth.json/COMPOSER_AUTH, persistent
storage/backups, and a publisher that writes that storage. `git push dokku` deploys
the service image; it does not by itself publish new bundle archives. Production
publication should use one writer and the final public URL. Keep public splitting
for packages that still need public Packagist distribution during this pilot.

## Native fallback / observed validation

On 2026-09-10 Podman failed to start (`vfkit exited ... code 1`), so Docker image
build/start could not be verified. Compose configuration passed using standalone
`docker-compose config --quiet`.

The publisher also runs with Python 3, PHP, Composer and a checked-out Satis install:

```sh
python3 publish.py --repo ~/sites/mono --data ./var \
  --satis /absolute/path/to/satis/bin/satis \
  --ref HEAD --version 0.0.1 --url http://127.0.0.1:8743
python3 -m http.server 8743 --bind 127.0.0.1 --directory ./var/current
```

Satis dependencies must first be installed with `composer install` in its checkout.
Native HTTP is a temporary development server, not the production serving process.
