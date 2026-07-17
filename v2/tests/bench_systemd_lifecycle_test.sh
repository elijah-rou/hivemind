#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/infra/bench/systemd_lifecycle.sh"
DEPLOY="$ROOT_DIR/infra/bench/deploy.sh"
TF="$ROOT_DIR/infra/bench/main.tf"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
: > "$TMP_DIR/calls"

cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %q ' "$@" >> "$CALLS"; echo >> "$CALLS"
case "$1:$*" in
  show:*LoadState*) [[ "$SYSTEMD_SCENARIO" == no-unit ]] && echo not-found || echo loaded ;;
  show:*ActiveState*) [[ "$SYSTEMD_SCENARIO" == stuck ]] && echo activating || echo inactive ;;
  stop:*) [[ "$SYSTEMD_SCENARIO" == stuck ]] && exit 124 || exit 0 ;;
  is-active:*) [[ "$SYSTEMD_SCENARIO" == failed-start ]] && exit 3 || exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
{ printf 'systemd-run '; printf '%q ' "$@"; echo; } >> "$CALLS"
[[ "$SYSTEMD_SCENARIO" == run-failure ]] && exit 1
exit 0
EOF
cat > "$TMP_DIR/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %q ' "$@" >> "$CALLS"; echo >> "$CALLS"
shift 2
"$@"
EOF
cat > "$TMP_DIR/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %q ' "$@" >> "$CALLS"; echo >> "$CALLS"
EOF
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH" CALLS="$TMP_DIR/calls" HIVEMIND_SYSTEMD_TIMEOUT_SEC=2
# shellcheck disable=SC1090,SC1091
source "$LIB"
unit=hivemind-bench-node-2.service
exe="$TMP_DIR/hivemind"
printf '#!/bin/sh\n' > "$exe"; chmod +x "$exe"

SYSTEMD_SCENARIO=no-unit hivemind_unit_stop_verified "$unit"
if grep -q ' stop ' "$CALLS"; then
  echo 'missing unit was stopped' >&2; exit 1
fi

: > "$CALLS"
SYSTEMD_SCENARIO=running hivemind_unit_stop_verified "$unit"
grep -q 'timeout .*2s.*systemctl.*stop' "$CALLS"
grep -q 'ActiveState' "$CALLS"

: > "$CALLS"
if SYSTEMD_SCENARIO=stuck hivemind_unit_stop_verified "$unit" >"$TMP_DIR/stuck.out" 2>&1; then
  echo 'stuck unit unexpectedly passed' >&2; exit 1
fi
grep -q 'bounded systemd stop failed' "$TMP_DIR/stuck.out"
grep -q 'journalctl' "$CALLS"

: > "$CALLS"
SYSTEMD_SCENARIO=running hivemind_unit_start_verified "$unit" "$exe" --node-id 2 --worker-port 9002 --data-dir /var/lib/hivemind/node-2
grep -q -- "--unit=$unit" "$CALLS"
grep -q -- "$exe.*--node-id.*2.*--worker-port.*9002.*--data-dir.*/var/lib/hivemind/node-2" "$CALLS"

: > "$CALLS"
if SYSTEMD_SCENARIO=failed-start hivemind_unit_start_verified "$unit" "$exe" --node-id 2 >"$TMP_DIR/start.out" 2>&1; then
  echo 'failed start unexpectedly passed' >&2; exit 1
fi
grep -q 'did not become active' "$TMP_DIR/start.out"
grep -q 'journalctl' "$CALLS"

# The deploy lock serializes concurrent replacement commands.
events="$TMP_DIR/events" lock="$TMP_DIR/launch.lock"
(flock -x 9; echo first-start >> "$events"; sleep 0.1; echo first-end >> "$events") 9>"$lock" & first=$!
(flock -x 9; echo second-start >> "$events"; echo second-end >> "$events") 9>"$lock" & second=$!
wait "$first" "$second"
python3 - "$events" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert lines in (["first-start", "first-end", "second-start", "second-end"],
                 ["second-start", "second-end", "first-start", "first-end"]), lines
PY

grep -q 'flock -x 9' "$DEPLOY"
grep -q 'hivemind_unit_stop_verified' "$DEPLOY"
grep -q 'hivemind_unit_start_verified' "$DEPLOY"
grep -q -- '--worker-port' "$TF"
grep -q -- '--data-dir /var/lib/hivemind/node-' "$TF"
if grep -Eq 'kill |PID|pid_lifecycle|nohup' "$DEPLOY" "$LIB"; then
  echo 'obsolete process lifecycle found' >&2; exit 1
fi
echo 'bench systemd lifecycle fixtures: PASS'
