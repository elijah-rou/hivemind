#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/infra/bench/systemd_lifecycle.sh"
DEPLOY="$ROOT_DIR/infra/bench/deploy.sh"
TF="$ROOT_DIR/infra/bench/main.tf"
TMP_DIR="$(mktemp -d)"
cleanup_fixture() {
  local status="$1"
  local pid pid_file
  local -a background_jobs=()
  trap - EXIT INT TERM
  set +e
  for pid_file in "$TMP_DIR"/stubborn-parent.pid "$TMP_DIR"/stubborn-child.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  mapfile -t background_jobs < <(jobs -pr)
  if (( ${#background_jobs[@]} > 0 )); then
    kill -TERM "${background_jobs[@]}" 2>/dev/null || true
    kill -KILL "${background_jobs[@]}" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap 'cleanup_fixture "$?"' EXIT INT TERM
mkdir -p "$TMP_DIR/bin"
chmod 700 "$TMP_DIR/bin"
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
cat > "$TMP_DIR/bin/stubborn-command" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
echo "$BASHPID" > "$STUBBORN_PARENT_PID"
(
  trap '' TERM
  echo "$BASHPID" > "$STUBBORN_CHILD_PID"
  while :; do sleep 1; done
) &
wait
EOF
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH" CALLS="$TMP_DIR/calls" ACTIVE_CALLS="$TMP_DIR/active-calls"
export STUBBORN_PARENT_PID="$TMP_DIR/stubborn-parent.pid" STUBBORN_CHILD_PID="$TMP_DIR/stubborn-child.pid"
export HIVEMIND_SYSTEMD_TIMEOUT_SEC=2 HIVEMIND_SYSTEMD_STABILIZE_SEC=1
# shellcheck disable=SC1090,SC1091 # LIB resolves to the known lifecycle helper under ROOT_DIR.
source "$LIB"
unit=hivemind-bench-node-2.service
exe="$TMP_DIR/hivemind"
printf '#!/bin/sh\n' > "$exe"; chmod +x "$exe"

mkdir "$TMP_DIR/no-timeout" "$TMP_DIR/non-gnu"
cat > "$TMP_DIR/non-gnu/timeout" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo 'BusyBox timeout'; exit 0; }
exec /usr/bin/timeout "$@"
EOF
chmod +x "$TMP_DIR/non-gnu/timeout"
if PATH="$TMP_DIR/no-timeout" hivemind_transaction_begin >"$TMP_DIR/missing-timeout.out" 2>&1; then
  echo 'missing timeout dependency unexpectedly passed' >&2; exit 1
fi
grep -q 'GNU timeout' "$TMP_DIR/missing-timeout.out"
if PATH="$TMP_DIR/non-gnu:$PATH" hivemind_transaction_begin >"$TMP_DIR/non-gnu.out" 2>&1; then
  echo 'non-GNU timeout dependency unexpectedly passed' >&2; exit 1
fi
grep -q 'GNU coreutils timeout' "$TMP_DIR/non-gnu.out"

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

# TERM-ignoring command groups are KILLed and cannot retain the deploy lock.
stubborn_lock="$TMP_DIR/stubborn.lock"
unset HIVEMIND_TRANSACTION_DEADLINE_EPOCH
# Three seconds avoids whole-second deadline truncation while retaining a tight bound.
HIVEMIND_SYSTEMD_TIMEOUT_SEC=3 hivemind_transaction_begin
start=$SECONDS
(
  exec 9>"$stubborn_lock"
  flock -x 9
  if hivemind_run_bounded stubborn-command; then
    echo 'TERM-ignoring command unexpectedly passed' >&2
    exit 1
  fi
) >"$TMP_DIR/stubborn.out" 2>&1
(( SECONDS - start <= 5 )) || { echo 'forced termination exceeded bound' >&2; exit 1; }
if ! flock -x -w 1 9 9>"$stubborn_lock"; then
  echo 'terminated descendant retained deploy lock' >&2; exit 1
fi
assert_process_gone() {
  local pid_file="$1" pid
  pid="$(cat "$pid_file")"
  for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  echo "stubborn process survived forced termination: $pid" >&2
  return 1
}
assert_process_gone "$STUBBORN_PARENT_PID"
assert_process_gone "$STUBBORN_CHILD_PID"
grep -q -- '--signal=TERM' "$CALLS"
grep -q -- '--kill-after=1s' "$CALLS"

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
