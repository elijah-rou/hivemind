# Hivemind POC workloads

These images are intentionally tiny app-level inference services for the final POC evidence run. Both expose:

- `GET /health`
- `POST /inference`
- listen on `PORT` (default `8080`)

Hivemind's worker forwards `/run` payloads to `/inference`, so no custom API gateway behavior is needed.

## CPU workload

Path: `workloads/poc/cpu`

A deterministic hash-embedding classifier implemented with Python stdlib only. It returns an embedding plus a top label. This proves a real non-echo CPU inference transform without external model downloads.

## GPU workload

Path: `workloads/poc/gpu`

A deterministic PyTorch CUDA MLP. It fails if CUDA is unavailable and returns CUDA/device metadata plus probabilities. This proves the pod is actually using the GPU runtime path, not only echoing payloads.

## Build/push

Use:

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com/hivemind-poc \
  bash infra/poc/build-workload-images.sh
```

The script prints `CPU_IMAGE=...` and `GPU_IMAGE=...` for the workload validation script.
