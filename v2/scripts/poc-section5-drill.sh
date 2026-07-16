#!/usr/bin/env bash
set -euo pipefail

# Run only POC Section 5 failure drills against already-live Hivemind POC infra.
# No Terraform apply, no Docker build/push, no EKS, no teardown.
#
# Preconditions:
#   - infra/poc Terraform state has live outputs
#   - Hivemind binaries/services are already deployed
#   - CPU_IMAGE is set, or artifacts/poc-final/00-runbook/images-*.env exists
#
# Usage:
#   SSH_KEY=$HOME/.ssh/id_ed25519 bash scripts/poc-section5-drill.sh
#   SECTION5_TIMEOUT_SECONDS=900 CPU_IMAGE=... bash scripts/poc-section5-drill.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GPU_TYPE="${GPU_TYPE:-t4}"
SECTION5_TIMEOUT_SECONDS="${SECTION5_TIMEOUT_SECONDS:-1200}"
TAG="${TAG:-section5-$(date +%Y%m%d%H%M%S)}"
ARTIFACT_ROOT="$ROOT_DIR/artifacts/poc-final"
OUT_DIR="${OUT_DIR:-$ARTIFACT_ROOT/05-failure-drills}"
LOG="$ARTIFACT_ROOT/00-runbook/section5-$TAG.log"
RUN_EKS="${RUN_EKS:-false}"

mkdir -p "$ARTIFACT_ROOT/00-runbook" "$OUT_DIR"
exec > >(tee -a "$LOG") 2>&1

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

raw_output() {
    local name="$1"
    terraform -chdir="$ROOT_DIR/infra/poc" output -raw "$name"
}

array_output_csv() {
    local name="$1"
    terraform -chdir="$ROOT_DIR/infra/poc" output -json "$name" | jq -r 'join(",")'
}

latest_image_env() {
    find "$ARTIFACT_ROOT/00-runbook" -maxdepth 1 -name 'images-*.env' -type f -print 2>/dev/null | sort | tail -1
}

run_with_timeout() {
    local seconds="$1"
    shift

    "$@" &
    local child=$!

    (
        sleep "$seconds"
        if kill -0 "$child" 2>/dev/null; then
            echo "TIMEOUT: command exceeded ${seconds}s; sending TERM to pid $child" >&2
            kill -TERM "$child" 2>/dev/null || true
            sleep 10
            if kill -0 "$child" 2>/dev/null; then
                echo "TIMEOUT: pid $child still alive; sending KILL" >&2
                kill -KILL "$child" 2>/dev/null || true
            fi
        fi
    ) &
    local watchdog=$!

    set +e
    wait "$child"
    local status=$?
    set -e

    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    if [[ "$status" -eq 143 || "$status" -eq 137 ]]; then
        return 124
    fi
    return "$status"
}

need terraform
need jq
need curl
need ssh
need python3

if [[ "$RUN_EKS" == "true" ]]; then
    echo "refusing RUN_EKS=true in Section 5-only runner" >&2
    exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
    echo "SSH key not found: $SSH_KEY" >&2
    exit 1
fi

if ! terraform -chdir="$ROOT_DIR/infra/poc" state list >/dev/null 2>&1; then
    echo "infra/poc has no readable Terraform state; run apply/deploy first" >&2
    exit 1
fi
if [[ -z "$(terraform -chdir="$ROOT_DIR/infra/poc" state list 2>/dev/null)" ]]; then
    echo "infra/poc Terraform state is empty; no live Hivemind infra to drill" >&2
    exit 1
fi

if [[ -z "${CPU_IMAGE:-}" ]]; then
    env_file="$(latest_image_env)"
    if [[ -z "$env_file" ]]; then
        echo "CPU_IMAGE is unset and no images-*.env artifact exists" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$env_file"
fi
if [[ -z "${CPU_IMAGE:-}" ]]; then
    echo "CPU_IMAGE could not be determined" >&2
    exit 1
fi

API_URL="${API_URL:-$(raw_output api_url)}"
REPLICA_PUBLIC_IPS="${REPLICA_PUBLIC_IPS:-$(array_output_csv replica_public_ips)}"
WORKER_CPU_PUBLIC_IP="${WORKER_CPU_PUBLIC_IP:-$(raw_output worker_cpu_public_ip)}"
WORKER_GPU_PUBLIC_IP="${WORKER_GPU_PUBLIC_IP:-$(raw_output worker_gpu_public_ip)}"

if ! curl -fsS --max-time 10 "$API_URL/v1/health" >/dev/null; then
    echo "API health check failed before Section 5 drill: $API_URL/v1/health" >&2
    exit 1
fi

cat <<INFO
section5_tag=$TAG
api_url=$API_URL
replica_public_ips=$REPLICA_PUBLIC_IPS
worker_cpu_public_ip=$WORKER_CPU_PUBLIC_IP
worker_gpu_public_ip=$WORKER_GPU_PUBLIC_IP
cpu_image=$CPU_IMAGE
timeout_seconds=$SECTION5_TIMEOUT_SECONDS
out_dir=$OUT_DIR
log=$LOG
INFO

export CPU_IMAGE OUT_DIR

set +e
run_with_timeout "$SECTION5_TIMEOUT_SECONDS" \
    bash "$ROOT_DIR/infra/poc/failure-drills.sh" "$API_URL" \
    --ssh-key "$SSH_KEY" \
    --replica-ips "$REPLICA_PUBLIC_IPS" \
    --cpu-worker-ip "$WORKER_CPU_PUBLIC_IP" \
    --gpu-worker-ip "$WORKER_GPU_PUBLIC_IP" \
    --gpu-type "$GPU_TYPE"
status=$?
set -e

if [[ "$status" -eq 124 ]]; then
    echo "Section 5 drill timed out after ${SECTION5_TIMEOUT_SECONDS}s" >&2
elif [[ "$status" -ne 0 ]]; then
    echo "Section 5 drill failed with status $status" >&2
else
    echo "Section 5 drill passed"
fi

echo "log=$LOG"
echo "evidence=$OUT_DIR"
exit "$status"
