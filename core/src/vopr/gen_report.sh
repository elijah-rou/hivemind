#!/bin/bash
set -euo pipefail

# Generate a self-contained HTML fuzz report from a JSONL trace file.
# Usage: ./gen_report.sh <trace.jsonl> [output.html]
#
# Example:
#   zig build fuzz -- replay 13 --trace /tmp/trace_13.jsonl
#   ./src/vopr/gen_report.sh /tmp/trace_13.jsonl /tmp/report.html
#   open /tmp/report.html

TRACE="${1:?Usage: gen_report.sh <trace.jsonl> [output.html]}"
OUTPUT="${2:-fuzz_report.html}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/report_template.html"

if [ ! -f "$TRACE" ]; then echo "Error: trace not found: $TRACE"; exit 1; fi
if [ ! -f "$TEMPLATE" ]; then echo "Error: template not found: $TEMPLATE"; exit 1; fi

# Build JSON array from JSONL
{
    echo -n "["
    first=true
    while IFS= read -r line; do
        if [ "$first" = true ]; then first=false; else echo -n ","; fi
        echo -n "$line"
    done < "$TRACE"
    echo "]"
} > /tmp/fuzz_events.json

# Inject into template using Python (handles escaping correctly)
python3 -c "
import sys
template = open('$TEMPLATE').read()
events = open('/tmp/fuzz_events.json').read()
result = template.replace('/*DATA_PLACEHOLDER*/[]', events)
open('$OUTPUT', 'w').write(result)
"

rm -f /tmp/fuzz_events.json
echo "Report: $OUTPUT ($(wc -l < "$TRACE" | tr -d ' ') events)"
