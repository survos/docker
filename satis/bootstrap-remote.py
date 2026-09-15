#!/usr/bin/env python3
"""Provision the dedicated Satis Dokku app on the existing host; run as root."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent

def run(*args, quiet=False):
    subprocess.run(list(args), check=True, stdout=subprocess.DEVNULL if quiet else None, cwd=root)

if subprocess.run(['dokku', 'apps:exists', 'satis'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
    run('dokku', 'apps:create', 'satis')
run('dokku', 'domains:set', 'satis', 'satis.survos.com')
mount = '/var/lib/dokku/data/storage/satis:/srv:ro'
mounts = subprocess.check_output(['dokku', 'storage:list', 'satis'], text=True)
if '/var/lib/dokku/data/storage/satis' not in mounts:
    run('dokku', 'storage:mount', 'satis', mount)
settings = []
for line in (root / 'server.env').read_text().splitlines():
    if not line or line.startswith('#'): continue
    name, value = line.split('=', 1)
    if name not in ('SATIS_USERNAME', 'SATIS_PASSWORD_HASH'):
        raise ValueError('Unexpected registry setting')
    settings.append(name + '=' + value.strip("'"))
run('dokku', 'config:set', '--no-restart', 'satis', *settings, quiet=True)
ports = subprocess.check_output(['dokku', 'ports:list', 'satis'], text=True)
if '8080' not in ports:
    run('dokku', 'ports:set', 'satis', 'http:80:8080')
run('dokku', 'resource:limit', '--memory', '128m', 'satis')
run('docker', 'build', '-f', 'Dockerfile.server', '-t', 'survos-satis:pilot', '.')
run('dokku', 'git:from-image', 'satis', 'survos-satis:pilot')
