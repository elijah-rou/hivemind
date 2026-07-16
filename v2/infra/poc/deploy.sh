#!/bin/bash
set -euo pipefail

# Hivemind POC deploy script
# Prerequisites: terraform applied, SSH key available, cross-compiled binaries
#
# Usage: ./deploy.sh [--build] [--key <ssh-key>]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
REPLICA_SSH_USER="${REPLICA_SSH_USER:-ec2-user}"   # AL2023 default
WORKER_SSH_USER="${WORKER_SSH_USER:-ubuntu}"       # hivemind-standalone AMI (Ubuntu)
BUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=true; shift ;;
        --key) SSH_KEY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY"

# --- Build Linux binaries ---
if [ "$BUILD" = true ]; then
    "$SCRIPT_DIR/build-binaries.sh" --output-dir "$SCRIPT_DIR"
    cd "$SCRIPT_DIR"
fi

# --- Get IPs from Terraform ---
echo "==> Reading Terraform outputs..."
cd "$SCRIPT_DIR"

REPLICA_IPS=($(terraform output -json replica_ips | jq -r '.[]'))
REPLICA_PUBLIC_IPS=($(terraform output -json replica_public_ips | jq -r '.[]'))
AGENT_CPU_IP=$(terraform output -raw worker_cpu_ip)
AGENT_GPU_IP=$(terraform output -raw worker_gpu_ip)

REPLICA_COUNT=${#REPLICA_IPS[@]}
echo "    Replicas: ${REPLICA_IPS[*]}"
echo "    Worker CPU: $AGENT_CPU_IP"
echo "    Worker GPU: $AGENT_GPU_IP"

# --- Build peer + api addrs strings ---
PEERS=""
API_ADDRS=""
for i in $(seq 0 $((REPLICA_COUNT - 1))); do
    if [ -n "$PEERS" ]; then PEERS="$PEERS,"; fi
    PEERS="${PEERS}${i}@${REPLICA_IPS[$i]}:9102"
    if [ -n "$API_ADDRS" ]; then API_ADDRS="$API_ADDRS,"; fi
    API_ADDRS="${API_ADDRS}${REPLICA_IPS[$i]}:9001"
done
echo "    Peers: $PEERS"
echo "    API addrs: $API_ADDRS"

# --- Deploy to replicas ---
for i in $(seq 0 $((REPLICA_COUNT - 1))); do
    PUBLIC_IP="${REPLICA_PUBLIC_IPS[$i]}"
    PRIVATE_IP="${REPLICA_IPS[$i]}"
    echo "==> Deploying replica $i to $PUBLIC_IP ($PRIVATE_IP)..."

    # Upload binaries
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind-linux" "$REPLICA_SSH_USER@$PUBLIC_IP:/tmp/hivemind"
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind-api-linux" "$REPLICA_SSH_USER@$PUBLIC_IP:/tmp/hivemind-api"
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind.service" "$REPLICA_SSH_USER@$PUBLIC_IP:/tmp/hivemind.service"
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind-api.service" "$REPLICA_SSH_USER@$PUBLIC_IP:/tmp/hivemind-api.service"

    # Install and configure
    ssh $SSH_OPTS "$REPLICA_SSH_USER@$PUBLIC_IP" bash <<REMOTE
        sudo mv /tmp/hivemind /usr/local/bin/hivemind
        sudo mv /tmp/hivemind-api /usr/local/bin/hivemind-api
        sudo chmod +x /usr/local/bin/hivemind /usr/local/bin/hivemind-api
        sudo mv /tmp/hivemind.service /etc/systemd/system/hivemind.service
        sudo mv /tmp/hivemind-api.service /etc/systemd/system/hivemind-api.service
        sudo mkdir -p /var/lib/hivemind /etc/hivemind

        # Update env with real peer addresses
        sudo sed -i "s|^HIVEMIND_PEERS=.*|HIVEMIND_PEERS=$PEERS|" /etc/hivemind/replica.env
        sudo sed -i "s|^HIVEMIND_NODE_ID=.*|HIVEMIND_NODE_ID=$i|" /etc/hivemind/replica.env
        sudo sed -i "s|^HIVEMIND_REPLICA_COUNT=.*|HIVEMIND_REPLICA_COUNT=$REPLICA_COUNT|" /etc/hivemind/replica.env
        sudo sed -i "s|^HIVEMIND_API_ADDRS=.*|HIVEMIND_API_ADDRS=$API_ADDRS|" /etc/hivemind/api.env

        sudo systemctl daemon-reload
        sudo systemctl enable hivemind hivemind-api
        sudo systemctl restart hivemind hivemind-api
REMOTE
    echo "    replica $i started"
done

# Wait for replicas to elect leader
echo "==> Waiting 10s for leader election..."
sleep 10

# --- Deploy to workers ---
# Worker can connect to any replica's worker port. It rotates through this list
# after disconnects so leader loss does not strand workers on the dead replica.
AGENT_REPLICA_ADDR=""
for i in $(seq 0 $((REPLICA_COUNT - 1))); do
    if [ -n "$AGENT_REPLICA_ADDR" ]; then AGENT_REPLICA_ADDR="$AGENT_REPLICA_ADDR,"; fi
    AGENT_REPLICA_ADDR="${AGENT_REPLICA_ADDR}${REPLICA_IPS[$i]}:9000"
done

AGENT_CPU_PUBLIC=$(terraform output -raw worker_cpu_public_ip 2>/dev/null || echo "")
AGENT_GPU_PUBLIC=$(terraform output -raw worker_gpu_public_ip 2>/dev/null || echo "")

for AGENT_PAIR in "cpu:$AGENT_CPU_PUBLIC" "gpu:$AGENT_GPU_PUBLIC"; do
    ROLE="${AGENT_PAIR%%:*}"
    PUBLIC_IP="${AGENT_PAIR#*:}"
    if [ -z "$PUBLIC_IP" ]; then
        echo "==> Worker $ROLE: no public IP, skipping"
        continue
    fi

    echo "==> Deploying worker ($ROLE) to $PUBLIC_IP..."
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind-worker-linux" "$WORKER_SSH_USER@$PUBLIC_IP:/tmp/hivemind-worker"
    scp $SSH_OPTS "$SCRIPT_DIR/hivemind-worker.service" "$WORKER_SSH_USER@$PUBLIC_IP:/tmp/hivemind-worker.service"
    scp $SSH_OPTS "$SCRIPT_DIR/update-worker-env.sh" "$WORKER_SSH_USER@$PUBLIC_IP:/tmp/update-worker-env.sh"

    ssh $SSH_OPTS "$WORKER_SSH_USER@$PUBLIC_IP" bash <<REMOTE
        sudo mv /tmp/hivemind-worker /usr/local/bin/hivemind-worker
        sudo chmod +x /usr/local/bin/hivemind-worker
        sudo mv /tmp/hivemind-worker.service /etc/systemd/system/hivemind-worker.service
        sudo mkdir -p /etc/hivemind

        # Preserve the Terraform-rendered PSK and only patch the replica address.
        sudo chmod +x /tmp/update-worker-env.sh
        sudo /tmp/update-worker-env.sh /etc/hivemind/worker.env "$AGENT_REPLICA_ADDR"
        rm -f /tmp/update-worker-env.sh

        sudo systemctl daemon-reload
        sudo systemctl enable hivemind-worker
        sudo systemctl restart hivemind-worker
REMOTE
    echo "    worker ($ROLE) started"
done

echo ""
echo "=== POC Deployment Complete ==="
echo "Replica IPs:  ${REPLICA_PUBLIC_IPS[*]}"
echo "Worker CPU:    $AGENT_CPU_PUBLIC"
echo "Worker GPU:    $AGENT_GPU_PUBLIC"
echo "API:          http://${REPLICA_PUBLIC_IPS[0]}:8080/v1/health"
echo "Dashboard:    http://${REPLICA_PUBLIC_IPS[0]}:8080/dashboard"
echo "Smoke:        ./smoke-test.sh http://${REPLICA_PUBLIC_IPS[0]}:8080 --gpu-worker ${AGENT_GPU_PUBLIC} --ssh-key ${SSH_KEY} --gpu-type t4"
