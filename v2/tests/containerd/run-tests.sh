#!/bin/bash
set -euo pipefail

# Run containerd integration tests inside Docker (OrbStack)
# Usage: ./tests/containerd/run-tests.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "==> Building containerd test container..."
docker build \
    -f "$SCRIPT_DIR/Dockerfile" \
    -t hivemind-containerd-test \
    "$REPO_ROOT"

echo "==> Running containerd integration tests..."
docker run --rm --privileged hivemind-containerd-test
