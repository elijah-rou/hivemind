#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="$SCRIPT_DIR/lib/gpu_container_evidence.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ctr" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "-n hivemind tasks list -q")
    echo unrelated-task
    [[ "${FIXTURE_TASK:-present}" == present ]] && echo task-owned
    ;;
  "-n hivemind containers info unrelated-task") echo 'devices: nvidia.com/gpu=7' ;;
  "-n hivemind containers info task-owned")
    [[ "${FIXTURE_CDI:-present}" == present ]] && echo 'devices: nvidia.com/gpu=0' || echo 'runtime: nvidia'
    ;;
  "-n hivemind tasks exec --exec-id "*" task-owned nvidia-smi")
    [[ "${FIXTURE_SMI:-success}" == success ]] && echo 'NVIDIA-SMI fixture Device 0' || exit 7
    ;;
  *) echo "unexpected ctr args: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$TMP/bin/ctr"

run_case() {
    local name="$1" expected="$2"; shift 2
    set +e
    env HIVEMIND_CTR="$TMP/bin/ctr" "$@" "$PROBE" >"$TMP/$name.out" 2>&1
    rc=$?
    set -e
    if [[ "$expected" == pass && "$rc" == 0 ]] || [[ "$expected" == fail && "$rc" != 0 ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name rc=$rc" >&2; cat "$TMP/$name.out" >&2; return 1
    fi
}
run_case no-task fail HIVEMIND_EXPECTED_GPU_TASK=task-owned FIXTURE_TASK=absent
run_case no-cdi fail HIVEMIND_EXPECTED_GPU_TASK=task-owned FIXTURE_CDI=absent
run_case smi-failure fail HIVEMIND_EXPECTED_GPU_TASK=task-owned FIXTURE_SMI=failure
run_case complete-evidence pass HIVEMIND_EXPECTED_GPU_TASK=task-owned FIXTURE_TASK=present FIXTURE_CDI=present FIXTURE_SMI=success
run_case unrelated-task-rejected fail HIVEMIND_EXPECTED_GPU_TASK=missing-task FIXTURE_TASK=present FIXTURE_CDI=present FIXTURE_SMI=success

grep -q '^task_id=task-owned$' "$TMP/complete-evidence.out"
grep -q '^cdi_device=nvidia.com/gpu=0$' "$TMP/complete-evidence.out"
grep -q '^nvidia_smi=NVIDIA-SMI fixture Device 0$' "$TMP/complete-evidence.out"
echo "PASS: gpu evidence requires one CDI-selected task and successful in-container nvidia-smi"
