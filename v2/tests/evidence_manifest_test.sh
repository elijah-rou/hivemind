#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$SCRIPT_DIR/live/evidence-manifest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sha="$(printf fixture | sha256sum | awk '{print $1}')"
printf 'preflight\t0\nworkload\t0\ncleanup\t0\nredaction_scan\t0\n' >"$TMP/status.tsv"
printf 'queue=0 in_flight=0\n' >"$TMP/metrics.txt"
printf 'journal fixture\n' >"$TMP/journals.txt"
printf 'instances=0 volumes=0 buckets=0 repositories=0 locks=0 units=0 processes=0\n' >"$TMP/cleanup.txt"
printf 'commit=%s\ndirty=\n' "$sha" >"$TMP/source-state.txt"
printf 'instances=0\n' >"$TMP/pre.txt"
printf '%s  fixture-binary\n' "$sha" >"$TMP/binary-list.sha256"
printf 'sha256:%s\n' "$sha" >"$TMP/image-digests.txt"
export HIVEMIND_EVIDENCE_STARTED_AT=2026-07-24T00:00:00Z HIVEMIND_EVIDENCE_ENDED_AT=2026-07-24T00:01:00Z
export HIVEMIND_EVIDENCE_COMMAND='./tests/live/run.sh' HIVEMIND_EVIDENCE_REGION=us-test-1
export HIVEMIND_EVIDENCE_OWNERSHIP_HASH="$sha" HIVEMIND_EVIDENCE_WORKSPACE_HASH="$sha"
export HIVEMIND_EVIDENCE_KEEP_INFRA=0 HIVEMIND_EVIDENCE_FINAL_STATUS=0

"$BUILDER" --commit "$sha" --binary-sha "$sha" --image-sha "$sha" \
  --binary-list "$TMP/binary-list.sha256" --image-digests "$TMP/image-digests.txt" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$TMP/metrics.txt" --journals "$TMP/journals.txt" \
  --source-state "$TMP/source-state.txt" --pre-inventory "$TMP/pre.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/manifest.json"
python3 - "$TMP/manifest.json" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))
required={"commit_sha","binary_sha256","image_sha256","exact_binary_digests","exact_image_digests","terraform_plan_sha256","command_exit_statuses","metrics","journals","source_state","pre_ownership_inventory","cleanup_inventory","started_at_utc","ended_at_utc","exact_command","region","ownership_token_sha256","workspace_sha256","keep_infra","capability_requirements","final_exit_status","redaction_scan_command","redaction_scan_exit_status"}
assert required <= m.keys()
assert m["command_exit_statuses"] == {"preflight": 0, "workload": 0, "cleanup": 0, "redaction_scan": 0}
assert m["cleanup_inventory"]["sha256"]
PY

too_large="$TMP/large"
dd if=/dev/zero of="$too_large" bs=1048577 count=1 status=none
if "$BUILDER" --commit "$sha" --binary-sha "$sha" --image-sha "$sha" \
  --binary-list "$TMP/binary-list.sha256" --image-digests "$TMP/image-digests.txt" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$too_large" --journals "$TMP/journals.txt" \
  --source-state "$TMP/source-state.txt" --pre-inventory "$TMP/pre.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/bad.json" 2>/dev/null; then
  echo "FAIL: oversized artifact accepted" >&2; exit 1
fi
if "$BUILDER" --commit dirty --binary-sha "$sha" --image-sha "$sha" \
  --binary-list "$TMP/binary-list.sha256" --image-digests "$TMP/image-digests.txt" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$TMP/metrics.txt" --journals "$TMP/journals.txt" \
  --source-state "$TMP/source-state.txt" --pre-inventory "$TMP/pre.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/bad.json" 2>/dev/null; then
  echo "FAIL: malformed digest accepted" >&2; exit 1
fi

mkdir "$TMP/scan"
printf 'secret\n' >"$TMP/scan/oversized"
truncate -s 1048577 "$TMP/scan/oversized"
if "$SCRIPT_DIR/live/redaction-scan.sh" "$TMP/scan" >"$TMP/scan-large.out" 2>&1; then
  echo "FAIL: redaction scan ignored oversized evidence" >&2; exit 1
fi
grep -q 'evidence file exceeds' "$TMP/scan-large.out"
rm "$TMP/scan/oversized"
printf 'ownership=e1fixtureabc123\n' >"$TMP/scan/token.txt"
if HIVEMIND_REDACTION_TOKEN=e1fixtureabc123 "$SCRIPT_DIR/live/redaction-scan.sh" "$TMP/scan" >"$TMP/scan-token.out" 2>&1; then
  echo "FAIL: redaction scan accepted raw ownership token" >&2; exit 1
fi
grep -q 'ownership token' "$TMP/scan-token.out"
echo "PASS: bounded evidence manifest fields and validation"
