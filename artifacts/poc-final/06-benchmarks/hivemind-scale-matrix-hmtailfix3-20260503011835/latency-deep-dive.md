# Hivemind latency deep dive

- source: `latency-events-consolidated.csv`
- events: 22

## Scenario wall-clock spans

| scenario | start_ms | end_ms | wall_ms |
|---|---:|---:|---:|
| multi_50x1 | 1777785549283 | 1777785570863 | 21580 |
| single | 1777785516001 | 1777785546909 | 30908 |

## Phase attribution

| scenario | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |
|---|---|---|---:|---:|---:|---:|---:|
| multi_50x1 | benchmark | deployment_ready_observed | 1 | 21580 | 21580 | 21580 | 21580 |
| multi_50x1 | benchmark | pods_created_observed | 1 | 9972 | 9972 | 9972 | 9972 |
| multi_50x1 | benchmark | pods_running_observed | 1 | 21580 | 21580 | 21580 | 21580 |
| multi_50x1 | benchmark | pods_scheduled_observed | 1 | 10859 | 10859 | 10859 | 10859 |
| multi_50x1 | create_deployment | create_50_submit | 1 | 9722 | 9722 | 9722 | 9722 |
| single | benchmark | deployment_ready_observed | 3 | 30323 | 925 | 29035 | 29035 |
| single | benchmark | deployment_zero_observed | 1 | 395 | 395 | 395 | 395 |
| single | benchmark | pods_created_observed | 3 | 1246 | 376 | 507 | 507 |
| single | benchmark | pods_running_observed | 3 | 30323 | 925 | 29035 | 29035 |
| single | benchmark | pods_scheduled_observed | 3 | 1246 | 376 | 507 | 507 |
| single | create_deployment | create_submit | 1 | 360 | 360 | 360 | 360 |
| single | scale_deployment | scale_0_to_50_submit | 1 | 152 | 152 | 152 | 152 |
| single | scale_deployment | scale_50_to_1_submit | 1 | 213 | 213 | 213 | 213 |
| single | scale_deployment | scale_to_zero_submit | 1 | 236 | 236 | 236 | 236 |
