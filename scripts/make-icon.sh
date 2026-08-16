#!/usr/bin/env bash
# Regenerate the official Wattly app icon into AppIcon.appiconset.
#
#   ./scripts/make-icon.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/generate_exact_html_icon.py
