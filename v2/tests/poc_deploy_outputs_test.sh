#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$ROOT_DIR/infra/poc/deploy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
install -d -m 700 "$TMP_DIR/bin"
: > "$TMP_DIR/mutations"

cat > "$TMP_DIR/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == output ]]
if [[ "${2:-}" == -json ]]; then
  name="$3"
  if [[ "$DEPLOY_OUTPUT_SCENARIO" == terraform-failure && "$name" == replica_ips ]]; then
    exit 1
  fi
  if [[ "$DEPLOY_OUTPUT_SCENARIO" == malformed-json && "$name" == replica_ips ]]; then
    printf '{malformed\n'; exit 0
  fi
  case "$name:$DEPLOY_OUTPUT_SCENARIO" in
    replica_ips:empty) printf '[]\n' ;;
    replica_public_ips:mismatch) printf '["198.51.100.10"]\n' ;;
    replica_ips:*|replica_ips:valid) printf '["10.0.0.10","10.0.0.11"]\n' ;;
    replica_public_ips:*|replica_public_ips:valid) printf '["198.51.100.10","198.51.100.11"]\n' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[[ "${2:-}" == -raw ]]
case "$3" in
  worker_cpu_ip) printf '10.0.1.10' ;;
  worker_gpu_ip) printf '10.0.1.11' ;;
  worker_cpu_public_ip) printf '198.51.100.20' ;;
  worker_gpu_public_ip) printf '198.51.100.21' ;;
  *) exit 2 ;;
esac
EOF

REAL_JQ="$(command -v jq)"
cat > "$TMP_DIR/bin/jq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${DEPLOY_OUTPUT_SCENARIO}" == partial-jq ]]; then
  cat >/dev/null
  printf '10.0.0.10\n'
  exit 1
fi
exec "$REAL_JQ" "\$@"
EOF

for command_name in ssh scp; do
  cat > "$TMP_DIR/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %q\n' "$(basename "$0")" "$*" >> "$DEPLOY_MUTATIONS"
cat >/dev/null || true
EOF
done
cat > "$TMP_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_DIR/bin/"*

export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export DEPLOY_MUTATIONS="$TMP_DIR/mutations"

run_failure() {
  local scenario="$1"
  local output="$TMP_DIR/$scenario.out"
  : > "$DEPLOY_MUTATIONS"
  if DEPLOY_OUTPUT_SCENARIO="$scenario" bash "$DEPLOY" >"$output" 2>&1; then
    echo "$scenario unexpectedly passed" >&2; exit 1
  fi
  if [[ -s "$DEPLOY_MUTATIONS" ]]; then
    echo "$scenario performed SSH mutation" >&2; cat "$DEPLOY_MUTATIONS" >&2; exit 1
  fi
}

run_failure terraform-failure
run_failure malformed-json
run_failure partial-jq
run_failure empty
run_failure mismatch

: > "$DEPLOY_MUTATIONS"
DEPLOY_OUTPUT_SCENARIO=valid bash "$DEPLOY" >"$TMP_DIR/valid.out" 2>&1
[[ -s "$DEPLOY_MUTATIONS" ]]
grep -q '^scp ' "$DEPLOY_MUTATIONS"
grep -q '^ssh ' "$DEPLOY_MUTATIONS"

echo 'poc deploy output fixtures: PASS'
