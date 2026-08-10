#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <env-file> <replica-addr>" >&2
    exit 1
fi

ENV_FILE="$1"
REPLICA_ADDR="$2"
ENV_DIR="$(dirname "$ENV_FILE")"

mkdir -p "$ENV_DIR"
touch "$ENV_FILE"

if grep -q '^HIVEMIND_REPLICA_ADDR=' "$ENV_FILE"; then
    sed -i.bak "s|^HIVEMIND_REPLICA_ADDR=.*|HIVEMIND_REPLICA_ADDR=$REPLICA_ADDR|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
else
    printf 'HIVEMIND_REPLICA_ADDR=%s\n' "$REPLICA_ADDR" >> "$ENV_FILE"
fi
