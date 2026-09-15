#!/bin/sh
# Point a Dokku app at this Elasticsearch service. Run as root on fsn1, from /opt/elasticsearch,
# after provision.py has created secrets/<app>-indexer.json. Never prints the key.
#
#   ./connect-app.sh packages
#
# The app must also be on the private network and see the CA (one-time, as dokku):
#   dokku network:set <app> attach-post-deploy survos-es-private
#   dokku storage:mount <app> /opt/elasticsearch/certs/ca.crt:/etc/ssl/survos-es/ca.crt
set -eu
app="$1"
cd "$(dirname "$0")"
# URL-encoded: the base64 key can contain '+', which parse_str would turn into a space.
key=$(python3 -c "import json,sys,urllib.parse; print(urllib.parse.quote(json.load(open(sys.argv[1]))['encoded'], safe=''))" "secrets/$app-indexer.json")
dokku config:set --no-restart "$app" \
    ELASTICSEARCH_DSN="elasticsearch+https://elasticsearch:9200?api_key=$key&ca=/etc/ssl/survos-es/ca.crt" \
    > /dev/null
echo "ELASTICSEARCH_DSN set for $app (no restart; takes effect on next deploy)."
