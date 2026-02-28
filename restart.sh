#!/usr/bin/env bash
# Quick restart — for an already-configured stack (no setup steps)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source .env

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "\033[0;31m[ERROR]${NC} $*"; exit 1; }

wait_healthy() {
  local name=$1 max=60 i=0
  while [ $i -lt $max ]; do
    s=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
    [ "$s" = "healthy" ] && { ok "$name healthy"; return 0; }
    printf "  waiting for %s (%s)...\r" "$name" "$s"
    sleep 5; i=$((i+1))
  done
  echo ""; die "Timed out waiting for $name"
}

info "Starting stack..."
docker compose up -d --remove-orphans

wait_healthy elasticsearch
wait_healthy kibana
wait_healthy fleet-server

# Kibana resets Fleet Server host to host.docker.internal on restart — fix it
info "Fixing Fleet Server host URL..."
curl -sf -X PUT \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  "http://localhost:${KIBANA_PORT}/api/fleet/fleet_server_hosts/fleet-default-fleet-server-host" \
  -d "{\"name\":\"Default\",\"is_default\":true,\"host_urls\":[\"http://localhost:${FLEET_PORT}\"]}" >/dev/null
ok "Fleet Server host → http://localhost:${FLEET_PORT}"

echo ""
echo -e "${GREEN}Stack is up!${NC}"
echo "  Kibana:  http://localhost:${KIBANA_PORT}  (elastic / ${ELASTIC_PASSWORD})"
echo ""
