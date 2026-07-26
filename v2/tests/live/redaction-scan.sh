#!/usr/bin/env bash
set -euo pipefail
DIR="${1:?usage: redaction-scan.sh EVIDENCE_DIR}"
TOKEN="${HIVEMIND_REDACTION_TOKEN:-}"
[[ -d "$DIR" && ! -L "$DIR" ]] || { echo "FAIL: evidence directory must be a real directory" >&2; exit 1; }

mapfile -d '' -t entries < <(find "$DIR" -mindepth 1 -print0 | sort -z)
[[ "${#entries[@]}" -le 256 ]] || { echo "FAIL: more than 256 evidence entries" >&2; exit 1; }
files=()
for entry in "${entries[@]}"; do
    [[ ! -L "$entry" ]] || { echo "FAIL: evidence entry is a symlink: $entry" >&2; exit 1; }
    if [[ -d "$entry" ]]; then
        continue
    fi
    [[ -f "$entry" ]] || { echo "FAIL: evidence entry is not a regular file: $entry" >&2; exit 1; }
    size="$(stat -c %s -- "$entry")"
    [[ "$size" =~ ^[0-9]+$ && "$size" -le 1048576 ]] || { echo "FAIL: evidence file exceeds 1048576 bytes: $entry" >&2; exit 1; }
    files+=("$entry")
done

if [[ -n "$TOKEN" ]]; then
    [[ "$TOKEN" =~ ^[a-z][a-z0-9]{11,31}$ ]] || { echo "FAIL: invalid ownership token for redaction scan" >&2; exit 2; }
    for file in "${files[@]}"; do
        [[ "$file" != *"$TOKEN"* ]] || { echo "FAIL: ownership token appears in evidence path" >&2; exit 1; }
    done
    if [[ "${#files[@]}" -gt 0 ]] && grep -IlF -- "$TOKEN" "${files[@]}" | grep -q .; then
        echo "FAIL: redaction scan found raw ownership token" >&2
        exit 1
    fi
fi
patterns='(arn:(aws|aws-us-gov|aws-cn):[^:]*:[^:]*:[0-9]{12}:)|([0-9]{12}\.dkr\.ecr\.)|([0-9]{1,3}\.){3}[0-9]{1,3}|(AKIA[0-9A-Z]{16})|(ASIA[0-9A-Z]{16})|(-----BEGIN [A-Z ]*PRIVATE KEY-----)|(Authorization:[[:space:]]*Bearer)|(image_pull_password["= :]+[^<[:space:]])|(aws_secret_access_key)'
if [[ "${#files[@]}" -gt 0 ]] && grep -Ein "$patterns" "${files[@]}"; then
    echo "FAIL: redaction scan found credential/account material" >&2
    exit 1
fi
echo "PASS: bounded evidence redaction scan"
