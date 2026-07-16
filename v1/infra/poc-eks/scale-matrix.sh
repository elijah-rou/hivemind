#!/usr/bin/env bash
set -euo pipefail

# EKS scale benchmark matrix with granular Kubernetes latency spans.
# Scenarios:
#   1. one deployment: 0 -> 50 -> 1
#   2. fifty deployments: 1 replica each
# Usage:
#   SCALE_IMAGE=docker.io/library/nginx:1.27-alpine bash infra/poc-eks/scale-matrix.sh

SCALE_IMAGE="${SCALE_IMAGE:-docker.io/library/nginx:1.27-alpine}"
NAMESPACE="${NAMESPACE:-hivemind-scale-matrix}"
OUT_DIR="${OUT_DIR:-../../artifacts/poc-final/06-benchmarks/eks-scale-matrix-$(date +%Y%m%d%H%M%S)}"
RUN_ID="${RUN_ID:-$(date +%s)}"
POLL_DELAY="${POLL_DELAY:-0.2}"
mkdir -p "$OUT_DIR"

EVENTS_CSV="$OUT_DIR/latency-events.csv"
SPANS_CSV="$OUT_DIR/latency-spans.csv"
SPANS_JSONL="$OUT_DIR/latency-spans.jsonl"
SPANS_JSON="$OUT_DIR/latency-spans.json"
POLL_JSONL="$OUT_DIR/poll-observations.jsonl"
DIAGNOSTICS_LOG="$OUT_DIR/latency-diagnostics.log"
OBSERVED_KEYS="$OUT_DIR/latency-observed-keys.json"
FOLDED_OUT="$OUT_DIR/latency-flamegraph.folded"
GRANULAR_SUMMARY="$OUT_DIR/latency-summary.md"

printf 'system,run_id,scenario,entity,phase,start_ms,end_ms,duration_ms,count,source\n' > "$EVENTS_CSV"
printf 'system,run_id,scenario,operation,entity,deployment,pod,namespace,node,image,phase,start_ms,end_ms,duration_ms,source,event_reason,event_time_ms,message\n' > "$SPANS_CSV"
: > "$SPANS_JSONL"
: > "$POLL_JSONL"
printf '[]\n' > "$OBSERVED_KEYS"
: > "$DIAGNOSTICS_LOG"
LAST_COUNTS="0 0 0 0 0"

cleanup() {
    trap - EXIT
    set +e
    kubectl delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

csv_event() {
    local scenario="$1"
    local entity="$2"
    local phase="$3"
    local start_ms="$4"
    local end_ms="$5"
    local count="$6"
    local source="$7"
    printf 'eks,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_ID" "$scenario" "$entity" "$phase" "$start_ms" "$end_ms" "$((end_ms - start_ms))" "$count" "$source" >> "$EVENTS_CSV"
}

span_event() {
    local scenario="$1"
    local operation="$2"
    local entity="$3"
    local deployment="$4"
    local pod="$5"
    local node="$6"
    local image="$7"
    local phase="$8"
    local start_ms="$9"
    local end_ms="${10}"
    local source="${11}"
    local reason="${12:-}"
    local event_time_ms="${13:-}"
    local message="${14:-}"

    RUN_ID="$RUN_ID" SCENARIO="$scenario" OPERATION="$operation" ENTITY="$entity" \
    DEPLOYMENT="$deployment" POD="$pod" NAMESPACE_VALUE="$NAMESPACE" NODE="$node" IMAGE_VALUE="$image" \
    PHASE="$phase" START_MS="$start_ms" END_MS="$end_ms" SOURCE_VALUE="$source" \
    EVENT_REASON="$reason" EVENT_TIME_MS="$event_time_ms" MESSAGE_VALUE="$message" \
    SPANS_CSV="$SPANS_CSV" SPANS_JSONL="$SPANS_JSONL" python3 <<'PY'
import csv, json, os

start_ms = int(os.environ["START_MS"])
end_ms = int(os.environ["END_MS"])
row = {
    "system": "eks",
    "run_id": os.environ["RUN_ID"],
    "scenario": os.environ["SCENARIO"],
    "operation": os.environ["OPERATION"],
    "entity": os.environ["ENTITY"],
    "deployment": os.environ["DEPLOYMENT"],
    "pod": os.environ["POD"],
    "namespace": os.environ["NAMESPACE_VALUE"],
    "node": os.environ["NODE"],
    "image": os.environ["IMAGE_VALUE"],
    "phase": os.environ["PHASE"],
    "start_ms": start_ms,
    "end_ms": end_ms,
    "duration_ms": max(0, end_ms - start_ms),
    "source": os.environ["SOURCE_VALUE"],
    "event_reason": os.environ["EVENT_REASON"],
    "event_time_ms": os.environ["EVENT_TIME_MS"],
    "message": os.environ["MESSAGE_VALUE"],
}
fieldnames = ["system", "run_id", "scenario", "operation", "entity", "deployment", "pod", "namespace", "node", "image", "phase", "start_ms", "end_ms", "duration_ms", "source", "event_reason", "event_time_ms", "message"]
with open(os.environ["SPANS_CSV"], "a", newline="") as f:
    csv.DictWriter(f, fieldnames=fieldnames).writerow(row)
with open(os.environ["SPANS_JSONL"], "a") as f:
    f.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

capture_k8s_state() {
    local name="$1"
    kubectl -n "$NAMESPACE" get deployments -o json > "$OUT_DIR/deployments-$name.json" || true
    kubectl -n "$NAMESPACE" get replicasets -o json > "$OUT_DIR/replicasets-$name.json" || true
    kubectl -n "$NAMESPACE" get pods -o json > "$OUT_DIR/pods-$name.json" || true
    kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp -o json > "$OUT_DIR/events-$name.json" || true
    kubectl -n "$NAMESPACE" get deployments -o wide > "$OUT_DIR/deployments-$name.txt" || true
    kubectl -n "$NAMESPACE" get replicasets -o wide > "$OUT_DIR/replicasets-$name.txt" || true
    kubectl -n "$NAMESPACE" get pods -o wide > "$OUT_DIR/pods-$name.txt" || true
}

capture_timeout_diagnostics() {
    capture_k8s_state timeout
}

snapshot_phase() {
    local phase="$1"
    capture_k8s_state "$phase"
}

state_counts() {
    local mode="$1"
    local selector="$2"
    local scenario="$3"
    local entity="$4"
    local operation="$5"
    local start_ms="$6"
    local observed_ms="$7"

    kubectl -n "$NAMESPACE" get deployments -o json > "$OUT_DIR/deployments-current.json" || return 1
    kubectl -n "$NAMESPACE" get replicasets -o json > "$OUT_DIR/replicasets-current.json" || return 1
    kubectl -n "$NAMESPACE" get pods -o json > "$OUT_DIR/pods-current.json" || return 1
    kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp -o json > "$OUT_DIR/events-current.json" || return 1

    MODE="$mode" SELECTOR_VALUE="$selector" RUN_ID="$RUN_ID" SCENARIO="$scenario" ENTITY="$entity" \
    OPERATION="$operation" START_MS="$start_ms" OBSERVED_MS="$observed_ms" NAMESPACE_VALUE="$NAMESPACE" \
    IMAGE_VALUE="$SCALE_IMAGE" SPANS_CSV="$SPANS_CSV" SPANS_JSONL="$SPANS_JSONL" \
    POLL_JSONL="$POLL_JSONL" DIAGNOSTICS_LOG="$DIAGNOSTICS_LOG" OBSERVED_KEYS="$OBSERVED_KEYS" \
    python3 - "$OUT_DIR/deployments-current.json" "$OUT_DIR/replicasets-current.json" "$OUT_DIR/pods-current.json" "$OUT_DIR/events-current.json" <<'PY'
import csv
import datetime as dt
import json
import os
import sys

mode = os.environ["MODE"]
selector = os.environ["SELECTOR_VALUE"]
run_id = os.environ["RUN_ID"]
scenario = os.environ["SCENARIO"]
entity = os.environ["ENTITY"]
operation = os.environ["OPERATION"]
start_ms = int(os.environ["START_MS"])
observed_ms = int(os.environ["OBSERVED_MS"])
namespace = os.environ["NAMESPACE_VALUE"]
default_image = os.environ["IMAGE_VALUE"]
spans_csv = os.environ["SPANS_CSV"]
spans_jsonl = os.environ["SPANS_JSONL"]
poll_jsonl = os.environ["POLL_JSONL"]
diagnostics_log = os.environ["DIAGNOSTICS_LOG"]
observed_keys_path = os.environ["OBSERVED_KEYS"]

with open(sys.argv[1]) as f:
    deployments = json.load(f).get("items", [])
with open(sys.argv[2]) as f:
    replicasets = json.load(f).get("items", [])
with open(sys.argv[3]) as f:
    pods = json.load(f).get("items", [])
with open(sys.argv[4]) as f:
    events = json.load(f).get("items", [])

try:
    with open(observed_keys_path) as f:
        observed_keys = set(json.load(f))
except Exception:
    observed_keys = set()

fieldnames = ["system", "run_id", "scenario", "operation", "entity", "deployment", "pod", "namespace", "node", "image", "phase", "start_ms", "end_ms", "duration_ms", "source", "event_reason", "event_time_ms", "message"]

def warn(message):
    with open(diagnostics_log, "a") as f:
        f.write(f"{observed_ms} scenario={scenario} operation={operation} {message}\n")

def selected_name(name):
    if mode == "exact":
        return name == selector
    return name.startswith(selector + "-")

def parse_ms(value):
    if not value:
        return None
    text = str(value)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return int(parsed.timestamp() * 1000)
    except Exception:
        warn(f"invalid_timestamp value={value!r}")
        return None

def effective_ms(value):
    parsed = parse_ms(value)
    if parsed is None or parsed < start_ms:
        return observed_ms
    return parsed

def dep_image(dep):
    containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []) or []
    for container in containers:
        image = container.get("image")
        if image:
            return image
    return default_image

def rs_owner_name(rs):
    for owner in rs.get("metadata", {}).get("ownerReferences", []) or []:
        if owner.get("kind") == "Deployment" and owner.get("name"):
            return owner.get("name")
    labels = rs.get("metadata", {}).get("labels", {}) or {}
    return labels.get("app", "")

def event_object_name(event):
    involved = event.get("involvedObject", {}) or {}
    return involved.get("name", "")

def event_object_kind(event):
    involved = event.get("involvedObject", {}) or {}
    return involved.get("kind", "")

def event_time_ms(event):
    for field in ("eventTime", "lastTimestamp", "firstTimestamp"):
        parsed = parse_ms(event.get(field))
        if parsed is not None:
            return max(parsed, start_ms)
    series = event.get("series") or {}
    parsed = parse_ms(series.get("lastObservedTime"))
    if parsed is not None:
        return max(parsed, start_ms)
    warn(f"event_missing_timestamp reason={event.get('reason', '')!r} object={event_object_name(event)!r}")
    return observed_ms

def emit(phase, deployment="", pod="", node="", image="", source="kubernetes-api", reason="", event_time="", message="", end_ms=None):
    if end_ms is None:
        end_ms = observed_ms
    key = "\x1f".join([run_id, scenario, operation, phase, deployment, pod, node, reason, str(event_time), message[:160]])
    if key in observed_keys:
        return
    observed_keys.add(key)
    row = {
        "system": "eks",
        "run_id": run_id,
        "scenario": scenario,
        "operation": operation,
        "entity": entity,
        "deployment": deployment,
        "pod": pod,
        "namespace": namespace,
        "node": node,
        "image": image or default_image,
        "phase": phase,
        "start_ms": start_ms,
        "end_ms": int(end_ms),
        "duration_ms": max(0, int(end_ms) - start_ms),
        "source": source,
        "event_reason": reason,
        "event_time_ms": event_time,
        "message": message,
    }
    with open(spans_csv, "a", newline="") as f:
        csv.DictWriter(f, fieldnames=fieldnames).writerow(row)
    with open(spans_jsonl, "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")

def condition_time(conditions, condition_type):
    for condition in conditions or []:
        if condition.get("type") == condition_type and condition.get("status") == "True":
            return effective_ms(condition.get("lastTransitionTime"))
    return None

selected_deps = []
selected = set()
ready = desired = 0
for dep in deployments:
    name = dep.get("metadata", {}).get("name", "")
    if not selected_name(name):
        continue
    selected_deps.append(dep)
    selected.add(name)
    spec_replicas = int(dep.get("spec", {}).get("replicas", 0) or 0)
    ready_replicas = int(dep.get("status", {}).get("readyReplicas", 0) or 0)
    desired += spec_replicas
    ready += ready_replicas
    image = dep_image(dep)
    emit("deployment_observed", deployment=name, image=image, source="kubernetes-poll", event_time=str(parse_ms(dep.get("metadata", {}).get("creationTimestamp")) or ""))
    if spec_replicas == ready_replicas and spec_replicas > 0:
        ready_time = None
        for condition in dep.get("status", {}).get("conditions", []) or []:
            if condition.get("type") == "Available" and condition.get("status") == "True":
                ready_time = effective_ms(condition.get("lastUpdateTime") or condition.get("lastTransitionTime"))
                break
        emit("deployment_ready", deployment=name, image=image, source="kubernetes-status", event_time=str(ready_time or ""), end_ms=ready_time or observed_ms)

rs_selected = []
rs_names = set()
for rs in replicasets:
    owner = rs_owner_name(rs)
    name = rs.get("metadata", {}).get("name", "")
    if owner not in selected:
        continue
    rs_selected.append(rs)
    rs_names.add(name)
    emit("replicaset_observed", deployment=owner, image=default_image, source="kubernetes-poll", event_time=str(parse_ms(rs.get("metadata", {}).get("creationTimestamp")) or ""))

pods_total = pods_scheduled = pods_ready = 0
selected_pods = set()
for pod in pods:
    labels = pod.get("metadata", {}).get("labels", {}) or {}
    deployment = labels.get("app", "")
    if deployment not in selected:
        continue
    metadata = pod.get("metadata", {}) or {}
    status = pod.get("status", {}) or {}
    spec = pod.get("spec", {}) or {}
    pod_name = metadata.get("name", "")
    selected_pods.add(pod_name)
    node = spec.get("nodeName", "") or ""
    containers = spec.get("containers", []) or []
    image = containers[0].get("image", default_image) if containers else default_image
    conditions = status.get("conditions", []) or []
    pods_total += 1
    emit("pod_created", deployment=deployment, pod=pod_name, node=node, image=image, source="kubernetes-status", event_time=str(parse_ms(metadata.get("creationTimestamp")) or ""), end_ms=effective_ms(metadata.get("creationTimestamp")))
    scheduled_time = condition_time(conditions, "PodScheduled")
    if node:
        pods_scheduled += 1
        emit("pod_scheduled", deployment=deployment, pod=pod_name, node=node, image=image, source="kubernetes-status", event_time=str(scheduled_time or ""), end_ms=scheduled_time or observed_ms)
    initialized_time = condition_time(conditions, "Initialized")
    if initialized_time is not None:
        emit("pod_condition_initialized", deployment=deployment, pod=pod_name, node=node, image=image, source="kubernetes-status", event_time=str(initialized_time), end_ms=initialized_time)
    containers_ready_time = condition_time(conditions, "ContainersReady")
    if containers_ready_time is not None:
        emit("pod_condition_containers_ready", deployment=deployment, pod=pod_name, node=node, image=image, source="kubernetes-status", event_time=str(containers_ready_time), end_ms=containers_ready_time)
    pod_ready_time = condition_time(conditions, "Ready")
    if pod_ready_time is not None:
        pods_ready += 1
        emit("pod_condition_ready", deployment=deployment, pod=pod_name, node=node, image=image, source="kubernetes-status", event_time=str(pod_ready_time), end_ms=pod_ready_time)
    for container_status in status.get("containerStatuses", []) or []:
        container_image = container_status.get("image") or image
        state = container_status.get("state", {}) or {}
        running = state.get("running") or {}
        started_at = running.get("startedAt")
        if started_at:
            started_ms = effective_ms(started_at)
            emit("container_started", deployment=deployment, pod=pod_name, node=node, image=container_image, source="containerStatuses", event_time=str(parse_ms(started_at) or ""), message=container_status.get("name", ""), end_ms=started_ms)
        if container_status.get("ready") is True:
            emit("container_ready_observed", deployment=deployment, pod=pod_name, node=node, image=container_image, source="containerStatuses", message=container_status.get("name", ""))

for event in events:
    kind = event_object_kind(event)
    object_name = event_object_name(event)
    if kind == "Pod" and object_name not in selected_pods:
        continue
    if kind == "Deployment" and object_name not in selected:
        continue
    if kind == "ReplicaSet" and object_name not in rs_names:
        continue
    if kind not in {"Pod", "Deployment", "ReplicaSet"}:
        continue
    reason = event.get("reason", "") or "Unknown"
    phase = "kubernetes_event_" + reason.lower().replace(" ", "_").replace("/", "_")
    end = event_time_ms(event)
    deployment = ""
    pod_name = ""
    node = ""
    if kind == "Pod":
        pod_name = object_name
        for pod in pods:
            if pod.get("metadata", {}).get("name") == pod_name:
                deployment = (pod.get("metadata", {}).get("labels", {}) or {}).get("app", "")
                node = pod.get("spec", {}).get("nodeName", "") or ""
                break
    elif kind == "Deployment":
        deployment = object_name
    elif kind == "ReplicaSet":
        for rs in rs_selected:
            if rs.get("metadata", {}).get("name") == object_name:
                deployment = rs_owner_name(rs)
                break
    emit(phase, deployment=deployment, pod=pod_name, node=node, image=default_image, source="kubernetes-event", reason=reason, event_time=str(end), message=event.get("message", ""), end_ms=end)

with open(poll_jsonl, "a") as f:
    f.write(json.dumps({
        "system": "eks",
        "run_id": run_id,
        "scenario": scenario,
        "operation": operation,
        "entity": entity,
        "namespace": namespace,
        "observed_ms": observed_ms,
        "ready": ready,
        "desired": desired,
        "pods_total": pods_total,
        "pods_scheduled": pods_scheduled,
        "pods_ready": pods_ready,
        "replicasets": len(rs_selected),
        "source": "kubectl-poll",
    }, separators=(",", ":")) + "\n")

with open(observed_keys_path, "w") as f:
    json.dump(sorted(observed_keys), f)

print(ready, desired, pods_total, pods_scheduled, pods_ready)
PY
}

wait_phase_counts() {
    local scenario="$1"
    local entity="$2"
    local operation="$3"
    local mode="$4"
    local selector="$5"
    local expected_ready="$6"
    local expected_pods="$7"
    local start_ms="$8"
    local attempts="${9:-300}"
    local delay="${10:-$POLL_DELAY}"

    local deployments_observed_recorded=0
    local replicasets_observed_recorded=0
    local pods_created_recorded=0
    local pods_scheduled_recorded=0
    local pods_ready_recorded=0

    for attempt in $(seq 1 "$attempts"); do
        local t
        t="$(now_ms)"
        LAST_COUNTS="$(state_counts "$mode" "$selector" "$scenario" "$entity" "$operation" "$start_ms" "$t" || echo "$LAST_COUNTS")"
        read -r ready desired pods_total pods_scheduled pods_ready <<< "$LAST_COUNTS"
        local rs_count
        rs_count="$(python3 - <<'PY' "$OUT_DIR/replicasets-current.json" "$mode" "$selector"
import json, sys
path, mode, selector = sys.argv[1:4]
try:
    items = json.load(open(path)).get("items", [])
except Exception:
    print(0)
    raise SystemExit
count = 0
for rs in items:
    owner = ""
    for ref in rs.get("metadata", {}).get("ownerReferences", []) or []:
        if ref.get("kind") == "Deployment":
            owner = ref.get("name", "")
            break
    if not owner:
        owner = (rs.get("metadata", {}).get("labels", {}) or {}).get("app", "")
    if (mode == "exact" and owner == selector) or (mode != "exact" and owner.startswith(selector + "-")):
        count += 1
print(count)
PY
)"
        if [[ "$deployments_observed_recorded" == "0" && "$desired" -ge 0 ]]; then
            csv_event "$scenario" "$entity" "deployment_observed" "$start_ms" "$t" "$desired" "kubectl-poll"
            snapshot_phase "${scenario}-${operation}-deployment-observed"
            deployments_observed_recorded=1
        fi
        if [[ "$replicasets_observed_recorded" == "0" && "$rs_count" -ge 1 ]]; then
            csv_event "$scenario" "$entity" "replicaset_observed" "$start_ms" "$t" "$rs_count" "kubectl-poll"
            snapshot_phase "${scenario}-${operation}-replicaset-observed"
            replicasets_observed_recorded=1
        fi
        if [[ "$pods_created_recorded" == "0" && "$pods_total" -ge "$expected_pods" ]]; then
            csv_event "$scenario" "$entity" "pods_created_observed" "$start_ms" "$t" "$pods_total" "kubernetes-api"
            snapshot_phase "${scenario}-${operation}-pods-created"
            pods_created_recorded=1
        fi
        if [[ "$pods_scheduled_recorded" == "0" && "$pods_scheduled" -ge "$expected_pods" ]]; then
            csv_event "$scenario" "$entity" "pods_scheduled_observed" "$start_ms" "$t" "$pods_scheduled" "kubernetes-api"
            snapshot_phase "${scenario}-${operation}-pods-scheduled"
            pods_scheduled_recorded=1
        fi
        if [[ "$pods_ready_recorded" == "0" && "$pods_ready" -ge "$expected_ready" ]]; then
            csv_event "$scenario" "$entity" "pods_ready_observed" "$start_ms" "$t" "$pods_ready" "kubernetes-api"
            snapshot_phase "${scenario}-${operation}-pods-ready"
            pods_ready_recorded=1
        fi
        if [[ "$ready" -ge "$expected_ready" && "$desired" -eq "$expected_ready" ]]; then
            csv_event "$scenario" "$entity" "deployment_ready_observed" "$start_ms" "$t" "$ready" "kubernetes-api"
            snapshot_phase "${scenario}-${operation}-deployment-ready"
            echo "ready scenario=$scenario entity=$entity operation=$operation expected=$expected_ready attempt=$attempt pods=$pods_ready/$pods_scheduled/$pods_total"
            return 0
        fi
        echo "waiting scenario=$scenario entity=$entity operation=$operation ready=$ready/$desired pods_ready=$pods_ready scheduled=$pods_scheduled total=$pods_total rs=$rs_count attempt=$attempt/$attempts"
        sleep "$delay"
    done

    echo "timeout waiting for $scenario $entity operation=$operation ready $expected_ready" >&2
    capture_timeout_diagnostics
    return 1
}

wait_zero_ready() {
    local scenario="$1"
    local entity="$2"
    local operation="$3"
    local mode="$4"
    local selector="$5"
    local start_ms="$6"
    local attempts="${7:-180}"
    local delay="${8:-$POLL_DELAY}"
    for attempt in $(seq 1 "$attempts"); do
        local t
        t="$(now_ms)"
        LAST_COUNTS="$(state_counts "$mode" "$selector" "$scenario" "$entity" "$operation" "$start_ms" "$t" || echo "$LAST_COUNTS")"
        read -r ready desired pods_total pods_scheduled pods_ready <<< "$LAST_COUNTS"
        if [[ "$ready" -eq 0 && "$desired" -eq 0 ]]; then
            csv_event "$scenario" "$entity" "deployment_zero_observed" "$start_ms" "$t" "0" "kubernetes-api"
            span_event "$scenario" "$operation" "$entity" "$selector" "" "" "$SCALE_IMAGE" "deployment_zero_observed" "$start_ms" "$t" "kubectl-poll" "" "" "deployment desired/ready observed at zero"
            snapshot_phase "${scenario}-${operation}-deployment-zero"
            echo "zero_ready scenario=$scenario entity=$entity operation=$operation attempt=$attempt"
            return 0
        fi
        echo "waiting_zero scenario=$scenario entity=$entity operation=$operation ready=$ready/$desired pods_ready=$pods_ready total=$pods_total attempt=$attempt/$attempts"
        sleep "$delay"
    done
    echo "timeout waiting for $scenario $entity operation=$operation zero ready" >&2
    capture_timeout_diagnostics
    return 1
}

apply_deployment() {
    local name="$1"
    local replicas="$2"
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
spec:
  replicas: $replicas
  selector:
    matchLabels:
      app: $name
  template:
    metadata:
      labels:
        app: $name
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: main
        image: $SCALE_IMAGE
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 10m
            memory: 16Mi
EOF
}

generate_reports() {
    python3 - "$SPANS_JSONL" "$SPANS_JSON" "$SPANS_CSV" "$FOLDED_OUT" "$GRANULAR_SUMMARY" "$EVENTS_CSV" "$POLL_JSONL" <<'PY'
import collections
import csv
import json
import sys

jsonl_path, json_path, csv_path, folded_path, summary_path, events_path, poll_path = sys.argv[1:]
rows = []
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
with open(json_path, "w") as f:
    json.dump(rows, f, indent=2, sort_keys=True)

folded = collections.Counter()
phase_summary = collections.defaultdict(lambda: {"count": 0, "total_ms": 0, "max_ms": 0})
for row in rows:
    duration = int(row.get("duration_ms") or 0)
    stack = ";".join(["eks", row.get("scenario", "unknown"), row.get("operation", "unknown"), row.get("phase", "unknown")])
    folded[stack] += duration
    key = (row.get("scenario", ""), row.get("operation", ""), row.get("phase", ""))
    phase_summary[key]["count"] += 1
    phase_summary[key]["total_ms"] += duration
    phase_summary[key]["max_ms"] = max(phase_summary[key]["max_ms"], duration)

with open(folded_path, "w") as f:
    for stack, duration in sorted(folded.items()):
        f.write(f"{stack} {duration}\n")

poll_count = 0
with open(poll_path) as f:
    for line in f:
        if line.strip():
            poll_count += 1

event_count = 0
with open(events_path) as f:
    reader = csv.DictReader(f)
    for _ in reader:
        event_count += 1

with open(summary_path, "w") as f:
    f.write("# EKS granular latency summary\n\n")
    f.write("## Artifacts\n\n")
    f.write("- latency-events.csv: aggregate Hivemind-comparable phase observations\n")
    f.write("- latency-spans.csv: per-deployment/pod granular spans\n")
    f.write("- latency-spans.jsonl: newline-delimited span records written during polling\n")
    f.write("- latency-spans.json: JSON array matching latency-spans.csv\n")
    f.write("- poll-observations.jsonl: dashboard/poll observation timeline\n")
    f.write("- latency-flamegraph.folded: folded stack cumulative milliseconds\n")
    f.write("- deployments/replicasets/pods/events-*.json: kubectl snapshots at phase boundaries\n\n")
    f.write(f"spans: {len(rows)}\n\n")
    f.write(f"aggregate_events: {event_count}\n\n")
    f.write(f"poll_observations: {poll_count}\n\n")
    f.write("| scenario | operation | phase | count | total_ms | max_ms |\n")
    f.write("|---|---|---|---:|---:|---:|\n")
    for (scenario, operation, phase), values in sorted(phase_summary.items()):
        f.write(f"| {scenario} | {operation} | {phase} | {values['count']} | {values['total_ms']} | {values['max_ms']} |\n")
PY
}

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
snapshot_phase namespace-created

single_name="eks-scale-single-$RUN_ID"
echo "=== EKS one deployment 0 -> 50 -> 1 ==="
create_start="$(now_ms)"
span_event "single" "create" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "kubectl_submit" "$create_start" "$create_start" "kubectl_apply" "" "" "kubectl apply deployment replicas=0 submitted"
apply_deployment "$single_name" 0
create_end="$(now_ms)"
csv_event "single" "$single_name" "create_submit" "$create_start" "$create_end" "0" "kubectl_apply"
span_event "single" "create" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "server_ack" "$create_start" "$create_end" "kubectl_apply" "" "" "kubectl apply returned"
snapshot_phase single-create-server-ack
wait_zero_ready "single" "$single_name" "create" exact "$single_name" "$create_start" 600

scale_up_start="$(now_ms)"
span_event "single" "scale_0_to_50" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "kubectl_submit" "$scale_up_start" "$scale_up_start" "kubectl_scale" "" "" "kubectl scale deployment replicas=50 submitted"
kubectl -n "$NAMESPACE" scale "deployment/$single_name" --replicas=50 >/dev/null
scale_up_submit="$(now_ms)"
csv_event "single" "$single_name" "scale_0_to_50_submit" "$scale_up_start" "$scale_up_submit" "50" "kubectl_scale"
span_event "single" "scale_0_to_50" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "server_ack" "$scale_up_start" "$scale_up_submit" "kubectl_scale" "" "" "kubectl scale returned"
snapshot_phase single-scale-up-server-ack
wait_phase_counts "single" "$single_name" "scale_0_to_50" exact "$single_name" 50 50 "$scale_up_start" 1500
scale_up_ready="$(now_ms)"

scale_down_start="$(now_ms)"
span_event "single" "scale_50_to_1" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "kubectl_submit" "$scale_down_start" "$scale_down_start" "kubectl_scale" "" "" "kubectl scale deployment replicas=1 submitted"
kubectl -n "$NAMESPACE" scale "deployment/$single_name" --replicas=1 >/dev/null
scale_down_submit="$(now_ms)"
csv_event "single" "$single_name" "scale_50_to_1_submit" "$scale_down_start" "$scale_down_submit" "1" "kubectl_scale"
span_event "single" "scale_50_to_1" "$single_name" "$single_name" "" "" "$SCALE_IMAGE" "server_ack" "$scale_down_start" "$scale_down_submit" "kubectl_scale" "" "" "kubectl scale returned"
snapshot_phase single-scale-down-server-ack
wait_phase_counts "single" "$single_name" "scale_50_to_1" exact "$single_name" 1 1 "$scale_down_start" 900
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

kubectl -n "$NAMESPACE" delete "deployment/$single_name" --wait=true >/dev/null 2>&1 || true
snapshot_phase single-deleted

multi_prefix="eks-scale-many-$RUN_ID"
echo ""
echo "=== EKS 50 deployments x 1 replica ==="
multi_start="$(now_ms)"
for i in $(seq 1 50); do
    dep_name="$multi_prefix-$i"
    dep_start="$(now_ms)"
    span_event "multi_50x1" "create_50x1" "$multi_prefix" "$dep_name" "" "" "$SCALE_IMAGE" "kubectl_submit" "$dep_start" "$dep_start" "kubectl_apply" "" "" "kubectl apply deployment replicas=1 submitted"
    apply_deployment "$dep_name" 1
    dep_end="$(now_ms)"
    span_event "multi_50x1" "create_50x1" "$multi_prefix" "$dep_name" "" "" "$SCALE_IMAGE" "server_ack" "$dep_start" "$dep_end" "kubectl_apply" "" "" "kubectl apply returned"
done
multi_submit="$(now_ms)"
csv_event "multi_50x1" "$multi_prefix" "create_50_submit" "$multi_start" "$multi_submit" "50" "kubectl_apply"
snapshot_phase multi-create-server-ack
wait_phase_counts "multi_50x1" "$multi_prefix" "create_50x1" prefix "$multi_prefix" 50 50 "$multi_start" 1500
multi_ready="$(now_ms)"

multi_submit_ms="$((multi_submit - multi_start))"
multi_ready_ms="$((multi_ready - multi_start))"
echo "50x1 submit total: ${multi_submit_ms}ms"
echo "50x1 all ready: ${multi_ready_ms}ms"

capture_k8s_state after
generate_reports

cat > "$OUT_DIR/summary.md" <<EOF
# EKS scale benchmark matrix

- run_id: $RUN_ID
- image: $SCALE_IMAGE
- namespace: $NAMESPACE
- latency_events: latency-events.csv
- latency_spans_csv: latency-spans.csv
- latency_spans_jsonl: latency-spans.jsonl
- latency_spans_json: latency-spans.json
- poll_observations: poll-observations.jsonl
- folded_flamegraph: latency-flamegraph.folded
- granular_summary: latency-summary.md

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
cleanup
trap - EXIT
