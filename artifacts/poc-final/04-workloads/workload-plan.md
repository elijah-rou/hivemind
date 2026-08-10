# Section 3 workload plan

Status: selected and scripted, not yet run on AWS in this slice.

## CPU workload

Image source: `workloads/poc/cpu`

Behavior:
- HTTP service on `PORT=8080`
- `POST /inference`
- deterministic hash-embedding classifier
- returns `model`, `device=cpu`, `embedding`, `classification`

Why this is acceptable for POC:
- non-echo inference transform
- no external model download
- small enough to cold-start quickly on CPU worker

## GPU workload

Image source: `workloads/poc/gpu`

Behavior:
- HTTP service on `PORT=8080`
- `POST /inference`
- deterministic PyTorch CUDA MLP
- fails if CUDA is unavailable
- returns `model`, CUDA version, GPU device name, probabilities, class id

Why this is acceptable for POC:
- exercises the GPU runtime path with PyTorch CUDA compute
- no external model download
- output proves CUDA-backed execution rather than payload echo

## Build/push

```bash
REGISTRY=<registry/repository> bash infra/poc/build-workload-images.sh
```

## Run validation after fresh AWS smoke

```bash
CPU_IMAGE=<printed-cpu-image> \
GPU_IMAGE=<printed-gpu-image> \
GPU_TYPE=t4 \
OUT_DIR=artifacts/poc-final/04-workloads \
bash infra/poc/workload-test.sh http://<api>:8080
```

The script captures create responses, request/response pairs, cold/warm latency, deployments HTML, and pods HTML.
