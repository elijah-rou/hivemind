#!/usr/bin/env bash
set -euo pipefail

# Compatibility entry point for the maintained real-process run contract.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/local-run-contract-smoke.sh" "$@"
