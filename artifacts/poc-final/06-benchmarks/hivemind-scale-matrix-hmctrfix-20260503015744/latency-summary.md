# Hivemind latency span summary

- events: 22
- csv: latency-events-consolidated.csv
- jsonl: latency-events-consolidated.jsonl
- folded: latency-flamegraph.folded

| component | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |
|---|---|---|---:|---:|---:|---:|---:|
| bench | benchmark | deployment_ready_observed | 4 | 32593 | 4357 | 23496 | 23496 |
| bench | benchmark | deployment_zero_observed | 1 | 447 | 447 | 447 | 447 |
| bench | benchmark | pods_created_observed | 4 | 11539 | 413 | 10427 | 10427 |
| bench | benchmark | pods_running_observed | 4 | 32593 | 4357 | 23496 | 23496 |
| bench | benchmark | pods_scheduled_observed | 4 | 12846 | 413 | 11734 | 11734 |
| bench | create_deployment | create_50_submit | 1 | 10254 | 10254 | 10254 | 10254 |
| bench | create_deployment | create_submit | 1 | 293 | 293 | 293 | 293 |
| bench | scale_deployment | scale_0_to_50_submit | 1 | 136 | 136 | 136 | 136 |
| bench | scale_deployment | scale_50_to_1_submit | 1 | 184 | 184 | 184 | 184 |
| bench | scale_deployment | scale_to_zero_submit | 1 | 191 | 191 | 191 | 191 |
