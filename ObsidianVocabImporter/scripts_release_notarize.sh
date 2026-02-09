#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible wrapper.
# New canonical path: ./scripts/release_notarize.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/scripts/release_notarize.sh" "$@"

