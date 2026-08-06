#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT_DIR/bench/compare.sh"
TMP_DIR="$(mktemp -d)"
REPLICA_BIN="$ROOT_DIR/core/zig-out/bin/hivemind"
BENCH_BIN="$ROOT_DIR/bench/hivemind-bench"
REPLICA_EXISTED=0
BENCH_EXISTED=0
if [[ -e "$REPLICA_BIN" ]]; then cp -p "$REPLICA_BIN" "$TMP_DIR/replica.backup"; REPLICA_EXISTED=1; fi
if [[ -e "$BENCH_BIN" ]]; then cp -p "$BENCH_BIN" "$TMP_DIR/bench.backup"; BENCH_EXISTED=1; fi
cleanup() {
  rm -f "$REPLICA_BIN" "$BENCH_BIN"
  if [[ "$REPLICA_EXISTED" == 1 ]]; then cp -p "$TMP_DIR/replica.backup" "$REPLICA_BIN"; fi
  if [[ "$BENCH_EXISTED" == 1 ]]; then cp -p "$TMP_DIR/bench.backup" "$BENCH_BIN"; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/bin" "$(dirname "$REPLICA_BIN")"

cat > "$TMP_DIR/bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "build -Doptimize=ReleaseFast" ]]
mkdir -p zig-out/bin
cat > zig-out/bin/hivemind <<'REPLICA'
#!/usr/bin/env bash
set -euo pipefail
node_id=""
while (( $# > 0 )); do
  if [[ "$1" == --node-id ]]; then node_id="$2"; shift 2; else shift; fi
done
[[ "$node_id" =~ ^[0-2]$ ]]
printf '%s\n' "$BASHPID" > "$BENCH_FIXTURE_STATE/leader-$node_id.pid"
ps -o pgid= -p "$BASHPID" | tr -d '[:space:]' > "$BENCH_FIXTURE_STATE/group-$node_id.pid"
if [[ "${STUB_REPLICA_EXIT_NODE:-}" == "$node_id" ]]; then exit 42; fi
(
  trap '' TERM
  printf '%s\n' "$BASHPID" > "$BENCH_FIXTURE_STATE/child-$node_id.pid"
  while :; do /bin/sleep 1; done
) &
wait
REPLICA
chmod +x zig-out/bin/hivemind
EOF

cat > "$TMP_DIR/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
  if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
done
[[ -n "$output" ]]
cat > "$output" <<'BENCH'
#!/usr/bin/env bash
[[ "${STUB_BENCH_FAIL:-0}" == 0 ]]
BENCH
chmod +x "$output"
EOF
chmod +x "$TMP_DIR/bin/zig" "$TMP_DIR/bin/go"

export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export BENCH_FIXTURE_STATE="$TMP_DIR/state"
mkdir -p "$BENCH_FIXTURE_STATE"

start=$SECONDS
set +e
HIVEMIND_ONLY=1 STUB_BENCH_FAIL=1 BENCH_STARTUP_WAIT_SEC=1 BENCH_CLEANUP_TIMEOUT_SEC=1 \
  "$COMPARE" 1 >"$TMP_DIR/compare.out" 2>"$TMP_DIR/compare.err"
rc=$?
set -e
elapsed=$((SECONDS - start))
[[ "$rc" -ne 0 ]]
(( elapsed <= 5 )) || { echo "compare cleanup exceeded aggregate bound: ${elapsed}s" >&2; exit 1; }

for node_id in 0 1 2; do
  leader="$(cat "$BENCH_FIXTURE_STATE/leader-$node_id.pid")"
  child="$(cat "$BENCH_FIXTURE_STATE/child-$node_id.pid")"
  group="$(cat "$BENCH_FIXTURE_STATE/group-$node_id.pid")"
  [[ "$leader" == "$group" ]] || {
    echo "replica $node_id was not its owned process-group leader" >&2
    exit 1
  }
  for pid in "$leader" "$child"; do
    if [[ -r "/proc/$pid/stat" ]]; then
      state="$(awk '{print $3}' "/proc/$pid/stat")"
      [[ "$state" == Z ]] || {
        echo "replica process survived cleanup: pid=$pid state=$state" >&2
        exit 1
      }
    fi
  done
done

rm -rf "$BENCH_FIXTURE_STATE"
mkdir -p "$BENCH_FIXTURE_STATE"
start=$SECONDS
set +e
HIVEMIND_ONLY=1 STUB_REPLICA_EXIT_NODE=1 BENCH_STARTUP_WAIT_SEC=1 BENCH_CLEANUP_TIMEOUT_SEC=1 \
  "$COMPARE" 1 >"$TMP_DIR/early-exit.out" 2>"$TMP_DIR/early-exit.err"
early_rc=$?
set -e
elapsed=$((SECONDS - start))
[[ "$early_rc" -ne 0 ]]
(( elapsed <= 5 )) || { echo "startup-failure cleanup exceeded aggregate bound: ${elapsed}s" >&2; exit 1; }
for node_id in 0 1; do
  for role in leader child; do
    pid_file="$BENCH_FIXTURE_STATE/$role-$node_id.pid"
    [[ -f "$pid_file" ]] || continue
    process_pid="$(cat "$pid_file")"
    if [[ -r "/proc/$process_pid/stat" ]]; then
      state="$(awk '{print $3}' "/proc/$process_pid/stat")"
      [[ "$state" == Z ]] || {
        echo "replica $role survived startup-failure cleanup: pid=$process_pid state=$state" >&2
        exit 1
      }
    fi
  done
done

grep -q 'setsid' "$COMPARE"
grep -Eq 'kill -TERM -- .*-.*pgid' "$COMPARE"
grep -Eq 'kill -KILL -- .*-.*pgid' "$COMPARE"
echo 'bench compare process-group cleanup fixtures: PASS'
