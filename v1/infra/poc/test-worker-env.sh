#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATER="$SCRIPT_DIR/update-worker-env.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_contains() {
    local file="$1"
    local expected="$2"

    if ! grep -Fxq "$expected" "$file"; then
        echo "expected line missing: $expected" >&2
        echo "file contents:" >&2
        cat "$file" >&2
        exit 1
    fi
}

env_with_key="$TMP_DIR/worker-with-key.env"
cat > "$env_with_key" <<'EOF'
HIVEMIND_REPLICA_ADDR=
HIVEMIND_SNAPSHOTTER=overlayfs
HIVEMIND_AGENT_METRICS_PORT=8081
HIVEMIND_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF

"$UPDATER" "$env_with_key" "10.0.0.10:9000"

assert_contains "$env_with_key" "HIVEMIND_REPLICA_ADDR=10.0.0.10:9000"
assert_contains "$env_with_key" "HIVEMIND_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

env_without_replica="$TMP_DIR/worker-no-replica.env"
cat > "$env_without_replica" <<'EOF'
HIVEMIND_SNAPSHOTTER=overlayfs
HIVEMIND_AGENT_METRICS_PORT=8081
HIVEMIND_ENCRYPTION_KEY=feedface
EOF

"$UPDATER" "$env_without_replica" "10.0.0.11:9000"

assert_contains "$env_without_replica" "HIVEMIND_REPLICA_ADDR=10.0.0.11:9000"
assert_contains "$env_without_replica" "HIVEMIND_ENCRYPTION_KEY=feedface"

echo "infra/poc worker env tests passed"
