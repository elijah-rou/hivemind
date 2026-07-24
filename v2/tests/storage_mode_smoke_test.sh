#!/usr/bin/env bash
set -euo pipefail

# The maintained storage-mode contract is now observable retained-state
# recovery, not startup text. Keep this compatibility entry point so callers do
# not duplicate local topology.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/local-storage-recovery-smoke.sh" "$@"
