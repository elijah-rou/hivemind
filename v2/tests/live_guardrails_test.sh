#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/live/run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws:%s\n' "$*" >>"${FIXTURE_LOG:?}"
[[ "$*" == 'sts get-caller-identity --query Account --output text --region us-test-1' ]] || exit 8
printf '%s\n' "${FIXTURE_ACCOUNT:?}"
STUB
cat >"$TMP/executor" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'executor\n' >>"${FIXTURE_LOG:?}"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' "$sha" >"${HIVEMIND_LIVE_EVIDENCE_DIR:?}/binary.sha256"
printf '%s\n' "$sha" >"$HIVEMIND_LIVE_EVIDENCE_DIR/image.sha256"
printf '%s  fixture-binary\n' "$sha" >"$HIVEMIND_LIVE_EVIDENCE_DIR/binary-list.sha256"
printf 'sha256:%s\n' "$sha" >"$HIVEMIND_LIVE_EVIDENCE_DIR/image-digests.txt"
printf 'queue=0 in_flight=0\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/metrics.txt"
printf 'journal=fixture\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/journals.txt"
printf 'reviewed fixture\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/reviewed-plan-record.txt"
printf 'apply fixture\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/terraform-apply.log"
printf '{}\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/terraform-outputs.json"
mkdir "$HIVEMIND_LIVE_EVIDENCE_DIR/runbook"
printf '{"request_id":1,"status":0}\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/api-identities.jsonl"
printf 'fault=leader-loss queue=0\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/fault-period-metrics.txt"
printf 'instances=1\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/intermediate-inventory.txt"
printf 'tasks=1 containers=1 cdi=verified cgroup=verified gpu=verified\n' >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/runtime-proof.txt"
printf 'cold_pull=verified digest=sha256:%s\n' "$sha" >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/ecr-proof.txt"
printf 'mode=0600 checksum=%s recovery=verified\n' "$sha" >"$HIVEMIND_LIVE_EVIDENCE_DIR/runbook/journal-proof.txt"
"${HIVEMIND_LIVE_INVENTORY_HOOK:?}" post >"$HIVEMIND_LIVE_EVIDENCE_DIR/post-apply-inventory.txt"
exit "${EXECUTOR_RC:-0}"
STUB
cat >"$TMP/cleanup" <<'STUB'
#!/usr/bin/env bash
printf 'cleanup\n' >>"${FIXTURE_LOG:?}"
printf 'destroy fixture\n' >"${HIVEMIND_LIVE_EVIDENCE_DIR:?}/terraform-destroy.log"
exit "${CLEANUP_RC:-0}"
STUB
cat >"$TMP/inventory" <<'STUB'
#!/usr/bin/env bash
instances=0
if [[ "${OWNED_INSTANCES:-0}" == 1 ]] && grep -q '^cleanup$' "${FIXTURE_LOG:?}"; then instances=1; fi
printf 'instances=%s\nvolumes=0\nnetwork_resources=0\nbuckets=0\nrepositories=0\nlocks=0\nunits=0\nprocesses=0\ndeployments=0\ncontainerd_tasks=0\ncontainerd_containers=0\njuicefs_mounts=0\nssm_commands=0\ntemporary_secret_files=0\n' "$instances"
STUB
chmod +x "$TMP/bin/aws" "$TMP/executor" "$TMP/cleanup" "$TMP/inventory"
: >"$TMP/review"
expiry="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
cat >"$TMP/approval.json" <<EOF
{"account":"111111111111","account_alias":"fixture","region":"us-test-1","run_id":"fixture-run-1","ownership_token_sha256":"$(printf e1fixtureabc123 | sha256sum | awk '{print $1}')","workspace":"hm-e1fixtureabc123","terraform_plan_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","maximum_duration_seconds":14400,"maximum_estimated_cost_usd":10,"expires_at_utc":"$expiry","cost_approved":true,"cleanup_approved":true,"quota_confirmed":true}
EOF
export PATH="$TMP/bin:/usr/bin:/bin" FIXTURE_LOG="$TMP/calls.log"
FIXTURE_ACCOUNT="$(printf '1%.0s' {1..12})"
export FIXTURE_ACCOUNT

validator="$SCRIPT_DIR/live/validate-reviewed-plan.py"
cat >"$TMP/valid-plan.json" <<'JSON'
{"resource_changes":[{"address":"aws_instance.replica[0]","mode":"managed","type":"aws_instance","change":{"actions":["create"],"before":null,"after":{"tags":{"HivemindRunToken":"fixture-token"}}}}]}
JSON
python3 "$validator" "$TMP/valid-plan.json" fixture-token fixture-ecr
cat >"$TMP/unknown-plan.json" <<'JSON'
{"resource_changes":[{"address":"aws_s3_bucket.unreviewed","mode":"managed","type":"aws_s3_bucket","change":{"actions":["create"],"before":null,"after":{"tags":{"HivemindRunToken":"fixture-token"}}}}]}
JSON
if python3 "$validator" "$TMP/unknown-plan.json" fixture-token fixture-ecr >"$TMP/unknown-plan.out" 2>&1; then
  echo "FAIL: unknown managed Terraform resource type accepted" >&2; exit 1
fi
grep -q 'unsupported managed resource type' "$TMP/unknown-plan.out"
cat >"$TMP/action-plan.json" <<'JSON'
{"resource_changes":[{"address":"aws_instance.replica[0]","mode":"managed","type":"aws_instance","change":{"actions":["forget"],"before":{"tags":{"HivemindRunToken":"fixture-token"}},"after":null}}]}
JSON
if python3 "$validator" "$TMP/action-plan.json" fixture-token fixture-ecr >"$TMP/action-plan.out" 2>&1; then
  echo "FAIL: unknown managed Terraform action accepted" >&2; exit 1
fi
grep -q 'unsupported managed action set' "$TMP/action-plan.out"

base_env=(
  HIVEMIND_ALLOW_LIVE=1 HIVEMIND_LIVE_FIXTURE_MODE=1 HIVEMIND_AWS_ACCOUNT_ALLOWLIST="$FIXTURE_ACCOUNT"
  AWS_REGION=us-test-1 HIVEMIND_AWS_REGION_ALLOWLIST=us-test-1 HIVEMIND_AWS_ACCOUNT_ALIAS=fixture
  HIVEMIND_RUN_ID=fixture-run-1 HIVEMIND_RUN_TOKEN=e1fixtureabc123 TF_WORKSPACE=hm-e1fixtureabc123
  HIVEMIND_LIVE_BUCKET=hm-e1fixtureabc123 HIVEMIND_LIVE_ECR=hm-e1fixtureabc123
  HIVEMIND_COST_APPROVED=1 HIVEMIND_CLEANUP_APPROVED=1 HIVEMIND_QUOTA_CONFIRMED=1 KEEP_INFRA=0
  HIVEMIND_APPROVED_PLAN_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  HIVEMIND_PLAN_REVIEW_RECORD="$TMP/review" HIVEMIND_LIVE_APPROVAL_RECORD="$TMP/approval.json"
  HIVEMIND_LIVE_EXECUTOR="$TMP/executor"
  HIVEMIND_LIVE_CLEANUP="$TMP/cleanup" HIVEMIND_LIVE_INVENTORY="$TMP/inventory"
  HIVEMIND_LIVE_EVIDENCE_DIR="$TMP/evidence"
)

: >"$FIXTURE_LOG"
for private_helper in "$SCRIPT_DIR/live/execute-reviewed-plan.sh" "$SCRIPT_DIR/live/cleanup-owned.sh"; do
  if env -i PATH=/usr/bin:/bin "$private_helper" >"$TMP/direct-helper.out" 2>&1; then
    echo "FAIL: direct private live helper execution accepted: $private_helper" >&2; exit 1
  fi
  grep -q 'private live helper requires guarded parent' "$TMP/direct-helper.out"
  HELPER="$private_helper" HIVEMIND_ALLOW_LIVE=1 HIVEMIND_GUARDRAILS_ACTIVE=1 \
      bash -c 'exec 9<"$1"; bash -c '\''"$HELPER"; :'\''' "$RUNNER" "$TMP/review" \
      >"$TMP/forged-tree.out" 2>&1
  grep -q 'private live helper requires guarded parent' "$TMP/forged-tree.out" || {
    echo "FAIL: forged argv process tree passed helper guard: $private_helper" >&2; exit 1
  }
done
if "$SCRIPT_DIR/../scripts/poc-runbook.sh" >"$TMP/direct-runbook.out" 2>&1; then
  echo "FAIL: direct unguarded runbook execution accepted" >&2; exit 1
fi
grep -q 'refusing live runbook outside' "$TMP/direct-runbook.out"
[[ ! -s "$FIXTURE_LOG" ]] || { echo "FAIL: direct runbook called AWS before guard" >&2; exit 1; }
if env HIVEMIND_ALLOW_LIVE=1 HIVEMIND_GUARDRAILS_ACTIVE=1 \
    "$SCRIPT_DIR/../scripts/poc-runbook.sh" >"$TMP/forged-runbook.out" 2>&1; then
  echo "FAIL: forged live guard environment accepted" >&2; exit 1
fi
grep -q 'refusing live runbook outside' "$TMP/forged-runbook.out"
[[ ! -s "$FIXTURE_LOG" ]] || { echo "FAIL: forged runbook called AWS before parent validation" >&2; exit 1; }

if env -u HIVEMIND_ALLOW_LIVE "$RUNNER" >"$TMP/deny.out" 2>&1; then
  echo "FAIL: missing live authorization accepted" >&2; exit 1
fi
[[ ! -s "$FIXTURE_LOG" ]] || { echo "FAIL: command ran before live authorization" >&2; exit 1; }

wrong_account="$(printf '9%.0s' {1..12})"
if env "${base_env[@]}" HIVEMIND_LIVE_FIXTURE_MODE=0 "$RUNNER" >"$TMP/hooks.out" 2>&1; then
  echo "FAIL: production mode accepted custom live hooks" >&2; exit 1
fi
grep -q 'production mode requires canonical live hooks' "$TMP/hooks.out"
[[ ! -s "$FIXTURE_LOG" ]] || { echo "FAIL: production hook rejection called AWS" >&2; exit 1; }

if env "${base_env[@]}" HIVEMIND_AWS_ACCOUNT_ALLOWLIST="$wrong_account" "$RUNNER" >"$TMP/account.out" 2>&1; then
  echo "FAIL: wrong account accepted" >&2; exit 1
fi
if grep -q "$FIXTURE_ACCOUNT" "$TMP/account.out"; then
  echo "FAIL: numeric account leaked to guard output" >&2; exit 1
fi

: >"$FIXTURE_LOG"; rm -rf "$TMP/evidence"
env "${base_env[@]}" HIVEMIND_LIVE_PREFLIGHT_ONLY=1 "$RUNNER" >"$TMP/preflight.out"
grep -q '^aws:' "$FIXTURE_LOG"
if grep -q '^executor' "$FIXTURE_LOG"; then
  echo "FAIL: preflight-only invoked executor" >&2; exit 1
fi
grep -q 'KEEP_INFRA=0' "$TMP/preflight.out"

: >"$FIXTURE_LOG"; rm -rf "$TMP/evidence"
env "${base_env[@]}" "$RUNNER" >"$TMP/success.out"
[[ "$(cat "$FIXTURE_LOG")" == $'aws:sts get-caller-identity --query Account --output text --region us-test-1\nexecutor\ncleanup' ]]
grep -q '^instances=0$' "$TMP/evidence/post-apply-inventory.txt"
grep -q '^instances=0$' "$TMP/evidence/pre-cleanup-inventory.txt"
grep -q '^instances=0$' "$TMP/evidence/post-cleanup-inventory.txt"
if grep -Rq 'e1fixtureabc123' "$TMP/success.out" "$TMP/evidence"; then
  echo "FAIL: raw ownership token entered publishable output" >&2; exit 1
fi
grep -q '^redaction_scan[[:space:]]0$' "$TMP/evidence/command-statuses.tsv"
python3 - "$TMP/evidence/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["redaction_scan_exit_status"] == 0
assert manifest["command_exit_statuses"]["redaction_scan"] == 0
PY

: >"$FIXTURE_LOG"; rm -rf "$TMP/evidence"
if env "${base_env[@]}" OWNED_INSTANCES=1 "$RUNNER" >"$TMP/residue.out" 2>&1; then
  echo "FAIL: residual owned instance accepted" >&2; exit 1
fi
grep -q '^cleanup$' "$FIXTURE_LOG"
grep -q 'post-cleanup inventory is not zero' "$TMP/residue.out"

echo "PASS: live authorization, account, uniqueness, trap, KEEP_INFRA, and post-cleanup inventory guardrails"
