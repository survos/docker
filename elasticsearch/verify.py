#!/usr/bin/env python3
"""Run after restarting the provisioned container; verify the probe survived, then remove it."""
import base64
import json
import ssl
import urllib.error
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent
context = ssl.create_default_context(cafile=str(root / 'certs/ca.crt'))
search = 'ApiKey ' + json.loads((root / 'secrets/global-giving-search.json').read_text())['encoded']
indexer = 'ApiKey ' + json.loads((root / 'secrets/global-giving-indexer.json').read_text())['encoded']
password = (root / 'secrets/elastic-password').read_text().strip()
admin = 'Basic ' + base64.b64encode(('elastic:' + password).encode()).decode()

def request(path, auth=None, method='GET'):
    req = urllib.request.Request('https://localhost:9200/' + path, method=method,
                                 headers={} if auth is None else {'Authorization': auth})
    with urllib.request.urlopen(req, context=context, timeout=30) as response:
        return json.load(response)

assert request('gg_compare_deployment_probe/_doc/1', search)['found']
print('Persistence after restart: passed')
for path, auth, expected in [('', None, 401), ('_cluster/health', search, 403)]:
    try:
        request(path, auth)
        raise AssertionError('Unexpected access')
    except urllib.error.HTTPError as e:
        assert e.code == expected
print('Unauthenticated requests denied; app key cannot administer cluster')
health = request('_cluster/health', admin)
print('Health:', health['status'])
nodes = request('_nodes/jvm,process', admin)['nodes']
for node in nodes.values():
    assert node['jvm']['mem']['heap_max_in_bytes'] == 1073741824
    assert node['process']['mlockall']
print('1 GiB heap and locked memory verified')
request('gg_compare_deployment_probe', indexer, 'DELETE')
print('Temporary probe index removed')
