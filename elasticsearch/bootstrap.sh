#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# Run on the server as root. Existing credentials/certificates are preserved.
install -d -m 750 certs
install -d -m 700 secrets
if [ ! -f secrets/elastic-password ]; then
    umask 077
    openssl rand -hex 32 > secrets/elastic-password
fi
if [ ! -f certs/ca.crt ]; then
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj '/CN=Survos Elasticsearch CA' -keyout secrets/ca.key -out certs/ca.crt
fi
if [ ! -f certs/server.crt ]; then
    openssl req -newkey rsa:3072 -nodes -subj '/CN=elasticsearch' \
      -keyout certs/server.key -out secrets/server.csr
    printf '%s\n' 'subjectAltName=DNS:elasticsearch,DNS:survos-es,DNS:localhost,IP:127.0.0.1' 'extendedKeyUsage=serverAuth,clientAuth' > secrets/server.ext
    openssl x509 -req -in secrets/server.csr -CA certs/ca.crt -CAkey secrets/ca.key \
      -CAcreateserial -out certs/server.crt -days 825 -sha256 -extfile secrets/server.ext
fi
# Group 0 is the official container user's secondary group.
chmod 640 certs/server.key secrets/elastic-password
chmod 644 certs/ca.crt certs/server.crt
python3 - <<'PY'
from pathlib import Path
p = Path('secrets/elastic-password').read_text().strip()
path = Path('secrets/health.netrc')
path.write_text('machine localhost login elastic password '+p+'\n')
path.chmod(0o640)
PY
docker compose config --quiet
docker compose up -d --wait --wait-timeout 180
