# Fuzz Report Viewer (Deferred)

## Overview

HTML report generator for fuzz results. Two modes:

1. **Corpus report** (from `fuzz_failures.jsonl`): overview of all failures across a fuzz run
2. **Trace report** (from trace JSONL): deep dive into one failing seed

## Corpus Report

- Summary stats: seeds tested, pass/fail ratio, seeds/sec
- Findings list: each failure with seed, outcome, config, violation details
- Property matrix: which invariants failed
- Discovery curve: cumulative failures over seeds

## Trace Report

- Timeline: horizontal strip per replica, colored by status (N/V/R), fault markers
- Commit progress: line chart of commit_min per replica over ticks
- Journal heatmap: which slots present/missing per replica at violation tick
- Event log: scrollable, filterable

## Implementation

- `zig build fuzz -- replay SEED --trace trace.jsonl` emits structured JSONL events
- `zig build fuzz -- report` reads corpus, generates self-contained HTML
- Single HTML file with inline JS + CSS, no external deps
- Dark theme matching dashboard

## Event Format

```json
{"tick":0,"type":"init","replicas":5,"seed":13}
{"tick":22,"type":"crash","replica":4,"pre":{"view":0,"op":4,"commit":4},"post":{...}}
{"tick":45,"type":"partition","replica":0}
{"tick":51,"type":"heal"}
{"tick":50,"type":"state","replicas":[{"id":0,"status":"V","view":0,"op":46,"commit":5},...]}
{"tick":297,"type":"violation","message":"...","replica":1}
{"tick":297,"type":"journal","replica":1,"op":286,"commit":33,"present":[31..286],"missing":[23..30]}
```

## Reference

- Antithesis: property matrix, findings feed, discovery curve
- TigerBeetle: no visualization, structured logs, seed replay
