> **LEGACY**: Phase 2 vision document. The Honeycomb registry/distribution system is not yet implemented.

# Honeycomb Technical Design

**Phase 2 of Hivemind Migration**
**Status**: Draft
**Dependency**: Phase 1 (Router) stable

## Overview

Honeycomb is the unified data distribution layer for Hivemind. It provides content-addressable storage with multi-tier caching, P2P distribution, and cross-region replication. The goal is sub-second cold starts for cached content and predictable pull times for uncached content.

### Design Principles

1. **Content-Addressable**: All content identified by cryptographic hash (SHA256)
2. **Lazy by Default**: Only pull what's needed, when needed (Nydus-style)
3. **Locality-Aware**: Prefer nearby sources (same node → same rack → same AZ → same region → origin)
4. **Eventually Consistent**: Regional caches sync asynchronously; origin is source of truth
5. **Bandwidth-Efficient**: P2P distribution reduces origin egress costs

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              HONEYCOMB                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         ORIGIN (Global)                          │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │ OCI Registry │  │  Metadata DB │  │   S3 Blob Storage    │   │    │
│  │  │     API      │  │   (Turso)    │  │  (Content-Addressed) │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                         Async Replication                                │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    REGIONAL CACHES (Per-Region)                  │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │ Cache Service│  │ Manifest DB  │  │   JuiceFS Backend    │   │    │
│  │  │  (OCI API)   │  │   (SQLite)   │  │  (S3 + Local SSD)    │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                            P2P Gossip                                    │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      NODE AGENTS (Per-Node)                      │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │  P2P Agent   │  │ Nydus Daemon │  │   Local SSD Cache    │   │    │
│  │  │ (BitTorrent) │  │ (Lazy Pull)  │  │   (/var/honeycomb)   │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Origin Service

The origin is the global source of truth for all content. It exposes an OCI Distribution API and stores blobs in S3.

#### OCI Registry API

```go
// Origin implements the OCI Distribution Specification v1.1
type Origin struct {
    metadata MetadataStore  // Turso for manifest/tag metadata
    blobs    BlobStore      // S3 for content-addressed blobs
    sync     SyncCoordinator // Cross-region replication
}

// Core endpoints (OCI Distribution Spec)
// GET  /v2/                                    # API version check
// GET  /v2/<name>/manifests/<reference>        # Pull manifest
// PUT  /v2/<name>/manifests/<reference>        # Push manifest
// GET  /v2/<name>/blobs/<digest>               # Pull blob
// POST /v2/<name>/blobs/uploads/               # Initiate blob upload
// PUT  /v2/<name>/blobs/uploads/<uuid>         # Complete blob upload
// HEAD /v2/<name>/blobs/<digest>               # Check blob exists
// GET  /v2/<name>/tags/list                    # List tags

// Honeycomb extensions
// GET  /v2/<name>/blobs/<digest>/locations     # Where is this cached?
// POST /v2/_honeycomb/preposition              # Request pre-positioning
// GET  /v2/_honeycomb/stats                    # Distribution statistics
```

#### Metadata Schema (Turso)

```sql
-- Image manifests
CREATE TABLE manifests (
    digest TEXT PRIMARY KEY,          -- sha256:...
    media_type TEXT NOT NULL,         -- application/vnd.oci.image.manifest.v1+json
    content BLOB NOT NULL,            -- JSON manifest
    size_bytes INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    config_digest TEXT,               -- Reference to config blob
    FOREIGN KEY (config_digest) REFERENCES blobs(digest)
);

-- Repository names and tags
CREATE TABLE repositories (
    name TEXT PRIMARY KEY,            -- project_id/image_name
    created_at INTEGER NOT NULL
);

CREATE TABLE tags (
    repository TEXT NOT NULL,
    tag TEXT NOT NULL,
    manifest_digest TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (repository, tag),
    FOREIGN KEY (repository) REFERENCES repositories(name),
    FOREIGN KEY (manifest_digest) REFERENCES manifests(digest)
);

-- Blob metadata (actual data in S3)
CREATE TABLE blobs (
    digest TEXT PRIMARY KEY,          -- sha256:...
    size_bytes INTEGER NOT NULL,
    media_type TEXT,
    upload_completed INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

-- Layer deduplication tracking
CREATE TABLE manifest_layers (
    manifest_digest TEXT NOT NULL,
    layer_digest TEXT NOT NULL,
    layer_index INTEGER NOT NULL,
    PRIMARY KEY (manifest_digest, layer_index),
    FOREIGN KEY (manifest_digest) REFERENCES manifests(digest),
    FOREIGN KEY (layer_digest) REFERENCES blobs(digest)
);

-- Cross-region sync state
CREATE TABLE sync_state (
    region TEXT NOT NULL,
    digest TEXT NOT NULL,
    sync_status TEXT NOT NULL,        -- pending, syncing, synced, failed
    last_attempt INTEGER,
    error_message TEXT,
    PRIMARY KEY (region, digest)
);
```

#### Blob Storage (S3)

```
s3://honeycomb-origin/
├── blobs/
│   └── sha256/
│       ├── ab/abcdef1234.../data     # Content-addressed blobs
│       └── cd/cdef5678.../data
└── uploads/
    └── <uuid>/                        # In-progress uploads
        ├── data
        └── metadata.json
```

### 2. Regional Cache Service

Each region runs a cache service that provides low-latency access to frequently-used content.

#### Cache Service

```go
type RegionalCache struct {
    upstream   *OriginClient      // Fallback to origin
    storage    *JuiceFSBackend    // JuiceFS for blob storage
    manifest   *SQLiteDB          // Local manifest cache
    peers      *PeerRegistry      // Other caches in region
    warmup     *WarmupScheduler   // Proactive warming
}

// Pull flow with tiered fallback
func (c *RegionalCache) GetBlob(ctx context.Context, digest string) (io.Reader, error) {
    // 1. Check local JuiceFS cache
    if blob, err := c.storage.Get(digest); err == nil {
        metrics.CacheHit("regional", digest)
        return blob, nil
    }

    // 2. Check peer caches in same region
    if peer := c.peers.FindWithBlob(digest); peer != nil {
        if blob, err := peer.Get(digest); err == nil {
            // Async: cache locally for future requests
            go c.storage.Put(digest, blob)
            metrics.CacheHit("peer", digest)
            return blob, nil
        }
    }

    // 3. Fall back to origin
    blob, err := c.upstream.GetBlob(ctx, digest)
    if err != nil {
        return nil, err
    }

    // Async: cache locally
    go c.storage.Put(digest, blob)
    metrics.CacheMiss(digest)
    return blob, nil
}
```

#### JuiceFS Backend Integration

Leverages existing JuiceFS infrastructure with S3 backend and local SSD caching.

```go
type JuiceFSBackend struct {
    mountPath   string            // /var/honeycomb/cache
    cacheGroup  string            // juicefs-cache-group
    s3Bucket    string            // Regional S3 bucket
}

// Storage layout
// /var/honeycomb/cache/
// ├── blobs/
// │   └── sha256/
// │       └── <digest>/data
// └── manifests/
//     └── <digest>.json
```

#### Cache Eviction Policy

```go
type EvictionPolicy struct {
    // Priority levels (higher = keep longer)
    // 0: Ephemeral (evict immediately when space needed)
    // 1: Normal (LRU eviction)
    // 2: Warm (recently pre-positioned)
    // 3: Hot (frequently accessed)
    // 4: Pinned (never evict, controlled by Hivemind)

    MaxCacheSize    int64         // Total cache size limit
    EvictionTarget  float64       // Evict until this % free (0.2 = 20%)
    MinAge          time.Duration // Don't evict content newer than this
}

func (e *EvictionPolicy) SelectForEviction(entries []CacheEntry) []CacheEntry {
    // Sort by: priority ASC, last_access ASC, size DESC
    sort.Slice(entries, func(i, j int) bool {
        if entries[i].Priority != entries[j].Priority {
            return entries[i].Priority < entries[j].Priority
        }
        if entries[i].LastAccess != entries[j].LastAccess {
            return entries[i].LastAccess.Before(entries[j].LastAccess)
        }
        return entries[i].Size > entries[j].Size
    })

    var toEvict []CacheEntry
    var freed int64
    target := int64(float64(e.MaxCacheSize) * e.EvictionTarget)

    for _, entry := range entries {
        if freed >= target {
            break
        }
        if entry.Priority >= PriorityPinned {
            continue // Never evict pinned content
        }
        if time.Since(entry.LastAccess) < e.MinAge {
            continue
        }
        toEvict = append(toEvict, entry)
        freed += entry.Size
    }

    return toEvict
}
```

### 3. Node P2P Agent

Each node runs a P2P agent that enables BitTorrent-style distribution and integrates with Nydus for lazy loading.

#### P2P Agent

```go
type P2PAgent struct {
    nodeID      string
    localCache  *LocalCache       // /var/honeycomb/node
    regional    *RegionalClient   // Regional cache fallback
    peers       *PeerSwarm        // Other nodes in cluster
    nydus       *NydusIntegration // Lazy-loading integration
    announcer   *ContentAnnouncer // Gossip what we have
}

// Content announcement via gossip
type ContentAnnouncement struct {
    NodeID    string
    Digest    string
    Available bool      // true = have it, false = evicted
    Timestamp time.Time
}

// Pull with P2P optimization
func (a *P2PAgent) Pull(ctx context.Context, digest string) error {
    // 1. Check local cache
    if a.localCache.Has(digest) {
        return nil
    }

    // 2. Find peers with content
    peers := a.peers.FindWithContent(digest)

    if len(peers) > 0 {
        // 3a. P2P download (parallel chunks from multiple peers)
        return a.downloadFromPeers(ctx, digest, peers)
    }

    // 3b. Fall back to regional cache
    return a.downloadFromRegional(ctx, digest)
}

// BitTorrent-style chunked download
func (a *P2PAgent) downloadFromPeers(ctx context.Context, digest string, peers []Peer) error {
    // Get chunk map from each peer
    chunkMaps := make(map[string]*ChunkMap)
    for _, peer := range peers {
        cm, err := peer.GetChunkMap(digest)
        if err == nil {
            chunkMaps[peer.ID] = cm
        }
    }

    // Download chunks in parallel from best sources
    chunks := planChunkDownload(chunkMaps)

    g, ctx := errgroup.WithContext(ctx)
    for _, chunk := range chunks {
        chunk := chunk
        g.Go(func() error {
            return a.downloadChunk(ctx, digest, chunk)
        })
    }

    if err := g.Wait(); err != nil {
        return err
    }

    // Verify integrity
    return a.localCache.Verify(digest)
}
```

#### Nydus Integration

Nydus enables on-demand loading of container image layers, pulling only the files actually accessed.

```go
type NydusIntegration struct {
    socket     string           // /run/nydus/api.sock
    cacheDir   string           // /var/lib/nydus/cache
    configPath string           // /etc/nydus/config.json
}

// Nydus configuration for Honeycomb backend
type NydusConfig struct {
    Device struct {
        Backend struct {
            Type   string `json:"type"`    // "honeycomb"
            Config struct {
                Endpoint   string `json:"endpoint"`   // Regional cache URL
                CacheDir   string `json:"cache_dir"`
                Timeout    int    `json:"timeout_ms"`
                RetryLimit int    `json:"retry_limit"`
            } `json:"config"`
        } `json:"backend"`
        Cache struct {
            Type   string `json:"type"`    // "filecache"
            Config struct {
                WorkDir string `json:"work_dir"`
            } `json:"config"`
        } `json:"cache"`
    } `json:"device"`
}

// Convert OCI image to Nydus format on push
func (n *NydusIntegration) ConvertToNydus(ctx context.Context, srcRef, dstRef string) error {
    // Use nydusify to convert
    cmd := exec.CommandContext(ctx,
        "nydusify", "convert",
        "--source", srcRef,
        "--target", dstRef,
        "--backend-type", "honeycomb",
        "--backend-config", n.configPath,
    )
    return cmd.Run()
}
```

### 4. Warmup Service

Proactively pre-positions content before it's needed, reducing cold start latency.

```go
type WarmupService struct {
    scheduler *WarmupScheduler
    regional  *RegionalCache
    metrics   *MetricsCollector
}

// Warmup request from Hivemind
type WarmupRequest struct {
    ContentID   string            // Manifest digest
    Regions     []string          // Target regions
    Priority    int               // 0-4, higher = more urgent
    Deadline    *time.Time        // Optional: must complete by
    Nodes       []string          // Optional: specific nodes
}

func (w *WarmupService) PrePosition(ctx context.Context, req WarmupRequest) error {
    // 1. Resolve manifest to list of layer digests
    manifest, err := w.regional.GetManifest(ctx, req.ContentID)
    if err != nil {
        return fmt.Errorf("resolve manifest: %w", err)
    }

    layers := manifest.Layers

    // 2. For each target region, ensure content is cached
    for _, region := range req.Regions {
        cache := w.regional.CacheForRegion(region)

        for _, layer := range layers {
            // Check if already cached
            if cache.Has(layer.Digest) {
                continue
            }

            // Schedule warmup job
            job := WarmupJob{
                Digest:   layer.Digest,
                Size:     layer.Size,
                Region:   region,
                Priority: req.Priority,
                Deadline: req.Deadline,
            }

            w.scheduler.Enqueue(job)
        }
    }

    return nil
}

// Warmup scheduler with priority queue
type WarmupScheduler struct {
    queue    *PriorityQueue[WarmupJob]
    workers  int
    regional *RegionalCache
}

func (s *WarmupScheduler) Run(ctx context.Context) {
    sem := make(chan struct{}, s.workers)

    for {
        select {
        case <-ctx.Done():
            return
        case sem <- struct{}{}:
            job, ok := s.queue.Pop()
            if !ok {
                <-sem
                time.Sleep(100 * time.Millisecond)
                continue
            }

            go func() {
                defer func() { <-sem }()
                s.executeWarmup(ctx, job)
            }()
        }
    }
}
```

### 5. Cross-Region Sync

Asynchronous replication from origin to regional caches.

```go
type SyncCoordinator struct {
    origin   *Origin
    regions  map[string]*RegionalCache
    queue    *SyncQueue
}

// Sync events
type SyncEvent struct {
    Type      string    // "manifest_push", "blob_push", "tag_update"
    Digest    string
    Regions   []string  // Target regions (empty = all)
    Priority  int
    CreatedAt time.Time
}

// Sync protocol
func (s *SyncCoordinator) ProcessEvent(ctx context.Context, event SyncEvent) error {
    switch event.Type {
    case "manifest_push":
        // Sync manifest and referenced blobs
        manifest, err := s.origin.GetManifest(ctx, event.Digest)
        if err != nil {
            return err
        }

        // Determine target regions
        regions := event.Regions
        if len(regions) == 0 {
            regions = s.allRegions()
        }

        // Sync to each region
        for _, region := range regions {
            cache := s.regions[region]

            // 1. Sync config blob
            if err := s.syncBlob(ctx, cache, manifest.Config.Digest); err != nil {
                return err
            }

            // 2. Sync layer blobs (parallel)
            g, ctx := errgroup.WithContext(ctx)
            for _, layer := range manifest.Layers {
                layer := layer
                g.Go(func() error {
                    return s.syncBlob(ctx, cache, layer.Digest)
                })
            }
            if err := g.Wait(); err != nil {
                return err
            }

            // 3. Sync manifest
            if err := cache.PutManifest(ctx, event.Digest, manifest); err != nil {
                return err
            }
        }

    case "tag_update":
        // Just update tag pointer, blobs already synced
        for _, region := range event.Regions {
            cache := s.regions[region]
            if err := cache.UpdateTag(ctx, event.Digest); err != nil {
                return err
            }
        }
    }

    return nil
}

// Bandwidth-efficient blob sync
func (s *SyncCoordinator) syncBlob(ctx context.Context, cache *RegionalCache, digest string) error {
    // Check if cache already has blob
    if cache.HasBlob(digest) {
        return nil
    }

    // Stream from origin to cache
    reader, err := s.origin.GetBlob(ctx, digest)
    if err != nil {
        return err
    }
    defer reader.Close()

    return cache.PutBlob(ctx, digest, reader)
}
```

## Hivemind Integration

Honeycomb exposes APIs for Hivemind to control content distribution.

### Hivemind → Honeycomb API

```go
// HoneycombClient is used by Hivemind to control content distribution
type HoneycombClient interface {
    // PrePosition requests content be cached in specific regions/nodes
    PrePosition(ctx context.Context, req PrePositionRequest) error

    // Evict removes content from specific nodes (for capacity management)
    Evict(ctx context.Context, req EvictRequest) error

    // SetPriority adjusts eviction priority (pin important content)
    SetPriority(ctx context.Context, contentID string, priority int) error

    // GetLocations returns nodes that have the content cached
    GetLocations(ctx context.Context, contentID string) ([]NodeLocation, error)

    // EstimatePullTime predicts how long it will take to pull content
    EstimatePullTime(ctx context.Context, contentID string, nodeID string) (time.Duration, error)

    // GetCapacity returns available cache space on a node
    GetCapacity(ctx context.Context, nodeID string) (int64, error)
}

type PrePositionRequest struct {
    ContentID string
    Regions   []string
    Nodes     []string          // Optional: specific nodes
    Priority  int
    Deadline  *time.Time
}

type EvictRequest struct {
    ContentID string
    Nodes     []string
    Reason    string            // For metrics/debugging
}

type NodeLocation struct {
    NodeID    string
    Region    string
    CacheType string            // "local", "regional", "origin"
    LastSeen  time.Time
}
```

### Honeycomb → Hivemind Callbacks

```go
// HivemindCallback notifies Hivemind of content events
type HivemindCallback interface {
    // OnContentCached called when content becomes available on a node
    OnContentCached(ctx context.Context, contentID string, nodeID string) error

    // OnContentEvicted called when content is removed from a node
    OnContentEvicted(ctx context.Context, contentID string, nodeID string) error

    // OnCacheCapacityLow called when node cache is running low
    OnCacheCapacityLow(ctx context.Context, nodeID string, available int64) error
}
```

## Observability

### Metrics

```go
// Key metrics for Honeycomb
var (
    // Cache hit rates
    cacheHits = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "honeycomb_cache_hits_total",
            Help: "Total cache hits by tier",
        },
        []string{"tier", "region"}, // tier: local, peer, regional, origin
    )

    cacheMisses = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "honeycomb_cache_misses_total",
            Help: "Total cache misses",
        },
        []string{"region"},
    )

    // Pull latency
    pullLatency = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "honeycomb_pull_latency_seconds",
            Help:    "Content pull latency",
            Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
        },
        []string{"tier", "region"},
    )

    // P2P efficiency
    p2pBytesTransferred = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "honeycomb_p2p_bytes_total",
            Help: "Bytes transferred via P2P",
        },
        []string{"direction", "region"}, // direction: sent, received
    )

    // Cache capacity
    cacheCapacityBytes = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "honeycomb_cache_capacity_bytes",
            Help: "Cache capacity",
        },
        []string{"region", "type"}, // type: total, used, available
    )

    // Sync lag
    syncLagSeconds = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "honeycomb_sync_lag_seconds",
            Help: "Replication lag from origin",
        },
        []string{"region"},
    )
)
```

### Tracing

```go
// Trace pull operations across tiers
func (c *RegionalCache) GetBlob(ctx context.Context, digest string) (io.Reader, error) {
    ctx, span := tracer.Start(ctx, "honeycomb.get_blob",
        trace.WithAttributes(
            attribute.String("digest", digest),
            attribute.String("region", c.region),
        ),
    )
    defer span.End()

    // ... pull logic with child spans for each tier
}
```

## Security

### Authentication

```go
// Registry authentication (reuse existing htpasswd mechanism)
type RegistryAuth struct {
    htpasswd  *htpasswd.File
    tokenTTL  time.Duration
}

// Docker registry authentication flow
// 1. Client requests /v2/ → 401 with WWW-Authenticate header
// 2. Client requests token from auth service with credentials
// 3. Client uses token in Authorization header for subsequent requests

func (a *RegistryAuth) Authenticate(r *http.Request) (*Identity, error) {
    // Check for Bearer token
    if token := extractBearerToken(r); token != "" {
        return a.validateToken(token)
    }

    // Check for Basic auth
    if username, password, ok := r.BasicAuth(); ok {
        if a.htpasswd.Verify(username, password) {
            return &Identity{Username: username}, nil
        }
    }

    return nil, ErrUnauthorized
}
```

### Authorization

```go
// Scope-based authorization (OCI distribution spec)
type AuthScope struct {
    Type    string   // "repository"
    Name    string   // "project_id/image_name"
    Actions []string // ["pull", "push"]
}

func (a *RegistryAuth) Authorize(identity *Identity, scope AuthScope) bool {
    // Project-based authorization
    projectID := extractProjectID(scope.Name)

    // Check if user has access to project
    // (integrate with existing Turso project_access table)
    return hasProjectAccess(identity.Username, projectID, scope.Actions)
}
```

### Network Security

```go
// P2P communication security
type P2PSecurity struct {
    // mTLS for P2P connections
    tlsConfig *tls.Config

    // Node identity verification
    nodeRegistry *NodeRegistry
}

// All P2P connections use mTLS with node certificates
func (s *P2PSecurity) DialPeer(ctx context.Context, peer Peer) (net.Conn, error) {
    return tls.DialWithDialer(
        &net.Dialer{Timeout: 5 * time.Second},
        "tcp",
        peer.Address,
        s.tlsConfig,
    )
}
```

## Implementation Phases

### Phase 2a: Origin Service (Week 1-2)

**Deliverables:**
- OCI Registry API implementation in Go
- S3 blob storage backend
- Turso metadata storage
- Basic push/pull functionality
- Authentication (htpasswd)

**Files:**
```
honeycomb/
├── cmd/
│   └── origin/
│       └── main.go
├── pkg/
│   ├── registry/
│   │   ├── api.go           # HTTP handlers
│   │   ├── blobs.go         # Blob operations
│   │   └── manifests.go     # Manifest operations
│   ├── storage/
│   │   ├── s3.go            # S3 backend
│   │   └── metadata.go      # Turso metadata
│   └── auth/
│       └── htpasswd.go      # Authentication
└── sql/
    └── schema.sql           # Turso schema
```

### Phase 2b: Regional Cache (Week 3-4)

**Deliverables:**
- Regional cache service
- JuiceFS backend integration
- Cache eviction policy
- Origin fallback

**Files:**
```
honeycomb/
├── cmd/
│   └── cache/
│       └── main.go
├── pkg/
│   ├── cache/
│   │   ├── service.go       # Cache service
│   │   ├── eviction.go      # Eviction policy
│   │   └── juicefs.go       # JuiceFS backend
│   └── sync/
│       └── coordinator.go   # Cross-region sync
```

### Phase 2c: P2P Agent (Week 5-6)

**Deliverables:**
- Node-level P2P agent (DaemonSet for now)
- Content gossip protocol
- BitTorrent-style chunk transfer
- Local SSD caching

**Files:**
```
honeycomb/
├── cmd/
│   └── agent/
│       └── main.go
├── pkg/
│   └── p2p/
│       ├── agent.go         # P2P agent
│       ├── gossip.go        # Content announcements
│       ├── transfer.go      # Chunk transfer
│       └── cache.go         # Local cache
```

### Phase 2d: Nydus Integration (Week 7-8)

**Deliverables:**
- Nydus backend for Honeycomb
- Image conversion pipeline
- Lazy-loading integration
- Performance validation

**Files:**
```
honeycomb/
├── pkg/
│   └── nydus/
│       ├── backend.go       # Honeycomb backend for Nydus
│       ├── convert.go       # Image conversion
│       └── config.go        # Configuration
```

## Migration from Current Infrastructure

### Compatibility Layer

The current registry infrastructure can be preserved during migration:

```go
// Proxy existing registry requests to Honeycomb
type CompatibilityProxy struct {
    honeycomb *Origin
    legacy    *LegacyRegistry  // Existing Docker registry
}

func (p *CompatibilityProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    // Check feature flag for gradual rollout
    if useHoneycomb(r) {
        p.honeycomb.ServeHTTP(w, r)
        return
    }

    p.legacy.ServeHTTP(w, r)
}
```

### Data Migration

```go
// Migrate existing images to Honeycomb
type Migrator struct {
    source      *LegacyRegistry
    destination *Origin
}

func (m *Migrator) MigrateRepository(ctx context.Context, repo string) error {
    // List all tags
    tags, err := m.source.ListTags(ctx, repo)
    if err != nil {
        return err
    }

    for _, tag := range tags {
        // Get manifest
        manifest, err := m.source.GetManifest(ctx, repo, tag)
        if err != nil {
            continue // Skip failed manifests
        }

        // Copy blobs
        for _, layer := range manifest.Layers {
            if !m.destination.HasBlob(layer.Digest) {
                blob, _ := m.source.GetBlob(ctx, layer.Digest)
                m.destination.PutBlob(ctx, layer.Digest, blob)
            }
        }

        // Copy config
        if !m.destination.HasBlob(manifest.Config.Digest) {
            config, _ := m.source.GetBlob(ctx, manifest.Config.Digest)
            m.destination.PutBlob(ctx, manifest.Config.Digest, config)
        }

        // Copy manifest and tag
        m.destination.PutManifest(ctx, repo, tag, manifest)
    }

    return nil
}
```

## Testing Strategy

### Unit Tests

```go
func TestCacheEviction(t *testing.T) {
    policy := &EvictionPolicy{
        MaxCacheSize:   1 << 30, // 1GB
        EvictionTarget: 0.2,
        MinAge:         time.Minute,
    }

    entries := []CacheEntry{
        {Digest: "a", Priority: 1, Size: 100 << 20, LastAccess: time.Now().Add(-time.Hour)},
        {Digest: "b", Priority: 2, Size: 200 << 20, LastAccess: time.Now().Add(-time.Minute)},
        {Digest: "c", Priority: 4, Size: 300 << 20, LastAccess: time.Now().Add(-time.Hour)}, // Pinned
    }

    toEvict := policy.SelectForEviction(entries)

    assert.Len(t, toEvict, 1)
    assert.Equal(t, "a", toEvict[0].Digest) // Lower priority, older
}
```

### Integration Tests

```go
func TestPullThroughCache(t *testing.T) {
    origin := setupTestOrigin(t)
    cache := setupTestCache(t, origin)

    // Push to origin
    digest := pushTestBlob(t, origin, []byte("test content"))

    // Pull through cache (should miss, then cache)
    content1, err := cache.GetBlob(context.Background(), digest)
    require.NoError(t, err)
    assert.Equal(t, []byte("test content"), readAll(content1))

    // Pull again (should hit cache)
    content2, err := cache.GetBlob(context.Background(), digest)
    require.NoError(t, err)
    assert.Equal(t, []byte("test content"), readAll(content2))

    // Verify metrics
    assert.Equal(t, int64(1), metrics.GetCacheHits("regional"))
    assert.Equal(t, int64(1), metrics.GetCacheMisses())
}
```

### Load Tests

```go
func TestP2PScaling(t *testing.T) {
    // Simulate 100 nodes pulling same content
    origin := setupTestOrigin(t)
    nodes := make([]*P2PAgent, 100)

    for i := range nodes {
        nodes[i] = setupTestAgent(t, origin)
    }

    // Push large blob to origin
    digest := pushTestBlob(t, origin, make([]byte, 100<<20)) // 100MB

    // Start pulls on all nodes simultaneously
    var wg sync.WaitGroup
    start := time.Now()

    for _, node := range nodes {
        wg.Add(1)
        go func(n *P2PAgent) {
            defer wg.Done()
            err := n.Pull(context.Background(), digest)
            require.NoError(t, err)
        }(node)
    }

    wg.Wait()
    elapsed := time.Since(start)

    // With P2P, should complete much faster than 100 sequential pulls
    // Single pull ~1s, P2P should allow parallel transfer
    assert.Less(t, elapsed, 10*time.Second)
}
```

---

## Technology Choice

### Language: Zig (Core) + Go (OCI API)

**Decision**: Dual-language architecture

Honeycomb has two distinct parts with different requirements:
1. **Core P2P/Distribution** - Needs DST for protocol correctness
2. **OCI Registry API** - Standard HTTP API, benefits from mature ecosystem

#### Core P2P/Distribution: Zig

| Factor | Zig Advantage |
|--------|---------------|
| **P2P protocol DST** | BitTorrent-style distribution needs deterministic testing of peer behavior |
| **Cache coordination** | Regional cache eviction and sync may need consensus |
| **Network simulation** | Must test partial failures, slow peers, network partitions |
| **Performance** | Layer transfer is latency-sensitive; no GC pauses |
| **Memory efficiency** | Chunk buffers, peer tables should have bounded allocation |

**Key P2P scenarios requiring DST:**
- Peer discovery under network partitions
- Chunk availability during node failures
- Cache eviction under memory pressure
- Supernode election and failover

#### OCI Registry API: Go

| Factor | Go Advantage |
|--------|--------------|
| **OCI spec compliance** | distribution/distribution is the reference implementation |
| **S3 client** | aws-sdk-go-v2 is mature and well-documented |
| **HTTP handling** | Standard OCI v2 API is straightforward HTTP |
| **Team familiarity** | API layer is CRUD-like, Go fits well |
| **Testing** | OCI conformance tests are easier to run against Go implementation |

#### Why Not Single Language?

| Consideration | Analysis |
|---------------|----------|
| **All Go** | P2P protocol correctness can't be verified without DST |
| **All Zig** | OCI API is standard HTTP; Zig HTTP ecosystem less mature than Go |
| **All Rust** | Splits the difference poorly - DST difficult, ecosystem less mature than Go |

#### Architecture Split

```
┌─────────────────────────────────────────────────────────────────┐
│                        HONEYCOMB                                  │
│                                                                  │
│   ┌─────────────────────────────┐                               │
│   │    OCI Registry API (Go)    │  ← Standard HTTP, team knows Go │
│   │                             │                               │
│   │  - Manifest operations      │                               │
│   │  - Auth/authz               │                               │
│   │  - S3 layer storage         │                               │
│   └─────────────┬───────────────┘                               │
│                 │                                                │
│                 │ Internal API (gRPC or Unix socket)            │
│                 ▼                                                │
│   ┌─────────────────────────────┐                               │
│   │   P2P Distribution (Zig)    │  ← DST-critical, needs simulation │
│   │                             │                               │
│   │  - Peer discovery           │                               │
│   │  - Chunk distribution       │                               │
│   │  - Regional sync            │                               │
│   │  - Cache management         │                               │
│   └─────────────────────────────┘                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Decision Rationale

The OCI API layer is well-defined and standard—Go's ecosystem advantage matters here. The P2P distribution layer is novel and correctness-critical—DST capability matters here.

This split:
1. Reduces Zig surface area to where it's truly needed
2. Allows team to move fast on OCI API with familiar tools
3. Ensures P2P protocol can be exhaustively tested
4. Enables independent scaling/deployment of API vs P2P

**Alternative consideration**: Could start with Go-only implementation, then port P2P to Zig once protocol stabilizes. This reduces initial complexity but delays DST capability.

### Key Libraries

**Go (OCI API):**
```
OCI Registry:    distribution/distribution (reference)
Storage:         aws-sdk-go-v2/service/s3
Database:        turso-go
HTTP:            net/http
Metrics:         prometheus/client_golang
```

**Zig (P2P Core):**
```
Networking:      Custom with DST interfaces
Protocol:        Custom BitTorrent-style
Storage:         std.fs with bounded buffers
IPC:             Unix domain sockets or gRPC via C
```

---

## Configuration

### Origin Configuration

```yaml
# honeycomb-origin.yaml
server:
  address: ":5000"
  tls:
    cert: /etc/honeycomb/tls/cert.pem
    key: /etc/honeycomb/tls/key.pem

storage:
  type: s3
  s3:
    bucket: honeycomb-origin
    region: us-east-1
    prefix: blobs/

metadata:
  type: turso
  turso:
    url: ${TURSO_URL}
    token: ${TURSO_TOKEN}

auth:
  htpasswd: /etc/honeycomb/htpasswd

sync:
  regions:
    - us-east-1
    - us-west-2
    - eu-west-1
  batch_size: 100
  workers: 10
```

### Regional Cache Configuration

```yaml
# honeycomb-cache.yaml
server:
  address: ":5000"

upstream:
  url: https://origin.honeycomb.internal
  timeout: 30s

storage:
  type: juicefs
  juicefs:
    mount_path: /var/honeycomb/cache
    cache_size: 100Gi

cache:
  max_size: 100Gi
  eviction_target: 0.2
  min_age: 1m

peers:
  discovery: dns
  dns_name: honeycomb-cache.honeycomb.svc.cluster.local
```

### P2P Agent Configuration

```yaml
# honeycomb-agent.yaml
node_id: ${NODE_NAME}

regional:
  url: https://cache.honeycomb.internal
  timeout: 10s

local_cache:
  path: /var/honeycomb/node
  max_size: 50Gi

p2p:
  listen: ":6881"
  announce_interval: 30s
  max_peers: 50

nydus:
  enabled: true
  socket: /run/nydus/api.sock
  config: /etc/nydus/config.json
```

## Appendix: Existing Infrastructure Reference

### JuiceFS (from juicefs.tf)
- CSI driver deployed via Helm
- S3 backend with regional bucket
- Local SSD caching via cache groups
- Warmup jobs for pre-positioning
- Storage classes: `juicefs-common`, `juicefs-serverless`

### Registry (from registry.tf)
- Per-cluster Docker registry
- JuiceFS backend storage
- htpasswd authentication
- Knative service for scaling

### Nydus (from bootstrap_nydus.tftpl)
- Installed on nodes via bootstrap
- Lazy-loading enabled
- JuiceFS cache integration

### Dragonfly (from p2p-registry/)
- Designed but not deployed
- Supernode + daemon architecture
- Can be referenced for P2P patterns
