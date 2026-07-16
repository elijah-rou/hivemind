# Locality origin inventory

Localhost smoke date: 2026-04-24

| origin_id | provider | region | locality | continent | federation URL | target URL |
|---|---|---|---|---|---|---|
| `aws-us-east-1` | `aws` | `us-east-1` | `us-east` | `na` | `http://127.0.0.1:9221/v1/internal/federation` | `http://127.0.0.1:9021` |
| `crusoe-us-east-1` | `crusoe` | `us-east-1` | `us-east` | `na` | `http://127.0.0.1:9222/v1/internal/federation` | `http://127.0.0.1:9022` |
| `crusoe-texas` | `crusoe` | `texas` | `us-central` | `na` | `http://127.0.0.1:9223/v1/internal/federation` | `http://127.0.0.1:9023` |
| `aws-eu-west-2` | `aws` | `eu-west-2` | `europe` | `eu` | `http://127.0.0.1:9224/v1/internal/federation` | `http://127.0.0.1:9024` |

`us-east` contains multiple independent origins from different provider buckets (`aws`, `crusoe`).
