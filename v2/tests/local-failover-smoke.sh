#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CLUSTER_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export LOCAL_CLUSTER_REPO_ROOT
# shellcheck source=lib/local_cluster.sh
# shellcheck disable=SC1091 # SCRIPT_DIR resolves to this repository helper.
source "$SCRIPT_DIR/lib/local_cluster.sh"

BUILD=false
[[ "${1:-}" == "--build" ]] && { BUILD=true; shift; }
[[ $# -eq 0 ]] || { echo "usage: $0 [--build]" >&2; exit 2; }

local_cluster_init "$BUILD" true
local_cluster_start_replicas
local_cluster_start_api
local_cluster_start_worker
local_cluster_wait_health

deployment="failover-data-plane-$$"
local_cluster_create_deployment "$deployment" >"$LOCAL_CLUSTER_ROOT/create.json"
local_cluster_wait_deployment "$deployment"

for _ in $(seq 1 100); do
    leader="$(local_cluster_leader_id)"
    [[ "$(local_cluster_metric "$leader" 'hivemind_pods{phase="running"}' 2>/dev/null || echo 0)" == 1 ]] && break
    sleep 0.2
done
[[ "$(local_cluster_metric "$leader" 'hivemind_pods{phase="running"}')" == 1 ]]

status="$(local_cluster_run "$deployment" 'before-leader-loss' "$LOCAL_CLUSTER_ROOT/before.out")"
[[ "$status" == 200 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["echo"] == "before-leader-loss"; assert value["execution_count"] == 1' "$LOCAL_CLUSTER_ROOT/before.out"
old_leader="$(local_cluster_leader_id)"
commit_before="$(local_cluster_metric "$old_leader" hivemind_consensus_commit)"
local_cluster_stop_replica "$old_leader"
new_leader="$(local_cluster_wait_new_leader "$old_leader")"
local_cluster_wait_health
[[ "$new_leader" != "$old_leader" ]]

# Wait for the worker to reconnect before issuing the non-idempotent workload
# exactly once. A transport or ambiguous result is a hard failure, never retried.
for _ in $(seq 1 100); do
    if [[ "$(local_cluster_metric "$new_leader" 'hivemind_connections{type="agents"}' 2>/dev/null || echo 0)" == 1 ]] &&
       [[ "$(local_cluster_metric "$new_leader" 'hivemind_pods{phase="running"}' 2>/dev/null || echo 0)" == 1 ]]; then
        break
    fi
    sleep 0.2
done
[[ "$(local_cluster_metric "$new_leader" 'hivemind_connections{type="agents"}')" == 1 ]]
[[ "$(local_cluster_metric "$new_leader" 'hivemind_pods{phase="running"}')" == 1 ]]
status="$(local_cluster_run "$deployment" 'after-leader-loss' "$LOCAL_CLUSTER_ROOT/after.out")"
[[ "$status" == 200 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["echo"] == "after-leader-loss"; assert value["execution_count"] == 1' "$LOCAL_CLUSTER_ROOT/after.out"

local_cluster_start_replica "$old_leader"
local_cluster_wait_convergence "$deployment" "$commit_before"
local_cluster_wait_queue_zero

echo "PASS: real worker process-runtime traffic continued across three-replica leader failover"
