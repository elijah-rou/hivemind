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

deployment="run-contract-$$"
local_cluster_create_deployment "$deployment" >"$LOCAL_CLUSTER_ROOT/create.json"
local_cluster_wait_deployment "$deployment"
for _ in $(seq 1 100); do
    leader="$(local_cluster_leader_id)"
    [[ "$(local_cluster_metric "$leader" 'hivemind_pods{phase="running"}' 2>/dev/null || echo 0)" == 1 ]] && break
    sleep 0.2
done
[[ "$(local_cluster_metric "$leader" 'hivemind_pods{phase="running"}')" == 1 ]]

status="$(local_cluster_run "$deployment" 'run-success' "$LOCAL_CLUSTER_ROOT/run-success.out")"
[[ "$status" == 200 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["echo"] == "run-success"; assert value["execution_count"] == 1' "$LOCAL_CLUSTER_ROOT/run-success.out"

status="$(local_cluster_run "$deployment" '__hivemind_test_response_too_large__' "$LOCAL_CLUSTER_ROOT/run-overflow.json")"
[[ "$status" == 502 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["error"] == "response_too_large"; assert value["status"] == 4' "$LOCAL_CLUSTER_ROOT/run-overflow.json"

status="$(local_cluster_run "$deployment" '__hivemind_test_forwarding_failure__' "$LOCAL_CLUSTER_ROOT/run-forwarding.json")"
[[ "$status" == 502 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["error"] == "forwarding_failed"; assert value["status"] == 6' "$LOCAL_CLUSTER_ROOT/run-forwarding.json"

started="$(date +%s%3N)"
status="$(local_cluster_run "$deployment" '__hivemind_test_trickle_deadline__' "$LOCAL_CLUSTER_ROOT/run-trickle.json")"
elapsed=$(( $(date +%s%3N) - started ))
[[ "$status" == 502 && "$elapsed" -ge 400 && "$elapsed" -lt 3000 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["error"] == "forwarding_failed"; assert value["status"] == 6' "$LOCAL_CLUSTER_ROOT/run-trickle.json"

# Abandon a real client after sending a request that cannot complete immediately.
abandon_leader="$(local_cluster_leader_id)"
abandon_enqueued_before="$(local_cluster_metric "$abandon_leader" hivemind_requests_enqueued_total)"
abandon_dispatched_before="$(local_cluster_metric "$abandon_leader" hivemind_requests_dispatched_total)"
python3 - "$(local_cluster_client_port "$abandon_leader")" "$deployment" <<'PY'
import socket,struct,sys
port=int(sys.argv[1]); name=sys.argv[2].encode(); payload=b'__hivemind_test_trickle_deadline__'
body=struct.pack('<Q', 0xabad1dea)+name.ljust(64,b'\0')+struct.pack('<I',len(payload))+payload
inner=struct.pack('<H',6)+bytes([0x22])+body
frame=struct.pack('<I',1+len(inner))+b'\0'+inner
with socket.create_connection(('127.0.0.1',port),timeout=2) as sock:
    sock.sendall(frame)
PY
for _ in $(seq 1 100); do
    abandon_enqueued_after="$(local_cluster_metric "$abandon_leader" hivemind_requests_enqueued_total 2>/dev/null || echo x)"
    [[ "$abandon_enqueued_after" =~ ^[0-9]+$ ]] &&
        (( abandon_enqueued_after == abandon_enqueued_before + 1 )) && break
    sleep 0.05
done
[[ "$abandon_enqueued_after" =~ ^[0-9]+$ ]]
(( abandon_enqueued_after == abandon_enqueued_before + 1 ))
for _ in $(seq 1 100); do
    abandon_dispatched_after="$(local_cluster_metric "$abandon_leader" hivemind_requests_dispatched_total 2>/dev/null || echo x)"
    [[ "$abandon_dispatched_after" =~ ^[0-9]+$ ]] &&
        (( abandon_dispatched_after == abandon_dispatched_before + 1 )) && break
    sleep 0.05
done
[[ "$abandon_dispatched_after" =~ ^[0-9]+$ ]]
(( abandon_dispatched_after == abandon_dispatched_before + 1 ))
local_cluster_wait_queue_zero

# Keep the API-side socket open through a frame relay while the actual leader
# process is killed. After that replica restarts from the same journal as a
# follower, the relay forwards one request to that real replica, records its
# actual status 9, and the API safely reprobes the real addresses exactly once.
stale_leader="$(local_cluster_leader_id)"
relay_port=$((LOCAL_CLUSTER_BASE_PORT + 4))
[[ "$relay_port" -lt "$LOCAL_CLUSTER_PROCESS_BASE_PORT" ]]
setsid python3 - "$relay_port" "$(local_cluster_client_port "$stale_leader")" "$LOCAL_CLUSTER_ROOT/stale-relay.log" <<'PY' &
import socket, struct, sys
listen_port, backend_port, log_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

def read_exact(sock, length):
    data = b''
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data

with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', listen_port))
    listener.listen(4)
    while True:
        front, _ = listener.accept()
        with front:
            front.settimeout(60)
            while True:
                try:
                    header = read_exact(front, 4)
                    length = struct.unpack('<I', header)[0]
                    assert 1 <= length <= 65536
                    request_body = read_exact(front, length)
                    request = header + request_body
                    with socket.create_connection(('127.0.0.1', backend_port), timeout=5) as backend:
                        backend.settimeout(5)
                        backend.sendall(request)
                        reply_header = read_exact(backend, 4)
                        reply_length = struct.unpack('<I', reply_header)[0]
                        assert 1 <= reply_length <= 65536
                        reply_body = read_exact(backend, reply_length)
                    if len(reply_body) >= 13 and reply_body[3] == 0x23:
                        with open(log_path, 'a', encoding='utf-8') as log:
                            log.write(f'run_status={reply_body[12]}\n')
                    front.sendall(reply_header + reply_body)
                except (EOFError, OSError, AssertionError):
                    break
PY
relay_pid=$!
local_cluster_record_pid "$relay_pid"
for _ in $(seq 1 50); do
    python3 - "$relay_port" <<'PY' 2>/dev/null && break
import socket,sys
with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=.2): pass
PY
    sleep 0.1
done
local_cluster_stop_api
local_cluster_start_api "127.0.0.1:$relay_port,$(local_cluster_client_addrs)"
local_cluster_wait_health

local_cluster_stop_replica "$stale_leader"
local_cluster_wait_new_leader "$stale_leader" >/dev/null
stale_follower_ready=false
for _ in $(seq 1 3); do
    local_cluster_start_replica "$stale_leader"
    for _ in $(seq 1 100); do
        stale_status="$(local_cluster_metric "$stale_leader" hivemind_replica_status 2>/dev/null || echo x)"
        stale_is_leader="$(local_cluster_metric "$stale_leader" hivemind_is_leader 2>/dev/null || echo x)"
        if [[ "$stale_status" == 0 ]]; then
            [[ "$stale_is_leader" == 0 ]] && stale_follower_ready=true
            break
        fi
        sleep 0.1
    done
    [[ "$stale_follower_ready" == true ]] && break
    local_cluster_stop_replica "$stale_leader"
    local_cluster_wait_new_leader "$stale_leader" >/dev/null
done
[[ "$stale_follower_ready" == true ]]
[[ "$(local_cluster_metric "$stale_leader" hivemind_replica_status)" == 0 ]]
[[ "$(local_cluster_metric "$stale_leader" hivemind_is_leader)" == 0 ]]
python3 - "$(local_cluster_client_port "$stale_leader")" "$deployment" <<'PY'
import socket, struct, sys
port, name = int(sys.argv[1]), sys.argv[2].encode()
payload = b'core-status-9-proof'
request_id = 0x9000000000000001
raw = struct.pack('<Q', request_id) + name.ljust(64, b'\0') + struct.pack('<I', len(payload)) + payload
inner = struct.pack('<H', 6) + b'\x22' + raw
frame = struct.pack('<I', 1 + len(inner)) + b'\0' + inner
def read_exact(sock, length):
    data = b''
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        assert chunk
        data += chunk
    return data
with socket.create_connection(('127.0.0.1', port), timeout=2) as sock:
    sock.settimeout(2)
    sock.sendall(frame)
    length = struct.unpack('<I', read_exact(sock, 4))[0]
    response = read_exact(sock, length)
assert response[3] == 0x23
assert struct.unpack('<Q', response[4:12])[0] == request_id
assert response[12] == 9
PY
reprobe_dispatched_before_0="$(local_cluster_metric 0 hivemind_requests_dispatched_total)"
reprobe_dispatched_before_1="$(local_cluster_metric 1 hivemind_requests_dispatched_total)"
reprobe_dispatched_before_2="$(local_cluster_metric 2 hivemind_requests_dispatched_total)"
status="$(local_cluster_run "$deployment" 'safe-reprobe-once' "$LOCAL_CLUSTER_ROOT/run-reprobe.out")"
[[ "$status" == 200 ]]
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["echo"] == "safe-reprobe-once"; assert value["execution_count"] == 1' "$LOCAL_CLUSTER_ROOT/run-reprobe.out"
grep -qx 'run_status=9' "$LOCAL_CLUSTER_ROOT/stale-relay.log"
[[ "$(local_cluster_metric "$stale_leader" hivemind_requests_enqueued_total)" == 0 ]]
reprobe_dispatched_after_0="$(local_cluster_metric 0 hivemind_requests_dispatched_total)"
reprobe_dispatched_after_1="$(local_cluster_metric 1 hivemind_requests_dispatched_total)"
reprobe_dispatched_after_2="$(local_cluster_metric 2 hivemind_requests_dispatched_total)"
(( reprobe_dispatched_after_0 >= reprobe_dispatched_before_0 ))
(( reprobe_dispatched_after_1 >= reprobe_dispatched_before_1 ))
(( reprobe_dispatched_after_2 >= reprobe_dispatched_before_2 ))
(( reprobe_dispatched_after_0 + reprobe_dispatched_after_1 + reprobe_dispatched_after_2 ==
   reprobe_dispatched_before_0 + reprobe_dispatched_before_1 + reprobe_dispatched_before_2 + 1 ))
local_cluster_wait_convergence "$deployment" 1

# Real bench performs its production leader probe and workload traffic.
"$LOCAL_CLUSTER_BENCH_BIN" --addrs "$(local_cluster_client_addrs)" --mode workload --deployment "$deployment" -n 2 -payload 32 >"$LOCAL_CLUSTER_ROOT/bench.log"
grep -q 'leader probe' "$LOCAL_CLUSTER_ROOT/bench.log"
grep -q 'Requests:     2' "$LOCAL_CLUSTER_ROOT/bench.log"
local_cluster_wait_queue_zero

# One real worker exists; the current leader's successful direct requests
# advance the single worker dispatch path.
dispatch_leader="$(local_cluster_leader_id)"
dispatched="$(local_cluster_metric "$dispatch_leader" hivemind_requests_dispatched_total)"
[[ "$dispatched" =~ ^[1-9][0-9]*$ ]]

echo "PASS: real-process /run statuses, abandonment, stale-leader reprobe, bench traffic, and exact zero accounting"
