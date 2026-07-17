#!/usr/bin/env bash
set -euo pipefail

# Bounded Section 5 cycle: apply Hivemind infra, deploy services, build/preload
# CPU workload image, run targeted Section 5 diagnostics, then optionally teardown.
# EKS is intentionally unsupported here.
#
# Usage:
#   SSH_KEY=$HOME/.ssh/id_ed25519 DESTROY_HIVEMIND_AFTER=true bash scripts/poc-section5-cycle.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../infra/poc/http.sh
# shellcheck disable=SC1091 # ROOT_DIR resolves to the known repository helper.
source "$ROOT_DIR/infra/poc/http.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
ECR_REPOSITORY="${ECR_REPOSITORY:-hivemind-poc}"
SSH_CIDR="${SSH_CIDR:-${TF_VAR_ssh_cidr:-}}"
TAG="${TAG:-section5-$(date +%Y%m%d%H%M%S)}"
DESTROY_HIVEMIND_AFTER="${DESTROY_HIVEMIND_AFTER:-true}"
RUN_EKS="${RUN_EKS:-false}"
SECTION5_TIMEOUT_SECONDS="${SECTION5_TIMEOUT_SECONDS:-1200}"
APPLY_TIMEOUT_SECONDS="${APPLY_TIMEOUT_SECONDS:-900}"
CPU_IMAGE_TIMEOUT_SECONDS="${CPU_IMAGE_TIMEOUT_SECONDS:-900}"
DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-900}"
PRELOAD_TIMEOUT_SECONDS="${PRELOAD_TIMEOUT_SECONDS:-600}"

ARTIFACT_ROOT="$ROOT_DIR/artifacts/poc-final"
LOG="$ARTIFACT_ROOT/00-runbook/section5-cycle-$TAG.log"
mkdir -p "$ARTIFACT_ROOT/00-runbook" "$ARTIFACT_ROOT/01-infra"
chmod 700 "$ARTIFACT_ROOT/00-runbook" "$ARTIFACT_ROOT/01-infra"
exec > >(tee -a "$LOG") 2>&1

CLEANUP_STARTED=false
CPU_IMAGE=""
API_URL=""
REPLICA_PUBLIC_IPS=""
WORKER_CPU_PUBLIC_IP=""
WORKER_GPU_PUBLIC_IP=""
REGISTRY=""

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

section() {
    echo ""
    echo "=== $* ==="
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

run_stage() {
    local name="$1"
    local seconds="$2"
    shift 2
    section "$name"
    echo "timeout_seconds=$seconds"
    run_with_timeout "$seconds" "$@"
}

teardown_on_exit() {
    local status="$?"
    trap - EXIT

    if [[ "$CLEANUP_STARTED" == "true" ]]; then
        exit "$status"
    fi
    CLEANUP_STARTED=true

    if [[ "$DESTROY_HIVEMIND_AFTER" == "true" ]]; then
        section "Teardown Hivemind POC infra"
        DESTROY_EKS=false DESTROY_HIVEMIND=true bash "$ROOT_DIR/scripts/poc-teardown.sh" || status=1
    else
        echo "infra left up for inspection. Destroy with: DESTROY_EKS=false DESTROY_HIVEMIND=true bash scripts/poc-teardown.sh"
    fi

    exit "$status"
}
trap teardown_on_exit EXIT

configure_ssh_cidr() {
    if [[ -z "$SSH_CIDR" ]]; then
        local deployer_ip
        deployer_ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
        if [[ -z "$deployer_ip" ]]; then
            echo "failed to auto-detect deployer IP; set SSH_CIDR=<ip>/32" >&2
            exit 1
        fi
        SSH_CIDR="$deployer_ip/32"
    fi
    if [[ "$SSH_CIDR" == "0.0.0.0/0" || "$SSH_CIDR" == "::/0" ]]; then
        echo "refusing public SSH/API CIDR: $SSH_CIDR" >&2
        exit 1
    fi
    export TF_VAR_ssh_cidr="$SSH_CIDR"
    export TF_VAR_region="$AWS_REGION"
    export TF_VAR_ecr_repository_name="$ECR_REPOSITORY"
    echo "ssh_cidr=$SSH_CIDR"
}

read_outputs() {
    API_URL="$(terraform -chdir="$ROOT_DIR/infra/poc" output -raw api_url)"
    REPLICA_PUBLIC_IPS="$(terraform -chdir="$ROOT_DIR/infra/poc" output -json replica_public_ips | jq -r 'join(",")')"
    WORKER_CPU_PUBLIC_IP="$(terraform -chdir="$ROOT_DIR/infra/poc" output -raw worker_cpu_public_ip)"
    WORKER_GPU_PUBLIC_IP="$(terraform -chdir="$ROOT_DIR/infra/poc" output -raw worker_gpu_public_ip)"
    REGISTRY="$(terraform -chdir="$ROOT_DIR/infra/poc" output -raw ecr_repository_url)"
}

apply_infra() {
    terraform -chdir="$ROOT_DIR/infra/poc" init -input=false
    terraform -chdir="$ROOT_DIR/infra/poc" apply -auto-approve
    terraform -chdir="$ROOT_DIR/infra/poc" output > "$ARTIFACT_ROOT/01-infra/terraform-outputs-$TAG.txt"
    read_outputs
    cat <<INFO
api_url=$API_URL
replica_public_ips=$REPLICA_PUBLIC_IPS
worker_cpu_public_ip=$WORKER_CPU_PUBLIC_IP
worker_gpu_public_ip=$WORKER_GPU_PUBLIC_IP
ecr_repository_url=$REGISTRY
INFO
}

build_push_cpu_image() {
    local registry_host="${REGISTRY%%/*}"
    local source_image=""
    CPU_IMAGE="$REGISTRY:cpu-$TAG"

    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry_host"

    source_image="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^${REGISTRY}:cpu-" | head -1 || true)"
    if [[ -n "$source_image" ]]; then
        echo "reuse_local_cpu_image=$source_image"
        docker tag "$source_image" "$CPU_IMAGE"
    else
        DOCKER_BUILDKIT=0 docker build --pull=false --platform linux/amd64 -t "$CPU_IMAGE" "$ROOT_DIR/workloads/poc/cpu"
    fi

    docker push "$CPU_IMAGE"
    cat > "$ARTIFACT_ROOT/00-runbook/images-$TAG.env" <<ENV
CPU_IMAGE=$CPU_IMAGE
TAG=$TAG
REGISTRY=$REGISTRY
AWS_REGION=$AWS_REGION
SSH_CIDR=$SSH_CIDR
ENV
    echo "CPU_IMAGE=$CPU_IMAGE"
}

deploy_hivemind() {
    (cd "$ROOT_DIR/infra/poc" && bash deploy.sh --build --key "$SSH_KEY") | tee "$ARTIFACT_ROOT/01-infra/deploy-$TAG.txt"
}

preload_cpu_image() {
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -i "$SSH_KEY")
    local worker_ip
    for worker_ip in "$WORKER_CPU_PUBLIC_IP" "$WORKER_GPU_PUBLIC_IP"; do
        [[ -n "$worker_ip" ]] || continue
        echo "preload_cpu_image worker=$worker_ip image=$CPU_IMAGE"
        local remote_command
        remote_command="set -euo pipefail; tmp=/tmp/hivemind-cpu-$TAG.tar; trap 'rm -f \"\$tmp\"' EXIT; cat > \"\$tmp\"; sudo ctr -n hivemind images import \"\$tmp\" >/tmp/hivemind-cpu-image-import.log 2>&1; sudo ctr -n hivemind images ls -q | grep -Fx '$CPU_IMAGE' >/dev/null"
        # shellcheck disable=SC2029 # Command is intentionally assembled from quoted local values; stdin carries the image tar.
        docker image save "$CPU_IMAGE" | ssh "${ssh_opts[@]}" "ubuntu@$worker_ip" "$remote_command"
    done
}

run_section5() {
    CPU_IMAGE="$CPU_IMAGE" \
    API_URL="$API_URL" \
    REPLICA_PUBLIC_IPS="$REPLICA_PUBLIC_IPS" \
    WORKER_CPU_PUBLIC_IP="$WORKER_CPU_PUBLIC_IP" \
    WORKER_GPU_PUBLIC_IP="$WORKER_GPU_PUBLIC_IP" \
    SECTION5_TIMEOUT_SECONDS="$SECTION5_TIMEOUT_SECONDS" \
    SSH_KEY="$SSH_KEY" \
    bash "$ROOT_DIR/scripts/poc-section5-drill.sh"
}

need aws
need curl
need docker
need jq
need ssh
need terraform
need python3

if [[ "$RUN_EKS" == "true" ]]; then
    echo "refusing RUN_EKS=true in Section 5 cycle" >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo "SSH key not found: $SSH_KEY" >&2
    exit 1
fi

configure_ssh_cidr

run_stage "1. Apply isolated Hivemind POC infra" "$APPLY_TIMEOUT_SECONDS" apply_infra
read_outputs

run_stage "2. Build and push CPU workload image" "$CPU_IMAGE_TIMEOUT_SECONDS" build_push_cpu_image
CPU_IMAGE="$REGISTRY:cpu-$TAG"

run_stage "3. Deploy Hivemind binaries/services" "$DEPLOY_TIMEOUT_SECONDS" deploy_hivemind
run_stage "4. Preload CPU image into workers" "$PRELOAD_TIMEOUT_SECONDS" preload_cpu_image
run_stage "5. Targeted Section 5 failure drill" "$SECTION5_TIMEOUT_SECONDS" run_section5

section "Section 5 cycle complete"
echo "log=$LOG"
echo "artifacts=$ARTIFACT_ROOT"
