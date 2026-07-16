#!/bin/bash
set -euo pipefail

# Hivemind replica cloud-init script
# Binaries must be uploaded separately (deploy.sh handles this)

mkdir -m 700 -p /var/lib/hivemind
mkdir -p /etc/hivemind

cat > /etc/hivemind/replica.env <<'ENVEOF'
HIVEMIND_NODE_ID=${node_id}
HIVEMIND_REPLICA_COUNT=${replica_count}
HIVEMIND_AGENT_PORT=9000
HIVEMIND_CLIENT_PORT=9001
HIVEMIND_PEER_PORT=${peer_port}
HIVEMIND_PEERS=${peers}
HIVEMIND_DATA_DIR=/var/lib/hivemind
HIVEMIND_METRICS_PORT=9200
HIVEMIND_S3_BACKUP=${s3_backup_uri}
HIVEMIND_GOSSIP_PORT=9300
HIVEMIND_GOSSIP_PEERS=
HIVEMIND_REGION=${region}
HIVEMIND_ENCRYPTION_KEY=${encryption_key}
ENVEOF

cat > /etc/hivemind/api.env <<'APIEOF'
HIVEMIND_API_LISTEN=:8080
HIVEMIND_API_ADDRS=127.0.0.1:9001
HIVEMIND_API_DNS_TARGETS=
HIVEMIND_ENCRYPTION_KEY=${encryption_key}
HIVEMIND_API_TOKEN=
APIEOF

echo "hivemind: replica ${node_id} cloud-init complete"
