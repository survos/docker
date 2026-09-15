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

for role, privileges in [('search', ['read', 'view_index_metadata']),
                         ('indexer', ['manage', 'read', 'write'])]:
    path = root / ('secrets/global-giving-' + role + '.json')
    if not path.exists():
        result = request('POST', '_security/api_key', {
            'name': 'global-giving-' + role,
            'role_descriptors': {'global-giving': {'cluster': [], 'indices': [{
                'names': ['gg_compare_*'], 'privileges': privileges}]}}
        })
        path.touch(mode=0o600)
        path.write_text(json.dumps(result, indent=2) + '\n')
    path.chmod(0o600)

search = 'ApiKey ' + json.loads((root / 'secrets/global-giving-search.json').read_text())['encoded']
indexer = 'ApiKey ' + json.loads((root / 'secrets/global-giving-indexer.json').read_text())['encoded']
index = 'gg_compare_deployment_probe'
try:
    request('PUT', index, {'settings': {'number_of_shards': 1, 'number_of_replicas': 0}}, indexer)
except urllib.error.HTTPError as e:
    if e.code != 400: raise
request('PUT', index + '/_doc/1?refresh=true', {'title': 'deployment persistence probe'}, indexer)
result = request('POST', index + '/_search', {'query': {'match': {'title': 'persistence'}}}, search)
assert result['hits']['total']['value'] == 1
try:
    request('PUT', index + '/_doc/2', {'title': 'must not write'}, search)
    raise AssertionError('Search key unexpectedly allowed writes')
except urllib.error.HTTPError as e:
    assert e.code == 403
print('Authenticated indexing/search passed; search-only key denies writes.')
health = request('GET', '_cluster/health')
print('Cluster health:', health['status'])
print('Probe remains for restart verification:', index)
