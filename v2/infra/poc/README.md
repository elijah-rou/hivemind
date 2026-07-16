# Hivemind POC Deployment

## Prerequisites

### Cross-compile toolchain (on macOS)

**Zig** (0.16.0+): Zig cross-compiles natively, no extra setup.

**Rust** (x86_64-linux-gnu target):
```bash
rustup target add x86_64-unknown-linux-gnu
```

`deploy.sh --build` now prefers `cargo` with a Zig-provided Linux linker, which avoids Docker/`cross` on macOS hosts. It falls back to `cross` only when Zig is unavailable.

Manual fallback options:
```bash
# Preferred on macOS when plain cargo lacks x86_64-linux-gnu gcc
cargo install cargo-zigbuild

# Or Docker-based fallback
cargo install cross
cross build --release --target x86_64-unknown-linux-gnu
```

**Go**: Cross-compiles natively via `GOOS=linux GOARCH=amd64`.

### AWS

- Terraform 1.5+
- AWS CLI configured with credentials
- Amazon Linux 2023 replica AMI ID and hivemind-standalone worker AMI ID for the target region
- SSH key pair registered in AWS

## Quick Start

```bash
cd infra/poc

# 1. Create infrastructure
terraform init
terraform apply \
  -var="replica_ami_id=ami-XXXXXXXX" \
  -var="worker_ami_id=ami-YYYYYYYY" \
  -var="key_name=your-key" \
  -var="ssh_cidr=$(curl -s ifconfig.me)/32" \
  -var="encryption_key=$(openssl rand -hex 32)"

# replica_ami_id: Amazon Linux 2023 x86_64 AMI (deploy.sh defaults to REPLICA_SSH_USER=ec2-user)
# worker_ami_id:  hivemind-standalone AMI (containerd + nydus + nvidia)

# 2. Build and deploy
./deploy.sh --build --key ~/.ssh/your-key.pem

# If you choose an Ubuntu replica AMI instead, override the SSH user:
# REPLICA_SSH_USER=ubuntu ./deploy.sh --build --key ~/.ssh/your-key.pem

# 3. Run smoke test
# Basic end-to-end proof (CPU + GPU echo workloads through /run):
./smoke-test.sh \
  http://$(terraform output -raw api_url | sed 's|http://||') \
  --gpu-worker "$(terraform output -raw worker_gpu_public_ip)" \
  --ssh-key ~/.ssh/your-key.pem \
  --gpu-type t4

# The SSH key is only needed for the remote GPU checks:
#   - `nvidia-smi -L` on the GPU worker
#   - `ctr -n hivemind tasks list`
#   - container runtime info showing `nvidia`
```

## Architecture

```
5x c5.xlarge (replicas)     1x c5.xlarge (CPU worker)     1x g4dn.xlarge (GPU worker)
  hivemind.service             hivemind-worker.service        hivemind-worker.service
  hivemind-api (on replica 0)
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 8080 | TCP | HTTP API + Dashboard |
| 9000 | TCP | Worker connections |
| 9001 | TCP | Client connections |
| 9102 | TCP | Peer VRR replication |
| 9200 | TCP | Prometheus metrics (replica) |
| 8081 | TCP | Prometheus metrics (worker) |
| 9300 | UDP | Cross-region gossip |

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Terraform: 5 replicas + 2 workers + security group |
| `hivemind.service` | Systemd unit for replica |
| `hivemind-worker.service` | Systemd unit for worker |
| `build-binaries.sh` | Cross-build Linux replica/worker/API binaries |
| `deploy.sh` | Build, upload, configure, start |
| `smoke-test.sh` | End-to-end verification |
| `replica-init.sh` | Cloud-init for replica env |
| `worker-init.sh` | Cloud-init for worker env |

## Teardown

```bash
terraform destroy
```
