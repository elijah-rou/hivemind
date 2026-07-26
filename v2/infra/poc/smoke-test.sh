#!/bin/bash
set -euo pipefail

# Hivemind POC smoke test
# Usage:
#   ./smoke-test.sh <api-url> [--gpu-worker <ip>] [--ssh-key <path>] [--gpu-type <type>] [--gpu-ssh-user <user>]
# Example:
#   ./smoke-test.sh http://10.0.1.1:8080 --gpu-worker 54.1.2.3 --ssh-key ~/.ssh/id_ed25519 --gpu-type t4

API_URL="${1:?Usage: ./smoke-test.sh <api-url> [--gpu-worker <ip>] [--ssh-key <path>] [--gpu-type <type>] [--gpu-ssh-user <user>]}"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run_retry.sh
# shellcheck disable=SC1091 # SCRIPT_DIR resolves to the known POC helper directory.
source "$SCRIPT_DIR/run_retry.sh"

GPU_WORKER_IP="${GPU_WORKER_IP:-}"
SSH_KEY="${SSH_KEY:-}"
GPU_SSH_USER="${GPU_SSH_USER:-ubuntu}"
GPU_TYPE="${GPU_TYPE:-t4}"
REQUIRE_GPU="${REQUIRE_GPU:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-worker) GPU_WORKER_IP="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --gpu-type) GPU_TYPE="$2"; shift 2 ;;
        --gpu-ssh-user) GPU_SSH_USER="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$GPU_WORKER_IP" ]] && command -v terraform >/dev/null 2>&1; then
    GPU_WORKER_IP="$(terraform output -raw worker_gpu_public_ip 2>/dev/null || true)"
fi
if [[ "$REQUIRE_GPU" != 0 && "$REQUIRE_GPU" != 1 ]]; then
    echo "FAIL: REQUIRE_GPU must be 0 or 1" >&2
    exit 2
fi
if [[ "$REQUIRE_GPU" == 1 && ( -z "$GPU_WORKER_IP" || -z "$SSH_KEY" || "$GPU_TYPE" == none ) ]]; then
    echo "FAIL: REQUIRE_GPU=1 requires --gpu-worker, --ssh-key, and a non-none --gpu-type" >&2
    exit 1
fi

SSH_OPTS=()
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS=(
        -o IdentityAgent=none
        -o IdentitiesOnly=yes
        -o BatchMode=yes
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -i "$SSH_KEY"
    )
fi

RUN_ID="$(date +%s)-$$"
CPU_DEPLOYMENT_NAME="smoke-cpu-$RUN_ID"
GPU_DEPLOYMENT_NAME="smoke-gpu-$RUN_ID"
CPU_DEPLOYMENT_ID=""
GPU_DEPLOYMENT_ID=""

cleanup() {
    set +e
    if [[ -n "$CPU_DEPLOYMENT_ID" ]]; then
        curl -fsS -X DELETE "$API_URL/v1/deployments/$CPU_DEPLOYMENT_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$GPU_DEPLOYMENT_ID" ]]; then
        curl -fsS -X DELETE "$API_URL/v1/deployments/$GPU_DEPLOYMENT_ID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

json_get() {
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

PASS=0
FAIL=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# Retry a curl until expected string appears or timeout
wait_for() {
    local name="$1"
    local url="$2"
    local expected="$3"
    local max_attempts="${4:-12}"
    local delay="${5:-5}"

    for i in $(seq 1 "$max_attempts"); do
        local result
        result=$(curl -s "$url" 2>/dev/null || echo "")
        if echo "$result" | grep -Eiq "$expected"; then
            echo "  PASS: $name (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        echo "    waiting... ($i/$max_attempts)"
        sleep "$delay"
    done
    echo "  FAIL: $name (timed out after $((max_attempts * delay))s)"
    FAIL=$((FAIL + 1))
    return 1
}

wait_for_run() {
    local name="$1"
    local url="$2"
    local payload="$3"
    local expected="$4"
    local max_attempts="${5:-12}"
    local delay="${6:-5}"

    if hivemind_run_with_retry "$name" "$url" "$payload" "$expected" "$max_attempts" "$delay"; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
    return 1
}

wait_for_remote() {
    local name="$1"
    local remote_cmd="$2"
    local expected="$3"
    local max_attempts="${4:-12}"
    local delay="${5:-5}"

    for i in $(seq 1 "$max_attempts"); do
        local result
        result=$(remote_ssh "$remote_cmd" 2>/dev/null || echo "")
        if echo "$result" | grep -Eiq "$expected"; then
            echo "  PASS: $name (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        echo "    waiting for remote check... ($i/$max_attempts)"
        sleep "$delay"
    done

    echo "  FAIL: $name (timed out after $((max_attempts * delay))s)"
    FAIL=$((FAIL + 1))
    return 1
}

remote_gpu_checks_enabled() {
    [[ -n "$GPU_WORKER_IP" && -n "$SSH_KEY" ]]
}

remote_ssh() {
    local remote_command="$1"
    printf '%s\n' "$remote_command" | ssh "${SSH_OPTS[@]}" "$GPU_SSH_USER@$GPU_WORKER_IP" 'bash -s'
}

echo "=== Hivemind POC Smoke Test ==="
echo "API: $API_URL"
if [[ -n "$GPU_WORKER_IP" ]]; then
    echo "GPU worker: $GPU_WORKER_IP ($GPU_TYPE)"
fi
echo ""

# 1. Health check
echo "[1/11] Health check..."
HEALTH=$(curl -s "$API_URL/v1/health")
check "health endpoint responds" "connected" "$HEALTH"

# 2. Dashboard accessible
echo "[2/11] Dashboard check..."
DASH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/dashboard")
check "dashboard returns 200" "200" "$DASH_STATUS"

# 3. Cluster state renders
echo "[3/11] Cluster state..."
CLUSTER=$(curl -s "$API_URL/dashboard/cluster")
check "cluster section renders" "Consensus" "$CLUSTER"

# 4. Nodes section shows at least one node
echo "[4/11] Nodes check..."
NODES=$(curl -s "$API_URL/dashboard/nodes")
check "nodes section renders" "Nodes" "$NODES"
if [[ "$GPU_TYPE" != "none" ]]; then
    check "gpu node visible" "$GPU_TYPE" "$NODES"
fi

# 5. Workers section shows the gpu worker if present
echo "[5/11] Workers check..."
WORKERS=$(curl -s "$API_URL/dashboard/workers")
check "workers section renders" "Workers" "$WORKERS"
if [[ "$GPU_TYPE" != "none" ]]; then
    check "gpu worker visible" "$GPU_TYPE" "$WORKERS"
fi

# 6. Optional remote GPU readiness checks
echo "[6/11] Remote GPU checks..."
if remote_gpu_checks_enabled; then
    wait_for_remote \
        "gpu worker has nvidia-smi" \
        "nvidia-smi -L" \
        "$GPU_TYPE" 24 10
    wait_for_remote \
        "gpu worker has containerd" \
        "sudo ctr version" \
        "Client:" 12 10
else
    echo "  SKIP: remote GPU checks (provide --gpu-worker and --ssh-key to enable)"
fi

# 7. Create CPU deployment
echo "[7/11] Create CPU deployment..."
DEPLOY_CPU=$(curl -fsS -X POST "$API_URL/v1/deployments" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$CPU_DEPLOYMENT_NAME\",\"image\":\"docker.io/mendhak/http-https-echo:31\",\"replicas\":1,\"cpu\":500,\"memory\":512,\"gpu_type\":\"none\",\"gpu_count\":0}")
check "cpu deployment created" "$CPU_DEPLOYMENT_NAME" "$DEPLOY_CPU"
CPU_DEPLOYMENT_ID="$(json_get id <<< "$DEPLOY_CPU")"
echo "    Response: $DEPLOY_CPU"

echo "    waiting for cpu deployment on dashboard..."
wait_for "cpu deployment visible" "$API_URL/dashboard/deployments" "$CPU_DEPLOYMENT_NAME" 12 5
wait_for "cpu deployment ready" "$API_URL/dashboard/deployments" "$CPU_DEPLOYMENT_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>" 24 5

CPU_RUN_PAYLOAD='{"probe":"poc-smoke-cpu"}'
wait_for_run "cpu run request echoes payload" "$API_URL/v1/deployments/$CPU_DEPLOYMENT_NAME/run" "$CPU_RUN_PAYLOAD" "poc-smoke-cpu" 12 5

# 8. Create GPU deployment
echo "[8/11] Create GPU deployment..."
DEPLOY_GPU=$(curl -fsS -X POST "$API_URL/v1/deployments" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$GPU_DEPLOYMENT_NAME\",\"image\":\"docker.io/mendhak/http-https-echo:31\",\"replicas\":1,\"cpu\":500,\"memory\":512,\"gpu_type\":\"$GPU_TYPE\",\"gpu_count\":1}")
check "gpu deployment created" "$GPU_DEPLOYMENT_NAME" "$DEPLOY_GPU"
GPU_DEPLOYMENT_ID="$(json_get id <<< "$DEPLOY_GPU")"
echo "    Response: $DEPLOY_GPU"

echo "    waiting for gpu deployment on dashboard..."
wait_for "gpu deployment visible" "$API_URL/dashboard/deployments" "$GPU_DEPLOYMENT_NAME" 12 5
wait_for "gpu deployment ready" "$API_URL/dashboard/deployments" "$GPU_DEPLOYMENT_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>" 24 5

GPU_RUN_PAYLOAD='{"probe":"poc-smoke-gpu"}'
wait_for_run "gpu run request echoes payload" "$API_URL/v1/deployments/$GPU_DEPLOYMENT_NAME/run" "$GPU_RUN_PAYLOAD" "poc-smoke-gpu" 24 5

# 9. Optional remote proof that the GPU worker is running a hivemind container via the nvidia runtime
echo "[9/11] Remote GPU runtime proof..."
if remote_gpu_checks_enabled; then
    wait_for_remote \
        "gpu worker task list has hivemind pod" \
        "sudo ctr -n hivemind tasks list" \
        "hivemind-pod-" 24 10
    wait_for_remote \
        "gpu worker container uses nvidia runtime" \
        "cid=\$(sudo ctr -n hivemind tasks list | awk 'NR==2 {print \$1}'); [ -n \"\$cid\" ] && sudo ctr -n hivemind containers info \"\$cid\"" \
        "nvidia" 24 10
else
    echo "  SKIP: remote GPU runtime proof (provide --gpu-worker and --ssh-key to enable)"
fi

# 10. Deployments page shows both slices
echo "[10/11] Deployments check..."
DEPLOYMENTS=$(curl -s "$API_URL/dashboard/deployments")
check "cpu deployment listed" "$CPU_DEPLOYMENT_NAME" "$DEPLOYMENTS"
check "gpu deployment listed" "$GPU_DEPLOYMENT_NAME" "$DEPLOYMENTS"

# 11. Pods page renders after both deployments
echo "[11/11] Pods check..."
PODS=$(curl -s "$API_URL/dashboard/pods")
check "pods section renders" "Pods" "$PODS"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
