#!/usr/bin/env python3
"""Generate local registry credentials once; never print the password."""
import json
import argparse
import os
from pathlib import Path
import secrets
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--data', type=Path, default=Path(__file__).resolve().parent / 'var')
parser.add_argument('--host', default='127.0.0.1:8743')
args = parser.parse_args()
data = args.data
data.mkdir(parents=True, exist_ok=True)
server = data / 'server.env'
auth = data / 'auth.json'
if server.exists() or auth.exists():
    if not (server.exists() and auth.exists()):
        raise SystemExit('Incomplete credentials: inspect var/server.env and var/auth.json before retrying')
    print('Existing registry credentials retained')
else:
    password = secrets.token_urlsafe(32)
    result = subprocess.run(
        ['docker', 'run', '--rm', '-i', '--entrypoint', 'caddy', 'docker-satis', 'hash-password'],
        input=password + '\n', text=True, capture_output=True, check=True,
    )
    hashed = result.stdout.strip()
    if not hashed.startswith('$2'):
        raise SystemExit('Caddy did not return a bcrypt password hash')
    # Single quotes prevent Compose from interpolating bcrypt dollar signs.
    fd = os.open(server, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write("SATIS_USERNAME=survos\nSATIS_PASSWORD_HASH='" + hashed + "'\n")
    fd = os.open(auth, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'http-basic': {args.host: {'username': 'survos', 'password': password}}}, f, indent=2)
        f.write('\n')
    print('Created var/server.env and var/auth.json (mode 0600, gitignored)')
