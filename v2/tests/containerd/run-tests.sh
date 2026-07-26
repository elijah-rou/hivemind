#!/bin/bash
set -euo pipefail

# Containerd gates. --check performs passive, read-only Docker host inspection.
# Actual component/full-stack modes are privileged, opt-in, and never called by fixtures.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:---component}"
DOCKER="${DOCKER:-docker}"
IMAGE="hivemind-containerd-test"
PRIVILEGED_PROBE_IMAGE="${HIVEMIND_PRIVILEGED_PROBE_IMAGE:-docker.io/library/alpine:3.20}"
CONTAINERD_COMMAND_TIMEOUT_SECONDS="${CONTAINERD_COMMAND_TIMEOUT_SECONDS:-900}"
[[ "$CONTAINERD_COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "CONTAINERD_COMMAND_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2; }

run_bounded() {
    timeout --signal=TERM --kill-after=10s "${CONTAINERD_COMMAND_TIMEOUT_SECONDS}s" "$@"
}

check_host() {
    command -v "$DOCKER" >/dev/null 2>&1 || { echo "containerd check: docker command unavailable" >&2; return 1; }
    local os_type
    os_type="$(timeout --foreground --kill-after=2s 15s "$DOCKER" info --format '{{.OSType}}' 2>/dev/null)" || {
        echo "containerd check: Docker daemon unavailable" >&2
        return 1
    }
    [[ "$os_type" == "linux" ]] || { echo "containerd check: Docker daemon is not Linux" >&2; return 1; }
    printf 'docker=%s os=%s passive=verified\n' "$DOCKER" "$os_type"
}

probe_privileged() {
    if ! run_bounded "$DOCKER" run --rm --privileged --network none \
        --entrypoint /bin/true "$PRIVILEGED_PROBE_IMAGE"; then
        echo "containerd check: disposable privileged container probe failed" >&2
        return 1
    fi
}

case "$MODE" in
    --check)
        check_host
        ;;
    --component)
        check_host
        probe_privileged
        echo "==> Building containerd component test image..."
        run_bounded "$DOCKER" build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE" "$REPO_ROOT"
        echo "==> Running containerd component integration tests..."
        run_bounded "$DOCKER" run --rm --privileged "$IMAGE"
        ;;
    --full-stack)
        check_host
        probe_privileged
        echo "==> Building containerd full-stack test image..."
        run_bounded "$DOCKER" build -f "$SCRIPT_DIR/Dockerfile.full-stack" -t "$IMAGE-full-stack" "$REPO_ROOT"
        echo "==> Running full-stack containerd restart/adoption contract..."
        docker_args=(--rm --privileged)
        if [[ "${REQUIRE_GPU:-0}" == 1 ]]; then
            docker_args+=(--gpus all)
            [[ ! -d /etc/cdi ]] || docker_args+=(-v /etc/cdi:/etc/cdi:ro)
            [[ ! -d /var/run/cdi ]] || docker_args+=(-v /var/run/cdi:/var/run/cdi:ro)
        fi
        run_bounded "$DOCKER" run "${docker_args[@]}" \
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
