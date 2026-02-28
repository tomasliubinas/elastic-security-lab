#!/usr/bin/env bash
# Stop the Elastic Security lab (preserves data volumes)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Stopping Elastic Security lab..."
docker compose down

echo ""
echo "Services stopped. Data volumes preserved."
echo "To also delete all data: docker compose down -v"
