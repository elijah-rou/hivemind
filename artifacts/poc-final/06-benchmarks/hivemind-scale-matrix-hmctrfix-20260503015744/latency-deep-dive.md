# Hivemind latency deep dive

- source: `latency-events-consolidated.csv`
- events: 22

## Scenario wall-clock spans

| scenario | start_ms | end_ms | wall_ms |
|---|---:|---:|---:|
| multi_50x1 | 1777787876166 | 1777787899662 | 23496 |
| single | 1777787864116 | 1777787873851 | 9735 |

## Phase attribution

| scenario | op | phase | count | sum_ms | p50_ms | p95_ms | max_ms |
|---|---|---|---:|---:|---:|---:|---:|
| multi_50x1 | benchmark | deployment_ready_observed | 1 | 23496 | 23496 | 23496 | 23496 |
| multi_50x1 | benchmark | pods_created_observed | 1 | 10427 | 10427 | 10427 | 10427 |
| multi_50x1 | benchmark | pods_running_observed | 1 | 23496 | 23496 | 23496 | 23496 |
| multi_50x1 | benchmark | pods_scheduled_observed | 1 | 11734 | 11734 | 11734 | 11734 |
| multi_50x1 | create_deployment | create_50_submit | 1 | 10254 | 10254 | 10254 | 10254 |
| single | benchmark | deployment_ready_observed | 3 | 9097 | 862 | 7853 | 7853 |
| single | benchmark | deployment_zero_observed | 1 | 447 | 447 | 447 | 447 |
| single | benchmark | pods_created_observed | 3 | 1112 | 382 | 444 | 444 |
| single | benchmark | pods_running_observed | 3 | 9097 | 862 | 7853 | 7853 |
| single | benchmark | pods_scheduled_observed | 3 | 1112 | 382 | 444 | 444 |
| single | create_deployment | create_submit | 1 | 293 | 293 | 293 | 293 |
| single | scale_deployment | scale_0_to_50_submit | 1 | 136 | 136 | 136 | 136 |
| single | scale_deployment | scale_50_to_1_submit | 1 | 184 | 184 | 184 | 184 |
| single | scale_deployment | scale_to_zero_submit | 1 | 191 | 191 | 191 | 191 |
