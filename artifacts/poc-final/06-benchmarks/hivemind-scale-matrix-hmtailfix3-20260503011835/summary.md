# Hivemind scale benchmark matrix

- run_id: hmtailfix3-20260503011835
- image: docker.io/library/nginx:1.27-alpine
- latency_events: latency-events.csv
- consolidated_latency_events: latency-events-consolidated.csv
- latency_events_json: latency-events-consolidated.jsonl
- latency_flamegraph: latency-flamegraph.folded
- latency_summary: latency-summary.md
- latency_deep_dive: latency-deep-dive.md
- latency_firechart: latency-firechart.html

| scenario | metric | value_ms |
|---|---|---:|
| one deployment 0 -> 50 -> 1 | create submit | 360 |
| one deployment 0 -> 50 -> 1 | 0 -> 50 submit | 152 |
| one deployment 0 -> 50 -> 1 | 0 -> 50 ready | 29099 |
| one deployment 0 -> 50 -> 1 | 50 -> 1 submit | 213 |
| one deployment 0 -> 50 -> 1 | 50 -> 1 ready | 469 |
| 50 deployments x 1 replica | submit total | 9722 |
| 50 deployments x 1 replica | all ready | 21644 |
