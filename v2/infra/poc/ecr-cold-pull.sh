#!/usr/bin/env bash
set -euo pipefail

# Removes and repulls one exact run-owned ECR image on one explicitly named worker.
# This is live/opt-in. It never scans or removes by prefix or wildcard.
IMAGE="${1:?usage: ecr-cold-pull.sh IMAGE RUN_TOKEN HOST USER EVIDENCE_DIR}"
RUN_TOKEN="${2:?}"
HOST="${3:?}"
REMOTE_USER="${4:?}"
EVIDENCE_DIR="${5:?}"
REQUIRE_ECR_COLD_PULL="${REQUIRE_ECR_COLD_PULL:-0}"
REGION="${AWS_REGION:?AWS_REGION is required}"

[[ "$REQUIRE_ECR_COLD_PULL" == 0 || "$REQUIRE_ECR_COLD_PULL" == 1 ]] || { echo "FAIL: REQUIRE_ECR_COLD_PULL must be 0 or 1" >&2; exit 2; }
if [[ "$REQUIRE_ECR_COLD_PULL" == 0 ]]; then
    echo "SKIP: cold-cache ECR mode not required; private-auth acceptance unavailable"
    exit 0
fi
[[ "$RUN_TOKEN" =~ ^[a-z][a-z0-9]{11,31}$ ]] || { echo "FAIL: invalid run token" >&2; exit 2; }
[[ "$HOST" =~ ^[A-Za-z0-9.-]{1,253}$ && "$REMOTE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "FAIL: invalid SSH target" >&2; exit 2; }
[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] || { echo "FAIL: invalid AWS region" >&2; exit 2; }
[[ "$IMAGE" =~ ^[0-9]{12}\.dkr\.ecr\.${REGION}\.amazonaws\.com/[a-z0-9][a-z0-9._/-]{1,127}:[A-Za-z0-9_.-]{1,64}$ ]] || {
    echo "FAIL: image is not an exact ECR image in the selected region" >&2; exit 1;
}
repository_and_tag="${IMAGE#*/}"
[[ "$repository_and_tag" == *"$RUN_TOKEN"* ]] || { echo "FAIL: ECR image is not owned by this run token" >&2; exit 1; }
[[ ! -e "$EVIDENCE_DIR" ]] || { echo "FAIL: evidence directory already exists" >&2; exit 1; }
umask 077
mkdir -p "$EVIDENCE_DIR"

EXPECTED_DIGEST="$(timeout --foreground --kill-after=2s 30s aws ecr describe-images \
    --region "$REGION" --repository-name "${repository_and_tag%%:*}" \
    --image-ids imageTag="${IMAGE##*:}" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: ECR credentials/digest lookup did not succeed" >&2; exit 1; }

# Inputs are strictly character-validated above. Credentials are resolved on the
# worker and never cross stdout or the local process argument list.
RAW_EVIDENCE="$EVIDENCE_DIR/.cold-pull.raw"
timeout --foreground --kill-after=5s "${ECR_COLD_PULL_TIMEOUT_SECONDS:-600}s" \
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER@$HOST" bash -s -- \
    "$IMAGE" "$REGION" "$EXPECTED_DIGEST" >"$RAW_EVIDENCE" <<'REMOTE'
set -euo pipefail
image="$1"; region="$2"; expected_digest="$3"
before="$(sudo ctr -n hivemind images list -q | grep -Fx "$image")"
[[ "$before" == "$image" ]]
printf 'cache_before=owned\n'
sudo ctr -n hivemind images rm "$image" >/dev/null
if sudo ctr -n hivemind images list -q | grep -Fx "$image" >/dev/null; then
    echo "owned image remained cached" >&2
    exit 1
fi
printf 'removed_exact=%s\n' "$image"
password="$(aws ecr get-login-password --region "$region")"
[[ -n "$password" ]]
sudo ctr -n hivemind images pull --user "AWS:$password" "$image" >/dev/null
unset password
actual_digest="$(sudo ctr -n hivemind images info "$image" | grep -Eo 'sha256:[0-9a-f]{64}' | head -n1)"
[[ "$actual_digest" == "$expected_digest" ]]
printf 'pull_auth=aws-ecr-credential-helper-executed\n'
printf 'pulled_digest=%s\n' "$actual_digest"
sudo ctr -n hivemind images list -q | grep -Fx "$image" >/dev/null
printf 'cache_after=owned\n'
REMOTE

grep -q '^cache_before=owned$' "$RAW_EVIDENCE"
grep -q "^removed_exact=$IMAGE$" "$RAW_EVIDENCE"
grep -q '^pull_auth=aws-ecr-credential-helper-executed$' "$RAW_EVIDENCE"
grep -q "^pulled_digest=$EXPECTED_DIGEST$" "$RAW_EVIDENCE"
grep -q '^cache_after=owned$' "$RAW_EVIDENCE"
redacted_image="[REDACTED_ACCOUNT].${IMAGE#*.}"
sed "s|^removed_exact=$IMAGE$|removed_exact=$redacted_image|" "$RAW_EVIDENCE" >"$EVIDENCE_DIR/cold-pull.txt"
rm -f "$RAW_EVIDENCE"
echo "PASS: exact owned ECR image cold-pulled with credential and digest evidence"
