#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT_DIR/tests/live/run.sh"
[[ "${HIVEMIND_ALLOW_LIVE:-0}" == 1 && "${HIVEMIND_GUARDRAILS_ACTIVE:-0}" == 1 && -r /proc/self/fd/9 ]] || {
    echo "FAIL: private live helper requires guarded parent" >&2
    exit 1
}
python3 - "$PPID" "$RUNNER" <<'PY' || { echo "FAIL: private live helper requires guarded parent" >&2; exit 1; }
import os, sys
pid = int(sys.argv[1])
expected = os.path.realpath(sys.argv[2])
capability = os.stat("/proc/self/fd/9")
for _ in range(6):
    try:
        script = os.path.realpath(f"/proc/{pid}/fd/255")
        inherited = os.stat(f"/proc/{pid}/fd/9")
        argv = [os.fsdecode(value) for value in open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0") if value]
        exact_script_arg = any("/" in value and os.path.realpath(value) == expected for value in argv)
        if script == expected and exact_script_arg and "-c" not in argv and (inherited.st_dev, inherited.st_ino) == (capability.st_dev, capability.st_ino):
            raise SystemExit(0)
        with open(f"/proc/{pid}/stat", encoding="ascii") as source:
            pid = int(source.read().split()[3])
    except (FileNotFoundError, PermissionError, ValueError):
        break
raise SystemExit(1)
PY
TF_ROOT="$ROOT_DIR/infra/poc"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:?}"
WORKSPACE="${TF_WORKSPACE:?}"
BUCKET="${HIVEMIND_LIVE_BUCKET:?}"
REGION="${AWS_REGION:?}"
KEEP_INFRA="${KEEP_INFRA:-0}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:?}"
RAW_DIR="${HIVEMIND_LIVE_RAW_DIR:?}"
[[ "$WORKSPACE" == *"$RUN_TOKEN"* && "$BUCKET" == *"$RUN_TOKEN"* ]]

if [[ "$KEEP_INFRA" == 1 ]]; then
    echo "KEEP_INFRA=1: no destructive cleanup performed; acceptance will remain incomplete"
    exit 0
fi

terraform -chdir="$TF_ROOT" workspace select "$WORKSPACE" >/dev/null
set +e
timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_DESTROY_TIMEOUT_SECONDS:-1800}s" \
    terraform -chdir="$TF_ROOT" destroy -auto-approve \
    -var "run_token=$RUN_TOKEN" -var "ecr_repository_name=${HIVEMIND_LIVE_ECR:?}" -var "region=$REGION" 2>&1 | \
    python3 -c 'import sys; p=open(sys.argv[1], "xb"); n=0
for chunk in iter(lambda: sys.stdin.buffer.read(65536), b""):
 sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
 if n < 1048576: data=chunk[:1048576-n]; p.write(data); n += len(data)
p.close()' "$RAW_DIR/terraform-destroy.log"
destroy_status=${PIPESTATUS[0]}
set -e
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$RAW_DIR/terraform-destroy.log" "$EVIDENCE_DIR/terraform-destroy.log"
[[ "$destroy_status" == 0 ]] || exit "$destroy_status"

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT
if timeout --foreground --kill-after=2s 30s aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$BUCKET" --key .hivemind-owner "$marker" >/dev/null
    [[ "$(cat "$marker")" == "$RUN_TOKEN" ]] || { echo "FAIL: refusing cleanup of bucket without exact ownership marker" >&2; exit 1; }
    timeout --foreground --kill-after=10s 300s aws s3 rm "s3://$BUCKET" --recursive --region "$REGION"
    timeout --foreground --kill-after=2s 30s aws s3 rb "s3://$BUCKET" --region "$REGION"
fi

env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace select default >/dev/null
env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace delete "$WORKSPACE" >/dev/null
