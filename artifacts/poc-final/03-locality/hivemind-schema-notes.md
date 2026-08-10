# Hivemind federation schema notes

Hivemind exposes machine-readable advisory state on the replica metrics listener:

```text
GET /v1/internal/federation
```

The response contains:

- local `origin` identity: `origin_id`, `provider`, `region`, `locality`, `continent`
- local capacity/load: CPU available/total, GPU available/total by type, queue depth, deployments, running pods, node count
- `peers`: gossip-derived peer origins with the same identity/capacity fields
- freshness: `last_seen_seconds`, `stale`, `active`

This endpoint was used instead of Prometheus text parsing for the POC branch.

Evidence files:

- `federation-aws-us-east-1.json`
- `federation-crusoe-us-east-1.json`
- `federation-crusoe-texas.json`
- `federation-aws-eu-west-2.json`
- `stale-peer-after-kill.json`
