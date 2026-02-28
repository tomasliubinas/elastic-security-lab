#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Elastic Security Lab – Start Script
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ES_URL="http://localhost:${ES_PORT}"
KB_URL="http://localhost:${KIBANA_PORT}"
ES_AUTH="elastic:${ELASTIC_PASSWORD}"

command -v docker >/dev/null 2>&1 || die "Docker not found."
docker info >/dev/null 2>&1       || die "Docker daemon not running."

wait_healthy() {
  local name=$1 max=120 i=0
  while [ $i -lt $max ]; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
    [ "$status" = "healthy" ] && { ok "$name is healthy"; return 0; }
    printf "  waiting for %s (%s)...\r" "$name" "$status"
    sleep 5; i=$((i+1))
  done
  echo ""
  die "Timed out waiting for $name. Run: docker logs $name"
}

# ── Stage 1: Elasticsearch ─────────────────────────────────────────────────
info "Starting Elasticsearch..."
docker compose up -d --remove-orphans elasticsearch
wait_healthy elasticsearch

# ── Stage 2: kibana_system password ───────────────────────────────────────
info "Setting kibana_system password..."
curl -sf -X POST \
  -u "${ES_AUTH}" \
  -H "Content-Type: application/json" \
  "${ES_URL}/_security/user/kibana_system/_password" \
  -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" >/dev/null
ok "kibana_system password set."

# ── Stage 3: Fleet service token (created via ES API) ─────────────────────
info "Creating Fleet Server service token..."
# Delete existing token if present (idempotent re-runs)
curl -sf -X DELETE \
  -u "${ES_AUTH}" \
  "${ES_URL}/_security/service/elastic/fleet-server/credential/token/lab-token" \
  >/dev/null 2>&1 || true

SERVICE_TOKEN=$(curl -sf -X POST \
  -u "${ES_AUTH}" \
  "${ES_URL}/_security/service/elastic/fleet-server/credential/token/lab-token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['value'])")
[ -n "$SERVICE_TOKEN" ] || die "Failed to create service token."
ok "Service token created."

# Write to .env so docker compose picks it up
sed -i '' "s|^FLEET_SERVER_SERVICE_TOKEN=.*|FLEET_SERVER_SERVICE_TOKEN=${SERVICE_TOKEN}|" .env

# ── Stage 4: Kibana ────────────────────────────────────────────────────────
info "Starting Kibana..."
docker compose up -d kibana
wait_healthy kibana

# ── Stage 5: Fleet setup + Fleet Server policy ────────────────────────────
info "Initialising Fleet..."
curl -sf -X POST \
  -u "${ES_AUTH}" \
  -H "kbn-xsrf: true" \
  "${KB_URL}/api/fleet/setup" >/dev/null
ok "Fleet initialised."

# Fix Fleet Server host URL — agents run on the Mac so they use localhost,
# not host.docker.internal (which is only resolvable inside Docker containers)
info "Configuring Fleet Server host URL..."
curl -sf -X PUT \
  -u "${ES_AUTH}" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  "${KB_URL}/api/fleet/fleet_server_hosts/fleet-default-fleet-server-host" \
  -d "{\"name\":\"Default\",\"is_default\":true,\"host_urls\":[\"http://localhost:${FLEET_PORT}\"]}" >/dev/null || true
ok "Fleet Server host → http://localhost:${FLEET_PORT}"

info "Configuring Fleet output..."
OUTPUT_ID=$(curl -sf \
  -u "${ES_AUTH}" \
  "${KB_URL}/api/fleet/outputs" \
  | python3 -c "
import sys,json
items=json.load(sys.stdin).get('items',[])
d=[o for o in items if o.get('is_default')]
print(d[0]['id'] if d else 'fleet-default-output')
" 2>/dev/null || echo "fleet-default-output")

curl -sf -X PUT \
  -u "${ES_AUTH}" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  "${KB_URL}/api/fleet/outputs/${OUTPUT_ID}" \
  -d "{
    \"name\": \"default\",
    \"type\": \"elasticsearch\",
    \"hosts\": [\"http://elasticsearch:9200\"],
    \"is_default\": true,
    \"is_default_monitoring\": true
  }" >/dev/null
ok "Fleet output → http://elasticsearch:9200"

info "Creating Fleet Server agent policy..."
POLICY_RESP=$(curl -sf -X POST \
  -u "${ES_AUTH}" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  "${KB_URL}/api/fleet/agent_policies" \
  -d '{
    "name": "Fleet Server Policy",
    "namespace": "default",
    "has_fleet_server": true,
    "monitoring_enabled": []
  }')
POLICY_ID=$(echo "$POLICY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])")
[ -n "$POLICY_ID" ] || die "Failed to create Fleet Server policy."
ok "Fleet Server policy created: ${POLICY_ID}"

# Add Fleet Server integration to the policy
info "Installing Fleet Server integration into policy..."
FS_VERSION=$(curl -sf \
  -u "${ES_AUTH}" \
  "${KB_URL}/api/fleet/epm/packages/fleet_server" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null \
  || echo "1.5.0")

curl -sf -X POST \
  -u "${ES_AUTH}" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  "${KB_URL}/api/fleet/package_policies" \
  -d "{
    \"name\": \"fleet-server-1\",
    \"namespace\": \"default\",
    \"policy_id\": \"${POLICY_ID}\",
    \"package\": { \"name\": \"fleet_server\", \"version\": \"${FS_VERSION}\" },
    \"inputs\": [{\"type\": \"fleet-server\", \"enabled\": true, \"streams\": [], \"vars\": {}}]
  }" >/dev/null
ok "Fleet Server integration installed (v${FS_VERSION})."

# Write policy ID to .env
sed -i '' "s|^FLEET_SERVER_POLICY_ID=.*|FLEET_SERVER_POLICY_ID=${POLICY_ID}|" .env

# ── Stage 6: Fleet Server container ───────────────────────────────────────
info "Starting Fleet Server..."
# Re-source .env so the new token and policy ID are available to docker compose
source .env
docker compose up -d fleet-server
wait_healthy fleet-server
echo ""
ok "All services healthy!"

# ── Stage 7: Download Elastic Agent for Mac ────────────────────────────────
ARCH=$(uname -m)
AGENT_ARCH="aarch64"; [ "$ARCH" != "arm64" ] && AGENT_ARCH="x86_64"
AGENT_TAR="elastic-agent-${STACK_VERSION}-darwin-${AGENT_ARCH}.tar.gz"
AGENT_DIR="elastic-agent-${STACK_VERSION}-darwin-${AGENT_ARCH}"

if [ -d "$AGENT_DIR" ]; then
  info "Elastic Agent already downloaded."
else
  info "Downloading Elastic Agent ${STACK_VERSION} (${AGENT_ARCH})..."
  curl -# -L -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/${AGENT_TAR}"
  tar xzf "$AGENT_TAR"
  ok "Extracted to ${AGENT_DIR}/"
fi

# ── Stage 8: Enrollment token ─────────────────────────────────────────────
info "Fetching enrollment token..."
ENROLL_TOKEN=$(curl -sf \
  -u "${ES_AUTH}" \
  "${KB_URL}/api/fleet/enrollment_api_keys" \
  | python3 -c "
import sys,json
keys=json.load(sys.stdin).get('items',[])
active=[k for k in keys if k.get('active')]
print(active[0]['api_key'] if active else '')
" 2>/dev/null || true)

# ── Stage 9: Install Elastic Agent on this Mac ────────────────────────────
# Fleet Server runs HTTP (insecure) so agents use --insecure
if [ -f /Library/Elastic/Agent/elastic-agent.yml ]; then
  ok "Elastic Agent already installed on this Mac."
elif [ -n "${ENROLL_TOKEN:-}" ]; then
  info "Installing Elastic Agent (requires sudo)..."
  sudo "./${AGENT_DIR}/elastic-agent" install \
    --url="http://localhost:${FLEET_PORT}" \
    --enrollment-token="${ENROLL_TOKEN}" \
    --insecure \
    --non-interactive
  ok "Elastic Agent installed and enrolled!"
else
  warn "No enrollment token found. Enroll manually:"
  echo "  Kibana → Fleet → Enrollment tokens → create one, then:"
  echo "  sudo ./${AGENT_DIR}/elastic-agent install \\"
  echo "    --url=http://localhost:${FLEET_PORT} \\"
  echo "    --enrollment-token=<TOKEN> \\"
  echo "    --insecure"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Elastic Security Lab is running!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Kibana:        http://localhost:${KIBANA_PORT}"
echo "  Elasticsearch: http://localhost:${ES_PORT}"
echo "  Fleet Server:  http://localhost:${FLEET_PORT}"
echo "  Username:      elastic / ${ELASTIC_PASSWORD}"
echo ""
echo "  In Kibana:"
echo "  1. Fleet → Agents → verify your Mac appears"
echo "  2. Fleet → Agent Policies → add 'Endpoint Security' (Elastic Defend)"
echo "  3. Fleet → Agent Policies → add 'System' (logs + metrics)"
echo "  4. Security → Alerts"
echo ""
echo "  docker compose down      ← stop (keep data)"
echo "  docker compose down -v   ← stop + wipe all data"
echo ""
