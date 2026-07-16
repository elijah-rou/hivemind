#!/usr/bin/env python3
import csv
import html
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def as_int(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def percentile(values, pct):
    if not values:
        return 0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[idx]


def main():
    if len(sys.argv) != 3:
        print("usage: hivemind-latency-deep-dive.py <latency-events-consolidated.csv> <out-dir>", file=sys.stderr)
        return 2

    csv_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    if csv_path.exists():
        with csv_path.open(newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))

    groups = defaultdict(list)
    scenario_bounds = {}
    for row in rows:
        scenario = row.get("scenario") or "unknown"
        op = row.get("op") or "unknown"
        phase = row.get("phase") or "unknown"
        duration = as_int(row.get("duration_ms"))
        start = as_int(row.get("start_ms"))
        end = as_int(row.get("end_ms"), start)
        groups[(scenario, op, phase)].append(duration)
        lo, hi = scenario_bounds.get(scenario, (start, end))
        scenario_bounds[scenario] = (min(lo, start), max(hi, end))

    md_path = out_dir / "latency-deep-dive.md"
    with md_path.open("w", encoding="utf-8") as f:
        f.write("# Hivemind latency deep dive\n\n")
        f.write(f"- source: `{csv_path.name}`\n")
        f.write(f"- events: {len(rows)}\n\n")
        f.write("## Scenario wall-clock spans\n\n")
        f.write("| scenario | start_ms | end_ms | wall_ms |\n")
        f.write("|---|---:|---:|---:|\n")
        for scenario, (start, end) in sorted(scenario_bounds.items()):
            f.write(f"| {scenario} | {start} | {end} | {max(0, end - start)} |\n")
        f.write("\n## Phase attribution\n\n")
        f.write("| scenario | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |\n")
        f.write("|---|---|---|---:|---:|---:|---:|---:|\n")
        for (scenario, op, phase), values in sorted(groups.items()):
            f.write(
                f"| {scenario} | {op} | {phase} | {len(values)} | {sum(values)} | "
                f"{int(statistics.median(values)) if values else 0} | {percentile(values, 95)} | {max(values) if values else 0} |\n"
            )

    firechart_path = out_dir / "latency-firechart.html"
    if rows:
        min_start = min(as_int(r.get("start_ms")) for r in rows)
        max_end = max(as_int(r.get("end_ms"), as_int(r.get("start_ms"))) for r in rows)
    else:
        min_start = 0
        max_end = 1
    width = 1200
    scale = width / max(1, max_end - min_start)
    lanes = sorted({(r.get("scenario") or "unknown", r.get("component") or "unknown") for r in rows})
    lane_index = {lane: i for i, lane in enumerate(lanes)}
    height = max(120, 40 + len(lanes) * 32)

    rects = []
    labels = []
    for row in rows:
        lane = (row.get("scenario") or "unknown", row.get("component") or "unknown")
        y = 30 + lane_index[lane] * 32
        start = as_int(row.get("start_ms"))
        end = as_int(row.get("end_ms"), start)
        x = int((start - min_start) * scale)
        w = max(1, int(max(1, end - start) * scale))
        title = html.escape(" / ".join([lane[0], lane[1], row.get("op") or "-", row.get("phase") or "-"]))
        rects.append(f'<rect x="{x}" y="{y}" width="{w}" height="18"><title>{title}</title></rect>')
    for lane, idx in lane_index.items():
        labels.append(f'<text x="0" y="{24 + idx * 32}" font-size="12">{html.escape(lane[0] + " / " + lane[1])}</text>')

    firechart_path.write_text(
        "<!doctype html><meta charset='utf-8'><title>Hivemind latency firechart</title>"
        "<style>body{font-family:sans-serif}svg{border:1px solid #ddd}rect{fill:#4f46e5;opacity:.7}rect:hover{opacity:1}</style>"
        f"<h1>Hivemind latency firechart</h1><p>events: {len(rows)}</p>"
        f"<svg width='{width}' height='{height}' viewBox='0 0 {width} {height}'>"
        + "".join(labels)
        + "<g transform='translate(0,12)'>"
        + "".join(rects)
        + "</g></svg>",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
