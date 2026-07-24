#!/usr/bin/env bash
set -euo pipefail
DIR="${1:?usage: redaction-scan.sh EVIDENCE_DIR}"
[[ -d "$DIR" && ! -L "$DIR" ]]
mapfile -d '' -t files < <(find "$DIR" -type f -size -1048577c -print0 | sort -z)
[[ "${#files[@]}" -le 256 ]] || { echo "FAIL: more than 256 evidence files" >&2; exit 1; }
patterns='(arn:(aws|aws-us-gov|aws-cn):[^:]*:[^:]*:[0-9]{12}:)|([0-9]{12}\.dkr\.ecr\.)|([0-9]{1,3}\.){3}[0-9]{1,3}|(AKIA[0-9A-Z]{16})|(ASIA[0-9A-Z]{16})|(-----BEGIN [A-Z ]*PRIVATE KEY-----)|(Authorization:[[:space:]]*Bearer)|(image_pull_password["= :]+[^<[:space:]])|(aws_secret_access_key)'
if [[ "${#files[@]}" -gt 0 ]] && grep -Ein "$patterns" "${files[@]}"; then
    echo "FAIL: redaction scan found credential/account material" >&2
    exit 1
fi
echo "PASS: bounded evidence redaction scan"
