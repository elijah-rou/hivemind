#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$SCRIPT_DIR/live/evidence-manifest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sha="$(printf fixture | sha256sum | awk '{print $1}')"
printf 'preflight\t0\nworkload\t7\ncleanup\t0\n' >"$TMP/status.tsv"
printf 'queue=0 in_flight=0\n' >"$TMP/metrics.txt"
printf 'journal fixture\n' >"$TMP/journals.txt"
printf 'instances=0 volumes=0 buckets=0 repositories=0 locks=0 units=0 processes=0\n' >"$TMP/cleanup.txt"

"$BUILDER" --commit "$sha" --binary-sha "$sha" --image-sha "$sha" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$TMP/metrics.txt" --journals "$TMP/journals.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/manifest.json"
python3 - "$TMP/manifest.json" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))
required={"commit_sha","binary_sha256","image_sha256","terraform_plan_sha256","command_exit_statuses","metrics","journals","cleanup_inventory","redaction_scan_exit_status"}
assert required <= m.keys()
assert m["command_exit_statuses"] == {"preflight": 0, "workload": 7, "cleanup": 0}
assert m["cleanup_inventory"]["sha256"]
PY

too_large="$TMP/large"
dd if=/dev/zero of="$too_large" bs=1048577 count=1 status=none
if "$BUILDER" --commit "$sha" --binary-sha "$sha" --image-sha "$sha" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$too_large" --journals "$TMP/journals.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/bad.json" 2>/dev/null; then
  echo "FAIL: oversized artifact accepted" >&2; exit 1
fi
if "$BUILDER" --commit dirty --binary-sha "$sha" --image-sha "$sha" --plan-sha "$sha" \
  --command-statuses "$TMP/status.tsv" --metrics "$TMP/metrics.txt" --journals "$TMP/journals.txt" \
  --cleanup "$TMP/cleanup.txt" --redaction-status 0 --output "$TMP/bad.json" 2>/dev/null; then
  echo "FAIL: malformed digest accepted" >&2; exit 1
fi
echo "PASS: bounded evidence manifest fields and validation"
