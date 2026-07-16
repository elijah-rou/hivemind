#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_REPO="$TMP_DIR/repo"
TEST_BIN="$TMP_DIR/bin"
TEST_LOG="$TMP_DIR/build.log"

mkdir -p "$TEST_REPO/infra/poc" "$TEST_REPO/core" "$TEST_REPO/worker" "$TEST_REPO/api" "$TEST_BIN"
cp "$REPO_ROOT/infra/poc/build-binaries.sh" "$TEST_REPO/infra/poc/build-binaries.sh"
chmod +x "$TEST_REPO/infra/poc/build-binaries.sh"

cat > "$TEST_BIN/zig" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'zig:%s|pwd=%s\n' "$*" "$PWD" >> "$TEST_LOG"
if [ "$#" -ge 1 ] && [ "$1" = "version" ]; then
    echo "0.16.0"
    exit 0
fi
if [ "$#" -ge 1 ] && [ "$1" = "build" ]; then
    mkdir -p "$PWD/zig-out/bin"
    printf 'replica\n' > "$PWD/zig-out/bin/hivemind"
    exit 0
fi
if [ "$#" -ge 1 ] && { [ "$1" = "cc" ] || [ "$1" = "c++" ] || [ "$1" = "ar" ]; }; then
    exit 0
fi
if [ "$#" -ge 2 ] && [ "$1" = "0.16.0" ] && { [ "$2" = "cc" ] || [ "$2" = "c++" ] || [ "$2" = "ar" ]; }; then
    exit 0
fi
echo "unexpected zig args: $*" >&2
exit 1
EOF
chmod +x "$TEST_BIN/zig"

cat > "$TEST_BIN/cargo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'cargo:%s\n' "$*" >> "$TEST_LOG"
printf 'cargo-linker:%s\n' "${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:-}" >> "$TEST_LOG"
printf 'cargo-cc:%s\n' "${CC_x86_64_unknown_linux_gnu:-}" >> "$TEST_LOG"
[ -n "${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:-}" ]
[ -n "${CC_x86_64_unknown_linux_gnu:-}" ]
"${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER}" --version >/dev/null 2>&1
mkdir -p "$PWD/target/x86_64-unknown-linux-gnu/release"
printf 'worker\n' > "$PWD/target/x86_64-unknown-linux-gnu/release/hivemind-worker"
EOF
chmod +x "$TEST_BIN/cargo"

cat > "$TEST_BIN/rustup" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "$1" = "target" ] && [ "$2" = "list" ] && [ "$3" = "--installed" ]; then
    echo "x86_64-unknown-linux-gnu"
    exit 0
fi
echo "unexpected rustup args: $*" >&2
exit 1
EOF
chmod +x "$TEST_BIN/rustup"

cat > "$TEST_BIN/go" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'go:%s\n' "$*" >> "$TEST_LOG"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        out="$2"
        shift 2
        continue
    fi
    shift
done
[ -n "$out" ]
printf 'api\n' > "$out"
EOF
chmod +x "$TEST_BIN/go"

export TEST_LOG
PATH="$TEST_BIN:/usr/bin:/bin" "$TEST_REPO/infra/poc/build-binaries.sh" --output-dir "$TEST_REPO/infra/poc/out"

assert_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "FAIL: missing $path"
        exit 1
    fi
}

assert_grep() {
    local pattern="$1"
    if ! grep -q "$pattern" "$TEST_LOG"; then
        echo "FAIL: missing log pattern: $pattern"
        cat "$TEST_LOG"
        exit 1
    fi
}

assert_file "$TEST_REPO/infra/poc/out/hivemind-linux"
assert_file "$TEST_REPO/infra/poc/out/hivemind-worker-linux"
assert_file "$TEST_REPO/infra/poc/out/hivemind-api-linux"
assert_grep 'cargo-linker:.*/zig-cc'
assert_grep 'cargo-cc:.*/zig-cc'
assert_grep 'zig:cc -target x86_64-linux-gnu --version'

echo "PASS: build-binaries zig linker path"
