# Authenticated Survos Satis pilot

A local Composer registry that exports allowlisted packages from a **committed
monorepo release tag**, indexes their ZIP archives with Satis, and serves both
metadata and downloads behind authentication. Consumer updates do not need GitHub
VCS discovery or GitHub downloads for the selected Survos packages.

The authenticated registry is hosted at **https://satis.survos.com** on the
existing fsn1 Dokku host. A separate local endpoint remains available at
`http://127.0.0.1:8743`; do not deploy lockfiles containing that loopback URL.

## Start

From `~/sites/docker`, with Docker/Podman running:

```sh
docker-compose build satis satis-publisher
python3 satis/init-auth.py
satis/release 2.28.7
docker-compose up -d satis
python3 satis/verify.py
```

Use `docker compose` in environments with the Compose plugin. The `release`
wrapper supports either form. Both services have profiles and are started
explicitly. Stop the static server with `docker-compose stop satis`. Existing
archives survive container recreation and restart.

`init-auth.py` generates a random reader password once and stores the Caddy hash in
`var/server.env` and Composer credentials in `var/auth.json`. Both are gitignored
and mode 0600. Re-running it retains credentials. The server refuses anonymous
access to its index, metadata and ZIPs. The local HTTP endpoint is bound to
loopback; remote publication requires HTTPS. No credentials belong in URLs,
composer.json, lockfiles, Dockerfiles, or commits.

## Publish a release

```sh
satis/release 2.28.7
# A selected package, when its dependencies are already published:
satis/release 2.28.7 --package survos/debug-utils
```

`--tag` resolves an existing monorepo tag to an exact commit and derives its
version. It does not create tags, push anything, run splits, or contact GitHub.
The publisher mounts `../mono` read-only. Dirty working-tree changes never enter
archives. `packages.json` explicitly allows Depot's 15 Survos packages and
`survos/debug-utils`; it is not a wildcard over the monorepo.

All selected packages are exported at that tag's version. This differs from the
public split workflow, which tags only changed packages. Dependency constraints
are preserved. A release must satisfy consumers' existing constraints; the old
`0.0.x` experimental versions remain downloadable but are not used for adoption.
Use a **new tag** for changed code. A package/version cannot be overwritten with
a different manifest or commit, even if a tag is moved.

For an explicit experimental commit/version, the lower-level interface remains:

```sh
docker-compose run --rm satis-publisher \
  --ref HEAD --version 0.0.3 --url http://127.0.0.1:8743 \
  --package survos/debug-utils
```

The entire snapshot is built and validated before the `current` symlink switches
atomically. A file lock serializes publication. Existing versions and old
hash-addressed metadata remain downloadable. There is no automatic pruning.

## Verify a real app without changing it

```sh
python3 satis/test-consumer.py --app ~/sites/depot
```

This creates an isolated Composer consumer under ignored `var/consumer-*`, copies
the app's manifest/lockfile, inserts the allowlisted canonical repository, removes
selected packages' redundant VCS overrides, and runs:

1. A Composer update of `survos/*` with dependencies.
2. A Survos reinstall using a separate empty cache.
3. Authentication, archive checksum and lockfile verification.
4. A check that fresh Survos downloads used the registry, with no GitHub downloads.

Use `--keep-versions` to migrate the current lockfile without upgrading any
package. All versions are compared before and after.

Plugins and scripts are disabled because this verifies dependency distribution,
not application boot or migrations. Original app files and vendor directories are
untouched. Logs and the resulting lockfile remain in the isolated directory.
Third-party packages still use their normal repositories and may download from
GitHub. Satis removes Survos traffic, not all Composer network activity.

Publisher regression checks:

```sh
python3 -m unittest discover -s satis -p 'test_*.py'
```

## Adopt in an app

After reviewing its isolated dependency update, add a `composer` repository before
Packagist and remove VCS overrides for migrated packages. Start with an explicit
`only` list; copy the selected names from `packages.json`:

```json
{
  "repositories": [{
    "type": "composer",
    "url": "https://satis.survos.com",
    "only": ["survos/debug-utils", "survos/kit-bundle"]
  }]
}
```

That abbreviated list is for a two-package experiment; Depot needs the full
allowlist used by `test-consumer.py`. Composer repositories are canonical by
default: a name present here will not fall through to Packagist for a missing
version. Publish suitable versions and required Survos dependencies before
broadening adoption. Keep the app's actual version constraints.

Supply credentials via Composer's ignored `auth.json` or `COMPOSER_AUTH`. For a
shell command using the hosted registry, without printing the password:

```sh
COMPOSER_AUTH="$(cat ~/sites/docker/satis/var/remote-secrets/auth.json)" composer update 'survos/*' -W --prefer-dist
```

Use the local-only `secure-http: false` setting only for loopback experiments, never for the hosted registry.
Do not replace a real app's lockfile with the isolated one until its normal tests,
plugins and scripts have been run in that app's development workflow.

## Migration to private distribution

`survos/mono` is already private (verified 2026-09-15). Satis does not need split
repositories or Packagist entries. For each package selected for private-only
future releases:

1. Add it and its required Survos dependencies to this explicit allowlist.
2. Remove its path from the private monorepo's `.github/workflows/split.yml`
   public-split catalog **before committing private implementation changes**.
3. Publish and verify the required version through the authenticated registry.
4. Move authorized consumers to the registry, providing their reader credentials.
5. Decide separately whether to archive or change visibility of the existing
   public split repository, and update public distribution notices as appropriate.

Already-public releases cannot be made secret by moving future releases. Public
packages must not acquire a required dependency on an unavailable private package.
No repository visibility or public split rules have been changed by this pilot;
package selection is an explicit product decision.

## Hosted registry and release operation

Hosted URL: **https://satis.survos.com**. Dokku app: `satis` on `fsn1-root`.
It uses the existing server (no new VM), a 128 MiB container limit, a read-only
persistent mount at `/srv`, and a Let's Encrypt certificate. Cloudflare has a
DNS-only A record to the host. `/healthz` is public and returns only `ok`; all
registry content requires authentication and sends `Cache-Control: private,
no-store`. HTTP redirects to HTTPS.

Publish the next existing release tag and upload it atomically:

```sh
satis/deploy-release 2.28.7
```

A deployment lock serializes the entire publish-and-upload operation.
This builds metadata for the HTTPS hostname under local `var/remote`, uploads
all retained artifacts first, then atomically replaces the remote `current`
symlink. It verifies authenticated downloads afterward. `--package survos/name`
can be repeated. The publishing machine needs the private monorepo checkout,
Docker/Compose, rsync, and authorized SSH access through `fsn1-root`.
The command does not call GitHub or create public split releases.

Remote data: `/var/lib/dokku/data/storage/satis`.
Server source/configuration: `/opt/satis`.
Local hosted-reader credentials: `var/remote-secrets/auth.json`.
The hosted and localhost credentials are different. App credentials for the
hosted endpoint must use the `satis.survos.com` key from that file.

For a new host, copy `Dockerfile.server`, `Caddyfile`, `CHECKS`,
`bootstrap-remote.py`, and a mode-0600 `server.env` into `/opt/satis`, upload
registry data to the storage directory, then run `python3 bootstrap-remote.py`
as root. Configure DNS, set the app's Let's Encrypt email, and enable its
certificate before distributing credentials. `bootstrap-remote.py` preserves
existing mount/port settings, including HTTPS. Updating the server image does
not publish new package releases.

The base-image digests identify **multi-architecture indexes**, supporting the
ARM64 Mac and x86 server. The Satis checkout is commit-pinned. Updating these
pins is an intentional maintenance operation.

Local `var/remote` retains a second copy of the hosted artifacts and snapshots.
Keep it and `var/remote-secrets` backed up securely; do not discard old archives
referenced by lockfiles. No automatic pruning or independent offsite backup job
is configured. To restore after server loss, upload the retained local data,
restore reader credentials, bootstrap the server, and reissue the certificate.

For private package adoption, use the HTTPS URL and a canonical `only` list in
the app, with its credentials supplied outside git. Do **not** set
`secure-http: false` for the hosted registry. The isolated consumer check also
supports this endpoint:

```sh
python3 satis/test-consumer.py --app ~/sites/depot \
  --url https://satis.survos.com --auth satis/var/remote-secrets/auth.json
```

## Verified 2026-09-15

- Both Docker images built under Podman; authenticated Caddy server started.
- 16 packages published at monorepo tag `2.28.7`
  (`1bf31fe7df8a867d9392e4afe143ee20a54647b4`).
- 19 ZIPs (including three retained pilot versions) passed authenticated download
  and checksum verification; anonymous metadata and archive requests received 401.
- An isolated copy of Depot installed all 15 Survos dependencies from this registry
  at `2.28.7`; a cold reinstall used local ZIP URLs without GitHub downloads.
- Five publisher tests passed: committed-source export/retention, immutable
  version protection, failed-build recovery, missing dependency detection, and
  rejection of remote plaintext HTTP URLs.

- Hosted TLS certificate installed; existing certificate auto-renewal cron is enabled.
- Hosted registry verified all 34 archives, including Depot's 15 retained versions.
- Hosted container uses native x86, a 128 MiB memory limit, and no public Docker port bindings.

### First consumer: Depot

Depot now uses the hosted canonical repository and its 15 existing Survos package
versions. Only their download/provenance metadata changed; non-Survos lock entries
and all version constraints were preserved. Credentials are in Depot's ignored,
mode-0600 `auth.json`. Composer install and Symfony `bin/console about` passed.
Other machines/CI using Depot need the registry reader credentials via Composer
authentication before installing this lockfile. No other app or public repository
visibility was changed.

- After a hosted-container restart, all 34 archives and Depot's 15 locked registry
  entries passed verification again. Depot's Symfony bootstrap also passed after
  its real vendor install.
