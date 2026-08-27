#!/usr/bin/env bash
# Create a database and its own user on the shared MariaDB.
#
#   bin/create-db.sh ff
#   bin/create-db.sh ff somepassword    # reuse an existing password
#
# Idempotent. Prints the .env lines for the site to use.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; source .env; set +a; }
root_pass="${MARIADB_ROOT_PASSWORD:-docker}"

name="${1:?usage: create-db.sh <name> [password]}"
pass="${2:-$(openssl rand -hex 12)}"

if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "name must be lowercase letters, digits and underscores: $name" >&2
    exit 1
fi

docker compose exec -T mariadb mariadb -uroot -p"$root_pass" <<SQL
CREATE DATABASE IF NOT EXISTS \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$name'@'%' IDENTIFIED BY '$pass';
ALTER USER '$name'@'%' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$name'@'%';
FLUSH PRIVILEGES;
SQL

cat <<ENV

Add to the site's .env:

DB_NAME='$name'
DB_USER='$name'
DB_PASSWORD='$pass'
DB_HOST='127.0.0.1:3307'
ENV
