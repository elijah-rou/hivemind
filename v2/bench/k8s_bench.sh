#!/bin/bash
#
# Kubernetes scheduling latency benchmark.
# Creates N deployments and measures time from kubectl apply to pod scheduled.
# Equivalent to the Hivemind bench tool for comparison.
#
set -euo pipefail

CLUSTER_NAME="hivemind-bench"
NUM_DEPLOYMENTS=${1:-20}
NAMESPACE="bench"

cleanup() {
    echo "Cleaning up..."
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
}

echo "=== K8s Scheduling Benchmark ==="
echo "Deployments: $NUM_DEPLOYMENTS"
echo ""

# Check if cluster exists, create if not
if ! kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo "Creating 3-node kind cluster..."
    cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
    echo ""
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null 2>&1
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

echo "Cluster ready. Starting benchmark..."
echo ""

# Clean previous deployments
kubectl delete deployments --all -n "$NAMESPACE" >/dev/null 2>&1 || true
sleep 2

LATENCIES=()
TOTAL_START=$(python3 -c "import time; print(time.time())")

for i in $(seq 0 $((NUM_DEPLOYMENTS - 1))); do
    NAME="bench-dep-$i"

    START=$(python3 -c "import time; print(time.time())")

    # Create deployment
    kubectl apply -n "$NAMESPACE" -f - >/dev/null 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $NAME
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      containers:
      - name: app
        image: nginx:latest
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

    # Wait for pod to be scheduled (not necessarily running, just scheduled)
    while true; do
        PHASE=$(kubectl get pods -n "$NAMESPACE" -l "app=$NAME" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        CONDITIONS=$(kubectl get pods -n "$NAMESPACE" -l "app=$NAME" -o jsonpath='{.items[0].status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null || echo "")
        if [ "$CONDITIONS" = "True" ] || [ "$PHASE" = "Running" ] || [ "$PHASE" = "Pending" ]; then
            # Check if actually scheduled (has a nodeName)
            NODE=$(kubectl get pods -n "$NAMESPACE" -l "app=$NAME" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
            if [ -n "$NODE" ]; then
                break
            fi
        fi
        sleep 0.05
    done

    END=$(python3 -c "import time; print(time.time())")
    LATENCY=$(python3 -c "print(round(($END - $START) * 1000, 2))")
    LATENCIES+=("$LATENCY")

    # Progress
    if (( (i + 1) % 10 == 0 )); then
        echo "  $((i + 1))/$NUM_DEPLOYMENTS completed..."
    fi
done

TOTAL_END=$(python3 -c "import time; print(time.time())")
TOTAL_MS=$(python3 -c "print(round(($TOTAL_END - $TOTAL_START) * 1000, 2))")

# Calculate stats
python3 <<PYEOF
import statistics

latencies = [${LATENCIES[@]/%/,}]
latencies.sort()

n = len(latencies)
avg = statistics.mean(latencies)
p50 = latencies[n // 2]
p99 = latencies[int(n * 0.99)]
p999 = latencies[min(int(n * 0.999), n - 1)]
throughput = n / (sum(latencies) / 1000) if sum(latencies) > 0 else 0

print()
print("=== Kubernetes Benchmark Results ===")
print(f"Deployments:  {n}")
print(f"Total time:   {$TOTAL_MS}ms")
print(f"Throughput:   {n / ($TOTAL_MS / 1000):.1f} deploys/sec")
print()
print("Latency (kubectl apply -> pod scheduled):")
print(f"  avg:  {avg:.2f}ms")
print(f"  p50:  {p50:.2f}ms")
print(f"  p99:  {p99:.2f}ms")
print(f"  p999: {p999:.2f}ms")
print(f"  min:  {latencies[0]:.2f}ms")
print(f"  max:  {latencies[-1]:.2f}ms")
PYEOF
