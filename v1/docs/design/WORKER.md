# Battery-Included Node Worker Technical Design

**Phase 5 of Hivemind Migration**
**Status**: Draft
**Dependency**: Phase 4 (Hivemind Control Plane) stable

## Overview

The Hivemind Node Worker replaces the current DaemonSet sprawl with a single binary that provides all node-level capabilities. It runs as a systemd service on each node, starting before the kubelet (initially), and eventually becoming the sole node management component.

### Design Principles

1. **Single Binary**: One process replaces 6+ DaemonSets
2. **Feature Flags**: Enable/disable capabilities per node type
3. **OS-Level Integration**: Runs as systemd, not a container
4. **Graceful Migration**: Coexist with DaemonSets during transition
5. **Fast Bootstrap**: Node ready in seconds, not minutes

## What Gets Replaced

| Current (DaemonSets) | Worker Module | Risk Level |
|---------------------|--------------|------------|
| NVIDIA device plugin | GPU Module | High |
| DCGM exporter | Metrics Module | Low |
| Fluent Bit | Logs Module | Medium |
| Node exporter | Metrics Module | Low |
| JuiceFS CSI | Storage Module | Medium |
| P2P worker (new) | P2P Module | Low |
| VPC CNI (future) | Network Module | High |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       HIVEMIND NODE WORKER                                │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                        WORKER CORE                                │   │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │   │
│   │  │   Config     │  │   Health     │  │   Control Plane      │   │   │
│   │  │   Manager    │  │   Monitor    │  │   Connection         │   │   │
│   │  └──────────────┘  └──────────────┘  └──────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│           ┌────────────────────────┼────────────────────────┐           │
│           │                        │                        │           │
│           ▼                        ▼                        ▼           │
│   ┌──────────────┐         ┌──────────────┐         ┌──────────────┐   │
│   │   METRICS    │         │    LOGS      │         │     P2P      │   │
│   │   MODULE     │         │   MODULE     │         │   MODULE     │   │
│   │              │         │              │         │              │   │
│   │ • Node stats │         │ • Container  │         │ • BitTorrent │   │
│   │ • GPU (DCGM) │         │   log tail   │         │ • Gossip     │   │
│   │ • Process    │         │ • Metadata   │         │ • Local      │   │
│   │ • Network    │         │ • ClickHouse │         │   cache      │   │
│   └──────────────┘         └──────────────┘         └──────────────┘   │
│           │                        │                        │           │
│           ▼                        ▼                        ▼           │
│   ┌──────────────┐         ┌──────────────┐         ┌──────────────┐   │
│   │   STORAGE    │         │     GPU      │         │   NETWORK    │   │
│   │   MODULE     │         │   MODULE     │         │   MODULE     │   │
│   │              │         │              │         │   (future)   │   │
│   │ • JuiceFS    │         │ • Device     │         │              │   │
│   │   mounts     │         │   plugin     │         │ • CNI        │   │
│   │ • Cache      │         │ • Health     │         │ • IP mgmt    │   │
│   │   management │         │ • NVML       │         │ • Routing    │   │
│   └──────────────┘         └──────────────┘         └──────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Worker Core

The core provides shared infrastructure for all modules.

```go
// Main worker binary
package main

import (
    "context"
    "os"
    "os/signal"
    "syscall"

    "github.com/elijahrou/hivemind/v1/worker/config"
    "github.com/elijahrou/hivemind/v1/worker/core"
    "github.com/elijahrou/hivemind/v1/worker/modules/gpu"
    "github.com/elijahrou/hivemind/v1/worker/modules/logs"
    "github.com/elijahrou/hivemind/v1/worker/modules/metrics"
    "github.com/elijahrou/hivemind/v1/worker/modules/p2p"
    "github.com/elijahrou/hivemind/v1/worker/modules/storage"
)

func main() {
    cfg, err := config.Load()
    if err != nil {
        log.Fatal(err)
    }

    worker := core.NewWorker(cfg)

    // Register modules based on feature flags
    if cfg.Modules.Metrics.Enabled {
        worker.RegisterModule(metrics.New(cfg.Modules.Metrics))
    }
    if cfg.Modules.Logs.Enabled {
        worker.RegisterModule(logs.New(cfg.Modules.Logs))
    }
    if cfg.Modules.P2P.Enabled {
        worker.RegisterModule(p2p.New(cfg.Modules.P2P))
    }
    if cfg.Modules.Storage.Enabled {
        worker.RegisterModule(storage.New(cfg.Modules.Storage))
    }
    if cfg.Modules.GPU.Enabled {
        worker.RegisterModule(gpu.New(cfg.Modules.GPU))
    }

    // Start worker
    ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
    defer cancel()

    if err := worker.Run(ctx); err != nil {
        log.Fatal(err)
    }
}
```

### Worker Core Implementation

```go
package core

type Worker struct {
    config     *config.WorkerConfig
    modules    []Module
    controlPlane *ControlPlaneClient
    health     *HealthMonitor
}

type Module interface {
    Name() string
    Start(ctx context.Context) error
    Stop(ctx context.Context) error
    Health() HealthStatus
}

type HealthStatus struct {
    Healthy bool
    Message string
    LastCheck time.Time
}

func NewWorker(cfg *config.WorkerConfig) *Worker {
    return &Worker{
        config:     cfg,
        modules:    make([]Module, 0),
        controlPlane: NewControlPlaneClient(cfg.ControlPlane),
        health:     NewHealthMonitor(),
    }
}

func (a *Worker) RegisterModule(m Module) {
    a.modules = append(a.modules, m)
    a.health.RegisterModule(m.Name())
}

func (a *Worker) Run(ctx context.Context) error {
    // Register with control plane
    if err := a.controlPlane.Register(ctx, a.nodeInfo()); err != nil {
        return fmt.Errorf("failed to register with control plane: %w", err)
    }

    // Start all modules
    g, ctx := errgroup.WithContext(ctx)

    for _, m := range a.modules {
        module := m
        g.Go(func() error {
            log.Printf("Starting module: %s", module.Name())
            if err := module.Start(ctx); err != nil {
                return fmt.Errorf("module %s failed: %w", module.Name(), err)
            }
            return nil
        })
    }

    // Start health reporting
    g.Go(func() error {
        return a.runHealthReporter(ctx)
    })

    // Start control plane heartbeat
    g.Go(func() error {
        return a.controlPlane.RunHeartbeat(ctx)
    })

    return g.Wait()
}

func (a *Worker) runHealthReporter(ctx context.Context) error {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return nil
        case <-ticker.C:
            status := a.collectHealthStatus()
            if err := a.controlPlane.ReportHealth(ctx, status); err != nil {
                log.Printf("Failed to report health: %v", err)
            }
        }
    }
}

func (a *Worker) collectHealthStatus() NodeHealthStatus {
    status := NodeHealthStatus{
        NodeID:    a.config.NodeID,
        Timestamp: time.Now(),
        Modules:   make(map[string]HealthStatus),
    }

    for _, m := range a.modules {
        status.Modules[m.Name()] = m.Health()
    }

    return status
}
```

## Module Implementations

### 1. Metrics Module

Replaces: Node Exporter, DCGM Exporter

```go
package metrics

type MetricsModule struct {
    config    *MetricsConfig
    collectors []Collector
    exporter  *prometheus.Exporter
}

type Collector interface {
    Name() string
    Collect(ctx context.Context) ([]Metric, error)
}

type MetricsConfig struct {
    Port           int           `yaml:"port"`
    ScrapeInterval time.Duration `yaml:"scrape_interval"`
    EnableNode     bool          `yaml:"enable_node"`
    EnableGPU      bool          `yaml:"enable_gpu"`
    EnableProcess  bool          `yaml:"enable_process"`
    EnableNetwork  bool          `yaml:"enable_network"`
}

func New(cfg *MetricsConfig) *MetricsModule {
    m := &MetricsModule{
        config:    cfg,
        collectors: make([]Collector, 0),
    }

    if cfg.EnableNode {
        m.collectors = append(m.collectors, &NodeCollector{})
    }
    if cfg.EnableGPU {
        m.collectors = append(m.collectors, &GPUCollector{})
    }
    if cfg.EnableProcess {
        m.collectors = append(m.collectors, &ProcessCollector{})
    }
    if cfg.EnableNetwork {
        m.collectors = append(m.collectors, &NetworkCollector{})
    }

    return m
}

func (m *MetricsModule) Name() string { return "metrics" }

func (m *MetricsModule) Start(ctx context.Context) error {
    // Start Prometheus exporter
    m.exporter = prometheus.NewExporter(m.config.Port)

    // Register collectors
    for _, c := range m.collectors {
        prometheus.MustRegister(c)
    }

    // Start HTTP server
    go func() {
        if err := m.exporter.ListenAndServe(); err != nil {
            log.Printf("Metrics exporter error: %v", err)
        }
    }()

    <-ctx.Done()
    return m.exporter.Shutdown(ctx)
}

// GPU metrics using NVML (replaces DCGM exporter)
type GPUCollector struct {
    nvml nvml.Interface
}

func (c *GPUCollector) Describe(ch chan<- *prometheus.Desc) {
    ch <- gpuUtilizationDesc
    ch <- gpuMemoryUsedDesc
    ch <- gpuTemperatureDesc
    ch <- gpuPowerUsageDesc
}

var (
    gpuUtilizationDesc = prometheus.NewDesc(
        "hivemind_gpu_utilization_percent",
        "GPU utilization percentage",
        []string{"gpu", "uuid"},
        nil,
    )
    gpuMemoryUsedDesc = prometheus.NewDesc(
        "hivemind_gpu_memory_used_bytes",
        "GPU memory used in bytes",
        []string{"gpu", "uuid"},
        nil,
    )
    gpuTemperatureDesc = prometheus.NewDesc(
        "hivemind_gpu_temperature_celsius",
        "GPU temperature in Celsius",
        []string{"gpu", "uuid"},
        nil,
    )
    gpuPowerUsageDesc = prometheus.NewDesc(
        "hivemind_gpu_power_usage_watts",
        "GPU power usage in watts",
        []string{"gpu", "uuid"},
        nil,
    )
)

func (c *GPUCollector) Collect(ch chan<- prometheus.Metric) {
    count, err := c.nvml.DeviceGetCount()
    if err != nil {
        return
    }

    for i := 0; i < int(count); i++ {
        device, err := c.nvml.DeviceGetHandleByIndex(i)
        if err != nil {
            continue
        }

        uuid, _ := device.GetUUID()
        name := fmt.Sprintf("gpu%d", i)

        // Utilization
        util, _ := device.GetUtilizationRates()
        ch <- prometheus.MustNewConstMetric(
            gpuUtilizationDesc,
            prometheus.GaugeValue,
            float64(util.Gpu),
            name, uuid,
        )

        // Memory
        mem, _ := device.GetMemoryInfo()
        ch <- prometheus.MustNewConstMetric(
            gpuMemoryUsedDesc,
            prometheus.GaugeValue,
            float64(mem.Used),
            name, uuid,
        )

        // Temperature
        temp, _ := device.GetTemperature(nvml.TEMPERATURE_GPU)
        ch <- prometheus.MustNewConstMetric(
            gpuTemperatureDesc,
            prometheus.GaugeValue,
            float64(temp),
            name, uuid,
        )

        // Power
        power, _ := device.GetPowerUsage()
        ch <- prometheus.MustNewConstMetric(
            gpuPowerUsageDesc,
            prometheus.GaugeValue,
            float64(power)/1000, // Convert mW to W
            name, uuid,
        )
    }
}

// Node metrics (replaces node_exporter)
type NodeCollector struct{}

func (c *NodeCollector) Collect(ch chan<- prometheus.Metric) {
    // CPU
    cpuTimes, _ := cpu.Times(true)
    for i, ct := range cpuTimes {
        ch <- prometheus.MustNewConstMetric(
            cpuSecondsDesc, prometheus.CounterValue,
            ct.User, fmt.Sprintf("cpu%d", i), "user",
        )
        ch <- prometheus.MustNewConstMetric(
            cpuSecondsDesc, prometheus.CounterValue,
            ct.System, fmt.Sprintf("cpu%d", i), "system",
        )
        ch <- prometheus.MustNewConstMetric(
            cpuSecondsDesc, prometheus.CounterValue,
            ct.Idle, fmt.Sprintf("cpu%d", i), "idle",
        )
    }

    // Memory
    mem, _ := mem.VirtualMemory()
    ch <- prometheus.MustNewConstMetric(
        memoryBytesDesc, prometheus.GaugeValue,
        float64(mem.Total), "total",
    )
    ch <- prometheus.MustNewConstMetric(
        memoryBytesDesc, prometheus.GaugeValue,
        float64(mem.Available), "available",
    )
    ch <- prometheus.MustNewConstMetric(
        memoryBytesDesc, prometheus.GaugeValue,
        float64(mem.Used), "used",
    )

    // Disk
    partitions, _ := disk.Partitions(false)
    for _, p := range partitions {
        usage, _ := disk.Usage(p.Mountpoint)
        ch <- prometheus.MustNewConstMetric(
            diskBytesDesc, prometheus.GaugeValue,
            float64(usage.Total), p.Device, p.Mountpoint, "total",
        )
        ch <- prometheus.MustNewConstMetric(
            diskBytesDesc, prometheus.GaugeValue,
            float64(usage.Used), p.Device, p.Mountpoint, "used",
        )
    }

    // Network
    netIO, _ := net.IOCounters(true)
    for _, n := range netIO {
        ch <- prometheus.MustNewConstMetric(
            networkBytesDesc, prometheus.CounterValue,
            float64(n.BytesRecv), n.Name, "receive",
        )
        ch <- prometheus.MustNewConstMetric(
            networkBytesDesc, prometheus.CounterValue,
            float64(n.BytesSent), n.Name, "transmit",
        )
    }
}
```

### 2. Logs Module

Replaces: Fluent Bit

```go
package logs

type LogsModule struct {
    config     *LogsConfig
    tailer     *Tailer
    processor  *LogProcessor
    outputs    []Output
}

type LogsConfig struct {
    ContainerLogPath string            `yaml:"container_log_path"`
    BufferSize       int               `yaml:"buffer_size"`
    FlushInterval    time.Duration     `yaml:"flush_interval"`
    Outputs          OutputsConfig     `yaml:"outputs"`
    Filters          []FilterConfig    `yaml:"filters"`
}

type Output interface {
    Name() string
    Write(ctx context.Context, logs []LogEntry) error
}

type LogEntry struct {
    Timestamp   time.Time         `json:"timestamp"`
    Log         string            `json:"log"`
    Stream      string            `json:"stream"`      // stdout, stderr
    AppID       string            `json:"app_id"`
    PodName     string            `json:"pod_name"`
    Namespace   string            `json:"k8s_namespace"`
    ContainerID string            `json:"container_id"`
    RunID       string            `json:"run_id,omitempty"`
    BuildID     string            `json:"build_id,omitempty"`
    Region      string            `json:"region"`
    Cluster     string            `json:"cluster_name"`
}

func New(cfg *LogsConfig) *LogsModule {
    m := &LogsModule{
        config:    cfg,
        tailer:    NewTailer(cfg.ContainerLogPath),
        processor: NewLogProcessor(cfg.Filters),
        outputs:   make([]Output, 0),
    }

    // Initialize outputs
    if cfg.Outputs.ClickHouse.Enabled {
        m.outputs = append(m.outputs, NewClickHouseOutput(cfg.Outputs.ClickHouse))
    }
    if cfg.Outputs.Redpanda.Enabled {
        m.outputs = append(m.outputs, NewRedpandaOutput(cfg.Outputs.Redpanda))
    }

    return m
}

func (m *LogsModule) Name() string { return "logs" }

func (m *LogsModule) Start(ctx context.Context) error {
    // Start tailing container logs
    logCh := m.tailer.Start(ctx)

    // Buffer for batching
    buffer := make([]LogEntry, 0, m.config.BufferSize)
    ticker := time.NewTicker(m.config.FlushInterval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            // Flush remaining logs
            m.flush(ctx, buffer)
            return nil

        case entry := <-logCh:
            // Process and filter
            processed, include := m.processor.Process(entry)
            if !include {
                continue
            }

            buffer = append(buffer, processed)

            // Flush if buffer full
            if len(buffer) >= m.config.BufferSize {
                m.flush(ctx, buffer)
                buffer = buffer[:0]
            }

        case <-ticker.C:
            // Periodic flush
            if len(buffer) > 0 {
                m.flush(ctx, buffer)
                buffer = buffer[:0]
            }
        }
    }
}

func (m *LogsModule) flush(ctx context.Context, logs []LogEntry) {
    for _, output := range m.outputs {
        if err := output.Write(ctx, logs); err != nil {
            log.Printf("Failed to write to %s: %v", output.Name(), err)
        }
    }
}

// Container log tailer
type Tailer struct {
    logPath string
    tailers map[string]*tail.Tail
    mu      sync.RWMutex
}

func (t *Tailer) Start(ctx context.Context) <-chan RawLogEntry {
    ch := make(chan RawLogEntry, 1000)

    // Watch for new log files
    go t.watchLogFiles(ctx, ch)

    return ch
}

func (t *Tailer) watchLogFiles(ctx context.Context, ch chan<- RawLogEntry) {
    watcher, _ := fsnotify.NewWatcher()
    watcher.Add(t.logPath)

    // Tail existing files
    files, _ := filepath.Glob(filepath.Join(t.logPath, "*.log"))
    for _, f := range files {
        t.startTailing(ctx, f, ch)
    }

    for {
        select {
        case <-ctx.Done():
            return
        case event := <-watcher.Events:
            if event.Op&fsnotify.Create == fsnotify.Create {
                if strings.HasSuffix(event.Name, ".log") {
                    t.startTailing(ctx, event.Name, ch)
                }
            }
        }
    }
}

// ClickHouse output (replaces Fluent Bit HTTP output)
type ClickHouseOutput struct {
    config *ClickHouseConfig
    client *http.Client
}

func (o *ClickHouseOutput) Write(ctx context.Context, logs []LogEntry) error {
    // Convert to JSON lines
    var buf bytes.Buffer
    encoder := json.NewEncoder(&buf)
    for _, log := range logs {
        encoder.Encode(log)
    }

    // Send to ClickHouse
    url := fmt.Sprintf("https://%s:8443/?query=INSERT+INTO+default.app_logs+FORMAT+JSONEachRow&async_insert=1",
        o.config.Host)

    req, _ := http.NewRequestWithContext(ctx, "POST", url, &buf)
    req.SetBasicAuth("default", o.config.Password)
    req.Header.Set("Content-Encoding", "gzip")

    resp, err := o.client.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("clickhouse returned %d", resp.StatusCode)
    }

    return nil
}

// Log processor with Kubernetes metadata enrichment
type LogProcessor struct {
    filters     []Filter
    k8sClient   *kubernetes.Clientset
    podCache    *lru.Cache
}

func (p *LogProcessor) Process(entry RawLogEntry) (LogEntry, bool) {
    // Parse container log format
    // Format: "2025-01-01T00:00:00.000000000Z stdout F log message"
    parts := strings.SplitN(entry.Line, " ", 4)
    if len(parts) < 4 {
        return LogEntry{}, false
    }

    timestamp, _ := time.Parse(time.RFC3339Nano, parts[0])
    stream := parts[1]
    logContent := parts[3]

    // Extract pod info from filename
    // Format: {pod_name}_{namespace}_{container_name}-{container_id}.log
    podInfo := p.extractPodInfo(entry.Filename)

    // Get Kubernetes metadata
    k8sMeta := p.getK8sMetadata(podInfo.PodName, podInfo.Namespace)

    processed := LogEntry{
        Timestamp:   timestamp,
        Log:         logContent,
        Stream:      stream,
        AppID:       k8sMeta.AppID,
        PodName:     podInfo.PodName,
        Namespace:   podInfo.Namespace,
        ContainerID: podInfo.ContainerID,
        RunID:       k8sMeta.RunID,
        BuildID:     k8sMeta.BuildID,
        Region:      p.region,
        Cluster:     p.cluster,
    }

    // Apply filters
    for _, f := range p.filters {
        if !f.Match(processed) {
            return LogEntry{}, false
        }
    }

    return processed, true
}
```

### 3. P2P Module

Integrates with Honeycomb for content distribution.

```go
package p2p

type P2PModule struct {
    config     *P2PConfig
    localCache *LocalCache
    swarm      *PeerSwarm
    honeycomb  *HoneycombClient
    announcer  *ContentAnnouncer
}

type P2PConfig struct {
    ListenPort      int           `yaml:"listen_port"`
    CachePath       string        `yaml:"cache_path"`
    MaxCacheSize    int64         `yaml:"max_cache_size"`
    AnnounceInterval time.Duration `yaml:"announce_interval"`
    HoneycombURL    string        `yaml:"honeycomb_url"`
}

func (m *P2PModule) Name() string { return "p2p" }

func (m *P2PModule) Start(ctx context.Context) error {
    // Initialize local cache
    m.localCache = NewLocalCache(m.config.CachePath, m.config.MaxCacheSize)

    // Start peer swarm
    m.swarm = NewPeerSwarm(m.config.ListenPort)
    if err := m.swarm.Start(ctx); err != nil {
        return err
    }

    // Start content announcer
    m.announcer = NewContentAnnouncer(m.localCache, m.swarm)
    go m.announcer.Run(ctx, m.config.AnnounceInterval)

    // Handle pull requests from control plane
    go m.handlePullRequests(ctx)

    <-ctx.Done()
    return nil
}

func (m *P2PModule) handlePullRequests(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            return
        case req := <-m.pullRequests:
            go m.handlePull(ctx, req)
        }
    }
}

func (m *P2PModule) handlePull(ctx context.Context, req PullRequest) {
    // Check local cache first
    if m.localCache.Has(req.Digest) {
        req.ResponseCh <- PullResponse{Success: true, FromCache: true}
        return
    }

    // Find peers with content
    peers := m.swarm.FindPeersWithContent(req.Digest)

    if len(peers) > 0 {
        // Download from peers
        if err := m.downloadFromPeers(ctx, req.Digest, peers); err == nil {
            req.ResponseCh <- PullResponse{Success: true, FromPeers: true}
            return
        }
    }

    // Fall back to Honeycomb regional cache
    if err := m.downloadFromHoneycomb(ctx, req.Digest); err != nil {
        req.ResponseCh <- PullResponse{Success: false, Error: err}
        return
    }

    req.ResponseCh <- PullResponse{Success: true, FromHoneycomb: true}
}

func (m *P2PModule) downloadFromPeers(ctx context.Context, digest string, peers []Peer) error {
    // BitTorrent-style chunked download
    // ... implementation similar to Honeycomb P2P worker
    return nil
}
```

### 4. Storage Module

Replaces: JuiceFS CSI driver, mount pods

Supports two storage types:
- **JuiceFS (shared)**: For serverless workloads, shared across replicas
- **Block Storage (workspace)**: For instances, persistent per-instance storage

See [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) for workspace storage design.

```go
package storage

type StorageModule struct {
    config      *StorageConfig
    juicefs     *JuiceFSManager
    workspace   *WorkspaceManager  // NEW: For instance workspaces
    mounts      map[string]*Mount
    blockMounts map[string]*BlockMount  // NEW: Block storage mounts
    mu          sync.RWMutex
}

type StorageConfig struct {
    // JuiceFS (shared storage)
    JuiceFSMeta    string `yaml:"juicefs_meta"`     // Redis URL
    JuiceFSStorage string `yaml:"juicefs_storage"`  // S3 URL
    CachePath      string `yaml:"cache_path"`
    CacheSize      int64  `yaml:"cache_size"`

    // Workspace Block Storage (instances)
    WorkspaceEnabled bool   `yaml:"workspace_enabled"`
    WorkspaceDriver  string `yaml:"workspace_driver"`  // "ebs", "local-nvme", "juicefs-block"
    WorkspaceBasePath string `yaml:"workspace_base_path"`
}

type Mount struct {
    Path       string
    ProjectID  string
    MountTime  time.Time
    Process    *os.Process
}

func (m *StorageModule) Name() string { return "storage" }

func (m *StorageModule) Start(ctx context.Context) error {
    // Initialize JuiceFS
    m.juicefs = NewJuiceFSManager(m.config)

    // Listen for mount requests from control plane
    go m.handleMountRequests(ctx)

    <-ctx.Done()
    return m.cleanup()
}

func (m *StorageModule) Mount(ctx context.Context, req MountRequest) error {
    m.mu.Lock()
    defer m.mu.Unlock()

    // Check if already mounted
    if _, exists := m.mounts[req.MountPath]; exists {
        return nil
    }

    // Create mount point
    if err := os.MkdirAll(req.MountPath, 0755); err != nil {
        return err
    }

    // Mount JuiceFS
    proc, err := m.juicefs.Mount(ctx, JuiceFSMountOptions{
        Name:       req.ProjectID,
        MountPoint: req.MountPath,
        CacheDir:   filepath.Join(m.config.CachePath, req.ProjectID),
        CacheSize:  req.CacheSize,
        SubDir:     req.SubDir,
    })
    if err != nil {
        return err
    }

    m.mounts[req.MountPath] = &Mount{
        Path:      req.MountPath,
        ProjectID: req.ProjectID,
        MountTime: time.Now(),
        Process:   proc,
    }

    return nil
}

func (m *StorageModule) Unmount(ctx context.Context, mountPath string) error {
    m.mu.Lock()
    defer m.mu.Unlock()

    mount, exists := m.mounts[mountPath]
    if !exists {
        return nil
    }

    // Unmount
    if err := m.juicefs.Unmount(ctx, mountPath); err != nil {
        return err
    }

    // Cleanup
    delete(m.mounts, mountPath)
    mount.Process.Kill()

    return nil
}

// JuiceFS manager wraps juicefs binary
type JuiceFSManager struct {
    config *StorageConfig
}

func (j *JuiceFSManager) Mount(ctx context.Context, opts JuiceFSMountOptions) (*os.Process, error) {
    args := []string{
        "mount",
        j.config.JuiceFSMeta,
        opts.MountPoint,
        "--cache-dir", opts.CacheDir,
        "--cache-size", fmt.Sprintf("%d", opts.CacheSize/1024/1024), // MB
        "--subdir", opts.SubDir,
        "--background",
        "--no-usage-report",
    }

    cmd := exec.CommandContext(ctx, "juicefs", args...)
    if err := cmd.Start(); err != nil {
        return nil, err
    }

    return cmd.Process, nil
}

// WorkspaceManager handles block storage for instance workspaces
// See WORKLOAD_TYPES.md for workspace spec details
type WorkspaceManager struct {
    config    *StorageConfig
    driver    WorkspaceDriver
    mounts    map[string]*BlockMount
    mu        sync.RWMutex
}

type BlockMount struct {
    InstanceID   string
    VolumeID     string
    DevicePath   string
    MountPath    string
    Size         int64
    FSType       string
    MountTime    time.Time
    Preserved    bool  // If true, preserve on instance stop
}

type WorkspaceDriver interface {
    CreateVolume(ctx context.Context, req CreateVolumeRequest) (*Volume, error)
    AttachVolume(ctx context.Context, volumeID, nodeID string) (string, error)  // Returns device path
    DetachVolume(ctx context.Context, volumeID, nodeID string) error
    DeleteVolume(ctx context.Context, volumeID string) error
    ExpandVolume(ctx context.Context, volumeID string, newSize int64) error
}

type CreateVolumeRequest struct {
    InstanceID string
    Size       int64   // Bytes
    FSType     string  // ext4, xfs
    IOPS       int     // Optional: provisioned IOPS
    Throughput int     // Optional: provisioned throughput (MB/s)
}

func NewWorkspaceManager(cfg *StorageConfig) *WorkspaceManager {
    var driver WorkspaceDriver

    switch cfg.WorkspaceDriver {
    case "ebs":
        driver = NewEBSDriver()
    case "local-nvme":
        driver = NewLocalNVMeDriver()
    case "juicefs-block":
        driver = NewJuiceFSBlockDriver(cfg)
    default:
        driver = NewLocalDriver(cfg.WorkspaceBasePath)
    }

    return &WorkspaceManager{
        config: cfg,
        driver: driver,
        mounts: make(map[string]*BlockMount),
    }
}

func (w *WorkspaceManager) ProvisionWorkspace(ctx context.Context, req WorkspaceProvisionRequest) error {
    w.mu.Lock()
    defer w.mu.Unlock()

    // 1. Create volume
    volume, err := w.driver.CreateVolume(ctx, CreateVolumeRequest{
        InstanceID: req.InstanceID,
        Size:       req.Size,
        FSType:     req.FSType,
    })
    if err != nil {
        return fmt.Errorf("failed to create volume: %w", err)
    }

    // 2. Attach volume to node
    devicePath, err := w.driver.AttachVolume(ctx, volume.ID, req.NodeID)
    if err != nil {
        w.driver.DeleteVolume(ctx, volume.ID)
        return fmt.Errorf("failed to attach volume: %w", err)
    }

    // 3. Format if needed
    if err := w.formatVolume(ctx, devicePath, req.FSType); err != nil {
        w.driver.DetachVolume(ctx, volume.ID, req.NodeID)
        w.driver.DeleteVolume(ctx, volume.ID)
        return fmt.Errorf("failed to format volume: %w", err)
    }

    // 4. Mount to workspace path
    mountPath := filepath.Join(w.config.WorkspaceBasePath, req.InstanceID, "workspace")
    if err := os.MkdirAll(mountPath, 0755); err != nil {
        return err
    }

    if err := syscall.Mount(devicePath, mountPath, req.FSType, 0, ""); err != nil {
        return fmt.Errorf("failed to mount: %w", err)
    }

    // 5. Record mount
    w.mounts[req.InstanceID] = &BlockMount{
        InstanceID: req.InstanceID,
        VolumeID:   volume.ID,
        DevicePath: devicePath,
        MountPath:  mountPath,
        Size:       req.Size,
        FSType:     req.FSType,
        MountTime:  time.Now(),
        Preserved:  req.PreserveOnStop,
    }

    return nil
}

func (w *WorkspaceManager) ReleaseWorkspace(ctx context.Context, instanceID string, preserve bool) error {
    w.mu.Lock()
    defer w.mu.Unlock()

    mount, exists := w.mounts[instanceID]
    if !exists {
        return nil
    }

    // 1. Unmount
    if err := syscall.Unmount(mount.MountPath, 0); err != nil {
        log.Printf("Warning: unmount failed: %v", err)
    }

    // 2. Detach volume
    if err := w.driver.DetachVolume(ctx, mount.VolumeID, ""); err != nil {
        log.Printf("Warning: detach failed: %v", err)
    }

    // 3. Delete volume if not preserving
    if !preserve {
        if err := w.driver.DeleteVolume(ctx, mount.VolumeID); err != nil {
            log.Printf("Warning: delete failed: %v", err)
        }
    }

    delete(w.mounts, instanceID)
    return nil
}

// EBSDriver for AWS instances
type EBSDriver struct {
    ec2Client *ec2.Client
}

func (d *EBSDriver) CreateVolume(ctx context.Context, req CreateVolumeRequest) (*Volume, error) {
    input := &ec2.CreateVolumeInput{
        Size:             aws.Int32(int32(req.Size / (1024 * 1024 * 1024))), // Convert to GiB
        VolumeType:       ec2types.VolumeTypeGp3,
        AvailabilityZone: aws.String(d.az),
        TagSpecifications: []ec2types.TagSpecification{{
            ResourceType: ec2types.ResourceTypeVolume,
            Tags: []ec2types.Tag{
                {Key: aws.String("InstanceID"), Value: aws.String(req.InstanceID)},
                {Key: aws.String("ManagedBy"), Value: aws.String("hivemind-worker")},
            },
        }},
    }

    result, err := d.ec2Client.CreateVolume(ctx, input)
    if err != nil {
        return nil, err
    }

    // Wait for volume to be available
    waiter := ec2.NewVolumeAvailableWaiter(d.ec2Client)
    if err := waiter.Wait(ctx, &ec2.DescribeVolumesInput{
        VolumeIds: []string{*result.VolumeId},
    }, 5*time.Minute); err != nil {
        return nil, err
    }

    return &Volume{ID: *result.VolumeId, Size: req.Size}, nil
}

func (d *EBSDriver) AttachVolume(ctx context.Context, volumeID, nodeID string) (string, error) {
    // Find next available device
    devicePath := d.findNextDevice()

    input := &ec2.AttachVolumeInput{
        VolumeId:   aws.String(volumeID),
        InstanceId: aws.String(nodeID),
        Device:     aws.String(devicePath),
    }

    _, err := d.ec2Client.AttachVolume(ctx, input)
    if err != nil {
        return "", err
    }

    // Wait for attachment and get NVMe device path
    actualDevice, err := d.waitForDevice(ctx, volumeID, devicePath)
    return actualDevice, err
}
```

### 5. GPU Module

Replaces: NVIDIA device plugin

```go
package gpu

type GPUModule struct {
    config      *GPUConfig
    nvml        nvml.Interface
    devices     []*GPUDevice
    allocator   *GPUAllocator
    pluginServer *deviceplugin.Server
}

type GPUConfig struct {
    DeviceListStrategy string `yaml:"device_list_strategy"` // "cdi-cri", "uuid"
    MIGStrategy        string `yaml:"mig_strategy"`         // "single", "mixed"
    PluginSocketPath   string `yaml:"plugin_socket_path"`
}

type GPUDevice struct {
    Index       int
    UUID        string
    Name        string
    Memory      uint64
    Allocated   bool
    AllocatedTo string
}

func (m *GPUModule) Name() string { return "gpu" }

func (m *GPUModule) Start(ctx context.Context) error {
    // Initialize NVML
    if err := nvml.Init(); err != nil {
        return fmt.Errorf("failed to initialize NVML: %w", err)
    }
    defer nvml.Shutdown()

    // Discover GPUs
    if err := m.discoverDevices(); err != nil {
        return err
    }

    // Initialize allocator
    m.allocator = NewGPUAllocator(m.devices)

    // Start device plugin server (for Kubernetes integration during migration)
    m.pluginServer = deviceplugin.NewServer(m.config.PluginSocketPath)
    m.pluginServer.RegisterDevicePlugin("nvidia.com/gpu", m)

    go func() {
        if err := m.pluginServer.Serve(); err != nil {
            log.Printf("Device plugin server error: %v", err)
        }
    }()

    <-ctx.Done()
    return nil
}

func (m *GPUModule) discoverDevices() error {
    count, err := nvml.DeviceGetCount()
    if err != nil {
        return err
    }

    m.devices = make([]*GPUDevice, 0, count)

    for i := 0; i < int(count); i++ {
        device, err := nvml.DeviceGetHandleByIndex(i)
        if err != nil {
            continue
        }

        uuid, _ := device.GetUUID()
        name, _ := device.GetName()
        memory, _ := device.GetMemoryInfo()

        m.devices = append(m.devices, &GPUDevice{
            Index:  i,
            UUID:   uuid,
            Name:   name,
            Memory: memory.Total,
        })
    }

    return nil
}

// Kubernetes device plugin interface
func (m *GPUModule) ListAndWatch(e *pluginapi.Empty, s pluginapi.DevicePlugin_ListAndWatchServer) error {
    for {
        devices := make([]*pluginapi.Device, 0, len(m.devices))
        for _, d := range m.devices {
            health := pluginapi.Healthy
            if d.Allocated {
                health = pluginapi.Unhealthy
            }

            devices = append(devices, &pluginapi.Device{
                ID:     d.UUID,
                Health: health,
            })
        }

        s.Send(&pluginapi.ListAndWatchResponse{Devices: devices})
        time.Sleep(5 * time.Second)
    }
}

func (m *GPUModule) Allocate(ctx context.Context, req *pluginapi.AllocateRequest) (*pluginapi.AllocateResponse, error) {
    responses := &pluginapi.AllocateResponse{}

    for _, container := range req.ContainerRequests {
        envs := make(map[string]string)
        annotations := make(map[string]string)

        deviceIDs := container.DevicesIDs
        envs["NVIDIA_VISIBLE_DEVICES"] = strings.Join(deviceIDs, ",")

        // Mark devices as allocated
        for _, id := range deviceIDs {
            m.allocator.Allocate(id)
        }

        responses.ContainerResponses = append(responses.ContainerResponses, &pluginapi.ContainerAllocateResponse{
            Envs:        envs,
            Annotations: annotations,
        })
    }

    return responses, nil
}

// GPU allocator with bin packing
type GPUAllocator struct {
    devices map[string]*GPUDevice
    mu      sync.Mutex
}

func (a *GPUAllocator) Allocate(uuid string) error {
    a.mu.Lock()
    defer a.mu.Unlock()

    device, exists := a.devices[uuid]
    if !exists {
        return fmt.Errorf("device %s not found", uuid)
    }

    if device.Allocated {
        return fmt.Errorf("device %s already allocated", uuid)
    }

    device.Allocated = true
    return nil
}

func (a *GPUAllocator) Free(uuid string) error {
    a.mu.Lock()
    defer a.mu.Unlock()

    device, exists := a.devices[uuid]
    if !exists {
        return fmt.Errorf("device %s not found", uuid)
    }

    device.Allocated = false
    return nil
}
```

## Configuration

```yaml
# /etc/hivemind/worker.yaml
node_id: ${NODE_NAME}
region: us-east-1
cluster: production

control_plane:
  endpoint: https://hivemind.internal
  token: ${WORKER_TOKEN}
  heartbeat_interval: 10s

modules:
  metrics:
    enabled: true
    port: 9100
    scrape_interval: 15s
    enable_node: true
    enable_gpu: true
    enable_process: false
    enable_network: true

  logs:
    enabled: true
    container_log_path: /var/log/containers
    buffer_size: 1000
    flush_interval: 250ms
    outputs:
      clickhouse:
        enabled: true
        host: ${CLICKHOUSE_HOST}
        password: ${CLICKHOUSE_PASSWORD}
      redpanda:
        enabled: true
        brokers: ${REDPANDA_BROKERS}
        topic: user-app-logs

  p2p:
    enabled: true
    listen_port: 6881
    cache_path: /var/hivemind/p2p
    max_cache_size: 50Gi
    announce_interval: 30s
    honeycomb_url: https://cache.honeycomb.internal

  storage:
    enabled: true
    # JuiceFS shared storage (serverless)
    juicefs_meta: ${JUICEFS_META_URL}
    juicefs_storage: ${JUICEFS_STORAGE_URL}
    cache_path: /var/hivemind/storage
    cache_size: 100Gi
    # Workspace block storage (instances) - see WORKLOAD_TYPES.md
    workspace_enabled: true
    workspace_driver: ebs          # ebs, local-nvme, juicefs-block
    workspace_base_path: /var/hivemind/workspaces

  gpu:
    enabled: true
    device_list_strategy: cdi-cri
    mig_strategy: single
    plugin_socket_path: /var/lib/kubelet/device-plugins/nvidia.sock
```

## Systemd Integration

```ini
# /etc/systemd/system/hivemind-worker.service
[Unit]
Description=Hivemind Node Worker
Documentation=https://docs.hivemind.dev/hivemind
After=network-online.target
Wants=network-online.target
Before=kubelet.service

[Service]
Type=notify
ExecStart=/usr/local/bin/hivemind-worker --config /etc/hivemind/worker.yaml
Restart=always
RestartSec=5
WatchdogSec=30
NotifyAccess=main

# Security
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=false
PrivateTmp=false

# Capabilities for GPU, storage, network
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_NET_RAW

# Resource limits
LimitNOFILE=1048576
LimitNPROC=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

## AMI Build

```bash
#!/bin/bash
# build-ami.sh - Create AMI with Hivemind worker

# Base: Amazon Linux 2023
AMI_BASE="ami-0123456789abcdef0"

# Install dependencies
yum install -y \
    nvidia-driver-latest \
    juicefs \
    containerd

# Install Hivemind worker
curl -Lo /usr/local/bin/hivemind-worker \
    https://releases.hivemind.dev/hivemind-worker/latest/linux-amd64
chmod +x /usr/local/bin/hivemind-worker

# Install systemd service
cat > /etc/systemd/system/hivemind-worker.service << 'EOF'
# ... service definition ...
EOF

systemctl enable hivemind-worker

# Configure containerd for Nydus
cat > /etc/containerd/config.toml << 'EOF'
# ... containerd config with Nydus snapshotter ...
EOF

# Clean up and create AMI
```

---

## Technology Choice

### Language: Zig

**Decision**: Zig

The Worker runs on every node in every cluster. Binary size, memory efficiency, and DST capability are all critical.

#### Why Zig?

| Factor | Zig Advantage |
|--------|---------------|
| **Binary size** | Single ~5MB binary vs 6+ DaemonSets. Zig produces small, static binaries. |
| **Memory efficiency** | No GC overhead. Critical when running on every node. |
| **GPU allocation DST** | Device assignment decisions must be deterministic and testable |
| **Storage mount DST** | JuiceFS mount/unmount sequences need deterministic testing |
| **Startup time** | Fast cold start - no runtime initialization |
| **C interop** | Direct NVML bindings, containerd/CRI integration |

#### Why Not Go?

| Factor | Go Consideration |
|--------|------------------|
| **Team familiarity** | Team knows Go well |
| **containerd client** | containerd client is written in Go |
| **Existing DaemonSets** | Current tools (Fluent Bit, node_exporter) have Go equivalents |
| **GC overhead** | Per-node GC memory overhead (10-50MB) adds up across fleet |
| **Binary size** | Go binaries typically 10-20MB; Zig can be <5MB |

#### Why Not Rust?

| Factor | Rust Consideration |
|--------|-------------------|
| **Small binaries** | Rust can produce small binaries with effort |
| **NVML bindings** | nvml-wrapper crate exists |
| **DST difficulty** | Async runtime complicates deterministic testing |
| **Compile times** | Slower iteration than Zig for systems code |

#### Decision Rationale

The Worker's requirements strongly favor Zig:

1. **Runs everywhere**: Every node in every cluster. Efficiency matters at scale.
2. **Replaces 6+ DaemonSets**: Must be lightweight to justify consolidation.
3. **GPU allocation**: Wrong device assignment → workload failure. Must be testable.
4. **Storage mounts**: Mount race conditions → data loss. Needs DST.
5. **C interop**: NVML is a C library; Zig has first-class C interop.

The binary size and memory efficiency alone justify Zig. Combined with DST requirements for GPU/storage modules, it's the clear choice.

### Key Libraries (Zig)

```
NVML:            Direct C bindings via @cImport
Containerd:      CRI via gRPC (or direct C bindings)
Prometheus:      Custom text format exporter
Logging:         std.log with structured output
Config:          YAML via C library or custom parser
```

### Binary Size Target

```
Current (6 DaemonSets):
  - node_exporter:     ~20MB
  - DCGM exporter:     ~30MB
  - Fluent Bit:        ~50MB
  - Dragonfly:         ~40MB
  - Device plugin:     ~15MB
  - CSI driver:        ~30MB
  Total: ~185MB per node

Worker (Zig):
  - Single binary:     <10MB target
  - Savings: >175MB per node
  - At 1000 nodes: 175GB less deployed
```

---

## Migration Order

### Phase 5a: Metrics Module (Week 1-2)

Low risk, easy to validate against existing exporters.

```bash
# 1. Deploy worker with metrics module only
kubectl apply -f worker-daemonset.yaml  # metrics enabled, others disabled

# 2. Compare metrics
curl http://node:9100/metrics > worker_metrics
curl http://node:9100/metrics > node_exporter_metrics  # existing
diff worker_metrics node_exporter_metrics

# 3. Update Prometheus to scrape worker
# 4. Disable node-exporter and dcgm-exporter DaemonSets
```

### Phase 5b: Logs Module (Week 3-4)

Medium risk, need to verify log completeness.

```bash
# 1. Enable logs module alongside Fluent Bit
# worker.yaml: modules.logs.enabled: true

# 2. Validate logs appear in ClickHouse from both sources

# 3. Compare log counts
SELECT count() FROM app_logs WHERE source = 'worker'
SELECT count() FROM app_logs WHERE source = 'fluent-bit'

# 4. Disable Fluent Bit DaemonSets
```

### Phase 5c: P2P Module (Week 5-6)

Low risk (new from Phase 2).

```bash
# P2P was introduced in Phase 2 (Honeycomb)
# This is just enabling it in the worker
# worker.yaml: modules.p2p.enabled: true
```

### Phase 5d: Storage Module (Week 7-8)

Medium risk, affects mount operations.

```bash
# 1. Enable storage module
# worker.yaml: modules.storage.enabled: true

# 2. Test mount/unmount operations
hivemind-worker mount --project test-project --path /mnt/test

# 3. Verify data access
ls /mnt/test

# 4. Migrate from JuiceFS CSI driver
```

### Phase 5e: GPU Module (Week 9-12)

High risk, test extensively before migrating.

```bash
# 1. Enable GPU module on test nodes only
# worker.yaml: modules.gpu.enabled: true

# 2. Verify GPU discovery
hivemind-worker gpu list

# 3. Test GPU allocation
kubectl run gpu-test --image=nvidia/cuda:12.0-base --resource="nvidia.com/gpu=1"

# 4. Validate GPU workloads run correctly

# 5. Gradually migrate nodes from NVIDIA device plugin
```

## Observability

### Worker Metrics

```go
var (
    workerUptime = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "hivemind_worker_uptime_seconds",
            Help: "Worker uptime in seconds",
        },
    )

    moduleStatus = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hivemind_worker_module_status",
            Help: "Module status (1=healthy, 0=unhealthy)",
        },
        []string{"module"},
    )

    logsProcessed = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hivemind_worker_logs_processed_total",
            Help: "Total logs processed",
        },
        []string{"output"},
    )

    p2pBytesTransferred = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hivemind_worker_p2p_bytes_total",
            Help: "Bytes transferred via P2P",
        },
        []string{"direction"},
    )

    gpuAllocations = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hivemind_worker_gpu_allocations_total",
            Help: "GPU allocation operations",
        },
        []string{"operation"}, // allocate, free
    )
)
```

## Rollback Procedure

```bash
#!/bin/bash
# rollback-to-daemonsets.sh

# 1. Stop worker
systemctl stop hivemind-worker

# 2. Re-enable DaemonSets
kubectl patch daemonset node-exporter -n monitoring -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
kubectl patch daemonset dcgm-exporter -n gpu-operator -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
kubectl patch daemonset fluent-bit -n fluent -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
kubectl patch daemonset nvidia-device-plugin -n gpu-operator -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'

# 3. Wait for DaemonSets to be ready
kubectl rollout status daemonset -n monitoring
kubectl rollout status daemonset -n gpu-operator
kubectl rollout status daemonset -n fluent

# 4. Verify functionality
# - Metrics available
# - Logs flowing
# - GPUs allocatable
```

## Testing Strategy

### Unit Tests

```go
func TestLogsProcessor(t *testing.T) {
    processor := NewLogProcessor(nil)

    entry := RawLogEntry{
        Line:     "2025-01-01T00:00:00.000000000Z stdout F test log message",
        Filename: "pod-name_namespace_container-abc123.log",
    }

    processed, include := processor.Process(entry)

    assert.True(t, include)
    assert.Equal(t, "test log message", processed.Log)
    assert.Equal(t, "stdout", processed.Stream)
    assert.Equal(t, "namespace", processed.Namespace)
}
```

### Integration Tests

```go
func TestGPUDiscovery(t *testing.T) {
    if os.Getenv("CI") == "true" {
        t.Skip("Skipping GPU test in CI")
    }

    module := gpu.New(&gpu.GPUConfig{})
    err := module.discoverDevices()
    require.NoError(t, err)

    // Should find at least one GPU on test node
    assert.GreaterOrEqual(t, len(module.devices), 1)
}
```

### Parity Tests

```go
func TestMetricsParity(t *testing.T) {
    // Get metrics from worker
    workerResp, _ := http.Get("http://localhost:9100/metrics")
    workerMetrics := parsePrometheusMetrics(workerResp.Body)

    // Get metrics from node_exporter
    exporterResp, _ := http.Get("http://localhost:9101/metrics")
    exporterMetrics := parsePrometheusMetrics(exporterResp.Body)

    // Compare key metrics
    for _, metric := range []string{
        "node_cpu_seconds_total",
        "node_memory_MemTotal_bytes",
        "node_disk_read_bytes_total",
    } {
        workerVal := workerMetrics[metric]
        exporterVal := exporterMetrics[metric]

        // Allow 5% variance
        diff := math.Abs(workerVal - exporterVal) / exporterVal
        assert.Less(t, diff, 0.05, "Metric %s differs by %.2f%%", metric, diff*100)
    }
}
```

---

## Related Documents

- [STATUS.md](../STATUS.md) - Current system architecture and implementation state
- [HIVEMIND.md](HIVEMIND.md) - Control plane (manages worker registration, workload dispatch)
- [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) - Jobs, CronJobs, and Instances (workspace storage specs)
- [HONEYCOMB.md](HONEYCOMB.md) - OCI registry (P2P module integrates with Honeycomb)
- [PROVIDERS.md](PROVIDERS.md) - Multi-provider abstraction (Worker runs on all provider nodes)
