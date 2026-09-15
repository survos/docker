#!/usr/bin/env python3
"""Create app-scoped API keys and verify indexing, reads and permissions. Never prints keys."""
import base64
import json
import ssl
import urllib.request
import urllib.error
from pathlib import Path

root = Path(__file__).resolve().parent
context = ssl.create_default_context(cafile=str(root / 'certs/ca.crt'))
password = (root / 'secrets/elastic-password').read_text().strip()
auth = 'Basic ' + base64.b64encode(('elastic:' + password).encode()).decode()

def request(method, path, body=None, authorization=auth):
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request('https://localhost:9200/' + path, data=payload, method=method,
                                 headers={'Authorization': authorization, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, context=context, timeout=30) as response:
        return json.load(response)

# Each app gets a search key and an indexer key, both confined to its own index prefix.
# Secrets land in secrets/<app>-<role>.json. global-giving's probe is left for verify.py.
APPS = {
    'global-giving': 'gg_compare_',
    'packages': 'packages_',
}

def key(app, role):
    return 'ApiKey ' + json.loads((root / ('secrets/' + app + '-' + role + '.json')).read_text())['encoded']

for app, prefix in APPS.items():
    for role, privileges in [('search', ['read', 'view_index_metadata']),
                             ('indexer', ['manage', 'read', 'write'])]:
        path = root / ('secrets/' + app + '-' + role + '.json')
        if not path.exists():
            result = request('POST', '_security/api_key', {
                'name': app + '-' + role,
                'role_descriptors': {app: {'cluster': [], 'indices': [{
                    'names': [prefix + '*'], 'privileges': privileges}]}}
            })
            path.touch(mode=0o600)
            path.write_text(json.dumps(result, indent=2) + '\n')
        path.chmod(0o600)

    search, indexer = key(app, 'search'), key(app, 'indexer')
    index = prefix + 'deployment_probe'
    try:
        request('PUT', index, {'settings': {'number_of_shards': 1, 'number_of_replicas': 0}}, indexer)
    except urllib.error.HTTPError as e:
        if e.code != 400: raise
    request('PUT', index + '/_doc/1?refresh=true', {'title': 'deployment persistence probe'}, indexer)
    result = request('POST', index + '/_search', {'query': {'match': {'title': 'persistence'}}}, search)
    assert result['hits']['total']['value'] == 1
    try:
        request('PUT', index + '/_doc/2', {'title': 'must not write'}, search)
        raise AssertionError(app + ' search key unexpectedly allowed writes')
    except urllib.error.HTTPError as e:
        assert e.code == 403
    for other_app, other_prefix in APPS.items():
        if other_app == app:
            continue
        try:
            request('PUT', other_prefix + 'scope_probe', {}, indexer)
            raise AssertionError(app + ' indexer key reached ' + other_prefix + '*')
        except urllib.error.HTTPError as e:
            assert e.code == 403
    if app != 'global-giving':
        request('DELETE', index, authorization=indexer)
    print(app + ': authenticated indexing/search passed; search key denies writes; scoped to ' + prefix + '*.')

health = request('GET', '_cluster/health')
print('Cluster health:', health['status'])
print('Probe remains for restart verification: gg_compare_deployment_probe')
