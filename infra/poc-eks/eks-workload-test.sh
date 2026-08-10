#!/usr/bin/env bash
set -euo pipefail

# EKS baseline workload test for Section 7.
# Deploys the same CPU and GPU workloads as Hivemind POC,
# measures deploy->ready and /run latency, then cleans up.
#
# Prerequisites:
#   - kubeconfig pointed at the poc-eks cluster
#   - CPU_IMAGE and GPU_IMAGE pushed to ECR
#   - nvidia-device-plugin daemonset absent or installed; script installs and cleans it up if absent
#
# Usage:
#   CPU_IMAGE=... GPU_IMAGE=... bash eks-workload-test.sh

CPU_IMAGE="${CPU_IMAGE:?set CPU_IMAGE}"
GPU_IMAGE="${GPU_IMAGE:?set GPU_IMAGE}"
NAMESPACE="${NAMESPACE:-hivemind-poc-baseline}"
OUT_DIR="${OUT_DIR:-../../artifacts/poc-final/06-benchmarks}"
install -d -m 700 "$OUT_DIR"

PF_CPU_PID=""
PF_GPU_PID=""
INSTALLED_NVIDIA_PLUGIN=false
NVIDIA_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"

cleanup() {
    trap - EXIT
    set +e
    if [[ -n "$PF_CPU_PID" ]]; then
        kill "$PF_CPU_PID" 2>/dev/null || true
    fi
    if [[ -n "$PF_GPU_PID" ]]; then
        kill "$PF_GPU_PID" 2>/dev/null || true
    fi
    echo ""
    echo "Cleaning up namespace $NAMESPACE..."
    kubectl delete namespace "$NAMESPACE" --wait=false || true
    if [[ "$INSTALLED_NVIDIA_PLUGIN" == "true" ]]; then
        echo "Cleaning up NVIDIA device plugin installed by this script..."
        kubectl delete -f "$NVIDIA_PLUGIN_URL" --ignore-not-found=true || true
    fi
}
trap cleanup EXIT

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ---------- Deploy CPU workload ----------

echo "=== CPU workload ==="
CPU_START="$(date +%s%N)"
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: poc-cpu
spec:
  replicas: 1
  selector:
    matchLabels:
      app: poc-cpu
  template:
    metadata:
      labels:
        app: poc-cpu
    spec:
      containers:
      - name: inference
        image: $CPU_IMAGE
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            cpu: 750m
            memory: 512Mi
          limits:
            cpu: 750m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: poc-cpu
spec:
  selector:
    app: poc-cpu
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP
EOF

echo "Waiting for CPU deployment ready..."
kubectl rollout status deployment/poc-cpu -n "$NAMESPACE" --timeout=180s
CPU_READY="$(date +%s%N)"
CPU_DEPLOY_MS="$(( (CPU_READY - CPU_START) / 1000000 ))"
echo "CPU deploy->ready: ${CPU_DEPLOY_MS}ms"

echo "Port-forwarding CPU service..."
kubectl port-forward -n "$NAMESPACE" svc/poc-cpu 18080:8080 &
PF_CPU_PID=$!
sleep 3

CPU_COLD_START="$(date +%s%N)"
curl -fsS -X POST http://127.0.0.1:18080/inference \
    -H 'Content-Type: application/json' \
    -d '{"text":"Hivemind should route low-latency inference workloads without Kubernetes."}' \
    | tee "$OUT_DIR/eks-cpu-run-cold.json"
CPU_COLD_END="$(date +%s%N)"
CPU_COLD_MS="$(( (CPU_COLD_END - CPU_COLD_START) / 1000000 ))"
echo ""
echo "CPU cold /run: ${CPU_COLD_MS}ms"

CPU_WARM_START="$(date +%s%N)"
curl -fsS -X POST http://127.0.0.1:18080/inference \
    -H 'Content-Type: application/json' \
    -d '{"text":"Second request should be warm."}' \
    | tee "$OUT_DIR/eks-cpu-run-warm.json"
CPU_WARM_END="$(date +%s%N)"
CPU_WARM_MS="$(( (CPU_WARM_END - CPU_WARM_START) / 1000000 ))"
echo ""
echo "CPU warm /run: ${CPU_WARM_MS}ms"

kill "$PF_CPU_PID" 2>/dev/null || true
PF_CPU_PID=""

# ---------- Deploy GPU workload ----------

echo ""
echo "=== GPU workload ==="

# Install nvidia device plugin if not present. If this script installs it,
# cleanup removes it too so the live cluster has no unmanaged leftovers.
if ! kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1; then
    kubectl apply -f "$NVIDIA_PLUGIN_URL"
    INSTALLED_NVIDIA_PLUGIN=true
fi

GPU_START="$(date +%s%N)"
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: poc-gpu
spec:
  replicas: 1
  selector:
    matchLabels:
      app: poc-gpu
  template:
    metadata:
      labels:
        app: poc-gpu
    spec:
      containers:
      - name: inference
        image: $GPU_IMAGE
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
            nvidia.com/gpu: "1"
          limits:
            cpu: "1"
            memory: 4Gi
            nvidia.com/gpu: "1"
---
apiVersion: v1
kind: Service
metadata:
  name: poc-gpu
spec:
  selector:
    app: poc-gpu
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP
EOF

echo "Waiting for GPU deployment ready..."
kubectl rollout status deployment/poc-gpu -n "$NAMESPACE" --timeout=600s
GPU_READY="$(date +%s%N)"
GPU_DEPLOY_MS="$(( (GPU_READY - GPU_START) / 1000000 ))"
echo "GPU deploy->ready: ${GPU_DEPLOY_MS}ms"

echo "Port-forwarding GPU service..."
kubectl port-forward -n "$NAMESPACE" svc/poc-gpu 18081:8080 &
PF_GPU_PID=$!
sleep 3

GPU_COLD_START="$(date +%s%N)"
curl -fsS -X POST http://127.0.0.1:18081/inference \
    -H 'Content-Type: application/json' \
    -d '{"values":[0.05,0.15,0.25,0.35,0.45,0.55,0.65,0.75]}' \
    | tee "$OUT_DIR/eks-gpu-run-cold.json"
GPU_COLD_END="$(date +%s%N)"
GPU_COLD_MS="$(( (GPU_COLD_END - GPU_COLD_START) / 1000000 ))"
echo ""
echo "GPU cold /run: ${GPU_COLD_MS}ms"

GPU_WARM_START="$(date +%s%N)"
curl -fsS -X POST http://127.0.0.1:18081/inference \
    -H 'Content-Type: application/json' \
    -d '{"values":[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8]}' \
    | tee "$OUT_DIR/eks-gpu-run-warm.json"
GPU_WARM_END="$(date +%s%N)"
GPU_WARM_MS="$(( (GPU_WARM_END - GPU_WARM_START) / 1000000 ))"
echo ""
echo "GPU warm /run: ${GPU_WARM_MS}ms"

kill "$PF_GPU_PID" 2>/dev/null || true
PF_GPU_PID=""

# ---------- Scheduling benchmark ----------

echo ""
echo "=== K8s scheduling benchmark (50 deployments) ==="

SCHED_START="$(date +%s%N)"
for i in $(seq 1 50); do
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sched-bench-$i
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sched-bench-$i
  template:
    metadata:
      labels:
        app: sched-bench-$i
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: main
        image: nginx:latest
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 10m
            memory: 16Mi
EOF
done

echo "Waiting for all 50 scheduled..."
SCHED_OK=0
for i in $(seq 1 50); do
    kubectl rollout status "deployment/sched-bench-$i" -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 && SCHED_OK=$((SCHED_OK + 1))
done
SCHED_END="$(date +%s%N)"
SCHED_MS="$(( (SCHED_END - SCHED_START) / 1000000 ))"
echo "Scheduled $SCHED_OK/50 in ${SCHED_MS}ms"

# ---------- Results ----------

cat > "$OUT_DIR/hivemind-vs-eks.md" <<EOF
# Hivemind vs EKS Baseline Comparison

| metric | hivemind | eks | notes |
|---|---|---|---|
| deploy->ready (CPU) | TBD | ${CPU_DEPLOY_MS}ms | same c5.xlarge instance type |
| deploy->ready (GPU) | TBD | ${GPU_DEPLOY_MS}ms | same g4dn.xlarge instance type |
| cold /run (CPU) | TBD | ${CPU_COLD_MS}ms | first request after deploy |
| warm /run (CPU) | TBD | ${CPU_WARM_MS}ms | second request |
| cold /run (GPU) | TBD | ${GPU_COLD_MS}ms | |
| warm /run (GPU) | TBD | ${GPU_WARM_MS}ms | |
| 50x sched latency | TBD | ${SCHED_MS}ms total | nginx 10m CPU pods |
| infra components | 3 binaries | EKS + VPC + IAM + node groups + device plugin | |
| operator steps | terraform apply + deploy.sh | terraform apply + kubeconfig + device plugin + manifests | |
EOF

echo ""
echo "evidence=$OUT_DIR"
echo "Fill in Hivemind TBD columns from workload-test.sh output."

# ---------- Cleanup ----------

cleanup
trap - EXIT
echo "Done. Destroy EKS cluster with: cd infra/poc-eks && terraform destroy"
