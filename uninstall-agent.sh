#!/usr/bin/env bash
# Uninstall Elastic Agent from this Mac
set -euo pipefail

if [ ! -f /Library/Elastic/Agent/elastic-agent ]; then
  echo "Elastic Agent does not appear to be installed."
  exit 0
fi

echo "Uninstalling Elastic Agent from this Mac (requires sudo)..."
sudo /Library/Elastic/Agent/elastic-agent uninstall --non-interactive
echo "Done. Elastic Agent removed."
