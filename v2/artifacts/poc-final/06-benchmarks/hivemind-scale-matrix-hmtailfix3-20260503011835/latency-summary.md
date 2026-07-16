# Hivemind latency span summary

- events: 22
- csv: latency-events-consolidated.csv
- jsonl: latency-events-consolidated.jsonl
- folded: latency-flamegraph.folded

| component | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |
|---|---|---|---:|---:|---:|---:|---:|
| bench | benchmark | deployment_ready_observed | 4 | 51903 | 11252 | 29035 | 29035 |
| bench | benchmark | deployment_zero_observed | 1 | 395 | 395 | 395 | 395 |
| bench | benchmark | pods_created_observed | 4 | 11218 | 441 | 9972 | 9972 |
| bench | benchmark | pods_running_observed | 4 | 51903 | 11252 | 29035 | 29035 |
| bench | benchmark | pods_scheduled_observed | 4 | 12105 | 441 | 10859 | 10859 |
| bench | create_deployment | create_50_submit | 1 | 9722 | 9722 | 9722 | 9722 |
| bench | create_deployment | create_submit | 1 | 360 | 360 | 360 | 360 |
| bench | scale_deployment | scale_0_to_50_submit | 1 | 152 | 152 | 152 | 152 |
| bench | scale_deployment | scale_50_to_1_submit | 1 | 213 | 213 | 213 | 213 |
| bench | scale_deployment | scale_to_zero_submit | 1 | 236 | 236 | 236 | 236 |
