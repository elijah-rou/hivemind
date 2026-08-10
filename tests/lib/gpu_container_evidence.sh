#!/usr/bin/env bash
set -euo pipefail

CTR_BIN="${HIVEMIND_CTR:-ctr}"
CTR_SUDO="${HIVEMIND_CTR_SUDO:-0}"
PROBE_TOKEN="${HIVEMIND_GPU_PROBE_TOKEN:-gpu-proof-$$}"
EXPECTED_TASK="${HIVEMIND_EXPECTED_GPU_TASK:?HIVEMIND_EXPECTED_GPU_TASK is required}"
[[ "$CTR_SUDO" == 0 || "$CTR_SUDO" == 1 ]] || { echo "FAIL: HIVEMIND_CTR_SUDO must be 0 or 1" >&2; exit 2; }
[[ "$PROBE_TOKEN" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { echo "FAIL: invalid GPU probe token" >&2; exit 2; }
[[ "$EXPECTED_TASK" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || { echo "FAIL: invalid expected GPU task identity" >&2; exit 2; }
command -v "$CTR_BIN" >/dev/null 2>&1 || { echo "FAIL: ctr unavailable" >&2; exit 1; }

CTR=("$CTR_BIN" -n hivemind)
if [[ "$CTR_SUDO" == 1 ]]; then
    command -v sudo >/dev/null 2>&1 || { echo "FAIL: sudo unavailable" >&2; exit 1; }
    CTR=(sudo "$CTR_BIN" -n hivemind)
fi

mapfile -t task_ids < <(timeout --foreground --kill-after=2s 15s "${CTR[@]}" tasks list -q)
[[ " ${task_ids[*]} " == *" $EXPECTED_TASK "* ]] || { echo "FAIL: expected GPU task is absent" >&2; exit 1; }
selected_task="$EXPECTED_TASK"
info="$(timeout --foreground --kill-after=2s 15s "${CTR[@]}" containers info "$selected_task")"
selected_device="$(grep -Eo 'nvidia\.com/gpu=[A-Za-z0-9_.:-]+' <<<"$info" | head -n1 || true)"
[[ -n "$selected_device" ]] || { echo "FAIL: expected GPU task has no CDI-selected device" >&2; exit 1; }

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
