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
exit "${EXECUTOR_RC:-0}"
STUB
cat >"$TMP/cleanup" <<'STUB'
#!/usr/bin/env bash
printf 'cleanup\n' >>"${FIXTURE_LOG:?}"
exit "${CLEANUP_RC:-0}"
STUB
cat >"$TMP/inventory" <<'STUB'
#!/usr/bin/env bash
instances=0
if [[ "${OWNED_INSTANCES:-0}" == 1 ]] && grep -q '^cleanup$' "${FIXTURE_LOG:?}"; then instances=1; fi
printf 'instances=%s\nvolumes=0\nnetwork_resources=0\nbuckets=0\nrepositories=0\nlocks=0\nunits=0\nprocesses=0\n' "$instances"
STUB
chmod +x "$TMP/bin/aws" "$TMP/executor" "$TMP/cleanup" "$TMP/inventory"
: >"$TMP/review"
export PATH="$TMP/bin:/usr/bin:/bin" FIXTURE_LOG="$TMP/calls.log"
FIXTURE_ACCOUNT="$(printf '1%.0s' {1..12})"
export FIXTURE_ACCOUNT

base_env=(
  HIVEMIND_ALLOW_LIVE=1 HIVEMIND_LIVE_FIXTURE_MODE=1 HIVEMIND_AWS_ACCOUNT_ALLOWLIST="$FIXTURE_ACCOUNT"
  AWS_REGION=us-test-1 HIVEMIND_AWS_REGION_ALLOWLIST=us-test-1
  HIVEMIND_RUN_TOKEN=e1fixtureabc123 TF_WORKSPACE=hm-e1fixtureabc123
  HIVEMIND_LIVE_BUCKET=hm-e1fixtureabc123 HIVEMIND_LIVE_ECR=hm-e1fixtureabc123
  HIVEMIND_COST_APPROVED=1 HIVEMIND_CLEANUP_APPROVED=1 HIVEMIND_QUOTA_CONFIRMED=1 KEEP_INFRA=0
  HIVEMIND_APPROVED_PLAN_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  HIVEMIND_PLAN_REVIEW_RECORD="$TMP/review" HIVEMIND_LIVE_EXECUTOR="$TMP/executor"
  HIVEMIND_LIVE_CLEANUP="$TMP/cleanup" HIVEMIND_LIVE_INVENTORY="$TMP/inventory"
  HIVEMIND_LIVE_EVIDENCE_DIR="$TMP/evidence"
)

: >"$FIXTURE_LOG"
for private_helper in "$SCRIPT_DIR/live/execute-reviewed-plan.sh" "$SCRIPT_DIR/live/cleanup-owned.sh"; do
  if env -i PATH=/usr/bin:/bin "$private_helper" >"$TMP/direct-helper.out" 2>&1; then
    echo "FAIL: direct private live helper execution accepted: $private_helper" >&2; exit 1
  fi
  grep -q 'private live helper requires guarded parent' "$TMP/direct-helper.out"
done
if "$SCRIPT_DIR/../scripts/poc-runbook.sh" >"$TMP/direct-runbook.out" 2>&1; then
  echo "FAIL: direct unguarded runbook execution accepted" >&2; exit 1
fi
grep -q 'refusing live runbook outside' "$TMP/direct-runbook.out"
[[ ! -s "$FIXTURE_LOG" ]] || { echo "FAIL: direct runbook called AWS before guard" >&2; exit 1; }

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
