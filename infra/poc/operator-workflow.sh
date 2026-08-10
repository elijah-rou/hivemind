#!/usr/bin/env bash
set -euo pipefail

# Operator workflow proof for POC section 4.
# Requires a live API and pushed CPU_IMAGE/GPU_IMAGE from build-workload-images.sh.

API_URL="${1:?Usage: CPU_IMAGE=... GPU_IMAGE=... operator-workflow.sh <api-url>}"
CPU_IMAGE="${CPU_IMAGE:?set CPU_IMAGE}"
GPU_IMAGE="${GPU_IMAGE:?set GPU_IMAGE}"
CPU_IMAGE_V2="${CPU_IMAGE_V2:-$CPU_IMAGE}"
GPU_TYPE="${GPU_TYPE:-t4}"
OUT_DIR="${OUT_DIR:-artifacts/poc-final/05-operator}"
IMAGE_PULL_REGISTRY="${IMAGE_PULL_REGISTRY:-}"
IMAGE_PULL_USERNAME="${IMAGE_PULL_USERNAME:-}"
IMAGE_PULL_PASSWORD="${IMAGE_PULL_PASSWORD:-}"
RUN_ID="${RUN_ID:-$(date +%s)}"
CPU_NAME="op-cpu-${RUN_ID}"
GPU_NAME="op-gpu-${RUN_ID}"
install -d -m 700 "$OUT_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run_retry.sh
# shellcheck disable=SC1091 # SCRIPT_DIR resolves to the known POC helper directory.
source "$SCRIPT_DIR/run_retry.sh"

TMP_FILES=()
cleanup() {
    for file in "${TMP_FILES[@]}"; do
        rm -f "$file"
    done
}
trap cleanup EXIT

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
api() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -fsS -X "$method" "$API_URL$path" -H 'Content-Type: application/json' --data-binary "@$body"
    else
        curl -fsS -X "$method" "$API_URL$path"
    fi
}
wait_for() {
    local name="$1" pattern="$2" attempts="${3:-36}" delay="${4:-5}"
    for i in $(seq 1 "$attempts"); do
        body="$(curl -fsS "$API_URL/dashboard/deployments" || true)"
        if echo "$body" | grep -Eiq "$pattern"; then
            echo "pass: $name attempt=$i"
            return 0
        fi
        sleep "$delay"
    done
    echo "timeout: $name" >&2
    exit 1
}
run_with_retry() {
    local deployment_name="$1" payload_file="$2" out_file="$3" attempts="${4:-36}" delay="${5:-5}"
    hivemind_run_with_retry "$deployment_name" \
        "$API_URL/v1/deployments/$deployment_name/run" \
        "@$payload_file" '' "$attempts" "$delay" "$out_file"
}

if [[ "${OPERATOR_WORKFLOW_RETRY_FIXTURE:-false}" == "true" ]]; then
    run_with_retry fixture \
        "${OPERATOR_WORKFLOW_RETRY_PAYLOAD:?set OPERATOR_WORKFLOW_RETRY_PAYLOAD}" \
        "${OPERATOR_WORKFLOW_RETRY_OUTPUT:?set OPERATOR_WORKFLOW_RETRY_OUTPUT}" \
        3 0
    exit $?
fi
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

CPU_CREATE_SECRET="$(mktemp)"
GPU_CREATE_SECRET="$(mktemp)"
TMP_FILES+=("$CPU_CREATE_SECRET" "$GPU_CREATE_SECRET")
write_create_payloads "$OUT_DIR/cpu-create-request.json" "$CPU_CREATE_SECRET" "$CPU_NAME" "$CPU_IMAGE" 1 750 512 none 0
write_create_payloads "$OUT_DIR/gpu-create-request.json" "$GPU_CREATE_SECRET" "$GPU_NAME" "$GPU_IMAGE" 1 1000 4096 "$GPU_TYPE" 1

api POST /v1/deployments "$CPU_CREATE_SECRET" | tee "$OUT_DIR/01-create-cpu.json"
CPU_ID="$(json_get id < "$OUT_DIR/01-create-cpu.json")"
wait_for create-cpu "$CPU_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>"

api POST /v1/deployments "$GPU_CREATE_SECRET" | tee "$OUT_DIR/02-create-gpu.json"
GPU_ID="$(json_get id < "$OUT_DIR/02-create-gpu.json")"
wait_for create-gpu "$GPU_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>" 60 5

cat > "$OUT_DIR/cpu-update-request.json" <<JSON
{"image":"$CPU_IMAGE_V2","cpu":750,"memory":512,"gpu_type":"none","gpu_count":0}
JSON
api PUT "/v1/deployments/$CPU_ID" "$OUT_DIR/cpu-update-request.json" | tee "$OUT_DIR/03-update-cpu.json"
api PUT "/v1/deployments/$CPU_ID/rollback" | tee "$OUT_DIR/04-rollback-cpu.json"

cat > "$OUT_DIR/scale-up-request.json" <<'JSON'
{"replicas":2}
JSON
api PUT "/v1/deployments/$CPU_ID/scale" "$OUT_DIR/scale-up-request.json" | tee "$OUT_DIR/05-scale-up.json"
wait_for scale-up "$CPU_NAME</td>.*<span class=\"ok\">2</span> <span class=\"muted\">/2</span>" 36 5

cat > "$OUT_DIR/scale-zero-request.json" <<'JSON'
{"replicas":0}
JSON
api PUT "/v1/deployments/$CPU_ID/scale" "$OUT_DIR/scale-zero-request.json" | tee "$OUT_DIR/06-scale-zero.json"
wait_for scale-zero "$CPU_NAME</td>.*>0</span> <span class=\"muted\">/0</span>" 36 5

cat > "$OUT_DIR/wake-request.json" <<'JSON'
{"text":"wake from zero"}
JSON
run_with_retry "$CPU_NAME" "$OUT_DIR/wake-request.json" "$OUT_DIR/07-wake-response.json"
cat "$OUT_DIR/07-wake-response.json"
wait_for wake-from-zero "$CPU_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>" 36 5

api DELETE "/v1/deployments/$CPU_ID" | tee "$OUT_DIR/08-delete-cpu.json"
api DELETE "/v1/deployments/$GPU_ID" | tee "$OUT_DIR/09-delete-gpu.json"
curl -fsS "$API_URL/dashboard/deployments" > "$OUT_DIR/deployments-final.html"
curl -fsS "$API_URL/dashboard/pods" > "$OUT_DIR/pods-final.html"

echo "evidence=$OUT_DIR"
