#!/usr/bin/env bash
set -euo pipefail

CTR_BIN="${HIVEMIND_CTR:-ctr}"
CTR_SUDO="${HIVEMIND_CTR_SUDO:-0}"
PROBE_TOKEN="${HIVEMIND_GPU_PROBE_TOKEN:-gpu-proof-$$}"
[[ "$CTR_SUDO" == 0 || "$CTR_SUDO" == 1 ]] || { echo "FAIL: HIVEMIND_CTR_SUDO must be 0 or 1" >&2; exit 2; }
[[ "$PROBE_TOKEN" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { echo "FAIL: invalid GPU probe token" >&2; exit 2; }
command -v "$CTR_BIN" >/dev/null 2>&1 || { echo "FAIL: ctr unavailable" >&2; exit 1; }

CTR=("$CTR_BIN" -n hivemind)
if [[ "$CTR_SUDO" == 1 ]]; then
    command -v sudo >/dev/null 2>&1 || { echo "FAIL: sudo unavailable" >&2; exit 1; }
    CTR=(sudo "$CTR_BIN" -n hivemind)
fi

mapfile -t task_ids < <(timeout --foreground --kill-after=2s 15s "${CTR[@]}" tasks list -q)
selected_task=""
selected_device=""
for task_id in "${task_ids[@]}"; do
    [[ "$task_id" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || { echo "FAIL: unsafe task identity in inventory" >&2; exit 1; }
    info="$(timeout --foreground --kill-after=2s 15s "${CTR[@]}" containers info "$task_id")"
    device="$(grep -Eo 'nvidia\.com/gpu=[A-Za-z0-9_.:-]+' <<<"$info" | head -n1 || true)"
    [[ -n "$device" ]] || continue
    [[ -z "$selected_task" ]] || { echo "FAIL: multiple CDI-selected GPU tasks found" >&2; exit 1; }
    selected_task="$task_id"
    selected_device="$device"
done
[[ -n "$selected_task" ]] || { echo "FAIL: no CDI-selected GPU task found" >&2; exit 1; }

exec_id="$PROBE_TOKEN"
smi="$(timeout --foreground --kill-after=2s 30s "${CTR[@]}" tasks exec --exec-id "$exec_id" "$selected_task" nvidia-smi)" || {
    echo "FAIL: in-container nvidia-smi failed" >&2
    exit 1
}
smi_line="$(grep -Em1 'NVIDIA-SMI|Driver Version' <<<"$smi" || true)"
[[ -n "$smi_line" ]] || { echo "FAIL: nvidia-smi returned no recognizable evidence" >&2; exit 1; }

printf 'task_id=%s\n' "$selected_task"
printf 'cdi_device=%s\n' "$selected_device"
printf 'nvidia_smi=%s\n' "$smi_line"
