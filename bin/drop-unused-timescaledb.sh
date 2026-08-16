#!/usr/bin/env bash
# Drop timescaledb + timescaledb_toolkit from the shared dev Postgres.
#
# WHY: audited 2026-08-16 -- all 33 local databases had these extensions and
# there were ZERO hypertables anywhere. They were inherited from template1, so
# every CREATE DATABASE picked them up automatically. Production has none.
#
# Removing them:
#   * makes image version bumps a plain tag swap instead of an ALTER EXTENSION
#     pass across every database (timescaledb refuses to run when the loaded
#     library version differs from the installed extension version)
#   * lets CONVENTIONS.md's schema_filter drop the _timescaledb_ /
#     toolkit_experimental exclusions
#   * removes a dev/prod divergence
#
# RUN THIS BEFORE pulling a new timescaledb-ha image, not after.
#
# Reversible: `CREATE EXTENSION timescaledb;` restores it. But if any hypertable
# ever exists, STOP -- dropping would take its data with it. The guard below
# refuses in that case.
set -euo pipefail

HOST=${PGHOST:-127.0.0.1}
PORT=${PGPORT:-5434}
USER=${PGUSER:-postgres}
export PGPASSWORD=${PGPASSWORD:-docker}

psql_() { psql -h "$HOST" -p "$PORT" -U "$USER" "$@"; }

dbs=$(psql_ -tAc "select datname from pg_database where datallowconn and datname <> 'template0'")

echo "== guard: refusing if any hypertable exists =="
found=0
for d in $dbs; do
  n=$(psql_ -d "$d" -tAc "select count(*) from timescaledb_information.hypertables" 2>/dev/null | tr -d ' ' || true)
  if [ -n "${n:-}" ] && [ "$n" != "0" ]; then
    echo "  !! $d has $n hypertables -- ABORTING, timescaledb is genuinely in use"
    found=1
  fi
done
[ "$found" = "0" ] || exit 1
echo "  none found, safe to proceed"
echo

echo "== dropping (template1 first, so new databases stop inheriting it) =="
for d in template1 $(echo "$dbs" | grep -v '^template1$'); do
  out=$(psql_ -d "$d" -tAc "drop extension if exists timescaledb_toolkit cascade; drop extension if exists timescaledb cascade;" 2>&1 || true)
  printf "  %-24s %s\n" "$d" "${out:-ok}"
done
echo

echo "== verify =="
remaining=$(for d in $dbs; do
  psql_ -d "$d" -tAc "select '$d' from pg_extension where extname like 'timescaledb%'" 2>/dev/null || true
done | tr -d ' ' | sort -u)
if [ -z "$remaining" ]; then
  echo "  clean -- no timescaledb extensions remain"
else
  echo "  STILL PRESENT in:"; echo "$remaining" | sed 's/^/    /'
fi

cat <<'NOTE'

Next:
  1. docker compose pull postgres && docker compose up -d postgres
  2. Confirm: psql -h 127.0.0.1 -p 5434 -U postgres -c '\dx'
  3. Simplify CONVENTIONS.md's schema_filter (drop _timescaledb_ /
     timescaledb_ / toolkit_experimental exclusions)

If PGDATA is ever reinitialized from scratch, the image re-creates these in
template1 -- re-run this script after any fresh init.
NOTE
