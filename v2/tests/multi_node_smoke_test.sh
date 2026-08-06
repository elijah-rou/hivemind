#!/usr/bin/env bash
# Compatibility entry point: maintained local multi-replica failover smoke.
# Uses exec so exit status and signals propagate to the caller.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/local-failover-smoke.sh" --build "$@"
