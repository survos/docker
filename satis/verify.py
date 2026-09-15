#!/usr/bin/env python3
"""Verify access protection, artifacts and an optional Composer consumer lockfile."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url', default='http://127.0.0.1:8743')
parser.add_argument('--auth', type=Path, default=Path(__file__).with_name('var') / 'auth.json')
parser.add_argument('--lock', type=Path)
args = parser.parse_args()
base = args.url.rstrip('/')
host = urllib.parse.urlsplit(base).netloc
credentials = json.loads(args.auth.read_text())['http-basic'][host]
header = 'Basic ' + base64.b64encode((credentials['username'] + ':' + credentials['password']).encode()).decode()

def fetch(path, authenticated=True):
    req = urllib.request.Request(base + '/' + path.lstrip('/'), headers={'Authorization': header} if authenticated else {})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()

def denied(path):
    try:
        fetch(path, False)
    except urllib.error.HTTPError as error:
        assert error.code == 401, (path, error.code)
    else:
        raise AssertionError('Anonymous access allowed: ' + path)

denied('packages.json')
root = json.loads(fetch('packages.json'))
packages = {}
# Includes contain complete manifests; p2 files may use Composer's minified format.
for path in root['includes']:
    data = fetch(path)
    assert hashlib.sha1(data).hexdigest() == root['includes'][path]['sha1']
    packages.update(json.loads(data)['packages'])
def verify_archive(item):
    name, version, package = item
    dist = package['dist']
    assert dist['url'].startswith(base + '/'), (name, version, dist['url'])
    path = dist['url'][len(base) + 1:]
    denied(path)
    archive = fetch(path)
    if dist.get('shasum'):
        assert hashlib.sha1(archive).hexdigest() == dist['shasum'], name
    assert not package.get('source'), (name, 'source fallback still present')

items = [(name, version, package) for name, versions in packages.items() for version, package in versions.items()]
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(verify_archive, items))
count = len(items)
print(f'PASS: authenticated metadata and {count} ZIPs; anonymous access denied; checksums valid')
if args.lock:
    lock = json.loads(args.lock.read_text())
    selected = [p for p in lock['packages'] + lock.get('packages-dev', []) if p['name'].startswith('survos/')]
    assert selected, 'No Survos packages in consumer lockfile'
    for package in selected:
        assert package['dist']['url'].startswith(base + '/'), package['name']
        assert not package.get('source'), package['name']
        assert package['version'] in packages[package['name']], package['name']
    print(f'PASS: all {len(selected)} consumer Survos packages use this registry, with no GitHub source fallback')
