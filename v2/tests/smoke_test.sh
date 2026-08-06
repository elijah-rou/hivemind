#!/usr/bin/env bash
# Compatibility entry point: maintained local three-replica smoke.
# Uses exec so exit status and signals propagate to the caller.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/local-smoke.sh" --build "$@"
