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
printf '%s\n' "$1" >> "$KILL_LOG"
EOF
chmod +x "$TMP_DIR/bin/kill-stub"
export KILL_LOG="$TMP_DIR/kills"
: > "$KILL_LOG"

# shellcheck source=../infra/bench/pid_lifecycle.sh
source "$LIB"

mkdir -p "$TMP_DIR/proc/101"
ln -s "$TMP_DIR/runs/token-a/hivemind" "$TMP_DIR/proc/101/exe"
printf '101 token-a %s\n' "$TMP_DIR/runs/token-a/hivemind" > "$TMP_DIR/state"
hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
grep -qx 101 "$KILL_LOG"

# Reused PID points at an unrelated executable. It must never be killed.
: > "$KILL_LOG"
rm "$TMP_DIR/proc/101/exe"
ln -s /usr/bin/sleep "$TMP_DIR/proc/101/exe"
hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
[[ ! -s "$KILL_LOG" ]]

# Token/path mismatch is stale state and must never be killed.
rm "$TMP_DIR/proc/101/exe"
ln -s "$TMP_DIR/runs/token-a/hivemind" "$TMP_DIR/proc/101/exe"
printf '101 token-b %s\n' "$TMP_DIR/runs/token-a/hivemind" > "$TMP_DIR/state"
hivemind_stop_verified "$TMP_DIR/state" "$TMP_DIR/runs" "$TMP_DIR/proc" "$TMP_DIR/bin/kill-stub"
[[ ! -s "$KILL_LOG" ]]

# The same launch lock serializes concurrent node launches.
lock="$TMP_DIR/launch.lock"
events="$TMP_DIR/events"
(
    flock -x 9
    echo first-start >> "$events"
    sleep 0.1
    echo first-end >> "$events"
) 9>"$lock" &
first=$!
(
    flock -x 9
    echo second-start >> "$events"
    echo second-end >> "$events"
) 9>"$lock" &
second=$!
wait "$first" "$second"
python3 - "$events" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert lines in (["first-start", "first-end", "second-start", "second-end"],
                 ["second-start", "second-end", "first-start", "first-end"]), lines
PY

grep -q 'flock -x 9' "$DEPLOY"
grep -q '/proc/\\$pid/exe' "$DEPLOY"
grep -q 'hivemind-runs/\$RUN_TOKEN' "$DEPLOY"
grep -q 'hivemind_stop_verified' "$DEPLOY"

echo "bench PID lifecycle fixtures: PASS"
