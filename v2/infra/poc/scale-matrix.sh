#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=http.sh
source "$SCRIPT_DIR/http.sh"

# Hivemind scale benchmark matrix with phase timing.
# Scenarios:
#   1. one deployment: 0 -> 50 -> 1
#   2. fifty deployments: 1 replica each
# Usage:
#   SCALE_IMAGE=docker.io/library/nginx:1.27-alpine bash infra/poc/scale-matrix.sh http://API:8080

API_URL="${1:?Usage: SCALE_IMAGE=... scale-matrix.sh <api-url>}"
SCALE_IMAGE="${SCALE_IMAGE:-docker.io/library/nginx:1.27-alpine}"
OUT_DIR="${OUT_DIR:-artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-$(date +%Y%m%d%H%M%S)}"
RUN_ID="${RUN_ID:-$(date +%s)}"
POLL_DELAY="${POLL_DELAY:-0.2}"
mkdir -p "$OUT_DIR"

EVENTS_CSV="$OUT_DIR/latency-events.csv"
EVENTS_JSONL="$OUT_DIR/latency-events.jsonl"
printf 'system,component,run_id,scenario,entity,deployment_id,pod_id,name,op,phase,start_ms,end_ms,duration_ms,count,source\n' > "$EVENTS_CSV"
: > "$EVENTS_JSONL"

IDS=()
LAST_COUNTS="0 0 0 0 0 0 0"

cleanup() {
    set +e
    if [ "${#IDS[@]}" -eq 0 ]; then
        return
    fi
    for id in "${IDS[@]}"; do
        curl -fsS -X DELETE "$API_URL/v1/deployments/$id" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

json_get() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

csv_event() {
    local scenario="$1"
    local entity="$2"
    local phase="$3"
    local start_ms="$4"
    local end_ms="$5"
    local count="$6"
    local source="$7"
    local deployment_id="${8:-0}"
    local pod_id="${9:-0}"
    local name="${10:-$entity}"
    local op="${11:-benchmark}"
    local duration_ms=$((end_ms - start_ms))
    printf 'hivemind,bench,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_ID" "$scenario" "$entity" "$deployment_id" "$pod_id" "$name" "$op" "$phase" "$start_ms" "$end_ms" "$duration_ms" "$count" "$source" >> "$EVENTS_CSV"
    python3 - "$EVENTS_JSONL" <<PY
import json, sys
row = {
  "system": "hivemind", "component": "bench", "run_id": "$RUN_ID",
  "scenario": "$scenario", "entity": "$entity", "deployment_id": int("$deployment_id"),
  "pod_id": int("$pod_id"), "name": "$name", "op": "$op", "phase": "$phase",
  "start_ms": int("$start_ms"), "end_ms": int("$end_ms"), "duration_ms": int("$duration_ms"),
  "count": int("$count"), "source": "$source",
}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

capture_state() {
    local name="$1"
    curl -fsS "$API_URL/v1/cluster-state" > "$OUT_DIR/state-$name.json" || true
}

capture_timeout_diagnostics() {
    capture_state timeout
    curl -fsS "$API_URL/dashboard/deployments" > "$OUT_DIR/deployments-timeout.html" || true
    curl -fsS "$API_URL/dashboard/pods" > "$OUT_DIR/pods-timeout.html" || true
    curl -fsS "$API_URL/metrics" > "$OUT_DIR/metrics-timeout.txt" || true
}

state_counts() {
    local ids_csv="$1"
    local state_file="$OUT_DIR/state-current.json"
    curl -fsS "$API_URL/v1/cluster-state" > "$state_file" || return 1
    IDS_CSV="$ids_csv" python3 - "$state_file" <<'PY'
import json, os, sys
state = json.load(open(sys.argv[1]))
ids = {int(x) for x in os.environ["IDS_CSV"].split(",") if x}
if not ids:
    print("0 0 0 0 0 0 0")
    raise SystemExit
ready = desired = 0
for dep in state.get("Deployments") or []:
    if int(dep.get("ID", 0)) in ids:
        ready += int(dep.get("ReadyReplicas", 0))
        desired += int(dep.get("Replicas", 0))
pods_total = pods_scheduled = pods_running = 0
for pod in state.get("Pods") or []:
    if int(pod.get("DeploymentID", 0)) not in ids:
        continue
    pods_total += 1
    if int(pod.get("NodeID", 0)) != 0:
        pods_scheduled += 1
    if int(pod.get("Phase", 0)) == 2:
        pods_running += 1
print(ready, desired, pods_total, pods_scheduled, pods_running, int(state.get("OpNumber", 0)), int(state.get("CommitMin", 0)))
PY
}

ids_join() {
    local IFS=,
    echo "$*"
}

poll_attempts() {
    python3 -c 'import math, sys; print(max(1, math.ceil(float(sys.argv[1]) / float(sys.argv[2]))))' "$1" "$POLL_DELAY"
}

wait_phase_counts() {
    local scenario="$1"
    local entity="$2"
    local ids_csv="$3"
    local expected_ready="$4"
    local expected_pods="$5"
    local start_ms="$6"
    local attempts="${7:-300}"
    local delay="${8:-$POLL_DELAY}"

    local pods_created_recorded=0
    local pods_scheduled_recorded=0
    local pods_running_recorded=0
    local ready_recorded=0

    for attempt in $(seq 1 "$attempts"); do
        LAST_COUNTS="$(state_counts "$ids_csv" || echo "$LAST_COUNTS")"
        read -r ready desired pods_total pods_scheduled pods_running op_number commit_min <<< "$LAST_COUNTS"

        local t
        t="$(now_ms)"
        if [[ "$pods_created_recorded" == "0" && "$pods_total" -ge "$expected_pods" ]]; then
            csv_event "$scenario" "$entity" "pods_created_observed" "$start_ms" "$t" "$pods_total" "v1/cluster-state"
            pods_created_recorded=1
        fi
        if [[ "$pods_scheduled_recorded" == "0" && "$pods_scheduled" -ge "$expected_pods" ]]; then
            csv_event "$scenario" "$entity" "pods_scheduled_observed" "$start_ms" "$t" "$pods_scheduled" "v1/cluster-state"
            pods_scheduled_recorded=1
        fi
        if [[ "$pods_running_recorded" == "0" && "$pods_running" -ge "$expected_ready" ]]; then
            csv_event "$scenario" "$entity" "pods_running_observed" "$start_ms" "$t" "$pods_running" "v1/cluster-state"
            pods_running_recorded=1
        fi

        if [[ "$ready" -ge "$expected_ready" && "$desired" -eq "$expected_ready" ]]; then
            if [[ "$ready_recorded" == "0" ]]; then
                csv_event "$scenario" "$entity" "deployment_ready_observed" "$start_ms" "$t" "$ready" "v1/cluster-state"
            fi
            echo "ready scenario=$scenario entity=$entity expected=$expected_ready attempt=$attempt op=$op_number commit=$commit_min pods=$pods_running/$pods_scheduled/$pods_total"
            return 0
        fi

        echo "waiting scenario=$scenario entity=$entity ready=$ready/$desired pods_running=$pods_running scheduled=$pods_scheduled total=$pods_total op=$op_number commit=$commit_min attempt=$attempt/$attempts"
        sleep "$delay"
    done

    echo "timeout waiting for $scenario $entity ready $expected_ready" >&2
    capture_timeout_diagnostics
    return 1
}

wait_zero_ready() {
    local scenario="$1"
    local entity="$2"
    local ids_csv="$3"
    local start_ms="$4"
    local attempts="${5:-180}"
    local delay="${6:-$POLL_DELAY}"
    for attempt in $(seq 1 "$attempts"); do
        LAST_COUNTS="$(state_counts "$ids_csv" || echo "$LAST_COUNTS")"
        read -r ready desired pods_total pods_scheduled pods_running op_number commit_min <<< "$LAST_COUNTS"
        local t
        t="$(now_ms)"
        if [[ "$ready" -eq 0 && "$desired" -eq 0 ]]; then
            csv_event "$scenario" "$entity" "deployment_zero_observed" "$start_ms" "$t" "0" "v1/cluster-state"
            echo "zero_ready scenario=$scenario entity=$entity attempt=$attempt op=$op_number commit=$commit_min"
            return 0
        fi
        echo "waiting_zero scenario=$scenario entity=$entity ready=$ready/$desired pods_running=$pods_running total=$pods_total attempt=$attempt/$attempts"
        sleep "$delay"
    done
    echo "timeout waiting for $scenario $entity zero ready" >&2
    capture_timeout_diagnostics
    return 1
}

create_deployment() {
    local name="$1"
    local replicas="$2"
    local scenario="${3:-}"
    local entity="${4:-$name}"
    local payload="$OUT_DIR/create-$name.json"
    local response="$OUT_DIR/create-$name-response.json"

    cat > "$payload" <<JSON
{"name":"$name","image":"$SCALE_IMAGE","replicas":$replicas,"cpu":10,"memory":16,"gpu_type":"none","gpu_count":0}
JSON
    local attempt
    for attempt in $(seq 1 5); do
        if curl -fsS -X POST "$API_URL/v1/deployments" -H 'Content-Type: application/json' -H "X-Hivemind-Scenario: $scenario" -H "X-Hivemind-Entity: $entity" --data-binary "@$payload" > "$response"; then
            json_get id < "$response"
            return 0
        fi
        echo "create retry name=$name attempt=$attempt/5" >&2
        sleep 2
    done
    echo "create failed name=$name" >&2
    return 1
}

scale_deployment() {
    local id="$1"
    local replicas="$2"
    local scenario="${3:-}"
    local entity="${4:-$id}"
    curl -fsS -X PUT "$API_URL/v1/deployments/$id/scale" -H 'Content-Type: application/json' -H "X-Hivemind-Scenario: $scenario" -H "X-Hivemind-Entity: $entity" -d "{\"replicas\":$replicas}" >/dev/null
}

single_name="hm-scale-single-$RUN_ID"
echo "=== Hivemind one deployment 0 -> 50 -> 1 ==="
create_start="$(now_ms)"
single_id="$(create_deployment "$single_name" 1 "single" "$single_name")"
IDS+=("$single_id")
create_end="$(now_ms)"
csv_event "single" "$single_name" "create_submit" "$create_start" "$create_end" "1" "api" "$single_id" "0" "$single_name" "create_deployment"
wait_phase_counts "single" "$single_name" "$single_id" 1 1 "$create_start" "$(poll_attempts 180)" "$POLL_DELAY"

scale_zero_start="$(now_ms)"
scale_deployment "$single_id" 0 "single" "$single_name"
scale_zero_submit="$(now_ms)"
csv_event "single" "$single_name" "scale_to_zero_submit" "$scale_zero_start" "$scale_zero_submit" "0" "api" "$single_id" "0" "$single_name" "scale_deployment"
wait_zero_ready "single" "$single_name" "$single_id" "$scale_zero_start" "$(poll_attempts 180)" "$POLL_DELAY"

scale_up_start="$(now_ms)"
scale_deployment "$single_id" 50 "single" "$single_name"
scale_up_submit="$(now_ms)"
csv_event "single" "$single_name" "scale_0_to_50_submit" "$scale_up_start" "$scale_up_submit" "50" "api" "$single_id" "0" "$single_name" "scale_deployment"
wait_phase_counts "single" "$single_name" "$single_id" 50 50 "$scale_up_start" "$(poll_attempts 300)" "$POLL_DELAY"
scale_up_ready="$(now_ms)"

scale_down_start="$(now_ms)"
scale_deployment "$single_id" 1 "single" "$single_name"
scale_down_submit="$(now_ms)"
csv_event "single" "$single_name" "scale_50_to_1_submit" "$scale_down_start" "$scale_down_submit" "1" "api" "$single_id" "0" "$single_name" "scale_deployment"
wait_phase_counts "single" "$single_name" "$single_id" 1 1 "$scale_down_start" "$(poll_attempts 180)" "$POLL_DELAY"
scale_down_ready="$(now_ms)"

single_create_submit_ms="$((create_end - create_start))"
single_scale_up_submit_ms="$((scale_up_submit - scale_up_start))"
single_scale_up_ready_ms="$((scale_up_ready - scale_up_start))"
single_scale_down_submit_ms="$((scale_down_submit - scale_down_start))"
single_scale_down_ready_ms="$((scale_down_ready - scale_down_start))"

echo "single create submit: ${single_create_submit_ms}ms"
echo "single 0->50 submit: ${single_scale_up_submit_ms}ms"
echo "single 0->50 ready: ${single_scale_up_ready_ms}ms"
echo "single 50->1 submit: ${single_scale_down_submit_ms}ms"
echo "single 50->1 ready: ${single_scale_down_ready_ms}ms"

curl -fsS -X DELETE "$API_URL/v1/deployments/$single_id" >/dev/null 2>&1 || true
sleep 2

multi_prefix="hm-scale-many-$RUN_ID"
echo ""
echo "=== Hivemind 50 deployments x 1 replica ==="
multi_start="$(now_ms)"
MULTI_IDS=()
for i in $(seq 1 50); do
    id="$(create_deployment "$multi_prefix-$i" 1 "multi_50x1" "$multi_prefix-$i")"
    IDS+=("$id")
    MULTI_IDS+=("$id")
done
multi_submit="$(now_ms)"
csv_event "multi_50x1" "$multi_prefix" "create_50_submit" "$multi_start" "$multi_submit" "50" "api" "0" "0" "$multi_prefix" "create_deployment"
multi_ids_csv="$(ids_join "${MULTI_IDS[@]}")"
wait_phase_counts "multi_50x1" "$multi_prefix" "$multi_ids_csv" 50 50 "$multi_start" "$(poll_attempts 300)" "$POLL_DELAY"
multi_ready="$(now_ms)"

multi_submit_ms="$((multi_submit - multi_start))"
multi_ready_ms="$((multi_ready - multi_start))"
echo "50x1 submit total: ${multi_submit_ms}ms"
echo "50x1 all ready: ${multi_ready_ms}ms"

capture_state after
curl -fsS "$API_URL/dashboard/deployments" > "$OUT_DIR/deployments-after.html" || true
curl -fsS "$API_URL/dashboard/pods" > "$OUT_DIR/pods-after.html" || true
curl -fsS "$API_URL/metrics" > "$OUT_DIR/metrics-after.txt" || true

generate_latency_artifacts() {
    python3 - "$OUT_DIR" "$EVENTS_CSV" "$EVENTS_JSONL" <<'PY'
import csv, json, os, re, statistics, sys
from pathlib import Path

out_dir = Path(sys.argv[1])
base_csv = Path(sys.argv[2])
base_jsonl = Path(sys.argv[3])
fields = ["system","component","run_id","scenario","entity","deployment_id","pod_id","name","op","phase","start_ms","end_ms","duration_ms","count","source"]
rows = []

def add(row):
    clean = {}
    for field in fields:
        value = row.get(field, "")
        if field in {"deployment_id", "pod_id", "start_ms", "end_ms", "duration_ms", "count"}:
            try:
                value = int(value)
            except Exception:
                value = 0
        clean[field] = value
    if clean["system"] == "": clean["system"] = "hivemind"
    if clean["component"] == "": clean["component"] = "unknown"
    if clean["duration_ms"] == 0 and clean["end_ms"] >= clean["start_ms"]:
        clean["duration_ms"] = clean["end_ms"] - clean["start_ms"]
    rows.append(clean)

if base_csv.exists():
    with base_csv.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            add(row)

key_value_re = re.compile(r'(\w+)=([^\s]+)')

def parse_kv_line(line):
    parsed = dict(key_value_re.findall(line))
    if not parsed:
        return None
    if "hivemind_worker_pod_event" in line:
        return {
            "system": parsed.get("system", "hivemind"),
            "component": parsed.get("component", "worker"),
            "run_id": os.environ.get("RUN_ID", ""),
            "scenario": parsed.get("scenario", ""),
            "entity": parsed.get("entity", parsed.get("name", "")),
            "deployment_id": parsed.get("deployment_id", 0),
            "pod_id": parsed.get("pod_id", 0),
            "name": parsed.get("name", ""),
            "op": parsed.get("op", "start_pod"),
            "phase": parsed.get("phase", ""),
            "start_ms": parsed.get("start_ms", parsed.get("tick", 0)),
            "end_ms": parsed.get("end_ms", parsed.get("tick", 0)),
            "duration_ms": parsed.get("duration_ms", 0),
            "count": parsed.get("count", 1),
            "source": parsed.get("source", "worker-log"),
        }
    if "hivemind_latency_span" in line:
        return {
            "system": parsed.get("system", "hivemind"),
            "component": parsed.get("component", "core"),
            "run_id": parsed.get("run_id", os.environ.get("RUN_ID", "")),
            "scenario": parsed.get("scenario", ""),
            "entity": parsed.get("entity", ""),
            "deployment_id": parsed.get("deployment_id", 0),
            "pod_id": parsed.get("pod_id", 0),
            "name": parsed.get("name", ""),
            "op": parsed.get("op", ""),
            "phase": parsed.get("phase", ""),
            "start_ms": parsed.get("start_ms", 0),
            "end_ms": parsed.get("end_ms", 0),
            "duration_ms": parsed.get("duration_ms", 0),
            "count": parsed.get("count", 1),
            "source": parsed.get("source", "latency-log"),
        }
    return None

log_paths = []
for env_name in ("HIVEMIND_LATENCY_LOGS", "LATENCY_LOGS"):
    for part in os.environ.get(env_name, "").split(","):
        if part.strip(): log_paths.append(Path(part.strip()))
for pattern in ("*.log", "*.txt", "*.jsonl"):
    log_paths.extend(out_dir.rglob(pattern))

seen_paths = set()
for path in log_paths:
    if path in seen_paths or not path.exists() or path == base_jsonl:
        continue
    seen_paths.add(path)
    try:
        with path.open(encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                if line.startswith("{"):
                    try:
                        obj = json.loads(line)
                    except Exception:
                        obj = None
                    if isinstance(obj, dict) and "phase" in obj:
                        add(obj)
                    continue
                parsed = parse_kv_line(line)
                if parsed:
                    add(parsed)
    except OSError:
        pass

consolidated_csv = out_dir / "latency-events-consolidated.csv"
with consolidated_csv.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)

consolidated_jsonl = out_dir / "latency-events-consolidated.jsonl"
with consolidated_jsonl.open("w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")

folded = out_dir / "latency-flamegraph.folded"
folded_totals = {}
for row in rows:
    duration = int(row.get("duration_ms", 0))
    if duration <= 0: continue
    stack = ";".join(["hivemind", str(row.get("component") or "unknown"), str(row.get("op") or "unknown"), str(row.get("phase") or "unknown")])
    folded_totals[stack] = folded_totals.get(stack, 0) + duration
with folded.open("w", encoding="utf-8") as f:
    for stack, duration in sorted(folded_totals.items()):
        f.write(f"{stack} {duration}\n")

summary = out_dir / "latency-summary.md"
groups = {}
for row in rows:
    key = (row.get("component", ""), row.get("op", ""), row.get("phase", ""))
    groups.setdefault(key, []).append(int(row.get("duration_ms", 0)))
with summary.open("w", encoding="utf-8") as f:
    f.write("# Hivemind latency span summary\n\n")
    f.write(f"- events: {len(rows)}\n")
    f.write("- csv: latency-events-consolidated.csv\n")
    f.write("- jsonl: latency-events-consolidated.jsonl\n")
    f.write("- folded: latency-flamegraph.folded\n\n")
    f.write("| component | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |\n")
    f.write("|---|---|---|---:|---:|---:|---:|---:|\n")
    for key, durations in sorted(groups.items()):
        durations = sorted(durations)
        if not durations: continue
        p50 = int(statistics.median(durations))
        p95 = durations[min(len(durations)-1, int(len(durations) * 0.95))]
        f.write(f"| {key[0]} | {key[1]} | {key[2]} | {len(durations)} | {sum(durations)} | {p50} | {p95} | {max(durations)} |\n")
PY
}

generate_latency_artifacts
if [[ -f "$OUT_DIR/latency-events-consolidated.csv" && -x "scripts/hivemind-latency-deep-dive.py" ]]; then
    scripts/hivemind-latency-deep-dive.py "$OUT_DIR/latency-events-consolidated.csv" "$OUT_DIR" || true
fi

cat > "$OUT_DIR/summary.md" <<EOF
# Hivemind scale benchmark matrix

- run_id: $RUN_ID
- image: $SCALE_IMAGE
- latency_events: latency-events.csv
- consolidated_latency_events: latency-events-consolidated.csv
- latency_events_json: latency-events-consolidated.jsonl
- latency_flamegraph: latency-flamegraph.folded
- latency_summary: latency-summary.md
- latency_deep_dive: latency-deep-dive.md
- latency_firechart: latency-firechart.html

| scenario | metric | value_ms |
|---|---|---:|
| one deployment 0 -> 50 -> 1 | create submit | $single_create_submit_ms |
| one deployment 0 -> 50 -> 1 | 0 -> 50 submit | $single_scale_up_submit_ms |
| one deployment 0 -> 50 -> 1 | 0 -> 50 ready | $single_scale_up_ready_ms |
| one deployment 0 -> 50 -> 1 | 50 -> 1 submit | $single_scale_down_submit_ms |
| one deployment 0 -> 50 -> 1 | 50 -> 1 ready | $single_scale_down_ready_ms |
| 50 deployments x 1 replica | submit total | $multi_submit_ms |
| 50 deployments x 1 replica | all ready | $multi_ready_ms |
EOF

cat "$OUT_DIR/summary.md"
echo "evidence=$OUT_DIR"
