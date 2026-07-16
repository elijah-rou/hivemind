#!/bin/bash
set -euo pipefail

# Hivemind worker cloud-init script
# Binaries are uploaded later by deploy.sh.
#
# The Hivemind ubuntu-eks-nydus AMI strips the cloud-init users-groups
# module, so ssh key injection via EC2 KeyPair metadata is skipped. We
# re-fetch the pubkey from IMDS and write it to ~ubuntu/.ssh/authorized_keys
# ourselves. Also runs /etc/eks/bootstrap.sh in standalone mode (no cluster
# name) to start containerd + nydus-snapshotter + nvidia runtime.

# --- 1. Install SSH key for user 'ubuntu' ---
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PUBKEY=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key")

install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
echo "$PUBKEY" > /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys

# --- 2. Run AMI bootstrap in standalone mode (no cluster → skip kubelet) ---
/etc/eks/bootstrap.sh --container-runtime containerd || true

# --- 3. Write hivemind worker env ---
mkdir -p /etc/hivemind

cat > /etc/hivemind/worker.env <<'ENVEOF'
HIVEMIND_REPLICA_ADDR=${replica_addr}
HIVEMIND_SNAPSHOTTER=overlayfs
HIVEMIND_AGENT_METRICS_PORT=8081
HIVEMIND_ENCRYPTION_KEY=${encryption_key}
ENVEOF

echo "hivemind: worker cloud-init complete"
