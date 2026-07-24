#!/bin/bash
set -euo pipefail

# Privileged containerd gates. --check performs read-only host compatibility checks.
# Actual component/full-stack modes are opt-in and must never be called by fixtures.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:---component}"
DOCKER="${DOCKER:-docker}"
IMAGE="hivemind-containerd-test"
PRIVILEGED_PROBE_IMAGE="${HIVEMIND_PRIVILEGED_PROBE_IMAGE:-docker.io/library/alpine:3.20}"

check_host() {
    command -v "$DOCKER" >/dev/null 2>&1 || { echo "containerd check: docker command unavailable" >&2; return 1; }
    local os_type
    os_type="$(timeout --foreground --kill-after=2s 15s "$DOCKER" info --format '{{.OSType}}' 2>/dev/null)" || {
        echo "containerd check: Docker daemon unavailable" >&2
        return 1
    }
    [[ "$os_type" == "linux" ]] || { echo "containerd check: Docker daemon is not Linux" >&2; return 1; }
    if ! timeout --kill-after=5s 60s "$DOCKER" run --rm --privileged --network none \
        --entrypoint /bin/true "$PRIVILEGED_PROBE_IMAGE"; then
        echo "containerd check: disposable privileged container probe failed" >&2
        return 1
    fi
    printf 'docker=%s os=%s privileged=verified\n' "$DOCKER" "$os_type"
}

case "$MODE" in
    --check)
        check_host
        ;;
    --component)
        check_host
        echo "==> Building containerd component test image..."
        "$DOCKER" build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE" "$REPO_ROOT"
        echo "==> Running containerd component integration tests..."
        "$DOCKER" run --rm --privileged "$IMAGE"
        ;;
    --full-stack)
        check_host
        echo "==> Building containerd full-stack test image..."
        "$DOCKER" build -f "$SCRIPT_DIR/Dockerfile.full-stack" -t "$IMAGE-full-stack" "$REPO_ROOT"
        echo "==> Running full-stack containerd restart/adoption contract..."
        docker_args=(--rm --privileged)
        if [[ "${REQUIRE_GPU:-0}" == 1 ]]; then
            docker_args+=(--gpus all)
            [[ ! -d /etc/cdi ]] || docker_args+=(-v /etc/cdi:/etc/cdi:ro)
            [[ ! -d /var/run/cdi ]] || docker_args+=(-v /var/run/cdi:/var/run/cdi:ro)
        fi
        "$DOCKER" run "${docker_args[@]}" \
            -e REQUIRE_CONTAINERD=1 \
            -e REQUIRE_GPU="${REQUIRE_GPU:-0}" \
            -e REQUIRE_NYDUS="${REQUIRE_NYDUS:-0}" \
            -e REQUIRE_JUICEFS="${REQUIRE_JUICEFS:-0}" \
            -e HIVEMIND_CONTAINERD_TEST_IMAGE \
            -e HIVEMIND_GPU_TEST_IMAGE \
            -e HIVEMIND_GPU_TYPE \
            -e JUICEFS_TEST_META_URL \
            "$IMAGE-full-stack"
        ;;
    *)
        echo "usage: run-tests.sh [--check|--component|--full-stack]" >&2
        exit 2
        ;;
esac
