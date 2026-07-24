#!/usr/bin/env bash
set -euo pipefail

# End-to-end Hivemind POC runbook orchestrator.
# Safe defaults:
#   - only touches infra/poc and infra/poc-eks Terraform states
#   - Hivemind workload ECR repository is Terraform-managed under infra/poc
#   - exit trap destroys requested resources even if smoke/workload/drill steps fail
#   - EKS is opt-in with RUN_EKS=true
#
# Required:
#   SSH_KEY=~/.ssh/id_ed25519
#
# Optional:
#   ECR_REPOSITORY=hivemind-poc   # Terraform-managed ECR repo name
#   SSH_CIDR=<deployer-ip>/32     # auto-detected if omitted
#   ADOPT_EXISTING_ECR=true       # import an existing same-name repo into Terraform state
#
# This executor is invoked only by tests/live/execute-reviewed-plan.sh after
# guarded authorization, reviewed-plan verification, and cleanup trap setup.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${HIVEMIND_GUARDRAILS_ACTIVE:-0}" == 1 && "${HIVEMIND_ALLOW_LIVE:-0}" == 1 &&
   "${HIVEMIND_LIVE_GUARD_NONCE:-}" =~ ^[0-9a-f]{32}$ ]] || {
    echo "refusing live runbook outside tests/live/run.sh guardrails" >&2
    exit 1
}
python3 - "$PPID" "$ROOT_DIR/tests/live/execute-reviewed-plan.sh" "$ROOT_DIR/tests/live/run.sh" <<'PY' || {
import os, sys
pid = int(sys.argv[1])
required = [os.path.realpath(path) for path in sys.argv[2:]]
seen = set()
for _ in range(5):
    try:
        argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        stat = open(f"/proc/{pid}/stat", encoding="ascii").read().split()
    except (FileNotFoundError, PermissionError, ValueError):
        break
    for raw in argv:
        if not raw:
            continue
        value = os.fsdecode(raw)
        if "/" in value:
            seen.add(os.path.realpath(value))
    pid = int(stat[3])
if not all(path in seen for path in required):
    raise SystemExit(1)
PY
    echo "refusing live runbook outside tests/live/run.sh guardrails" >&2
    exit 1
}
# shellcheck source=../infra/poc/http.sh
# shellcheck disable=SC1091 # ROOT_DIR resolves to the known repository helper.
source "$ROOT_DIR/infra/poc/http.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
ECR_REPOSITORY="${ECR_REPOSITORY:-hivemind-poc}"
SSH_CIDR="${SSH_CIDR:-${TF_VAR_ssh_cidr:-}}"
TAG="${TAG:-poc-$(date +%Y%m%d%H%M%S)}"
GPU_TYPE="${GPU_TYPE:-t4}"
RUN_EKS="${RUN_EKS:-false}"
DESTROY_HIVEMIND_AFTER="${DESTROY_HIVEMIND_AFTER:-false}"
DESTROY_EKS_AFTER="${DESTROY_EKS_AFTER:-false}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-false}"
SKIP_HIVEMIND_APPLY="${SKIP_HIVEMIND_APPLY:-false}"
SKIP_HIVEMIND_DEPLOY="${SKIP_HIVEMIND_DEPLOY:-false}"
SKIP_FAILURE_DRILLS="${SKIP_FAILURE_DRILLS:-false}"
SKIP_OPERATOR_WORKFLOW="${SKIP_OPERATOR_WORKFLOW:-false}"
SKIP_WORKLOAD_PRELOAD="${SKIP_WORKLOAD_PRELOAD:-false}"
PRELOAD_EKS_WORKLOAD_IMAGES="${PRELOAD_EKS_WORKLOAD_IMAGES:-false}"
CAPTURE_REMOTE_LOGS="${CAPTURE_REMOTE_LOGS:-true}"
ADOPT_EXISTING_ECR="${ADOPT_EXISTING_ECR:-false}"
REQUIRE_CONTAINERD="${REQUIRE_CONTAINERD:-0}"
REQUIRE_GPU="${REQUIRE_GPU:-0}"
REQUIRE_NYDUS="${REQUIRE_NYDUS:-0}"
REQUIRE_JUICEFS="${REQUIRE_JUICEFS:-0}"
REQUIRE_ECR_COLD_PULL="${REQUIRE_ECR_COLD_PULL:-0}"
for pair in "REQUIRE_CONTAINERD:$REQUIRE_CONTAINERD" "REQUIRE_GPU:$REQUIRE_GPU" "REQUIRE_NYDUS:$REQUIRE_NYDUS" "REQUIRE_JUICEFS:$REQUIRE_JUICEFS" "REQUIRE_ECR_COLD_PULL:$REQUIRE_ECR_COLD_PULL"; do
    name="${pair%%:*}"; value="${pair#*:}"
    [[ "$value" == 0 || "$value" == 1 ]] || { echo "$name must be 0 or 1" >&2; exit 2; }
done
if [[ "$REQUIRE_JUICEFS" == 1 ]]; then
    echo "REQUIRE_JUICEFS=1: current API/AppSpec cannot request a required JuiceFS mount; failing rather than skipping" >&2
    exit 1
fi

API_URL=""
REPLICA_PUBLIC_IPS=""
WORKER_CPU_PUBLIC_IP=""
WORKER_GPU_PUBLIC_IP=""

ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT_DIR/artifacts/poc-final}"
[[ "$ARTIFACT_ROOT" == /* ]] || { echo "ARTIFACT_ROOT must be absolute" >&2; exit 2; }
mkdir -p "$ARTIFACT_ROOT/00-runbook" "$ARTIFACT_ROOT/01-infra" "$ARTIFACT_ROOT/04-workloads" "$ARTIFACT_ROOT/05-operator" "$ARTIFACT_ROOT/05-failure-drills" "$ARTIFACT_ROOT/06-benchmarks"
chmod 700 "$ARTIFACT_ROOT/00-runbook" "$ARTIFACT_ROOT/01-infra" "$ARTIFACT_ROOT/04-workloads" "$ARTIFACT_ROOT/05-operator" "$ARTIFACT_ROOT/05-failure-drills" "$ARTIFACT_ROOT/06-benchmarks"
LOG="$ARTIFACT_ROOT/00-runbook/runbook-$TAG.log"
exec > >(tee -a "$LOG") 2>&1

CLEANUP_STARTED=false

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

section() {
    echo ""
    echo "=== $* ==="
}

confirm_path_safety() {
    local path="$1"
    case "$path" in
        "$ROOT_DIR/infra/poc"|"$ROOT_DIR/infra/poc-eks") ;;
        *) echo "refusing to run terraform outside isolated POC dirs: $path" >&2; exit 1 ;;
    esac
}

terraform_apply_dir() {
    local dir="$1"
    confirm_path_safety "$dir"
    (cd "$dir" && terraform init -input=false)
    if [[ "$dir" == "$ROOT_DIR/infra/poc" ]]; then
        guard_ecr_state "$dir"
    fi
    (cd "$dir" && terraform apply -auto-approve)
}

json_output_array_csv() {
    local dir="$1" name="$2"
    (cd "$dir" && terraform output -json "$name" | jq -r 'join(",")')
}

raw_output() {
    local dir="$1" name="$2"
    (cd "$dir" && terraform output -raw "$name")
}

ecr_repository_name() {
    if [[ -z "$ECR_REPOSITORY" ]]; then
        echo "ECR_REPOSITORY must not be empty" >&2
        exit 1
    fi
    if [[ "$ECR_REPOSITORY" == *.dkr.ecr.*.amazonaws.com/* ]]; then
        echo "${ECR_REPOSITORY#*/}"
        return 0
    fi
    echo "$ECR_REPOSITORY"
}

guard_ecr_state() {
    local dir="$1"
    if (cd "$dir" && terraform state show aws_ecr_repository.workloads >/dev/null 2>&1); then
        return 0
    fi
    if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPOSITORY_NAME" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$ADOPT_EXISTING_ECR" != "true" ]]; then
        echo "ECR repo '$ECR_REPOSITORY_NAME' already exists outside this Terraform state." >&2
        echo "Choose a different ECR_REPOSITORY or set ADOPT_EXISTING_ECR=true to import it for Terraform teardown." >&2
        exit 1
    fi
    echo "importing existing ECR repo into Terraform state: $ECR_REPOSITORY_NAME"
    (cd "$dir" && terraform import -input=false aws_ecr_repository.workloads "$ECR_REPOSITORY_NAME")
}

configure_ssh_cidr() {
    if [[ -z "$SSH_CIDR" ]]; then
        local deployer_ip
        deployer_ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
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
    echo "ssh_cidr=$SSH_CIDR"
}

run_teardown_on_exit() {
    local status="$?"
    trap - EXIT

    if [[ "$CLEANUP_STARTED" == "true" ]]; then
        exit "$status"
    fi
    CLEANUP_STARTED=true

    if [[ "$status" -ne 0 ]]; then
        capture_remote_logs || true
    fi

    if [[ "$DESTROY_HIVEMIND_AFTER" == "true" || "$DESTROY_EKS_AFTER" == "true" ]]; then
        section "Exit teardown"
        DESTROY_HIVEMIND="$DESTROY_HIVEMIND_AFTER" DESTROY_EKS="$DESTROY_EKS_AFTER" \
            bash "$ROOT_DIR/scripts/poc-teardown.sh" || status=1
    fi

    exit "$status"
}
trap run_teardown_on_exit EXIT

capture_ssh() {
    local user="$1"
    local host="$2"
    local name="$3"
    local command="$4"
    local out_dir="$ARTIFACT_ROOT/00-runbook/remote-logs-$TAG"
    local safe_name="${name//[^A-Za-z0-9_.-]/_}"
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes -i "$SSH_KEY")

    install -d -m 700 "$out_dir"
    echo "capture_remote_log host=$host name=$name"
    printf '%s\n' "$command" | ssh "${ssh_opts[@]}" "$user@$host" 'bash -s' > "$out_dir/$safe_name.txt" 2>&1 || true
}

capture_remote_logs() {
    if [[ "$CAPTURE_REMOTE_LOGS" != "true" ]]; then
        return 0
    fi
    if [[ -z "$REPLICA_PUBLIC_IPS" && -z "$WORKER_CPU_PUBLIC_IP" && -z "$WORKER_GPU_PUBLIC_IP" ]]; then
        return 0
    fi

    section "Remote log capture"
    local replica_cmd='hostname; date; uptime; sudo systemctl --no-pager status hivemind hivemind-api --lines=80 || true; sudo journalctl -u hivemind -u hivemind-api --no-pager -n 300 || true; sudo ss -ltnp || true; ls -la /opt/hivemind /usr/local/bin/hivemind* 2>/dev/null || true'
    local worker_cmd='hostname; date; uptime; sudo systemctl --no-pager status hivemind-worker containerd --lines=80 || true; sudo journalctl -u hivemind-worker -u containerd --no-pager -n 300 || true; sudo ctr -n hivemind images ls || true; sudo ctr -n hivemind containers ls || true; sudo ctr -n hivemind tasks ls || true; sudo ss -ltnp || true; ls -la /opt/hivemind /usr/local/bin/hivemind-worker 2>/dev/null || true'

    local replicas=()
    if [[ -n "$REPLICA_PUBLIC_IPS" ]]; then
        IFS=',' read -ra replicas <<< "$REPLICA_PUBLIC_IPS"
    fi
    local idx=0
    for ip in "${replicas[@]}"; do
        [[ -n "$ip" ]] || continue
        capture_ssh ec2-user "$ip" "replica-$idx-$ip" "$replica_cmd"
        idx=$((idx + 1))
    done
    if [[ -n "$WORKER_CPU_PUBLIC_IP" ]]; then
        capture_ssh ubuntu "$WORKER_CPU_PUBLIC_IP" "worker-cpu-$WORKER_CPU_PUBLIC_IP" "$worker_cmd"
    fi
    if [[ -n "$WORKER_GPU_PUBLIC_IP" ]]; then
        capture_ssh ubuntu "$WORKER_GPU_PUBLIC_IP" "worker-gpu-$WORKER_GPU_PUBLIC_IP" "$worker_cmd"
    fi
    echo "remote_logs=$ARTIFACT_ROOT/00-runbook/remote-logs-$TAG"
}

preload_image_to_worker() {
    local image="$1"
    local worker_ip="$2"
    local label="$3"
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -i "$SSH_KEY")

    local image_q
    image_q="$(printf '%q' "$image")"

    echo "preload_image worker=$worker_ip label=$label image=$image"
    if command -v docker >/dev/null 2>&1; then
        local remote_tmp="/tmp/hivemind-${label}-${TAG}.tar"
        local remote_tmp_q
        remote_tmp_q="$(printf '%q' "$remote_tmp")"
        local remote_command
        remote_command="set -euo pipefail; trap 'rm -f $remote_tmp_q' EXIT; cat > $remote_tmp_q; sudo ctr -n hivemind images import $remote_tmp_q >/tmp/hivemind-${label}-image-import.log 2>&1; sudo ctr -n hivemind images ls -q | grep -Fx $image_q >/dev/null"
        # shellcheck disable=SC2029 # Command is intentionally assembled from shell-quoted local values; stdin carries the image tar.
        docker image save "$image" | ssh "${ssh_opts[@]}" "ubuntu@$worker_ip" "$remote_command"
    else
        local registry_host password password_q
        registry_host="${image%%/*}"
        if [[ "$registry_host" != *.dkr.ecr.*.amazonaws.com ]]; then
            echo "docker missing and image is not ECR-backed: $image" >&2
            return 1
        fi
        password="$(aws ecr get-login-password --region "$AWS_REGION")"
        password_q="$(printf '%q' "$password")"
        local remote_command
        remote_command="set -euo pipefail; sudo ctr -n hivemind images pull --user AWS:$password_q $image_q >/tmp/hivemind-${label}-image-pull.log 2>&1; sudo ctr -n hivemind images ls -q | grep -Fx $image_q >/dev/null"
        printf '%s\n' "$remote_command" | ssh "${ssh_opts[@]}" "ubuntu@$worker_ip" 'bash -s'
    fi

    printf '%s\n' "sudo ctr -n hivemind images ls -q | grep -Fx $image_q" | \
        ssh "${ssh_opts[@]}" "ubuntu@$worker_ip" 'bash -s'
}

prove_worker_runtime_capabilities() {
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -i "$SSH_KEY")
    if [[ "$REQUIRE_CONTAINERD" == 1 ]]; then
        printf '%s\n' 'set -euo pipefail; sudo ctr version; systemctl cat hivemind-worker | grep -F -- "--runtime containerd"' |
            ssh "${ssh_opts[@]}" "ubuntu@$WORKER_CPU_PUBLIC_IP" 'bash -s'
        echo "PASS: REQUIRE_CONTAINERD=1 worker service uses reachable containerd"
    else
        echo "SKIP: strict containerd worker proof not required"
    fi
    if [[ "$REQUIRE_NYDUS" == 1 ]]; then
        # shellcheck disable=SC2016 # This complete script is intentionally evaluated by the remote shell.
        printf '%s\n' 'set -euo pipefail; sudo ctr plugins list | awk '\''$1 == "io.containerd.snapshotter.v1" && $2 == "nydus" && $4 == "ok" {found=1} END {exit !found}'\''; for id in $(sudo ctr -n hivemind containers list -q); do sudo ctr -n hivemind containers info "$id"; done | grep -qi nydus' |
            ssh "${ssh_opts[@]}" "ubuntu@$WORKER_CPU_PUBLIC_IP" 'bash -s'
        echo "PASS: REQUIRE_NYDUS=1 healthy plugin and active container evidence"
    else
        echo "SKIP: strict Nydus proof not required"
    fi
}

preload_worker_images() {
    if [[ "$SKIP_WORKLOAD_PRELOAD" == "true" ]]; then
        echo "skip workload image preload"
        return 0
    fi
    need ssh
    preload_image_to_worker "$CPU_IMAGE" "$WORKER_CPU_PUBLIC_IP" cpu-on-cpu
    preload_image_to_worker "$CPU_IMAGE" "$WORKER_GPU_PUBLIC_IP" cpu-on-gpu
    preload_image_to_worker "$GPU_IMAGE" "$WORKER_GPU_PUBLIC_IP" gpu-on-gpu
}

preload_eks_images() {
    if [[ "$PRELOAD_EKS_WORKLOAD_IMAGES" != "true" ]]; then
        echo "skip EKS image preload"
        return 0
    fi
    need kubectl

    local namespace="hivemind-preload-$TAG"
    echo "preload_eks_images namespace=$namespace"
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$namespace" apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: preload-cpu
spec:
  selector:
    matchLabels:
      app: preload-cpu
  template:
    metadata:
      labels:
        app: preload-cpu
    spec:
      nodeSelector:
        eks.amazonaws.com/nodegroup: cpu-workers
      tolerations:
      - operator: Exists
      containers:
      - name: preload
        image: $CPU_IMAGE
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "sleep 3600"]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: preload-gpu
spec:
  selector:
    matchLabels:
      app: preload-gpu
  template:
    metadata:
      labels:
        app: preload-gpu
    spec:
      nodeSelector:
        eks.amazonaws.com/nodegroup: gpu-workers
      tolerations:
      - operator: Exists
      containers:
      - name: preload
        image: $GPU_IMAGE
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "sleep 3600"]
EOF
    kubectl -n "$namespace" rollout status daemonset/preload-cpu --timeout=300s
    kubectl -n "$namespace" rollout status daemonset/preload-gpu --timeout=900s
    kubectl -n "$namespace" get pods -o wide
    kubectl delete namespace "$namespace" --wait=true
}

write_env_file() {
    local env_file="$ARTIFACT_ROOT/00-runbook/images-$TAG.env"
    cat > "$env_file" <<ENV
CPU_IMAGE=$CPU_IMAGE
GPU_IMAGE=$GPU_IMAGE
TAG=$TAG
REGISTRY=$REGISTRY
AWS_REGION=$AWS_REGION
SSH_CIDR=$SSH_CIDR
ENV
    echo "image_env=$env_file"
}

need aws
need curl
need jq
need terraform
need python3

ECR_REPOSITORY_NAME="$(ecr_repository_name)"
export TF_VAR_ecr_repository_name="$ECR_REPOSITORY_NAME"
export TF_VAR_region="$AWS_REGION"
configure_ssh_cidr

section "1. Apply isolated Hivemind POC infra"
if [[ "$SKIP_HIVEMIND_APPLY" != "true" ]]; then
    terraform_apply_dir "$ROOT_DIR/infra/poc"
else
    echo "skip Hivemind terraform apply"
fi
(cd "$ROOT_DIR/infra/poc" && terraform output > "$ARTIFACT_ROOT/01-infra/terraform-outputs-$TAG.txt")
API_URL="$(raw_output "$ROOT_DIR/infra/poc" api_url)"
REPLICA_PUBLIC_IPS="$(json_output_array_csv "$ROOT_DIR/infra/poc" replica_public_ips)"
WORKER_CPU_PUBLIC_IP="$(raw_output "$ROOT_DIR/infra/poc" worker_cpu_public_ip)"
WORKER_GPU_PUBLIC_IP="$(raw_output "$ROOT_DIR/infra/poc" worker_gpu_public_ip)"
REGISTRY="$(raw_output "$ROOT_DIR/infra/poc" ecr_repository_url)"
echo "api_url=$API_URL"
echo "replica_public_ips=$REPLICA_PUBLIC_IPS"
echo "worker_cpu_public_ip=$WORKER_CPU_PUBLIC_IP"
echo "worker_gpu_public_ip=$WORKER_GPU_PUBLIC_IP"
echo "ecr_repository_url=$REGISTRY"

section "2. Build and push workload images"
if [[ "$SKIP_IMAGE_BUILD" == "true" ]]; then
    CPU_IMAGE="${CPU_IMAGE:?set CPU_IMAGE when SKIP_IMAGE_BUILD=true}"
    GPU_IMAGE="${GPU_IMAGE:?set GPU_IMAGE when SKIP_IMAGE_BUILD=true}"
    REGISTRY="${REGISTRY:-manual}"
else
    need docker
    build_output="$(REGISTRY="$REGISTRY" TAG="$TAG" bash "$ROOT_DIR/infra/poc/build-workload-images.sh")"
    echo "$build_output"
    CPU_IMAGE="$(echo "$build_output" | awk -F= '/^CPU_IMAGE=/{print $2}')"
    GPU_IMAGE="$(echo "$build_output" | awk -F= '/^GPU_IMAGE=/{print $2}')"
fi
[[ -n "$CPU_IMAGE" && -n "$GPU_IMAGE" ]] || { echo "failed to determine CPU_IMAGE/GPU_IMAGE" >&2; exit 1; }
write_env_file

section "3. Deploy Hivemind binaries/services"
if [[ "$SKIP_HIVEMIND_DEPLOY" != "true" ]]; then
    (cd "$ROOT_DIR/infra/poc" && bash deploy.sh --build --key "$SSH_KEY") | tee "$ARTIFACT_ROOT/01-infra/deploy-$TAG.txt"
else
    echo "skip Hivemind deploy"
fi

section "4. Preload workload images into Hivemind workers"
preload_worker_images

section "5. Fresh Hivemind smoke"
(cd "$ROOT_DIR/infra/poc" && bash smoke-test.sh "$API_URL" --gpu-worker "$WORKER_GPU_PUBLIC_IP" --ssh-key "$SSH_KEY" --gpu-type "$GPU_TYPE") \
    | tee "$ARTIFACT_ROOT/01-infra/smoke-fresh-$TAG.txt"
prove_worker_runtime_capabilities
if [[ "$REQUIRE_ECR_COLD_PULL" == 1 ]]; then
    bash "$ROOT_DIR/infra/poc/ecr-cold-pull.sh" "$CPU_IMAGE" "${HIVEMIND_RUN_TOKEN:?}" \
        "$WORKER_CPU_PUBLIC_IP" ubuntu "$ARTIFACT_ROOT/01-infra/ecr-cold-$TAG"
else
    echo "SKIP: private ECR cold-cache pull not required; private-auth acceptance unavailable"
fi

section "6. Section 3 real workload validation"
CPU_IMAGE="$CPU_IMAGE" GPU_IMAGE="$GPU_IMAGE" GPU_TYPE="$GPU_TYPE" OUT_DIR="$ARTIFACT_ROOT/04-workloads" \
    bash "$ROOT_DIR/infra/poc/workload-test.sh" "$API_URL" | tee "$ARTIFACT_ROOT/04-workloads/workload-test-$TAG.txt"

section "7. Section 4 operator workflow proof"
if [[ "$SKIP_OPERATOR_WORKFLOW" != "true" ]]; then
    CPU_IMAGE="$CPU_IMAGE" GPU_IMAGE="$GPU_IMAGE" GPU_TYPE="$GPU_TYPE" OUT_DIR="$ARTIFACT_ROOT/05-operator" \
        bash "$ROOT_DIR/infra/poc/operator-workflow.sh" "$API_URL" | tee "$ARTIFACT_ROOT/05-operator/operator-workflow-$TAG.txt"
else
    echo "skip operator workflow"
fi

section "8. Section 5 failure drills"
if [[ "$SKIP_FAILURE_DRILLS" != "true" ]]; then
    CPU_IMAGE="$CPU_IMAGE" OUT_DIR="$ARTIFACT_ROOT/05-failure-drills" \
        bash "$ROOT_DIR/infra/poc/failure-drills.sh" "$API_URL" \
        --ssh-key "$SSH_KEY" \
        --replica-ips "$REPLICA_PUBLIC_IPS" \
        --cpu-worker-ip "$WORKER_CPU_PUBLIC_IP" \
        --gpu-worker-ip "$WORKER_GPU_PUBLIC_IP" \
        --gpu-type "$GPU_TYPE" | tee "$ARTIFACT_ROOT/05-failure-drills/failure-drills-$TAG.txt"
else
    echo "skip failure drills"
fi

section "9. Optional isolated EKS baseline"
if [[ "$RUN_EKS" == "true" ]]; then
    terraform_apply_dir "$ROOT_DIR/infra/poc-eks"
    EKS_CLUSTER_NAME="$(raw_output "$ROOT_DIR/infra/poc-eks" cluster_name)"
    aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
    preload_eks_images
    CPU_IMAGE="$CPU_IMAGE" GPU_IMAGE="$GPU_IMAGE" OUT_DIR="$ARTIFACT_ROOT/06-benchmarks" \
        bash "$ROOT_DIR/infra/poc-eks/eks-workload-test.sh" | tee "$ARTIFACT_ROOT/06-benchmarks/eks-workload-test-$TAG.txt"
else
    echo "skip EKS baseline. Set RUN_EKS=true to run it."
fi

section "10. Final remote log capture"
capture_remote_logs || true

section "11. Teardown plan"
if [[ "$DESTROY_HIVEMIND_AFTER" == "true" || "$DESTROY_EKS_AFTER" == "true" ]]; then
    echo "teardown requested; exit trap will run scripts/poc-teardown.sh"
else
    echo "infra left up for inspection. Destroy with: bash scripts/poc-teardown.sh"
fi

section "Runbook complete"
echo "log=$LOG"
echo "artifacts=$ARTIFACT_ROOT"
