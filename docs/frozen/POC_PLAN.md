# Hivemind POC Plan

> Final acceptance gate now lives in `docs/POC_ACCEPTANCE.md`. This file explains background/scope; `POC_ACCEPTANCE.md` is the pass/fail checklist.

## Goal

Demonstrate that one Hivemind cluster managing nodes across providers/regions is more effective than running multiple Kubernetes clusters in parallel. Specifically:

1. Deploy app via API → pods schedule across heterogeneous nodes (CPU + GPU)
2. Run inference requests → routed to pods, responses return
3. Dashboard shows unified view of cluster, nodes, deployments, pods
4. Cross-region gossip shows capacity from multiple regions
5. All traffic encrypted (PSK frame encryption)
6. Benchmarks: scheduling latency, request throughput vs equivalent EKS setup

**Success criteria**: end-to-end deploy→run→observe loop working on real AWS infrastructure using the hivemind-standalone ubuntu AMI, with measurably lower latency than K8s equivalent.

**2026-04-22 status note**: the fresh AWS redeploy/smoke gate is now closed on live infra. The corrected smoke passed end-to-end on a fresh cluster, including remote GPU checks and CPU/GPU `/run` paths. The POC finish line is no longer “does fresh AWS smoke pass?” It is now the federated acceptance work in `docs/POC_ACCEPTANCE.md`: locality/routing proof, real workloads, resilience drills, repeatability, and K8s comparison.

## What's Built

| Component | Status | Notes |
|-----------|--------|-------|
| VRR 5-node consensus | Done | View change, log repair, disk persistence, crash recovery |
| Worker (Rust) | Done | containerd via ctr CLI, GPU via CDI devices on `io.containerd.runc.v2`, secrets, JuiceFS, metrics |
| HTTP API (Go) | Done | Deployment CRUD, run requests, bearer auth |
| HTMX Dashboard | Done | Cluster state, nodes, deployments, workers, queue, pods (templ + HTMX) |
| Cross-region gossip | Done | UDP broadcast, 5s interval, 30s stale |
| S3 journal backup | Done | Forked aws s3 cp, 60s interval |
| Frame encryption | Done | XChaCha20-Poly1305, PSK via env/flag, all paths (TCP + UDP) |
| Prometheus metrics | Done | 25+ series across replica + worker |
| DNS probes | Done | Background goroutine, /metrics endpoint |
| Fuzz tooling | Done | Standalone fuzzer, trace output, HTML report viewer |
| Simulation hardening | Done | Stability params, pause, path clogging, storage faults, ratios |
| POC terraform | Done | 5 replicas + 2 workers (CPU + GPU), security groups |
| Systemd units | Done | hivemind.service, hivemind-worker.service |
| Deploy script | Done | Builds on macOS without Docker/`cross`, uploads, configures peers, starts services |
| Smoke test | Done | Corrected live smoke passes on fresh AWS infra, including remote GPU checks and CPU/GPU `/run` assertions |
| Local smoke test | Done | 16 checks pass on macOS |

## What's Needed

### Critical (blocks POC demo)

**1. ~~Fix journal wrap bug~~ DONE**
Three fixes applied in `v2/src/replica.zig`:
- Pipeline depth guard in `onRequest()` and `onPrepare()`: reject ops where `op_number - commit_min >= LOG_SIZE_MAX`
- `journalPut()`: refuse overwriting committed entries (slot occupied by op <= commit_min)
- `onStartView()` and `installView()`: use `@max(sv.op_number, logHighOp())` to prevent op_number < commit_min after view change

Also fixed VOPR `run_traced` to configure network/disk faults matching `run` for deterministic replay.

All 15 originally-listed seeds now pass with 0 safety violations. 1 remaining safety violation (seed 32) is a disk write fault corner case (pre-existing, separate concern).

**2. ~~Verify cross-compile to linux-x86_64~~ DONE**
Fixed cross-compile issues:
- `encryption.zig`: replaced macOS-only `std.c.getentropy` with `std.c.getrandom` for Linux
- `fuzz.zig`: replaced `std.c.open` with `std.posix.openatZ` for portability
- `build.zig`: added `link_libc = true` to fuzz module
- `api/`: added missing `golang.org/x/sys` transitive dependency

All three targets cross-compile from macOS:
- `cd v2 && zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast` ✓
- `cd api && GOOS=linux GOARCH=amd64 go build` ✓
- Worker (Rust) needs verification: `cargo build --release --target x86_64-unknown-linux-gnu`

**3. ~~Validate on ubuntu-ami~~ DONE (2026-04-17)**
Forked `ubuntu-eks-nydus` on branch `elijah-rou/hivemind-standalone` (local-only, not pushed) and built worker AMI `ami-0714f823ff4e72d73` (Ubuntu 24.04 + containerd + nydus + nvidia-ctk). Validated on `c5.xlarge` and `g4dn.xlarge`:
- worker connected over encrypted TCP on :9000 with matching PSK
- reported full node capacity and ~50 ms heartbeat freshness
- survived replica restarts and reconnects

Caveat: the AMI strips cloud-init `users-groups`, so `worker-init.sh` re-fetches the SSH pubkey from IMDS and writes `~ubuntu/.ssh/authorized_keys` manually.

**4. ~~API gateway on replica node~~ DONE**
`hivemind-api.service` now lives alongside `hivemind.service`; deploy.sh installs it on replicas.

### Important (should have for demo)

**5. Final AWS confirmation from latest pushed `master`**
Local and simulated coverage is green, and an earlier live AWS pass already proved encrypted cluster health, CPU `/run`, GPU scheduling, and GPU `/run`. One brief final redeploy/smoke should confirm the latest pushed queue-cleanup and GPU CDI fixes together on fresh infra.

**6. Peer auto-discovery from terraform**
Still TODO. Acceptable for the POC; revisit with Route53 private hosted zone when productionising.

**7. ~~Run a real workload~~ DONE**
The live AWS path now proved deploy -> pod running -> `/run` response on both CPU and GPU workers using the echo workload.

**8. ~~Dashboard accessible externally~~ DONE**
Dashboard was reachable externally during the AWS deploys. Port 8080 is now scoped to `var.ssh_cidr` after a GuardDuty finding.

### Nice to Have

**9. Second region**
Gossip is built. Deploying a second 5-node cluster in eu-west-1 with gossip peers configured would demonstrate cross-region capacity visibility on the dashboard.

**10. Benchmark comparison**
Rerun bench tool against POC cluster and compare with EKS results from earlier (33x on c5.xlarge). Publish updated numbers.

**11. TLS for external traffic**
API + dashboard served over plaintext HTTP. For a polished demo, terminate TLS at ALB or add self-signed cert to Go API.

## Execution Order

```
1. ✓ Fix journal wrap bug (replica.zig)
2. ✓ Cross-compile validation (macOS → linux)
3. ✓ Deploy to AWS (terraform apply + deploy.sh)
4. ✓ Validate worker on standalone worker AMI
5. ✓ Run real workload end-to-end on live AWS cluster (CPU + GPU)
6. Final AWS confirmation from latest pushed `master`
7. Benchmark comparison (optional)
8. Second region with gossip (optional)
```

## Infrastructure

```
Region: us-east-1
Replica AMI: Amazon Linux 2023 (ami-098e39bafa7e7303d)
Worker  AMI: hivemind-standalone (ami-0714f823ff4e72d73)

5x c5.xlarge   → hivemind replicas (VRR consensus)
1x c5.xlarge   → CPU worker (echo/nginx pods)
1x g4dn.xlarge → GPU worker (GPU-constrained echo / ML inference)

Encryption: HIVEMIND_ENCRYPTION_KEY env var (64-char hex PSK)
```

## Commands

```bash
# 1. Fix bug, rebuild, run fuzz to verify
cd v2 && zig build fuzz -- sequential --seeds 100

# 2. Build Linux binaries from macOS
bash infra/poc/build-binaries.sh --output-dir /tmp/hivemind-build

# 3. Deploy
KEY="$(openssl rand -hex 32)"
cd infra/poc && terraform apply -var="ami_id=ami-XXX" -var="key_name=XXX" -var="encryption_key=$KEY"
./deploy.sh --build --key ~/.ssh/key.pem

# 4. Smoke test
./smoke-test.sh http://<replica-0-public-ip>:8080

# 5. Open dashboard
open http://<replica-0-public-ip>:8080/dashboard
```
