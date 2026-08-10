# Locality map

| locality | origins |
|---|---|
| `us-east` | `aws-us-east-1`, `crusoe-us-east-1` |
| `us-central` | `crusoe-texas` |
| `europe` | `aws-eu-west-2` |

The smoke keeps each origin as an independent single-replica Hivemind process. Cross-origin state is exchanged through gossip and exposed by `GET /v1/internal/federation`.
