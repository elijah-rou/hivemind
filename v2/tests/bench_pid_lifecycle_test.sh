#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/infra/bench/pid_lifecycle.sh"
DEPLOY="$ROOT_DIR/infra/bench/deploy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/proc" "$TMP_DIR/runs/token-a" "$TMP_DIR/bin"
touch "$TMP_DIR/runs/token-a/hivemind"

cat > "$TMP_DIR/bin/kill-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$KILL_LOG"
case "$KILL_MODE:$1" in
  graceful:-TERM) rm -f "$PROC_ROOT/$2/exe" ;;
  reused:-TERM) rm -f "$PROC_ROOT/$2/exe"; ln -s /usr/bin/sleep "$PROC_ROOT/$2/exe" ;;
  stuck:-KILL) rm -f "$PROC_ROOT/$2/exe" ;;
esac
EOF
chmod +x "$TMP_DIR/bin/kill-stub"
export KILL_LOG="$TMP_DIR/kills" PROC_ROOT="$TMP_DIR/proc"
export HIVEMIND_STOP_TIMEOUT_SEC=1 HIVEMIND_STOP_POLL_SEC=0.05

# shellcheck source=../infra/bench/pid_lifecycle.sh
source "$LIB"

reset_target() {
  rm -rf "$TMP_DIR/proc/101"
  mkdir -p "$TMP_DIR/proc/101"
  ln -s "$TMP_DIR/runs/token-a/hivemind" "$TMP_DIR/proc/101/exe"
  printf '101 token-a %s\n' "$TMP_DIR/runs/token-a/hivemind" > "$TMP_DIR/state"
  : > "$KILL_LOG"
}

# Graceful stop confirms disappearance before returning.
reset_target
KILL_MODE=graceful hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
grep -qx -- '-TERM 101' "$KILL_LOG"
[[ ! -e "$TMP_DIR/proc/101/exe" ]]

# Stuck SIGTERM is escalated, with identity revalidated before SIGKILL.
reset_target
KILL_MODE=stuck hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
printf '%s\n' '-TERM 101' '-KILL 101' | diff -u - "$KILL_LOG"

# PID reuse proves the old identity disappeared and never kills the replacement.
reset_target
KILL_MODE=reused hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
grep -qx -- '-TERM 101' "$KILL_LOG"
[[ "$(readlink "$TMP_DIR/proc/101/exe")" == /usr/bin/sleep ]]

# A process surviving both signals fails closed, preventing PID-state overwrite.
reset_target
set +e
KILL_MODE=timeout hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub" >"$TMP_DIR/timeout.out" 2>&1
timeout_status=$?
set -e
[[ "$timeout_status" -ne 0 ]]
grep -q 'did not disappear' "$TMP_DIR/timeout.out"
printf '%s\n' '-TERM 101' '-KILL 101' | diff -u - "$KILL_LOG"

# Stale identity is never signalled.
reset_target
rm "$TMP_DIR/proc/101/exe"
ln -s /usr/bin/sleep "$TMP_DIR/proc/101/exe"
KILL_MODE=timeout hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
[[ ! -s "$KILL_LOG" ]]

# The same launch lock serializes concurrent node launches.
lock="$TMP_DIR/launch.lock"
events="$TMP_DIR/events"
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
grep -q 'hivemind_stop_verified' "$DEPLOY"
echo "bench PID lifecycle fixtures: PASS"
