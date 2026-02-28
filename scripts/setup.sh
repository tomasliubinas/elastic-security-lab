#!/bin/bash
set -euo pipefail
# Generates CA + fleet-server cert only.
# Elasticsearch uses plain HTTP so no ES cert is needed.

if [ ! -f config/certs/ca.zip ]; then
  echo "==> Generating CA..."
  bin/elasticsearch-certutil ca --silent --pem -out config/certs/ca.zip
  unzip -o config/certs/ca.zip -d config/certs
fi

if [ ! -f config/certs/certs.zip ]; then
  echo "==> Generating fleet-server certificate..."
  cat > config/certs/instances.yml << 'INSTANCES'
instances:
  - name: fleet-server
    dns: [fleet-server, localhost]
    ip: [127.0.0.1]
INSTANCES

  bin/elasticsearch-certutil cert --silent --pem \
    --ca-cert config/certs/ca/ca.crt \
    --ca-key  config/certs/ca/ca.key \
    --in      config/certs/instances.yml \
    -out      config/certs/certs.zip

  unzip -o config/certs/certs.zip -d config/certs
fi

chown -R 1000:0 config/certs
chmod -R 770    config/certs
echo "==> Certificates ready."
