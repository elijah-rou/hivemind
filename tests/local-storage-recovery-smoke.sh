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

local_cluster_init "$BUILD" false
local_cluster_start_replicas
local_cluster_start_api
local_cluster_start_worker
local_cluster_wait_health

original="storage-original-$$"
after_failover="storage-after-failover-$$"
after_restart="storage-after-restart-$$"

local_cluster_create_deployment "$original" >"$LOCAL_CLUSTER_ROOT/create-original.json"
local_cluster_wait_deployment "$original"
initial_commit="$(local_cluster_metric "$(local_cluster_leader_id)" hivemind_consensus_commit)"
[[ "$initial_commit" =~ ^[1-9][0-9]*$ ]]

old_leader="$(local_cluster_leader_id)"
local_cluster_stop_replica "$old_leader"
new_leader="$(local_cluster_wait_new_leader "$old_leader")"
local_cluster_wait_health
[[ "$new_leader" != "$old_leader" ]] || { echo "leader did not change" >&2; exit 1; }

local_cluster_create_deployment "$after_failover" >"$LOCAL_CLUSTER_ROOT/create-after-failover.json"
local_cluster_wait_deployment "$after_failover"
failover_commit="$(local_cluster_metric "$new_leader" hivemind_consensus_commit)"
[[ "$failover_commit" -gt "$initial_commit" ]]

local_cluster_start_replica "$old_leader"
local_cluster_wait_convergence "$original" "$failover_commit"

local_cluster_stop_all
local_cluster_start_replicas
local_cluster_start_api
local_cluster_start_worker
local_cluster_wait_health
local_cluster_wait_deployment "$original"
local_cluster_wait_deployment "$after_failover"
local_cluster_wait_convergence "$original" "$failover_commit"

local_cluster_create_deployment "$after_restart" >"$LOCAL_CLUSTER_ROOT/create-after-restart.json"
local_cluster_wait_deployment "$after_restart"
recovered_commit="$(local_cluster_metric "$(local_cluster_leader_id)" hivemind_consensus_commit)"
[[ "$recovered_commit" -gt "$failover_commit" ]]
local_cluster_wait_convergence "$after_restart" "$recovered_commit"
local_cluster_wait_queue_zero

echo "PASS: retained storage recovered named state across leader and full-cluster restart"
