#!/usr/bin/env bash
set -euo pipefail

# Opt-in privileged boundary: real Zig replicas + Go API + Rust worker/containerd.
# The outer Docker invocation is disposable, but this script still inventories and
# removes only task/container IDs created after its exact baseline.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CLUSTER_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export LOCAL_CLUSTER_REPO_ROOT
# shellcheck source=../lib/local_cluster.sh disable=SC1091
source "$LOCAL_CLUSTER_REPO_ROOT/tests/lib/local_cluster.sh"

REQUIRE_CONTAINERD="${REQUIRE_CONTAINERD:-1}"
REQUIRE_GPU="${REQUIRE_GPU:-0}"
REQUIRE_NYDUS="${REQUIRE_NYDUS:-0}"
REQUIRE_JUICEFS="${REQUIRE_JUICEFS:-0}"
CONTAINER_IMAGE="${HIVEMIND_CONTAINERD_TEST_IMAGE:-docker.io/mendhak/http-https-echo:31}"
GPU_IMAGE="${HIVEMIND_GPU_TEST_IMAGE:-}"
SNAPSHOTTER="overlayfs"
CONTAINERD_PID=""
BASE_TASKS=""
BASE_CONTAINERS=""
JUICEFS_MOUNT=""
DEPLOYMENT_ID=""
RUN_TOKEN="containerd-$PPID-$$"

for pair in "REQUIRE_CONTAINERD:$REQUIRE_CONTAINERD" "REQUIRE_GPU:$REQUIRE_GPU" "REQUIRE_NYDUS:$REQUIRE_NYDUS" "REQUIRE_JUICEFS:$REQUIRE_JUICEFS"; do
    name="${pair%%:*}"; value="${pair#*:}"
    [[ "$value" == 0 || "$value" == 1 ]] || { echo "FAIL: $name must be 0 or 1" >&2; exit 2; }
done
[[ "$REQUIRE_CONTAINERD" == 1 ]] || { echo "FAIL: full-stack containerd requires REQUIRE_CONTAINERD=1" >&2; exit 2; }
[[ "$RUN_TOKEN" =~ ^[A-Za-z0-9-]+$ ]] || { echo "FAIL: invalid run token" >&2; exit 2; }

ctr_bounded() {
    timeout --foreground --kill-after=2s 15s ctr "$@"
}

ctr_ids() {
    local kind="$1"
    ctr_bounded -n hivemind "$kind" list -q 2>/dev/null | LC_ALL=C sort
}

owned_ids() {
    local baseline="$1" current="$2"
    comm -13 <(printf '%s\n' "$baseline" | sed '/^$/d' | LC_ALL=C sort) \
             <(printf '%s\n' "$current" | sed '/^$/d' | LC_ALL=C sort)
}

cleanup_full_stack() {
    local status=$? cleanup_failed=0 id
    trap - EXIT INT TERM
    set +e
    if [[ -n "$DEPLOYMENT_ID" && -n "${LOCAL_CLUSTER_API_PORT:-}" ]]; then
        curl --connect-timeout 1 --max-time 5 -fsS -X DELETE \
            "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/deployments/$DEPLOYMENT_ID" >/dev/null || true
    fi
    if command -v ctr >/dev/null 2>&1 && timeout --foreground --kill-after=2s 15s ctr version >/dev/null 2>&1; then
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            timeout --foreground --kill-after=2s 15s ctr -n hivemind tasks kill --signal SIGKILL "$id" >/dev/null 2>&1 || true
            timeout --foreground --kill-after=2s 15s ctr -n hivemind tasks rm "$id" >/dev/null 2>&1 || cleanup_failed=1
        done < <(owned_ids "$BASE_TASKS" "$(ctr_ids tasks)")
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            timeout --foreground --kill-after=2s 15s ctr -n hivemind containers rm "$id" >/dev/null 2>&1 || cleanup_failed=1
        done < <(owned_ids "$BASE_CONTAINERS" "$(ctr_ids containers)")
        [[ "$(ctr_ids tasks)" == "$BASE_TASKS" ]] || { echo "cleanup residue: containerd task inventory differs" >&2; cleanup_failed=1; }
        [[ "$(ctr_ids containers)" == "$BASE_CONTAINERS" ]] || { echo "cleanup residue: containerd container inventory differs" >&2; cleanup_failed=1; }
    fi
    if [[ -n "$JUICEFS_MOUNT" ]]; then
        timeout --foreground --kill-after=2s 15s juicefs umount "$JUICEFS_MOUNT" >/dev/null 2>&1 || cleanup_failed=1
        mountpoint -q "$JUICEFS_MOUNT" && cleanup_failed=1
        rmdir "$JUICEFS_MOUNT" 2>/dev/null || true
    fi
    if [[ -n "${LOCAL_CLUSTER_ROOT:-}" ]]; then
        local_cluster_cleanup "$status" || cleanup_failed=1
    fi
    if [[ -n "$CONTAINERD_PID" ]]; then
        kill -TERM "$CONTAINERD_PID" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$CONTAINERD_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$CONTAINERD_PID" 2>/dev/null; then
            kill -KILL "$CONTAINERD_PID" 2>/dev/null || true
        fi
        wait "$CONTAINERD_PID" 2>/dev/null || true
        kill -0 "$CONTAINERD_PID" 2>/dev/null && cleanup_failed=1
    fi
    [[ "$cleanup_failed" == 0 ]] || status=1
    exit "$status"
}
# Installed before starting containerd or acquiring any task, mount, process, or port.
trap cleanup_full_stack EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v containerd >/dev/null
command -v ctr >/dev/null
containerd >"/tmp/$RUN_TOKEN-containerd.log" 2>&1 &
CONTAINERD_PID=$!
containerd_start_deadline=$((SECONDS + 30))
while (( SECONDS < containerd_start_deadline )); do
    timeout --foreground --kill-after=1s 2s ctr version >/dev/null 2>&1 && break
    sleep 0.1
done
ctr_bounded version
BASE_TASKS="$(ctr_ids tasks)"
BASE_CONTAINERS="$(ctr_ids containers)"

if [[ "$REQUIRE_NYDUS" == 1 ]]; then
    ctr_bounded plugins list | awk '$1 == "io.containerd.snapshotter.v1" && $2 == "nydus" && $4 == "ok" {found=1} END {exit !found}'
    SNAPSHOTTER=nydus
    echo "PASS: REQUIRE_NYDUS=1 active snapshotter plugin is healthy"
else
    echo "SKIP: Nydus not required; overlayfs selected"
fi

if [[ "$REQUIRE_JUICEFS" == 1 ]]; then
    : "${JUICEFS_TEST_META_URL:?REQUIRE_JUICEFS=1 requires JUICEFS_TEST_META_URL}"
    command -v juicefs >/dev/null
    JUICEFS_MOUNT="/tmp/hivemind-juicefs-$RUN_TOKEN"
    mkdir -m 700 "$JUICEFS_MOUNT"
    timeout --foreground --kill-after=2s 30s juicefs mount "$JUICEFS_TEST_META_URL" "$JUICEFS_MOUNT"
    mountpoint -q "$JUICEFS_MOUNT"
    printf '%s\n' "$RUN_TOKEN" >"$JUICEFS_MOUNT/$RUN_TOKEN"
    [[ "$(cat "$JUICEFS_MOUNT/$RUN_TOKEN")" == "$RUN_TOKEN" ]]
    rm "$JUICEFS_MOUNT/$RUN_TOKEN"
    echo "PASS: REQUIRE_JUICEFS=1 mounted and completed read/write evidence"
else
    echo "SKIP: JuiceFS not required"
fi

local_cluster_init false false
# local_cluster_init installs its own trap; restore the broader ownership trap.
trap cleanup_full_stack EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
local_cluster_start_replicas
local_cluster_start_api
local_cluster_wait_health

start_containerd_worker() {
    # shellcheck disable=SC2153 # Assigned by sourced local_cluster_init.
    setsid "$LOCAL_CLUSTER_WORKER_BIN" run "$(local_cluster_worker_addrs)" \
        --runtime containerd --snapshotter "$SNAPSHOTTER" \
        --metrics-port "$LOCAL_CLUSTER_WORKER_METRICS_PORT" \
        >"$LOCAL_CLUSTER_ROOT/logs/worker.log" 2>&1 &
    LOCAL_CLUSTER_WORKER_PID=$!
    local_cluster_record_pid "$LOCAL_CLUSTER_WORKER_PID"
}
start_containerd_worker

deployment="ctr-$PPID-$$"
image="$CONTAINER_IMAGE"; gpu_type=none; gpu_count=0
if [[ "$REQUIRE_GPU" == 1 ]]; then
    : "${GPU_IMAGE:?REQUIRE_GPU=1 requires HIVEMIND_GPU_TEST_IMAGE}"
    image="$GPU_IMAGE"; gpu_type="${HIVEMIND_GPU_TYPE:-t4}"; gpu_count=1
fi
create_json="$(curl --connect-timeout 1 --max-time 10 -fsS -X POST \
    "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/deployments" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$deployment\",\"image\":\"$image\",\"replicas\":1,\"cpu\":100,\"memory\":128,\"gpu_type\":\"$gpu_type\",\"gpu_count\":$gpu_count}")"
DEPLOYMENT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$create_json")"
[[ "$DEPLOYMENT_ID" =~ ^[0-9]+$ ]]
local_cluster_wait_deployment "$deployment"

owned_task=""
for _ in $(seq 1 300); do
    mapfile -t task_delta < <(owned_ids "$BASE_TASKS" "$(ctr_ids tasks)")
    [[ "${#task_delta[@]}" == 1 ]] && { owned_task="${task_delta[0]}"; break; }
    sleep 0.2
done
[[ -n "$owned_task" ]]
mapfile -t container_delta < <(owned_ids "$BASE_CONTAINERS" "$(ctr_ids containers)")
[[ "${#container_delta[@]}" == 1 && "${container_delta[0]}" == "$owned_task" ]]

if [[ "$REQUIRE_GPU" == 1 ]]; then
    cdi_info="$(ctr_bounded -n hivemind containers info "$owned_task")"
    grep -q 'nvidia.com/gpu=' <<<"$cdi_info"
    exec_id="gpu-proof-$RUN_TOKEN"
    gpu_evidence="$(timeout --foreground --kill-after=2s 30s ctr -n hivemind tasks exec --exec-id "$exec_id" "$owned_task" nvidia-smi)"
    grep -Eq 'NVIDIA-SMI|Driver Version' <<<"$gpu_evidence"
    echo "PASS: REQUIRE_GPU=1 CDI-selected device visible and in-container nvidia-smi succeeded"
else
    echo "SKIP: GPU not required"
fi

status="$(local_cluster_run "$deployment" 'containerd-before-restart' "$LOCAL_CLUSTER_ROOT/before.out")"
[[ "$status" == 200 && -s "$LOCAL_CLUSTER_ROOT/before.out" ]]
local_cluster_stop_pid "$LOCAL_CLUSTER_WORKER_PID"
LOCAL_CLUSTER_WORKER_PID=""
start_containerd_worker
for _ in $(seq 1 150); do
    leader="$(local_cluster_leader_id 2>/dev/null || true)"
    [[ -n "$leader" ]] && [[ "$(local_cluster_metric "$leader" 'hivemind_connections{type="agents"}' 2>/dev/null || echo 0)" == 1 ]] && break
    sleep 0.2
done
grep -Fxq "$owned_task" < <(ctr_ids tasks)
status="$(local_cluster_run "$deployment" 'containerd-after-restart' "$LOCAL_CLUSTER_ROOT/after.out")"
[[ "$status" == 200 && -s "$LOCAL_CLUSTER_ROOT/after.out" ]]
local_cluster_wait_queue_zero

curl --connect-timeout 1 --max-time 8 -fsS -X DELETE \
    "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/deployments/$DEPLOYMENT_ID" >/dev/null
DEPLOYMENT_ID=""
for _ in $(seq 1 150); do
    [[ "$(ctr_ids tasks)" == "$BASE_TASKS" && "$(ctr_ids containers)" == "$BASE_CONTAINERS" ]] && break
    sleep 0.2
done
[[ "$(ctr_ids tasks)" == "$BASE_TASKS" ]]
[[ "$(ctr_ids containers)" == "$BASE_CONTAINERS" ]]
echo "PASS: full-stack containerd request, worker restart/adoption, and exact cleanup contract"
