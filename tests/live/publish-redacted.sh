#!/usr/bin/env bash
set -euo pipefail
SOURCE="${1:?usage: publish-redacted.sh SOURCE DESTINATION}"
DESTINATION="${2:?usage: publish-redacted.sh SOURCE DESTINATION}"
TOKEN="${HIVEMIND_REDACTION_TOKEN:?HIVEMIND_REDACTION_TOKEN is required}"
[[ "$TOKEN" =~ ^[a-z][a-z0-9]{11,31}$ ]] || { echo "FAIL: invalid ownership token" >&2; exit 2; }
[[ ! -e "$DESTINATION" ]] || { echo "FAIL: redacted destination already exists: $DESTINATION" >&2; exit 1; }
python3 - "$SOURCE" "$DESTINATION" "$TOKEN" <<'PY'
import os, pathlib, re, shutil, stat, sys
source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
token = sys.argv[3].encode()
max_file_bytes = 1_048_576
max_files = 256
max_tree_bytes = 64 * max_file_bytes
patterns = (
    (re.compile(re.escape(token)), b"[REDACTED_TOKEN]"),
    (re.compile(rb"(?<![0-9])[0-9]{12}(?![0-9])"), b"[REDACTED_ACCOUNT]"),
    (re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"), b"[REDACTED_IP]"),
)
def sanitize(data):
    for pattern, replacement in patterns:
        data = pattern.sub(replacement, data)
    return data
def regular(path):
    mode = path.lstat().st_mode
    return stat.S_ISREG(mode) and not path.is_symlink()
def sanitized_relative(relative):
    parts = []
    for part in relative.parts:
        redacted = sanitize(os.fsencode(part))
        parts.append(os.fsdecode(redacted))
    return pathlib.Path(*parts)
def copy_file(src, dst):
    if not regular(src):
        raise SystemExit(f"source artifact is not a regular non-symlink file: {src}")
    size = src.stat().st_size
    if size > max_file_bytes:
        raise SystemExit(f"source artifact exceeds {max_file_bytes} bytes: {src}")
    data = sanitize(src.read_bytes())
    dst.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with dst.open("xb") as output:
        output.write(data)
    os.chmod(dst, 0o600)
    return size
if source.is_symlink():
    raise SystemExit(f"source artifact must not be a symlink: {source}")
if source.is_file():
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    copy_file(source, destination)
elif source.is_dir():
    destination.mkdir(mode=0o700, parents=True)
    count = 0
    total = 0
    for root, directories, files in os.walk(source):
        directories.sort()
        files.sort()
        root_path = pathlib.Path(root)
        for name in directories:
            if (root_path / name).is_symlink():
                raise SystemExit(f"source artifact tree contains a symlink: {root_path / name}")
        for name in files:
            src = root_path / name
            relative = sanitized_relative(src.relative_to(source))
            count += 1
            if count > max_files:
                raise SystemExit(f"source artifact tree exceeds {max_files} files")
            total += copy_file(src, destination / relative)
            if total > max_tree_bytes:
                raise SystemExit(f"source artifact tree exceeds {max_tree_bytes} bytes")
else:
    raise SystemExit(f"source artifact does not exist: {source}")
PY
