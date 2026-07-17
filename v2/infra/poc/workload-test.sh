#!/usr/bin/env bash
set -euo pipefail

# Real workload validation for POC section 3.
# Usage:
#   CPU_IMAGE=... GPU_IMAGE=... bash infra/poc/workload-test.sh http://API:8080

API_URL="${1:?Usage: CPU_IMAGE=... GPU_IMAGE=... workload-test.sh <api-url>}"
CPU_IMAGE="${CPU_IMAGE:?set CPU_IMAGE}"
GPU_IMAGE="${GPU_IMAGE:?set GPU_IMAGE}"
GPU_TYPE="${GPU_TYPE:-t4}"
OUT_DIR="${OUT_DIR:-artifacts/poc-final/04-workloads}"
IMAGE_PULL_REGISTRY="${IMAGE_PULL_REGISTRY:-}"
IMAGE_PULL_USERNAME="${IMAGE_PULL_USERNAME:-}"
IMAGE_PULL_PASSWORD="${IMAGE_PULL_PASSWORD:-}"
RUN_ID="${RUN_ID:-$(date +%s)}"
CPU_NAME="poc-cpu-${RUN_ID}"
GPU_NAME="poc-gpu-${RUN_ID}"
install -d -m 700 "$OUT_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run_retry.sh
# shellcheck disable=SC1091 # SCRIPT_DIR resolves to the known POC helper directory.
source "$SCRIPT_DIR/run_retry.sh"

TMP_FILES=()
CPU_ID=""
GPU_ID=""
cleanup() {
    set +e
    if [[ -n "$GPU_ID" ]]; then
        curl -fsS -X DELETE "$API_URL/v1/deployments/$GPU_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$CPU_ID" ]]; then
        curl -fsS -X DELETE "$API_URL/v1/deployments/$CPU_ID" >/dev/null 2>&1 || true
    fi
    for file in "${TMP_FILES[@]}"; do
        rm -f "$file"
    done
}
trap cleanup EXIT

json_get() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

wait_for_dashboard() {
    local name="$1"
    local pattern="$2"
    local attempts="${3:-36}"
    local delay="${4:-5}"
    for i in $(seq 1 "$attempts"); do
        body="$(curl -fsS "$API_URL/dashboard/deployments" || true)"
        if echo "$body" | grep -Eiq "$pattern"; then
            echo "ready: $name attempt=$i"
            return 0
        fi
        echo "waiting: $name attempt=$i/$attempts"
        sleep "$delay"
    done
    echo "timeout waiting for $name" >&2
    return 1
}

run_once() {
    local name="$1"
    local payload_file="$2"
    local out_file="$3"
    local time_file="$4"
    local expected_field="$5"
    local attempts="${6:-36}"
    local delay="${7:-5}"
    if ! hivemind_run_with_retry "$name" \
        "$API_URL/v1/deployments/$name/run" "@$payload_file" \
        "\"$expected_field\"" "$attempts" "$delay" "$out_file"; then
        return 1
    fi
    printf '%s\n' "$HIVEMIND_RUN_TIME" > "$time_file"
    return 0
}

require_response_field() {
    local file="$1"
    local field="$2"
    if ! grep -q "\"$field\"" "$file"; then
        echo "missing field $field in $file" >&2
        cat "$file" >&2
        exit 1
    fi
}

write_create_payloads() {
    local artifact_file="$1"
    local secret_file="$2"
    local name="$3"
    local image="$4"
    local replicas="$5"
    local cpu="$6"
    local memory="$7"
    local gpu_type="$8"
    local gpu_count="$9"

    if [[ -n "$IMAGE_PULL_REGISTRY" || -n "$IMAGE_PULL_USERNAME" || -n "$IMAGE_PULL_PASSWORD" ]]; then
        cat > "$artifact_file" <<JSON
{"name":"$name","image":"$image","replicas":$replicas,"cpu":$cpu,"memory":$memory,"gpu_type":"$gpu_type","gpu_count":$gpu_count,"image_pull_registry":"$IMAGE_PULL_REGISTRY","image_pull_username":"$IMAGE_PULL_USERNAME","image_pull_password":"<redacted>","image_pull_password_is_secret":false}
JSON
        cat > "$secret_file" <<JSON
{"name":"$name","image":"$image","replicas":$replicas,"cpu":$cpu,"memory":$memory,"gpu_type":"$gpu_type","gpu_count":$gpu_count,"image_pull_registry":"$IMAGE_PULL_REGISTRY","image_pull_username":"$IMAGE_PULL_USERNAME","image_pull_password":"$IMAGE_PULL_PASSWORD","image_pull_password_is_secret":false}
JSON
    else
        cat > "$artifact_file" <<JSON
{"name":"$name","image":"$image","replicas":$replicas,"cpu":$cpu,"memory":$memory,"gpu_type":"$gpu_type","gpu_count":$gpu_count}
JSON
        cp "$artifact_file" "$secret_file"
    fi
}

cat > "$OUT_DIR/cpu-run-request.json" <<'JSON'
{"text":"Hivemind should route low-latency inference workloads without Kubernetes."}
JSON
cat > "$OUT_DIR/gpu-run-request.json" <<'JSON'
{"values":[0.05,0.15,0.25,0.35,0.45,0.55,0.65,0.75]}
JSON

CPU_CREATE_PAYLOAD="$OUT_DIR/cpu-create-request.json"
GPU_CREATE_PAYLOAD="$OUT_DIR/gpu-create-request.json"
CPU_CREATE_SECRET="$(mktemp)"
GPU_CREATE_SECRET="$(mktemp)"
TMP_FILES+=("$CPU_CREATE_SECRET" "$GPU_CREATE_SECRET")
write_create_payloads "$CPU_CREATE_PAYLOAD" "$CPU_CREATE_SECRET" "$CPU_NAME" "$CPU_IMAGE" 1 750 512 none 0
write_create_payloads "$GPU_CREATE_PAYLOAD" "$GPU_CREATE_SECRET" "$GPU_NAME" "$GPU_IMAGE" 1 1000 4096 "$GPU_TYPE" 1

CPU_DEPLOY_START_MS="$(now_ms)"
curl -fsS -X POST "$API_URL/v1/deployments" -H 'Content-Type: application/json' --data-binary "@$CPU_CREATE_SECRET" | tee "$OUT_DIR/cpu-create.json"
CPU_ID="$(json_get id < "$OUT_DIR/cpu-create.json")"
wait_for_dashboard "$CPU_NAME" "$CPU_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>"
CPU_DEPLOY_READY_MS="$(now_ms)"
printf '%s\n' "$((CPU_DEPLOY_READY_MS - CPU_DEPLOY_START_MS))" > "$OUT_DIR/cpu-deploy-ready-ms.txt"
echo "CPU deploy->ready: $(cat "$OUT_DIR/cpu-deploy-ready-ms.txt")ms"
run_once "$CPU_NAME" "$OUT_DIR/cpu-run-request.json" "$OUT_DIR/cpu-run-response-cold.json" "$OUT_DIR/cpu-latency-cold.txt" model
run_once "$CPU_NAME" "$OUT_DIR/cpu-run-request.json" "$OUT_DIR/cpu-run-response-warm.json" "$OUT_DIR/cpu-latency-warm.txt" model
require_response_field "$OUT_DIR/cpu-run-response-cold.json" model
require_response_field "$OUT_DIR/cpu-run-response-cold.json" embedding

GPU_DEPLOY_START_MS="$(now_ms)"
curl -fsS -X POST "$API_URL/v1/deployments" -H 'Content-Type: application/json' --data-binary "@$GPU_CREATE_SECRET" | tee "$OUT_DIR/gpu-create.json"
GPU_ID="$(json_get id < "$OUT_DIR/gpu-create.json")"
wait_for_dashboard "$GPU_NAME" "$GPU_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>" 60 5
GPU_DEPLOY_READY_MS="$(now_ms)"
printf '%s\n' "$((GPU_DEPLOY_READY_MS - GPU_DEPLOY_START_MS))" > "$OUT_DIR/gpu-deploy-ready-ms.txt"
echo "GPU deploy->ready: $(cat "$OUT_DIR/gpu-deploy-ready-ms.txt")ms"
run_once "$GPU_NAME" "$OUT_DIR/gpu-run-request.json" "$OUT_DIR/gpu-run-response-cold.json" "$OUT_DIR/gpu-latency-cold.txt" probabilities 90 5
run_once "$GPU_NAME" "$OUT_DIR/gpu-run-request.json" "$OUT_DIR/gpu-run-response-warm.json" "$OUT_DIR/gpu-latency-warm.txt" probabilities 36 5
require_response_field "$OUT_DIR/gpu-run-response-cold.json" probabilities
require_response_field "$OUT_DIR/gpu-run-response-cold.json" cuda

cat > "$OUT_DIR/latency-summary.md" <<EOF
# Workload latency summary

| workload | deployment | id | deploy_ready_ms | cold_s | warm_s |
|---|---|---:|---:|---:|---:|
| CPU | $CPU_NAME | $CPU_ID | $(cat "$OUT_DIR/cpu-deploy-ready-ms.txt") | $(cat "$OUT_DIR/cpu-latency-cold.txt") | $(cat "$OUT_DIR/cpu-latency-warm.txt") |
| GPU | $GPU_NAME | $GPU_ID | $(cat "$OUT_DIR/gpu-deploy-ready-ms.txt") | $(cat "$OUT_DIR/gpu-latency-cold.txt") | $(cat "$OUT_DIR/gpu-latency-warm.txt") |
EOF

curl -fsS "$API_URL/dashboard/deployments" > "$OUT_DIR/deployments.html"
curl -fsS "$API_URL/dashboard/pods" > "$OUT_DIR/pods.html"

echo "CPU_DEPLOYMENT_ID=$CPU_ID"
echo "GPU_DEPLOYMENT_ID=$GPU_ID"
echo "evidence=$OUT_DIR"
