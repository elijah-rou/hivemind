> **LEGACY**: Phase 3 vision document. The Beekeeper build system is not yet implemented. Current platform uses Depot.

# Beekeeper Technical Design

**Phase 3 of Hivemind Migration**
**Status**: Draft
**Dependency**: Phase 2 (Honeycomb) stable

## Overview

Beekeeper replaces Depot with an in-house build system. It transforms user code into container images optimized for serverless execution and pushes them to Honeycomb. The goal is cost reduction (no Depot fees), tighter integration with the platform, and custom optimizations for AI workloads.

### Design Principles

1. **BuildKit-Native**: Use BuildKit directly, same as Depot does internally
2. **Cache Everything**: Distributed layer cache across all builds
3. **Honeycomb-First**: Deep integration with Honeycomb for image storage
4. **Serverless-Optimized**: Build optimizations specific to serverless AI
5. **Observable**: Rich metrics for build times, cache efficiency, layer sizes

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              BEEKEEPER                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      BEEKEEPER API                               │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │ Build Queue  │  │  Status API  │  │   Logs Streaming     │   │    │
│  │  │   (SQS/RQ)   │  │   (REST)     │  │   (WebSocket)        │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                              Job Assignment                              │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    BUILD CLUSTER                                 │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │  Builder 1   │  │  Builder 2   │  │    Builder N         │   │    │
│  │  │  (BuildKit)  │  │  (BuildKit)  │  │    (BuildKit)        │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                              Shared Cache                                │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                 DISTRIBUTED CACHE (S3 + Local)                   │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │ Layer Cache  │  │  Git Cache   │  │  Dependency Cache    │   │    │
│  │  │  (S3-backed) │  │ (EFS/JuiceFS)│  │  (pip/conda/apt)     │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                              Image Push                                  │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    HONEYCOMB ORIGIN                              │    │
│  │                  (OCI Registry + S3)                             │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Current State Analysis

### Depot Integration (Current)

From `dashboard-backend/go-build-service/src/libs/depot/depot.go`:

```go
// Current flow:
// 1. Register build with Depot cloud
// 2. Acquire BuildKit machine from Depot pool
// 3. Connect to BuildKit and solve
// 4. Push to per-cluster registry
// 5. Stream logs to ClickHouse via Redpanda

func KickOffBuild(ctx context.Context, config BuildConfig) (string, int64, error) {
    // Write Docker config with registry credentials
    docker.WriteDockerConfig(config.RegistryEndpoint, config.RegistryPassword)

    // Register with Depot cloud
    build, err := depotBuild.NewBuild(ctx, req, os.Getenv("DEPOT_TOKEN"))

    // Acquire a BuildKit machine (this is what costs money)
    buildkit, err := machine.Acquire(ctx, build.ID, build.Token, "amd64")

    // Connect and solve
    buildkitClient, err := buildkit.Connect(connectCtx)
    _, err = buildkitClient.Solve(ctx, nil, solverOptions, buildLogsCh)
}
```

**What Depot Provides:**
- Managed BuildKit instances with fast cold start
- Persistent layer cache across builds
- Automatic scaling based on demand
- Build orchestration and queueing

**What Beekeeper Must Replace:**
- BuildKit instance management
- Layer cache distribution
- Build queueing and assignment
- Machine acquisition latency optimization

## Component Details

### 1. Beekeeper API

The API receives build requests and manages the build lifecycle.

```go
// Build request from CLI/dashboard
type BuildRequest struct {
    ProjectID       string            `json:"project_id"`
    AppID           string            `json:"app_id"`
    BuildID         string            `json:"build_id"`
    Source          BuildSource       `json:"source"`
    Config          AppConfig   `json:"config"`
    Dockerfile      *string           `json:"dockerfile,omitempty"`     // Custom Dockerfile
    DockerAuth      *DockerAuth       `json:"docker_auth,omitempty"`    // Private registry auth
}

type BuildSource struct {
    Type     string `json:"type"`      // "upload", "git", "s3"
    URL      string `json:"url"`       // Git URL or S3 path
    Ref      string `json:"ref"`       // Git branch/tag/commit
    UploadID string `json:"upload_id"` // For upload type
}

type AppConfig struct {
    PythonVersion   string            `json:"python_version"`
    BaseImage       string            `json:"base_image"`
    AptPackages     []string          `json:"apt_packages"`
    CondaPackages   []string          `json:"conda_packages"`
    PipPackages     []string          `json:"pip_packages"`
    PreBuildCmds    []string          `json:"pre_build_commands"`
    ShellCmds       []string          `json:"shell_commands"`
    UseUv           bool              `json:"use_uv"`
    Hardware        HardwareConfig    `json:"hardware"`
}
```

#### API Endpoints

```go
// Beekeeper API service
type BeekeeperAPI struct {
    queue       BuildQueue
    builders    BuilderPool
    honeycomb   *HoneycombClient
    db          *TursoDB
}

// Endpoints
// POST /v1/builds                    # Submit new build
// GET  /v1/builds/{id}               # Get build status
// GET  /v1/builds/{id}/logs          # Stream build logs (WebSocket)
// POST /v1/builds/{id}/cancel        # Cancel build
// GET  /v1/builds/{id}/artifacts     # Get build artifacts (manifest digest)

func (api *BeekeeperAPI) SubmitBuild(ctx context.Context, req BuildRequest) (*Build, error) {
    // 1. Validate request
    if err := req.Validate(); err != nil {
        return nil, err
    }

    // 2. Create build record
    build := &Build{
        ID:        req.BuildID,
        ProjectID: req.ProjectID,
        AppID:     req.AppID,
        Status:    BuildStatusPending,
        CreatedAt: time.Now(),
    }

    if err := api.db.CreateBuild(ctx, build); err != nil {
        return nil, err
    }

    // 3. Enqueue for processing
    if err := api.queue.Enqueue(ctx, req); err != nil {
        api.db.UpdateBuildStatus(ctx, build.ID, BuildStatusFailed)
        return nil, err
    }

    return build, nil
}
```

### 2. Build Queue

Manages build job distribution to available builders.

```go
type BuildQueue interface {
    Enqueue(ctx context.Context, req BuildRequest) error
    Dequeue(ctx context.Context) (*BuildRequest, error)
    Acknowledge(ctx context.Context, buildID string) error
    Requeue(ctx context.Context, buildID string) error
}

// SQS-based queue for production
type SQSBuildQueue struct {
    client    *sqs.Client
    queueURL  string
    visibilityTimeout time.Duration
}

func (q *SQSBuildQueue) Enqueue(ctx context.Context, req BuildRequest) error {
    body, err := json.Marshal(req)
    if err != nil {
        return err
    }

    _, err = q.client.SendMessage(ctx, &sqs.SendMessageInput{
        QueueUrl:    &q.queueURL,
        MessageBody: aws.String(string(body)),
        MessageAttributes: map[string]types.MessageAttributeValue{
            "ProjectID": {
                DataType:    aws.String("String"),
                StringValue: &req.ProjectID,
            },
            "Priority": {
                DataType:    aws.String("Number"),
                StringValue: aws.String(strconv.Itoa(req.Priority)),
            },
        },
    })
    return err
}
```

### 3. Builder Pool

Manages a pool of BuildKit instances that execute builds.

```go
type BuilderPool struct {
    builders    []*Builder
    assignments map[string]*Builder  // buildID → builder
    mu          sync.RWMutex
    metrics     *BuilderMetrics
}

type Builder struct {
    ID          string
    Address     string              // BuildKit address
    Client      *client.Client      // BuildKit client
    Status      BuilderStatus       // idle, building, draining
    CurrentBuild *string
    CacheSize   int64
    LastUsed    time.Time
}

type BuilderStatus string
const (
    BuilderStatusIdle     BuilderStatus = "idle"
    BuilderStatusBuilding BuilderStatus = "building"
    BuilderStatusDraining BuilderStatus = "draining"
)

// Acquire a builder for a build
func (p *BuilderPool) Acquire(ctx context.Context, buildID string) (*Builder, error) {
    p.mu.Lock()
    defer p.mu.Unlock()

    // Find idle builder with best cache affinity
    var best *Builder
    var bestScore int

    for _, b := range p.builders {
        if b.Status != BuilderStatusIdle {
            continue
        }

        // Score based on cache state (higher = better)
        score := p.calculateCacheAffinity(ctx, b, buildID)
        if best == nil || score > bestScore {
            best = b
            bestScore = score
        }
    }

    if best == nil {
        return nil, ErrNoAvailableBuilder
    }

    best.Status = BuilderStatusBuilding
    best.CurrentBuild = &buildID
    p.assignments[buildID] = best

    return best, nil
}

// Release a builder after build completes
func (p *BuilderPool) Release(ctx context.Context, buildID string) {
    p.mu.Lock()
    defer p.mu.Unlock()

    if builder, ok := p.assignments[buildID]; ok {
        builder.Status = BuilderStatusIdle
        builder.CurrentBuild = nil
        builder.LastUsed = time.Now()
        delete(p.assignments, buildID)
    }
}
```

### 4. Build Executor

The core build execution logic, using BuildKit directly.

```go
type BuildExecutor struct {
    pool        *BuilderPool
    cache       *DistributedCache
    honeycomb   *HoneycombClient
    logs        *LogStreamer
}

type BuildResult struct {
    Digest      string            // Image manifest digest
    Size        int64             // Total image size
    Layers      []LayerInfo       // Layer information
    Duration    time.Duration     // Build duration
    CacheStats  CacheStats        // Cache hit/miss stats
}

type LayerInfo struct {
    Digest string
    Size   int64
    Cached bool
}

type CacheStats struct {
    LayerHits   int
    LayerMisses int
    CacheSize   int64
}

func (e *BuildExecutor) Execute(ctx context.Context, req BuildRequest) (*BuildResult, error) {
    // 1. Acquire a builder
    builder, err := e.pool.Acquire(ctx, req.BuildID)
    if err != nil {
        return nil, fmt.Errorf("failed to acquire builder: %w", err)
    }
    defer e.pool.Release(ctx, req.BuildID)

    // 2. Prepare build context
    buildCtx, err := e.prepareBuildContext(ctx, req)
    if err != nil {
        return nil, fmt.Errorf("failed to prepare build context: %w", err)
    }
    defer buildCtx.Cleanup()

    // 3. Generate or use provided Dockerfile
    dockerfile, err := e.resolveDockerfile(ctx, req, buildCtx)
    if err != nil {
        return nil, fmt.Errorf("failed to resolve dockerfile: %w", err)
    }

    // 4. Configure BuildKit solve options
    solveOpt := e.buildSolveOptions(req, buildCtx, dockerfile)

    // 5. Create log channel
    logsCh := make(chan *client.SolveStatus, 10000)
    go e.logs.Stream(ctx, req.BuildID, logsCh)

    // 6. Execute build
    result, err := builder.Client.Solve(ctx, nil, solveOpt, logsCh)
    if err != nil {
        return nil, fmt.Errorf("build failed: %w", err)
    }

    // 7. Extract build result
    digest := result.ExporterResponse["containerimage.digest"]

    return &BuildResult{
        Digest:   digest,
        Duration: time.Since(buildCtx.StartTime),
    }, nil
}

func (e *BuildExecutor) buildSolveOptions(req BuildRequest, buildCtx *BuildContext, dockerfile string) client.SolveOpt {
    // Honeycomb registry endpoint
    registryEndpoint := e.honeycomb.RegistryEndpoint()
    imageName := fmt.Sprintf("%s/%s/%s", registryEndpoint, req.ProjectID, req.AppID)

    exportAttrs := map[string]string{
        "name":              imageName,
        "push":              "true",
        "oci-mediatypes":    "true",
        "force-compression": "true",
    }

    // Enable Nydus compression for lazy loading
    if req.Config.Hardware.RequiresLazyLoading() {
        exportAttrs["compression"] = "nydus"
    }

    return client.SolveOpt{
        Frontend: "dockerfile.v0",
        FrontendAttrs: map[string]string{
            "filename": "Dockerfile",
            "platform": "linux/amd64",
        },
        LocalDirs: map[string]string{
            "context":    buildCtx.Path,
            "dockerfile": buildCtx.Path,
        },
        Session: []session.Attachable{
            authprovider.NewDockerAuthProvider(authprovider.DockerAuthProviderConfig{
                ConfigFile: e.honeycomb.DockerConfig(),
            }),
        },
        CacheExports: []client.CacheOptionsEntry{
            {
                Type: "s3",
                Attrs: map[string]string{
                    "bucket": e.cache.Bucket(),
                    "region": e.cache.Region(),
                    "prefix": fmt.Sprintf("cache/%s/", req.ProjectID),
                },
            },
        },
        CacheImports: []client.CacheOptionsEntry{
            {
                Type: "s3",
                Attrs: map[string]string{
                    "bucket": e.cache.Bucket(),
                    "region": e.cache.Region(),
                    "prefix": fmt.Sprintf("cache/%s/", req.ProjectID),
                },
            },
            // Also import from global cache for base layers
            {
                Type: "s3",
                Attrs: map[string]string{
                    "bucket": e.cache.Bucket(),
                    "region": e.cache.Region(),
                    "prefix": "cache/global/",
                },
            },
        },
        Exports: []client.ExportEntry{
            {
                Type:  "image",
                Attrs: exportAttrs,
            },
        },
    }
}
```

### 5. Distributed Cache

S3-backed layer cache shared across all builders.

```go
type DistributedCache struct {
    s3Client   *s3.Client
    bucket     string
    region     string
    localCache string  // Local SSD cache directory
}

// Cache key structure:
// s3://beekeeper-cache/
// ├── cache/
// │   ├── global/           # Shared base layers (python, cuda, etc.)
// │   │   └── sha256/
// │   │       └── <digest>
// │   └── <project_id>/     # Per-project layers
// │       └── sha256/
// │           └── <digest>
// └── git/                   # Git repository cache
//     └── <repo_hash>/

func (c *DistributedCache) Bucket() string {
    return c.bucket
}

func (c *DistributedCache) Region() string {
    return c.region
}

// Warm cache for common base images
func (c *DistributedCache) WarmGlobalCache(ctx context.Context) error {
    baseImages := []string{
        "python:3.10-slim",
        "python:3.11-slim",
        "nvidia/cuda:12.1-runtime-ubuntu22.04",
        // ... other common bases
    }

    for _, image := range baseImages {
        if err := c.pullAndCacheImage(ctx, image); err != nil {
            log.Printf("Warning: failed to cache %s: %v", image, err)
        }
    }

    return nil
}
```

### 6. Dockerfile Generator

Generates optimized Dockerfiles from app.toml configuration.

```go
type DockerfileGenerator struct {
    templates *template.Template
}

type DockerfileContext struct {
    BaseImage       string
    PythonVersion   string
    AptPackages     []string
    CondaPackages   []string
    PipPackages     []string
    PreBuildCmds    []string
    ShellCmds       []string
    UseUv           bool
    RegistryEndpoint string
}

func (g *DockerfileGenerator) Generate(ctx context.Context, config AppConfig) (string, error) {
    tmplCtx := DockerfileContext{
        BaseImage:     g.resolveBaseImage(config),
        PythonVersion: config.PythonVersion,
        AptPackages:   config.AptPackages,
        CondaPackages: config.CondaPackages,
        PipPackages:   config.PipPackages,
        PreBuildCmds:  config.PreBuildCmds,
        ShellCmds:     config.ShellCmds,
        UseUv:         config.UseUv,
    }

    var buf bytes.Buffer
    if err := g.templates.ExecuteTemplate(&buf, "dockerfile.tmpl", tmplCtx); err != nil {
        return "", err
    }

    return buf.String(), nil
}

// Optimized Dockerfile template
var dockerfileTemplate = `
# syntax=docker/dockerfile:1.4
ARG HIVEMIND_BASE_IMAGE={{.BaseImage}}

FROM ${HIVEMIND_BASE_IMAGE} AS base

# Install apt packages (cached layer)
{{- if .AptPackages}}
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
    {{range .AptPackages}}{{.}} {{end}} \
    && rm -rf /var/lib/apt/lists/*
{{- end}}

# Install conda packages (cached layer)
{{- if .CondaPackages}}
RUN --mount=type=cache,target=/opt/conda/pkgs \
    conda install -y {{range .CondaPackages}}{{.}} {{end}}
{{- end}}

# Install pip packages (cached layer)
{{- if .PipPackages}}
{{- if .UseUv}}
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system {{range .PipPackages}}{{.}} {{end}}
{{- else}}
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install {{range .PipPackages}}{{.}} {{end}}
{{- end}}
{{- end}}

# Pre-build commands
{{- range .PreBuildCmds}}
RUN {{.}}
{{- end}}

# Copy application code (changes frequently, at end)
COPY app /app
WORKDIR /app

# Shell commands (run at container start)
{{- range .ShellCmds}}
# {{.}}
{{- end}}
`
```

### 7. Log Streamer

Streams build logs to clients and persists to ClickHouse.

```go
type LogStreamer struct {
    redpanda *redpanda.Producer
    wsHub    *WebSocketHub
}

type BuildLog struct {
    BuildID     string    `json:"build_id"`
    Timestamp   time.Time `json:"timestamp"`
    LineNumber  int       `json:"line_number"`
    Stage       string    `json:"stage"`
    Log         string    `json:"log"`
    Stream      string    `json:"stream"`  // stdout, stderr
}

func (s *LogStreamer) Stream(ctx context.Context, buildID string, logsCh <-chan *client.SolveStatus) {
    lineNum := 0
    stageTracker := NewStageTracker()

    for status := range logsCh {
        // Track build stages from vertices
        for _, vertex := range status.Vertexes {
            stageTracker.ProcessVertex(vertex)
        }

        // Process log entries
        for _, log := range status.Logs {
            if log == nil || len(log.Data) == 0 {
                continue
            }

            stage := stageTracker.GetStage(string(log.Vertex))
            lines := strings.Split(string(log.Data), "\n")

            for _, line := range lines {
                if line == "" {
                    continue
                }

                buildLog := BuildLog{
                    BuildID:    buildID,
                    Timestamp:  time.Now(),
                    LineNumber: lineNum,
                    Stage:      stage,
                    Log:        s.filterLog(line),
                    Stream:     "stdout",
                }
                lineNum++

                // Send to WebSocket clients
                s.wsHub.Broadcast(buildID, buildLog)

                // Persist to Redpanda/ClickHouse
                s.redpanda.Send(ctx, "build-logs", buildLog)
            }
        }
    }
}

func (s *LogStreamer) filterLog(line string) string {
    // Apply same filtering as current Depot integration
    // Remove internal build noise, keep user-relevant logs
    // See depot.go filterLogs() for current implementation
    return filterBuildLog(line)
}
```

## Honeycomb Integration

Beekeeper pushes built images directly to Honeycomb origin.

```go
type HoneycombClient struct {
    endpoint   string
    authToken  string
    httpClient *http.Client
}

// Push notification after successful build
type BuildCompleteNotification struct {
    ProjectID   string    `json:"project_id"`
    AppID       string    `json:"app_id"`
    BuildID     string    `json:"build_id"`
    Digest      string    `json:"digest"`
    Size        int64     `json:"size"`
    Layers      []string  `json:"layers"`
    Tags        []string  `json:"tags"`
    CompletedAt time.Time `json:"completed_at"`
}

func (c *HoneycombClient) NotifyBuildComplete(ctx context.Context, notif BuildCompleteNotification) error {
    // Notify Honeycomb that a new image is available
    // Honeycomb can then trigger pre-positioning to likely deployment regions
    body, _ := json.Marshal(notif)

    req, _ := http.NewRequestWithContext(ctx, "POST",
        fmt.Sprintf("%s/v2/_honeycomb/build-complete", c.endpoint),
        bytes.NewReader(body),
    )
    req.Header.Set("Authorization", "Bearer "+c.authToken)
    req.Header.Set("Content-Type", "application/json")

    resp, err := c.httpClient.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("honeycomb notification failed: %d", resp.StatusCode)
    }

    return nil
}

// Docker config for BuildKit authentication to Honeycomb registry
func (c *HoneycombClient) DockerConfig() *configfile.ConfigFile {
    cfg := configfile.New("")
    cfg.AuthConfigs[c.endpoint] = dockerTypes.AuthConfig{
        Username: "beekeeper",
        Password: c.authToken,
    }
    return cfg
}

func (c *HoneycombClient) RegistryEndpoint() string {
    return c.endpoint
}
```

## Build Optimizations

### Layer Ordering

Optimize layer order for better caching:

```go
type LayerOptimizer struct{}

// Optimal layer order (least changing → most changing):
// 1. Base image (python, cuda)
// 2. System packages (apt)
// 3. Conda packages
// 4. Pip packages (with cache mount)
// 5. Pre-build commands
// 6. Application code (changes every deploy)

func (o *LayerOptimizer) OptimizeDockerfile(dockerfile string) string {
    // Reorder RUN commands for optimal caching
    // Ensure apt-get, pip install use cache mounts
    // Move COPY app to end
    return optimized
}
```

### Dependency Deduplication

Share common dependencies across projects:

```go
type DependencyDeduplicator struct {
    commonPackages map[string]string  // package → layer digest
}

// Track common packages across builds
func (d *DependencyDeduplicator) AnalyzeDependencies(ctx context.Context, config AppConfig) []string {
    // Identify packages that are commonly used
    // These can be pre-cached in global cache
    common := []string{}

    for _, pkg := range config.PipPackages {
        if d.isCommon(pkg) {
            common = append(common, pkg)
        }
    }

    return common
}

// Common AI/ML packages that should be globally cached
var commonPackages = []string{
    "torch", "torchvision", "torchaudio",
    "transformers", "diffusers", "accelerate",
    "numpy", "pandas", "scikit-learn",
    "tensorflow", "keras",
    "opencv-python", "pillow",
    "fastapi", "uvicorn",
    "pydantic", "requests",
}
```

### Pre-compilation

AOT compile Python for faster cold starts:

```go
type Precompiler struct{}

func (p *Precompiler) AddPrecompilationStep(dockerfile string) string {
    // Add step to compile .py to .pyc
    precompileStep := `
# Pre-compile Python files for faster startup
RUN python -m compileall -b /app
`
    return dockerfile + precompileStep
}
```

## Observability

### Metrics

```go
var (
    buildDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "beekeeper_build_duration_seconds",
            Help:    "Build duration in seconds",
            Buckets: []float64{10, 30, 60, 120, 300, 600, 1200},
        },
        []string{"project_id", "status"},
    )

    builderAcquisitionTime = prometheus.NewHistogram(
        prometheus.HistogramOpts{
            Name:    "beekeeper_builder_acquisition_seconds",
            Help:    "Time to acquire a builder",
            Buckets: []float64{0.1, 0.5, 1, 2, 5, 10, 30},
        },
    )

    cacheHitRate = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "beekeeper_cache_hit_rate",
            Help: "Layer cache hit rate",
        },
        []string{"project_id", "cache_type"}, // cache_type: global, project
    )

    imageSize = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "beekeeper_image_size_bytes",
            Help:    "Built image size in bytes",
            Buckets: []float64{100e6, 500e6, 1e9, 2e9, 5e9, 10e9, 20e9},
        },
        []string{"project_id"},
    )

    buildQueueDepth = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "beekeeper_queue_depth",
            Help: "Number of builds waiting in queue",
        },
    )

    activeBuilders = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "beekeeper_active_builders",
            Help: "Number of builders currently executing builds",
        },
    )
)
```

### Tracing

```go
func (e *BuildExecutor) Execute(ctx context.Context, req BuildRequest) (*BuildResult, error) {
    ctx, span := tracer.Start(ctx, "beekeeper.build",
        trace.WithAttributes(
            attribute.String("project_id", req.ProjectID),
            attribute.String("app_id", req.AppID),
            attribute.String("build_id", req.BuildID),
        ),
    )
    defer span.End()

    // ... build execution with child spans for each phase
}
```

## Deployment Architecture

### Builder Nodes

```yaml
# builder-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beekeeper-builder
spec:
  replicas: 5
  selector:
    matchLabels:
      app: beekeeper-builder
  template:
    metadata:
      labels:
        app: beekeeper-builder
    spec:
      nodeSelector:
        hivemind.dev/workload: BUILD
      containers:
      - name: buildkitd
        image: moby/buildkit:latest
        securityContext:
          privileged: true
        ports:
        - containerPort: 1234
          name: buildkit
        volumeMounts:
        - name: cache
          mountPath: /var/lib/buildkit
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
          limits:
            cpu: "8"
            memory: "32Gi"
      volumes:
      - name: cache
        hostPath:
          path: /var/beekeeper/cache
          type: DirectoryOrCreate
```

### API Service

```yaml
# api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beekeeper-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: beekeeper-api
  template:
    spec:
      containers:
      - name: api
        image: hivemind/beekeeper-api:latest
        ports:
        - containerPort: 8080
        env:
        - name: BUILDER_POOL_ADDRESSES
          value: "beekeeper-builder-0:1234,beekeeper-builder-1:1234,..."
        - name: CACHE_BUCKET
          value: "beekeeper-cache"
        - name: HONEYCOMB_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: beekeeper-secrets
              key: honeycomb-endpoint
```

## Migration Strategy

### Phase 3a: Parallel Deployment (Week 1-2)

Deploy Beekeeper alongside Depot without routing traffic:

```go
// Feature flag for gradual rollout
func selectBuildBackend(projectID string) string {
    // Check feature flag
    if featureflags.IsEnabled("beekeeper", projectID) {
        return "beekeeper"
    }
    return "depot"
}

// Build handler routes to appropriate backend
func HandleBuild(ctx context.Context, req BuildRequest) error {
    backend := selectBuildBackend(req.ProjectID)

    switch backend {
    case "beekeeper":
        return beekeeperClient.Build(ctx, req)
    case "depot":
        return depotClient.Build(ctx, req)
    }
}
```

### Phase 3b: Canary Testing (Week 3-4)

Route a small percentage of builds to Beekeeper:

```go
// Canary routing
func selectBuildBackend(projectID string) string {
    // 5% canary to Beekeeper
    if hash(projectID) % 100 < 5 {
        return "beekeeper"
    }
    return "depot"
}
```

### Phase 3c: Gradual Migration (Week 5-6)

Increase Beekeeper traffic while monitoring:

```go
// Monitor and compare
type BuildComparison struct {
    Backend       string
    Duration      time.Duration
    CacheHitRate  float64
    ImageSize     int64
    Success       bool
}

func compareBuildMetrics(depot, beekeeper BuildComparison) {
    // Alert if Beekeeper is significantly worse
    if beekeeper.Duration > depot.Duration*1.5 {
        alert("Beekeeper builds 50% slower than Depot")
    }
    if beekeeper.CacheHitRate < depot.CacheHitRate*0.8 {
        alert("Beekeeper cache hit rate 20% lower than Depot")
    }
}
```

### Phase 3d: Full Migration (Week 7-8)

Route all traffic to Beekeeper, deprecate Depot:

```go
// Final cutover
func selectBuildBackend(projectID string) string {
    // All traffic to Beekeeper
    return "beekeeper"
}

// Depot integration can be removed after validation period
```

## Testing Strategy

### Unit Tests

```go
func TestDockerfileGeneration(t *testing.T) {
    gen := NewDockerfileGenerator()

    config := AppConfig{
        PythonVersion: "3.11",
        PipPackages:   []string{"torch", "transformers"},
        UseUv:         true,
    }

    dockerfile, err := gen.Generate(context.Background(), config)
    require.NoError(t, err)

    assert.Contains(t, dockerfile, "python:3.11")
    assert.Contains(t, dockerfile, "uv pip install")
    assert.Contains(t, dockerfile, "torch")
}
```

### Integration Tests

```go
func TestEndToEndBuild(t *testing.T) {
    api := setupTestAPI(t)

    req := BuildRequest{
        ProjectID: "test-project",
        AppID:     "test-app",
        BuildID:   "test-build-1",
        Source: BuildSource{
            Type: "upload",
            // ... test build context
        },
        Config: AppConfig{
            PythonVersion: "3.11",
            PipPackages:   []string{"fastapi"},
        },
    }

    build, err := api.SubmitBuild(context.Background(), req)
    require.NoError(t, err)

    // Wait for completion
    result := waitForBuild(t, api, build.ID, 5*time.Minute)

    assert.Equal(t, BuildStatusSuccess, result.Status)
    assert.NotEmpty(t, result.Digest)
}
```

### Load Tests

```go
func TestBuildConcurrency(t *testing.T) {
    api := setupTestAPI(t)

    // Submit 50 concurrent builds
    var wg sync.WaitGroup
    results := make(chan *Build, 50)

    for i := 0; i < 50; i++ {
        wg.Add(1)
        go func(idx int) {
            defer wg.Done()

            req := BuildRequest{
                BuildID:   fmt.Sprintf("load-test-%d", idx),
                ProjectID: fmt.Sprintf("project-%d", idx%10),
                // ... minimal config
            }

            build, err := api.SubmitBuild(context.Background(), req)
            if err == nil {
                results <- build
            }
        }(i)
    }

    wg.Wait()
    close(results)

    // Verify all builds completed
    completed := 0
    for build := range results {
        result := waitForBuild(t, api, build.ID, 10*time.Minute)
        if result.Status == BuildStatusSuccess {
            completed++
        }
    }

    assert.GreaterOrEqual(t, completed, 45) // 90% success rate minimum
}
```

## Configuration

```yaml
# beekeeper-config.yaml
api:
  address: ":8080"
  tls:
    enabled: true
    cert: /etc/beekeeper/tls/cert.pem
    key: /etc/beekeeper/tls/key.pem

queue:
  type: sqs
  sqs:
    queue_url: ${SQS_QUEUE_URL}
    visibility_timeout: 600s  # 10 minutes
    max_receive_count: 3

builders:
  pool_size: 10
  buildkit:
    address_pattern: "beekeeper-builder-{n}:1234"
  timeout: 30m

cache:
  type: s3
  s3:
    bucket: beekeeper-cache
    region: us-east-1
    global_prefix: cache/global/
    project_prefix: cache/

honeycomb:
  endpoint: https://registry.honeycomb.internal
  auth_token: ${HONEYCOMB_TOKEN}

logs:
  redpanda:
    brokers: ${REDPANDA_BROKERS}
    topic: build-logs
  websocket:
    enabled: true

metrics:
  prometheus:
    enabled: true
    port: 9090
```

## Technology Choice

### Language: Go

**Decision**: Go

Beekeeper is an orchestration layer around BuildKit. It doesn't require deterministic simulation testing—builds are independent operations with clear success/failure outcomes.

#### Why Go?

| Factor | Go Advantage |
|--------|--------------|
| **Team familiarity** | Team already uses Go for Lambda API and CLI |
| **BuildKit integration** | Official BuildKit client libraries are in Go |
| **Kubernetes client** | client-go is mature and well-documented |
| **Rapid iteration** | Fast compile times, easy debugging |
| **Mature ecosystem** | HTTP servers, SQS clients, S3 SDKs all well-tested |

#### Why Not Zig?

| Factor | Zig Consideration |
|--------|-------------------|
| **No DST requirement** | Builds are independent operations—no complex state machine or consensus |
| **BuildKit bindings** | Would need to write FFI bindings or shell out to buildctl |
| **AWS SDK** | No official Zig SDK; would need to use REST APIs directly |
| **Learning curve** | Investment not justified for orchestration layer |

#### Why Not Rust?

| Factor | Rust Consideration |
|--------|-------------------|
| **BuildKit client** | Less mature than Go client |
| **AWS SDK** | aws-sdk-rust exists but less mature than Go SDK |
| **Complexity** | Borrow checker adds overhead for what is essentially CRUD + job queue |

#### Decision Rationale

Beekeeper's job is simple: receive build requests, queue them, dispatch to BuildKit workers, track status, push results. This is classic orchestration:

1. **No complex state to simulate** - Builds either succeed or fail
2. **No consensus needed** - SQS provides ordering, DynamoDB provides state
3. **External systems do heavy lifting** - BuildKit handles actual building

Go's ecosystem fit (BuildKit client, K8s client, AWS SDK) and team familiarity make it the clear choice. The team's Go expertise means faster delivery without sacrificing quality.

### Key Libraries (Go)

```
Build Engine:    github.com/moby/buildkit/client
HTTP Server:     net/http or gin
Queue:           aws-sdk-go-v2/service/sqs
Storage:         aws-sdk-go-v2/service/s3
Database:        turso-go or go-sqlite3
Metrics:         prometheus/client_golang
Logging:         zerolog
```

---

## Appendix: Cost Analysis

### Depot Costs (Current)

- Per-build minute pricing
- Persistent cache storage fees
- Higher costs for GPU builds

### Beekeeper Costs (Projected)

- Fixed infrastructure: EC2 instances for builders
- S3 storage for cache
- Compute: ~$X/month for N builders
- Storage: ~$Y/month for cache

### Break-even Analysis

```
Depot monthly cost = (avg_builds/day * 30) * avg_build_minutes * price_per_minute
Beekeeper monthly cost = infrastructure_fixed + storage_variable

Break-even when: Depot_cost > Beekeeper_cost
```

Assuming:
- 1000 builds/day
- 5 min average build time
- 10 builder nodes at $500/month each
- S3 cache: ~$100/month

Beekeeper becomes cost-effective at scale while providing:
- Tighter platform integration
- Custom optimization opportunities
- No vendor dependency
