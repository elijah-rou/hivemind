#!/usr/bin/env bash
set -euo pipefail

# Section 5 failure drills — leader loss, worker loss, abandoned run cleanup.
# Usage:
#   bash infra/poc/failure-drills.sh <api-url> \
#     --ssh-key <path> \
#     --replica-ips <ip1,ip2,...> \
#     --cpu-worker-ip <ip> \
#     [--gpu-worker-ip <ip>] \
#     [--gpu-type t4] \
#     [--cpu-image <image>]

API_URL="${1:?Usage: failure-drills.sh <api-url> --ssh-key <key> --replica-ips <ips> --cpu-worker-ip <ip>}"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run_retry.sh
# shellcheck disable=SC1091 # SCRIPT_DIR resolves to the known POC helper directory.
source "$SCRIPT_DIR/run_retry.sh"

SSH_KEY=""
REPLICA_IPS_CSV=""
CPU_WORKER_IP=""
GPU_WORKER_IP=""
CPU_IMAGE="${CPU_IMAGE:-docker.io/mendhak/http-https-echo:31}"
REPLICA_SSH_USER="${REPLICA_SSH_USER:-ec2-user}"
WORKER_SSH_USER="${WORKER_SSH_USER:-ubuntu}"
OUT_DIR="${OUT_DIR:-artifacts/poc-final/05-failure-drills}"
IMAGE_PULL_REGISTRY="${IMAGE_PULL_REGISTRY:-}"
IMAGE_PULL_USERNAME="${IMAGE_PULL_USERNAME:-}"
IMAGE_PULL_PASSWORD="${IMAGE_PULL_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --replica-ips) REPLICA_IPS_CSV="$2"; shift 2 ;;
        --cpu-worker-ip) CPU_WORKER_IP="$2"; shift 2 ;;
        --gpu-worker-ip) GPU_WORKER_IP="$2"; shift 2 ;;
        --gpu-type) shift 2 ;; # Accepted for caller compatibility; this CPU drill does not use it.
        --cpu-image) CPU_IMAGE="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$SSH_KEY" ]] && { echo "--ssh-key required"; exit 1; }
[[ -z "$REPLICA_IPS_CSV" ]] && { echo "--replica-ips required"; exit 1; }
[[ -z "$CPU_WORKER_IP" ]] && { echo "--cpu-worker-ip required"; exit 1; }

IFS=',' read -ra REPLICA_IPS <<< "$REPLICA_IPS_CSV"
install -d -m 700 "$OUT_DIR"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -i "$SSH_KEY")
LEADER_STOPPED_IP=""
CPU_WORKER_STOPPED=false
DRILL_DEPLOYMENT_ID=""
TMP_FILES=()
RUN_RESULT=""

cleanup() {
    trap - EXIT
    set +e
    if [[ -n "$LEADER_STOPPED_IP" ]]; then
        echo "[Cleanup] Restarting stopped leader replica $LEADER_STOPPED_IP..."
        ssh "${SSH_OPTS[@]}" "$REPLICA_SSH_USER@$LEADER_STOPPED_IP" \
            "sudo systemctl start hivemind hivemind-api" 2>/dev/null || true
    fi
    if [[ "$CPU_WORKER_STOPPED" == "true" ]]; then
        echo "[Cleanup] Restarting stopped CPU worker $CPU_WORKER_IP..."
        ssh "${SSH_OPTS[@]}" "$WORKER_SSH_USER@$CPU_WORKER_IP" \
            "sudo systemctl start hivemind-worker" 2>/dev/null || true
    fi
    if [[ -z "$DRILL_DEPLOYMENT_ID" && -f "$OUT_DIR/drill-create.json" ]]; then
        DRILL_DEPLOYMENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$OUT_DIR/drill-create.json" 2>/dev/null || echo "")"
    fi
    if [[ -n "$DRILL_DEPLOYMENT_ID" ]]; then
        echo "[Cleanup] Deleting drill deployment $DRILL_DEPLOYMENT_ID..."
        curl -fsS --max-time 15 -X DELETE "$API_URL/v1/deployments/$DRILL_DEPLOYMENT_ID" >/dev/null 2>&1 || true
    fi
    for file in "${TMP_FILES[@]}"; do
        rm -f "$file"
    done
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
    local name="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qi "$expected"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

wait_api() {
    local name="$1" expected="$2" max="${3:-20}" delay="${4:-3}"
    for i in $(seq 1 "$max"); do
        result="$(curl -s "$API_URL/v1/health" 2>/dev/null || echo "")"
        if echo "$result" | grep -qi "$expected"; then
            echo "  PASS: $name (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$delay"
    done
    echo "  FAIL: $name (timed out)" >&2
    FAIL=$((FAIL + 1))
    return 1
}

capture_worker_runtime_diagnostics() {
    local label="$1"
    local diag_dir="$OUT_DIR/diagnostics-$label"
    install -d -m 700 "$diag_dir"

    echo "[Diagnostics] Capturing worker runtime state: $label -> $diag_dir"
    local workers=("cpu:$CPU_WORKER_IP")
    if [[ -n "$GPU_WORKER_IP" ]]; then
        workers+=("gpu:$GPU_WORKER_IP")
    fi

    for item in "${workers[@]}"; do
        local role="${item%%:*}"
        local public_ip="${item#*:}"
        local out="$diag_dir/worker-$role-${public_ip//./-}.txt"
        echo "  capture $role worker $public_ip"
        ssh "${SSH_OPTS[@]}" "$WORKER_SSH_USER@$public_ip" 'bash -s' > "$out" 2>&1 <<'REMOTE' || true
set +e
echo "== host =="
date -u +%Y-%m-%dT%H:%M:%SZ
hostname
hostname -I

echo
echo "== service =="
systemctl is-active hivemind-worker || true
systemctl status --no-pager hivemind-worker || true

echo
echo "== containerd tasks =="
sudo ctr -n hivemind tasks list || true

echo
echo "== containerd containers =="
sudo ctr -n hivemind containers list || true

echo
echo "== recent worker logs =="
journalctl -u hivemind-worker --since '15 minutes ago' --no-pager || true
REMOTE
    done
}

capture_replica_diagnostics() {
    local label="$1"
    local diag_dir="$OUT_DIR/diagnostics-$label"
    install -d -m 700 "$diag_dir"

    echo "[Diagnostics] Capturing replica state: $label -> $diag_dir"
    {
        echo "label=$label"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "api_url=$API_URL"
        echo "public_api_health=$(curl -s --max-time 5 "$API_URL/v1/health" 2>/dev/null || echo unavailable)"
        echo "killed_leader_addr=${KILLED_LEADER_ADDR:-}"
        echo "leader_stopped_ip=${LEADER_STOPPED_IP:-}"
    } > "$diag_dir/summary.txt"

    for public_ip in "${REPLICA_IPS[@]}"; do
        local safe_ip="${public_ip//./-}"
        local out="$diag_dir/replica-$safe_ip.txt"
        echo "  capture $public_ip"
        ssh "${SSH_OPTS[@]}" "$REPLICA_SSH_USER@$public_ip" 'bash -s' > "$out" 2>&1 <<'REMOTE' || true
set +e
echo "== host =="
date -u +%Y-%m-%dT%H:%M:%SZ
hostname
hostname -I

echo
echo "== services =="
systemctl is-active hivemind || true
systemctl is-active hivemind-api || true
systemctl status --no-pager hivemind hivemind-api || true

echo
echo "== local api health =="
curl -s --max-time 5 http://127.0.0.1:8080/v1/health || true

echo
echo "== consensus metrics =="
curl -s --max-time 5 http://127.0.0.1:9200/metrics 2>/dev/null | grep -E 'hivemind_consensus_|hivemind_is_leader|hivemind_leader_id|hivemind_replica_status|hivemind_view_change_votes|hivemind_repair_pending|hivemind_connections' || true

echo
echo "== sockets 9001/9102 =="
ss -tanp | grep -E ':(9001|9102)\b' || true

echo
echo "== processes =="
ps -eo pid,lstart,cmd | grep -E '[h]ivemind|[h]ivemind-api' || true

echo
echo "== recent hivemind logs =="
journalctl -u hivemind -u hivemind-api --since '15 minutes ago' --no-pager || true
REMOTE
    done
}

run_expect_field() {
    local name="$1"
    local payload="$2"
    local expected_field="$3"
    local max="${4:-12}"
    local delay="${5:-5}"
    RUN_RESULT=""
    if hivemind_run_with_retry "$name" \
        "$API_URL/v1/deployments/$DRILL_NAME/run" "$payload" \
        "\"$expected_field\"" "$max" "$delay" '' 30; then
        RUN_RESULT="$HIVEMIND_RUN_BODY"
        PASS=$((PASS + 1))
        return 0
    fi
    echo "  FAIL: $name" >&2
    FAIL=$((FAIL + 1))
    return 1
}

find_leader() {
    local health
    health="$(curl -s "$API_URL/v1/health" || echo "")"
    echo "$health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("leader",""))' 2>/dev/null || echo ""
}

leader_replica_ip() {
    local leader_addr leader_private public_ip private_ips
    leader_addr="$(find_leader)"
    leader_private="${leader_addr%%:*}"
    for public_ip in "${REPLICA_IPS[@]}"; do
        private_ips="$(ssh "${SSH_OPTS[@]}" "$REPLICA_SSH_USER@$public_ip" "hostname -I" 2>/dev/null || true)"
        if echo " $private_ips " | grep -q " $leader_private "; then
            echo "$public_ip"
            return 0
        fi
    done
    echo ""
}

write_create_payloads() {
    local artifact_file="$1"
    local secret_file="$2"

    if [[ -n "$IMAGE_PULL_REGISTRY" || -n "$IMAGE_PULL_USERNAME" || -n "$IMAGE_PULL_PASSWORD" ]]; then
        cat > "$artifact_file" <<JSON
{"name":"$DRILL_NAME","image":"$CPU_IMAGE","replicas":1,"cpu":500,"memory":512,"gpu_type":"none","gpu_count":0,"image_pull_registry":"$IMAGE_PULL_REGISTRY","image_pull_username":"$IMAGE_PULL_USERNAME","image_pull_password":"<redacted>","image_pull_password_is_secret":false}
JSON
        cat > "$secret_file" <<JSON
{"name":"$DRILL_NAME","image":"$CPU_IMAGE","replicas":1,"cpu":500,"memory":512,"gpu_type":"none","gpu_count":0,"image_pull_registry":"$IMAGE_PULL_REGISTRY","image_pull_username":"$IMAGE_PULL_USERNAME","image_pull_password":"$IMAGE_PULL_PASSWORD","image_pull_password_is_secret":false}
JSON
    else
        cat > "$artifact_file" <<JSON
{"name":"$DRILL_NAME","image":"$CPU_IMAGE","replicas":1,"cpu":500,"memory":512,"gpu_type":"none","gpu_count":0}
JSON
        cp "$artifact_file" "$secret_file"
    fi
}

assert_drill_pod_on_cpu_worker() {
    local cpu_hostname workers_html pods_html deployment_hex
    cpu_hostname="$(ssh "${SSH_OPTS[@]}" "$WORKER_SSH_USER@$CPU_WORKER_IP" 'hostname' 2>/dev/null || true)"
    if [[ -z "$cpu_hostname" ]]; then
        echo "  FAIL: could not read CPU worker hostname" >&2
        FAIL=$((FAIL + 1))
        capture_worker_runtime_diagnostics "worker-placement-no-cpu-host-$RUN_ID"
        return 1
    fi

    workers_html="$OUT_DIR/worker-placement-workers.html"
    pods_html="$OUT_DIR/worker-placement-pods.html"
    deployment_hex="$(python3 -c 'import sys; print(format(int(sys.argv[1]), "x"))' "$DRILL_DEPLOYMENT_ID")"

    for i in $(seq 1 12); do
        curl -fsS --max-time 5 "$API_URL/dashboard/workers" > "$workers_html" 2>/dev/null || true
        curl -fsS --max-time 5 "$API_URL/dashboard/pods" > "$pods_html" 2>/dev/null || true
        if python3 - "$workers_html" "$pods_html" "$cpu_hostname" "$deployment_hex" <<'PY'
from html.parser import HTMLParser
import sys

class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = None
        self.cell = None
        self.in_cell = False

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag == "td" and self.row is not None:
            self.cell = []
            self.in_cell = True

    def handle_data(self, data):
        if self.in_cell and self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag == "td" and self.in_cell and self.row is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
            self.in_cell = False
        elif tag == "tr" and self.row is not None:
            if self.row:
                self.rows.append(self.row)
            self.row = None

def parse(path):
    parser = TableParser()
    with open(path, "r", encoding="utf-8") as f:
        parser.feed(f.read())
    return parser.rows

workers_path, pods_path, cpu_hostname, deployment_hex = sys.argv[1:]
workers = parse(workers_path)
pods = parse(pods_path)

cpu_node = ""
for row in workers:
    if len(row) >= 5 and row[0] == cpu_hostname:
        cpu_node = row[1].lower()
        break
if not cpu_node:
    print(f"cpu worker row not found for hostname={cpu_hostname}; rows={workers}")
    sys.exit(2)

pod_nodes = []
for row in pods:
    if len(row) >= 4 and row[1].lower() == deployment_hex and row[3].lower() == "running":
        pod_nodes.append(row[2].lower())
if len(pod_nodes) != 1:
    print(f"expected exactly one running drill pod for deployment={deployment_hex}; pod_nodes={pod_nodes}; rows={pods}")
    sys.exit(3)
if pod_nodes[0] != cpu_node:
    print(f"drill pod on node={pod_nodes[0]}, cpu worker node={cpu_node}")
    sys.exit(4)

print(f"drill pod placement ok: hostname={cpu_hostname} node={cpu_node}")
PY
        then
            echo "  PASS: drill pod placed on CPU worker (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep 5
    done

    echo "  FAIL: drill pod is not placed on CPU worker; refusing inconclusive Drill B" >&2
    FAIL=$((FAIL + 1))
    capture_worker_runtime_diagnostics "worker-placement-failed-$RUN_ID"
    return 1
}

RUN_ID="$(date +%s)-$$"
DRILL_NAME="drill-cpu-$RUN_ID"

# ─────────────────────────────────────────────────
echo "=== Drill A: Leader loss during traffic ==="
echo ""

echo "[A1] Create deployment for drill traffic..."
DRILL_CREATE_PAYLOAD="$OUT_DIR/drill-create-request.json"
DRILL_CREATE_SECRET="$(mktemp)"
TMP_FILES+=("$DRILL_CREATE_SECRET")
write_create_payloads "$DRILL_CREATE_PAYLOAD" "$DRILL_CREATE_SECRET"
curl -fsS -X POST "$API_URL/v1/deployments" \
    -H 'Content-Type: application/json' \
    --data-binary "@$DRILL_CREATE_SECRET" \
    | tee "$OUT_DIR/drill-create.json"
DRILL_DEPLOYMENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$OUT_DIR/drill-create.json")"
echo ""

echo "[A2] Wait for deployment ready..."
for i in $(seq 1 36); do
    body="$(curl -fsS "$API_URL/dashboard/deployments" 2>/dev/null || echo "")"
    if echo "$body" | grep -Eiq "$DRILL_NAME</td>.*<span class=\"ok\">1</span> <span class=\"muted\">/1</span>"; then
        echo "  ready at attempt $i"
        break
    fi
    sleep 5
done

echo "[A3] Verify /run works before kill..."
run_expect_field "pre-kill run succeeds" '{"text":"pre-kill"}' model
PRE_RUN="$RUN_RESULT"

KILLED_LEADER_ADDR="$(find_leader)"
LEADER_IP="$(leader_replica_ip)"
echo "[A4] Current leader: $KILLED_LEADER_ADDR public_ip=$LEADER_IP"
if [[ -z "$LEADER_IP" ]]; then
    echo "  FAIL: could not map leader to public replica IP"
    FAIL=$((FAIL + 1))
else
    echo "     Killing hivemind on leader..."
    LEADER_STOPPED_IP="$LEADER_IP"
    ssh "${SSH_OPTS[@]}" "$REPLICA_SSH_USER@$LEADER_IP" \
        "sudo systemctl stop hivemind" 2>/dev/null || true
fi
echo "     Leader stopped."

echo "[A5] Wait for new leader election + API reconnect..."
sleep 5
if ! wait_api "api reconnects after leader loss" "connected" 30 3; then
    capture_replica_diagnostics "leader-loss-timeout-$RUN_ID"
    exit 1
fi
capture_replica_diagnostics "leader-loss-recovered-$RUN_ID"

NEW_LEADER="$(find_leader)"
echo "     New leader: $NEW_LEADER"
check "new leader different from killed" "different" "$([ "$NEW_LEADER" != "$KILLED_LEADER_ADDR" ] && echo "different" || echo "same")"

echo "[A6] Verify /run works after failover..."
if ! run_expect_field "post-kill run succeeds" '{"text":"post-kill"}' model 18 5; then
    capture_replica_diagnostics "leader-loss-post-run-failed-$RUN_ID"
    exit 1
fi
POST_RUN="$RUN_RESULT"

echo "[A7] Restart killed replica..."
ssh "${SSH_OPTS[@]}" "$REPLICA_SSH_USER@$LEADER_IP" \
    "sudo systemctl start hivemind hivemind-api" 2>/dev/null || true
LEADER_STOPPED_IP=""
sleep 5
echo "     Restarted."

# Save evidence
cat > "$OUT_DIR/leader-failover.txt" <<EOF
leader_before=$LEADER_IP
leader_after=$NEW_LEADER
pre_kill_run=$PRE_RUN
post_kill_run=$POST_RUN
EOF

echo ""
echo "=== Drill B: CPU worker loss during traffic ==="
echo ""

echo "[B1] Verify /run works before worker kill..."
run_expect_field "pre-worker-kill run succeeds" '{"text":"pre-worker-kill"}' model
PRE_WORKER="$RUN_RESULT"

if ! assert_drill_pod_on_cpu_worker; then
    exit 1
fi

echo "[B2] Stop worker service on $CPU_WORKER_IP..."
CPU_WORKER_STOPPED=true
ssh "${SSH_OPTS[@]}" "$WORKER_SSH_USER@$CPU_WORKER_IP" \
    "sudo systemctl stop hivemind-worker" 2>/dev/null || true
echo "     Worker stopped."
sleep 35

echo "[B3] Verify /run times out or errors (no worker)..."
NO_WORKER="$(curl -s --max-time 15 -X POST "$API_URL/v1/deployments/$DRILL_NAME/run" \
    -H 'Content-Type: application/json' -d '{"text":"no-worker"}' 2>/dev/null || echo "timeout_or_error")"
echo "     Response: $NO_WORKER"
if echo "$NO_WORKER" | grep -q '"model"'; then
    echo "  FAIL: run still succeeded after CPU worker stop"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: run unavailable after CPU worker stop"
    PASS=$((PASS + 1))
fi

echo "[B4] Restart worker on $CPU_WORKER_IP..."
ssh "${SSH_OPTS[@]}" "$WORKER_SSH_USER@$CPU_WORKER_IP" \
    "sudo systemctl start hivemind-worker" 2>/dev/null || true
CPU_WORKER_STOPPED=false
sleep 20

echo "[B5] Verify /run recovers after worker restart..."
RECOVERED=""
if hivemind_run_with_retry "worker recovery" \
    "$API_URL/v1/deployments/$DRILL_NAME/run" '{"text":"recovered"}' \
    '"model"' 12 5 '' 10; then
    RECOVERED="$HIVEMIND_RUN_BODY"
    PASS=$((PASS + 1))
else
    echo "  FAIL: run did not recover"
    FAIL=$((FAIL + 1))
fi

cat > "$OUT_DIR/worker-loss.txt" <<EOF
cpu_worker=$CPU_WORKER_IP
pre_kill=$PRE_WORKER
no_worker=$NO_WORKER
recovered=$RECOVERED
EOF

echo ""
echo "=== Drill C: Client disconnect / timeout cleanup ==="
echo ""

echo "[C1] Fire /run and force timeout after 2s..."
TIMEOUT_OUT="$(curl -s --max-time 2 -X POST "$API_URL/v1/deployments/$DRILL_NAME/run" \
    -H 'Content-Type: application/json' -d '{"probe":"timeout-test"}' 2>/dev/null || echo "curl_timeout")"
echo "     Timeout response: $TIMEOUT_OUT"
sleep 5

echo "[C2] Check queue for in-flight leak..."
QUEUE_METRICS="$(curl -s "$API_URL/dashboard/cluster" 2>/dev/null || echo "")"
IN_FLIGHT="$(echo "$QUEUE_METRICS" | grep -oi 'in.flight[^0-9]*[0-9]*' | head -1 || echo "unknown")"
echo "     Queue state: $IN_FLIGHT"

echo "[C3] Verify next /run still succeeds..."
run_expect_field "post-timeout run succeeds" '{"text":"after-timeout"}' model
NEXT_RUN="$RUN_RESULT"

cat > "$OUT_DIR/run-timeout-cleanup.txt" <<EOF
timeout_response=$TIMEOUT_OUT
queue_state=$IN_FLIGHT
next_run=$NEXT_RUN
EOF

# ─────────────────────────────────────────────────
echo ""
cleanup
trap - EXIT

echo ""
echo "=== Failure Drill Results: $PASS passed, $FAIL failed ==="
echo "evidence=$OUT_DIR"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
