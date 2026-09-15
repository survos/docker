#!/usr/bin/env python3
"""Run a real app's Composer update in isolation, then force fresh Survos downloads."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--url', default='http://127.0.0.1:8743')
parser.add_argument('--auth', type=Path, default=root / 'var/auth.json')
parser.add_argument('--keep-versions', action='store_true', help='Migrate download sources without upgrading locked packages')
args = parser.parse_args()
base = args.url.rstrip('/')
catalog = json.loads((root / 'packages.json').read_text())
work = Path(tempfile.mkdtemp(prefix='consumer-', dir=root / 'var'))
manifest = json.loads((args.app / 'composer.json').read_text())
# Keep unrelated custom repositories; omit VCS overrides for migrated packages.
repos = manifest.get('repositories', [])
if isinstance(repos, dict): repos = list(repos.values())
selected_repos = []
for repo in repos:
    if not isinstance(repo, dict):
        selected_repos.append(repo); continue
    url = str(repo.get('url', '')).removesuffix('.git').rstrip('/')
    if any(url.endswith('/' + name) for name in catalog):
        continue
    selected_repos.append(repo)
manifest['repositories'] = [{'type': 'composer', 'url': base, 'only': list(catalog)}, *selected_repos]
if base.startswith('http://127.0.0.1:'):
    manifest.setdefault('config', {})['secure-http'] = False
(work / 'composer.json').write_text(json.dumps(manifest, indent=2) + '\n')
lock = args.app / 'composer.lock'
if lock.exists(): (work / 'composer.lock').write_bytes(lock.read_bytes())
if args.keep_versions and not lock.exists():
    raise SystemExit('--keep-versions requires an existing composer.lock')
env = os.environ.copy()
env['COMPOSER_AUTH'] = args.auth.read_text()
env['COMPOSER_HOME'] = str(work / 'composer-home')
env['COMPOSER_CACHE_DIR'] = str(work / 'cache')

def run(command, log_name):
    with (work / log_name).open('w') as log:
        result = subprocess.run(command, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'Composer failed: inspect {work / log_name}')

print(f'Isolated consumer: {work}', flush=True)
flags = ['--no-scripts', '--no-plugins', '--no-interaction', '--prefer-dist', '--no-progress']
selection = ['--lock'] if args.keep_versions else (['survos/*', '--with-all-dependencies'] if lock.exists() else [])
run(['composer', 'update', *selection, *flags], 'update.log')
if args.keep_versions:
    before, after = json.loads(lock.read_text()), json.loads((work / 'composer.lock').read_text())
    for key in ('packages', 'packages-dev'):
        assert {p['name']: p['version'] for p in before.get(key, [])} == {p['name']: p['version'] for p in after.get(key, [])}, 'Package versions changed'
    print('PASS: every locked package version preserved', flush=True)
# An empty, separate cache proves package archives are downloadable independently
# of the first install or the developer's existing Composer cache.
env['COMPOSER_CACHE_DIR'] = str(work / 'fresh-download-cache')
run(['composer', 'reinstall', 'survos/*', '-vvv', *flags], 'reinstall.log')
subprocess.run(['python3', str(root / 'verify.py'), '--url', base, '--auth', str(args.auth.resolve()), '--lock', str(work / 'composer.lock')], check=True)
log_text = (work / 'reinstall.log').read_text()
assert 'api.github.com' not in log_text and 'codeload.github.com' not in log_text, 'Survos reinstall contacted GitHub'
assert base + '/dist/' in log_text, 'No registry downloads observed'
print('PASS: cold Survos reinstall downloaded registry archives without GitHub downloads')
print('Original app composer.json, lockfile, vendor and configuration were not modified')
print(f'Logs and isolated lockfile retained at {work}')
