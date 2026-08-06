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
    replica_ips:empty-element) printf '["","10.0.0.11"]\n' ;;
    replica_public_ips:host-token) printf '["worker.example","198.51.100.11"]\n' ;;
    replica_ips:out-of-range) printf '["256.0.0.1","10.0.0.11"]\n' ;;
    replica_public_ips:option-injection) printf '["-oProxyCommand=bad","198.51.100.11"]\n' ;;
    replica_ips:whitespace-token) printf '["10.0.0.10 bad","10.0.0.11"]\n' ;;
    replica_ips:valid-bound) printf '["0.0.0.0","255.255.255.255"]\n' ;;
    replica_public_ips:valid-bound) printf '["255.255.255.255","0.0.0.0"]\n' ;;
    replica_ips:*) printf '["10.0.0.10","10.0.0.11"]\n' ;;
    replica_public_ips:*) printf '["198.51.100.10","198.51.100.11"]\n' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[[ "${2:-}" == -raw ]]
if [[ "$DEPLOY_OUTPUT_SCENARIO" == "raw-failure-$3" ]]; then
  exit 1
fi
case "$3:$DEPLOY_OUTPUT_SCENARIO" in
  worker_cpu_ip:worker-private-empty) ;;
  worker_cpu_ip:worker-private-malformed) printf '10.0.1.10 bad' ;;
  worker_gpu_ip:worker-private-out-of-range) printf '10.0.1.999' ;;
  worker_cpu_public_ip:worker-public-malformed) printf 'public.example' ;;
  worker_gpu_public_ip:worker-public-option) printf -- '-oProxyCommand=bad' ;;
  worker_cpu_ip:valid-bound) printf '0.0.0.0' ;;
  worker_gpu_ip:valid-bound) printf '255.255.255.255' ;;
  worker_cpu_public_ip:valid-bound) printf '0.0.0.0' ;;
  worker_gpu_public_ip:valid-bound) printf '255.255.255.255' ;;
  worker_cpu_ip:*) printf '10.0.1.10' ;;
  worker_gpu_ip:*) printf '10.0.1.11' ;;
  worker_cpu_public_ip:*) [[ "$DEPLOY_OUTPUT_SCENARIO" == empty-public ]] || printf '198.51.100.20' ;;
  worker_gpu_public_ip:*) [[ "$DEPLOY_OUTPUT_SCENARIO" == empty-public ]] || printf '198.51.100.21' ;;
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
run_failure raw-failure-worker_cpu_ip
run_failure raw-failure-worker_gpu_ip
run_failure raw-failure-worker_cpu_public_ip
run_failure raw-failure-worker_gpu_public_ip
run_failure empty-element
run_failure host-token
run_failure out-of-range
run_failure option-injection
run_failure whitespace-token
run_failure worker-private-empty
run_failure worker-private-malformed
run_failure worker-private-out-of-range
run_failure worker-public-malformed
run_failure worker-public-option

: > "$DEPLOY_MUTATIONS"
DEPLOY_OUTPUT_SCENARIO=valid-bound bash "$DEPLOY" >"$TMP_DIR/valid-bound.out" 2>&1
[[ -s "$DEPLOY_MUTATIONS" ]]

: > "$DEPLOY_MUTATIONS"
DEPLOY_OUTPUT_SCENARIO=empty-public bash "$DEPLOY" >"$TMP_DIR/empty-public.out" 2>&1
[[ -s "$DEPLOY_MUTATIONS" ]]
if grep -Eq '198\.51\.100\.(20|21)' "$DEPLOY_MUTATIONS"; then
  echo 'empty optional worker output triggered worker SSH' >&2; exit 1
fi

: > "$DEPLOY_MUTATIONS"
DEPLOY_OUTPUT_SCENARIO=valid bash "$DEPLOY" >"$TMP_DIR/valid.out" 2>&1
[[ -s "$DEPLOY_MUTATIONS" ]]
grep -q '^scp ' "$DEPLOY_MUTATIONS"
grep -q '^ssh ' "$DEPLOY_MUTATIONS"

echo 'poc deploy output fixtures: PASS'
