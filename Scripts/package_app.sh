#!/usr/bin/env bash

# Compatibility entry point. Keep one release implementation so app and DMG packaging cannot
# silently drift on resources, signing, notarization, or license attribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "package_app.sh now uses the canonical package_dmg.sh release pipeline."
exec "$ROOT/Scripts/package_dmg.sh" "$@"
