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
if [[ "$SYSTEMD_SCENARIO" == hanging && "$1" == show ]]; then sleep 5; fi
case "$1:$*" in
  show:*LoadState*) [[ "$SYSTEMD_SCENARIO" == load-failure ]] && exit 1; [[ "$SYSTEMD_SCENARIO" == no-unit ]] && echo not-found || echo loaded ;;
  show:*ActiveState*) [[ "$SYSTEMD_SCENARIO" == stuck ]] && echo activating || echo inactive ;;
  show:*MainPID*) echo 4242 ;;
  stop:*) [[ "$SYSTEMD_SCENARIO" == stuck ]] && exit 124 || exit 0 ;;
  is-active:*)
    if [[ "$SYSTEMD_SCENARIO" == inactive-after-run ]]; then
      count=$(cat "$ACTIVE_CALLS" 2>/dev/null || echo 0); echo $((count + 1)) > "$ACTIVE_CALLS"
      (( count == 0 )) && exit 0 || exit 3
    fi
    [[ "$SYSTEMD_SCENARIO" == failed-start ]] && exit 3 || exit 0 ;;
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
exec /usr/bin/timeout "$@"
EOF
cat > "$TMP_DIR/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %q ' "$@" >> "$CALLS"; echo >> "$CALLS"
EOF
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH" CALLS="$TMP_DIR/calls" ACTIVE_CALLS="$TMP_DIR/active-calls"
export HIVEMIND_SYSTEMD_TIMEOUT_SEC=2 HIVEMIND_SYSTEMD_STABILIZE_SEC=1
# shellcheck disable=SC1090,SC1091
source "$LIB"
unit=hivemind-bench-node-2.service
exe="$TMP_DIR/hivemind"
printf '#!/bin/sh\n' > "$exe"; chmod +x "$exe"

hivemind_transaction_begin
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
unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
hivemind_transaction_begin
if SYSTEMD_SCENARIO=load-failure hivemind_unit_stop_verified "$unit" >"$TMP_DIR/load.out" 2>&1; then
  echo 'LoadState query failure unexpectedly passed' >&2; exit 1
fi
grep -q 'LoadState query failed' "$TMP_DIR/load.out"

: > "$CALLS"
unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
HIVEMIND_SYSTEMD_TIMEOUT_SEC=1 hivemind_transaction_begin
start=$SECONDS
if SYSTEMD_SCENARIO=hanging hivemind_unit_stop_verified "$unit" >"$TMP_DIR/hanging.out" 2>&1; then
  echo 'hanging systemctl unexpectedly passed' >&2; exit 1
fi
(( SECONDS - start <= 2 )) || { echo 'hanging command exceeded transaction deadline' >&2; exit 1; }

unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
HIVEMIND_SYSTEMD_TIMEOUT_SEC=1 hivemind_transaction_begin
sleep 2
if SYSTEMD_SCENARIO=running hivemind_unit_stop_verified "$unit" >"$TMP_DIR/deadline.out" 2>&1; then
  echo 'expired transaction unexpectedly passed' >&2; exit 1
fi
grep -q 'deadline exhausted' "$TMP_DIR/deadline.out"

: > "$CALLS"
unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
hivemind_transaction_begin
SYSTEMD_SCENARIO=running hivemind_unit_start_verified "$unit" "$exe" --node-id 2 --worker-port 9002 --data-dir /var/lib/hivemind/node-2
grep -q -- "--unit=$unit" "$CALLS"
grep -q -- "$exe.*--node-id.*2.*--worker-port.*9002.*--data-dir.*/var/lib/hivemind/node-2" "$CALLS"

: > "$CALLS"
if SYSTEMD_SCENARIO=failed-start hivemind_unit_start_verified "$unit" "$exe" --node-id 2 >"$TMP_DIR/start.out" 2>&1; then
  echo 'failed start unexpectedly passed' >&2; exit 1
fi
grep -q 'did not become active' "$TMP_DIR/start.out"
grep -q 'journalctl' "$CALLS"

: > "$CALLS"; : > "$ACTIVE_CALLS"
unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
hivemind_transaction_begin
if SYSTEMD_SCENARIO=inactive-after-run hivemind_unit_start_verified "$unit" "$exe" --node-id 2 >"$TMP_DIR/inactive.out" 2>&1; then
  echo 'unit inactive after systemd-run unexpectedly passed' >&2; exit 1
fi
grep -q 'did not remain active' "$TMP_DIR/inactive.out"

# A held deployment lock fails within the configured wait bound.
held_lock="$TMP_DIR/held.lock"
exec 8>"$held_lock"
flock -x 8
if flock -x -w 1 9 9>"$held_lock"; then
  echo 'held lock unexpectedly acquired' >&2; exit 1
fi

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

grep -q 'flock -x -w' "$DEPLOY"
grep -q 'hivemind_unit_stop_verified' "$DEPLOY"
grep -q 'hivemind_unit_start_verified' "$DEPLOY"
grep -q -- '--worker-port' "$TF"
grep -q -- '--data-dir /var/lib/hivemind/node-' "$TF"
if grep -Eq 'kill |pid_lifecycle|nohup' "$DEPLOY" "$LIB"; then
  echo 'obsolete process lifecycle found' >&2; exit 1
fi
echo 'bench systemd lifecycle fixtures: PASS'
