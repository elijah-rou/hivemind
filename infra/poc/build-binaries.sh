#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"
BUILD_REPLICA=true
BUILD_WORKER=true
BUILD_API=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --replica-only)
            BUILD_REPLICA=true
            BUILD_WORKER=false
            BUILD_API=false
            shift
            ;;
        --worker-only)
            BUILD_REPLICA=false
            BUILD_WORKER=true
            BUILD_API=false
            shift
            ;;
        --api-only)
            BUILD_REPLICA=false
            BUILD_WORKER=false
            BUILD_API=true
            shift
            ;;
        *)
            echo "Unknown arg: $1"
            exit 1
            ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

TARGET_TRIPLE="x86_64-unknown-linux-gnu"
TARGET_ZIG="x86_64-linux-gnu"
TARGET_ENV_PREFIX="CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU"
TARGET_CC_PREFIX="x86_64_unknown_linux_gnu"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
}

ensure_rust_target() {
    if rustup target list --installed | grep -qx "$TARGET_TRIPLE"; then
        return
    fi

    echo "ERROR: Rust target '$TARGET_TRIPLE' not installed. Run: rustup target add $TARGET_TRIPLE"
    exit 1
}

build_worker_with_zig() {
    local zig_bin="$1"
    local work_dir
    work_dir="$(mktemp -d)"

    cat > "$work_dir/zig-cc" <<EOF
#!/bin/bash
set -euo pipefail
args=()
saw_target=0
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --target=${TARGET_TRIPLE})
            args+=( -target "${TARGET_ZIG}" )
            saw_target=1
            shift
            ;;
        -target)
            saw_target=1
            shift
            if [ "\$1" = "${TARGET_TRIPLE}" ]; then
                args+=( -target "${TARGET_ZIG}" )
            else
                args+=( -target "\$1" )
            fi
            shift
            ;;
        *)
            args+=( "\$1" )
            shift
            ;;
    esac
done
if [ "\$saw_target" -eq 0 ]; then
    args=( -target "${TARGET_ZIG}" "\${args[@]}" )
fi
exec "$zig_bin" cc "\${args[@]}"
EOF

    cat > "$work_dir/zig-cxx" <<EOF
#!/bin/bash
set -euo pipefail
args=()
saw_target=0
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --target=${TARGET_TRIPLE})
            args+=( -target "${TARGET_ZIG}" )
            saw_target=1
            shift
            ;;
        -target)
            saw_target=1
            shift
            if [ "\$1" = "${TARGET_TRIPLE}" ]; then
                args+=( -target "${TARGET_ZIG}" )
            else
                args+=( -target "\$1" )
            fi
            shift
            ;;
        *)
            args+=( "\$1" )
            shift
            ;;
    esac
done
if [ "\$saw_target" -eq 0 ]; then
    args=( -target "${TARGET_ZIG}" "\${args[@]}" )
fi
exec "$zig_bin" c++ "\${args[@]}"
EOF

    cat > "$work_dir/zig-ar" <<EOF
#!/bin/bash
set -euo pipefail
exec ar "\$@"
EOF

    chmod +x "$work_dir/zig-cc" "$work_dir/zig-cxx" "$work_dir/zig-ar"

    (
        cd "$REPO_ROOT/worker"
        env \
            "CC_${TARGET_CC_PREFIX}=$work_dir/zig-cc" \
            "CXX_${TARGET_CC_PREFIX}=$work_dir/zig-cxx" \
            "AR_${TARGET_CC_PREFIX}=$work_dir/zig-ar" \
            "${TARGET_ENV_PREFIX}_LINKER=$work_dir/zig-cc" \
            "${TARGET_ENV_PREFIX}_AR=$work_dir/zig-ar" \
            cargo build --release --target "$TARGET_TRIPLE"
    )

    rm -rf "$work_dir"
}

build_worker_linux() {
    echo "==> Building Rust worker (linux-x86_64)..."
    ensure_rust_target

    if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
        echo "    using cargo-zigbuild ($(cargo-zigbuild --version), zig $(zig version))"
        (
            cd "$REPO_ROOT/worker"
            cargo zigbuild --release --target "$TARGET_TRIPLE"
        )
        cp "$REPO_ROOT/worker/target/$TARGET_TRIPLE/release/hivemind-worker" "$OUTPUT_DIR/hivemind-worker-linux"
        return
    fi

    if command -v zig >/dev/null 2>&1; then
        echo "    using cargo + zig linker ($(zig version))"
        build_worker_with_zig "$(command -v zig)"
        cp "$REPO_ROOT/worker/target/$TARGET_TRIPLE/release/hivemind-worker" "$OUTPUT_DIR/hivemind-worker-linux"
        return
    fi

    if command -v cross >/dev/null 2>&1; then
        echo "    using cross"
        (
            cd "$REPO_ROOT/worker"
            cross build --release --target "$TARGET_TRIPLE"
        )
        cp "$REPO_ROOT/worker/target/$TARGET_TRIPLE/release/hivemind-worker" "$OUTPUT_DIR/hivemind-worker-linux"
        return
    fi

    echo "    using cargo target linker from host toolchain"
    (
        cd "$REPO_ROOT/worker"
        cargo build --release --target "$TARGET_TRIPLE"
    )
    cp "$REPO_ROOT/worker/target/$TARGET_TRIPLE/release/hivemind-worker" "$OUTPUT_DIR/hivemind-worker-linux"
}

if [ "$BUILD_REPLICA" = true ]; then
    require_cmd zig
    echo "==> Building Zig replica (linux-x86_64)..."
    (
        cd "$REPO_ROOT/core"
        zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
    )
    cp "$REPO_ROOT/core/zig-out/bin/hivemind" "$OUTPUT_DIR/hivemind-linux"
fi

if [ "$BUILD_WORKER" = true ]; then
    require_cmd cargo
    require_cmd rustup
    build_worker_linux
fi

if [ "$BUILD_API" = true ]; then
    require_cmd go
    echo "==> Building Go API (linux-x86_64)..."
    (
        cd "$REPO_ROOT/api"
        GOOS=linux GOARCH=amd64 go build -o "$OUTPUT_DIR/hivemind-api-linux" .
    )
fi
