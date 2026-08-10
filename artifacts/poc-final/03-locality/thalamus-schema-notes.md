# Thalamus POC branch schema notes

Branch: `feat/hivemind-poc-locality`

Type/schema extensions landed for the POC:

```go
type ClusterMetadata struct {
    ClusterID string
    Domain    *url.URL
    Provider  string
    Region    string
    Locality  string
    Continent string
    Active    bool
}

type ClusterCapacity struct {
    ClusterID        string
    Hardware         HardwareType
    Cost             int
    RunningCapacity  int
    ProviderCapacity int
    QueueDepth       int
    HealthScore      float64
    UpdatedAt        time.Time
}

type AppRoutingPolicy struct {
    AppID             string
    PreferredLocality string
    AllowedLocalities []string
    ResidencyMode     string
    FallbackOrder     []string
}
```

Resolver behavior:

1. build candidates from existing app capacity, cluster capacity, metadata, health, killswitch, affinity stores
2. filter inactive, stale, unhealthy, or no-capacity candidates
3. apply app routing policy before final candidate pick
4. score only candidates in the selected fallback tier
5. emit locality reasons used by the smoke trace

Reasons evidenced:

- `same-locality-best`
- `same-locality-failover`
- `cross-locality-fallback`
- `residency-restricted`
