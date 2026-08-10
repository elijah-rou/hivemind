> **DESIGN STAGE**: Extended workload types (jobs, cron, instances). Serverless is fully implemented; jobs and instances are designed but not yet integrated.

# Workload Types: Jobs and Persistent Instances

**Status**: Draft
**Dependency**: Phase 4 (Hivemind Control Plane)

## Overview

Hivemind must support three distinct workload types:

| Type | Description | Lifecycle | Access Pattern |
|------|-------------|-----------|----------------|
| **Serverless** | Request/response inference | Scale 0→N based on demand | HTTP/gRPC via Router |
| **Job** | Run-to-completion tasks | Start → Run → Complete | API submission, async results |
| **Instance** | Persistent VM-like workloads | Always-on or timed lease, user-controlled | SSH shell, HTTP endpoints |

This document extends the base Hivemind design to support Jobs and Instances alongside the existing Serverless workloads.

---

## Unified Workload Model

### WorkloadSpec Extension

```go
type WorkloadKind string

const (
    WorkloadKindServerless WorkloadKind = "serverless"  // Current design
    WorkloadKindJob        WorkloadKind = "job"         // Run-to-completion
    WorkloadKindCronJob    WorkloadKind = "cronjob"     // Recurring jobs
    WorkloadKindInstance   WorkloadKind = "instance"    // Persistent VM-like
)

type Workload struct {
    ID          string            `json:"id"`
    ProjectID   string            `json:"project_id"`
    AppID       string            `json:"app_id"`
    Name        string            `json:"name"`
    Kind        WorkloadKind      `json:"kind"`           // NEW
    Spec        WorkloadSpec      `json:"spec"`
    Status      WorkloadStatus    `json:"status"`
    Placement   *PlacementDecision `json:"placement,omitempty"`
    CreatedAt   time.Time         `json:"created_at"`
    UpdatedAt   time.Time         `json:"updated_at"`
}

type WorkloadSpec struct {
    // Common fields (all workload types)
    Image           string            `json:"image"`
    CPU             float64           `json:"cpu"`
    Memory          int64             `json:"memory"`
    GPU             GPUSpec           `json:"gpu,omitempty"`
    Env             map[string]string `json:"env,omitempty"`
    Secrets         []SecretRef       `json:"secrets,omitempty"`
    Volumes         []VolumeSpec      `json:"volumes,omitempty"`

    // Serverless-specific (Kind: serverless)
    Serverless      *ServerlessSpec   `json:"serverless,omitempty"`

    // Job-specific (Kind: job, cronjob)
    Job             *JobSpec          `json:"job,omitempty"`

    // Instance-specific (Kind: instance)
    Instance        *InstanceSpec     `json:"instance,omitempty"`
}
```

---

## Part 1: Jobs

### Job Types

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           JOB WORKLOADS                                  │
│                                                                          │
│   One-time Job                        Recurring Job (CronJob)            │
│   ┌─────────────────────────┐        ┌─────────────────────────┐        │
│   │                         │        │                         │        │
│   │  Submit ──► Run ──► Done│        │  Schedule triggers      │        │
│   │                         │        │       │                 │        │
│   │  • Training run         │        │       ▼                 │        │
│   │  • Data processing      │        │  ┌─────────┐            │        │
│   │  • Batch inference      │        │  │ Job Run │──► Done    │        │
│   │  • One-time migration   │        │  └─────────┘            │        │
│   │                         │        │       │                 │        │
│   └─────────────────────────┘        │       ▼ (next trigger)  │        │
│                                      │  ┌─────────┐            │        │
│                                      │  │ Job Run │──► Done    │        │
│                                      │  └─────────┘            │        │
│                                      │                         │        │
│                                      │  • Scheduled training   │        │
│                                      │  • Periodic sync        │        │
│                                      │  • Daily reports        │        │
│                                      └─────────────────────────┘        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### JobSpec

```go
type JobSpec struct {
    // Schedule (CronJob only)
    Schedule        string            `json:"schedule,omitempty"`      // Cron syntax: "0 */6 * * *"
    Timezone        string            `json:"timezone,omitempty"`      // e.g., "America/New_York"

    // Execution policy
    Parallelism     int               `json:"parallelism"`             // Concurrent pods (default: 1)
    Completions     int               `json:"completions"`             // Required successful completions (default: 1)
    BackoffLimit    int               `json:"backoff_limit"`           // Retry attempts (default: 3)

    // Timeouts
    ActiveDeadline  time.Duration     `json:"active_deadline"`         // Max runtime before kill
    StartDeadline   time.Duration     `json:"start_deadline"`          // Max time to wait for scheduling

    // Completion
    CompletionMode  CompletionMode    `json:"completion_mode"`         // indexed, non_indexed
    TTLAfterDone    time.Duration     `json:"ttl_after_done"`          // Cleanup delay after completion

    // History (CronJob only)
    SuccessHistory  int               `json:"success_history_limit"`   // Keep N successful runs
    FailureHistory  int               `json:"failure_history_limit"`   // Keep N failed runs

    // Concurrency (CronJob only)
    ConcurrencyPolicy ConcurrencyPolicy `json:"concurrency_policy"`    // allow, forbid, replace
}

type CompletionMode string
const (
    CompletionModeNonIndexed CompletionMode = "non_indexed"  // Any N completions
    CompletionModeIndexed    CompletionMode = "indexed"      // Specific index completions
)

type ConcurrencyPolicy string
const (
    ConcurrencyAllow   ConcurrencyPolicy = "allow"    // Allow concurrent runs
    ConcurrencyForbid  ConcurrencyPolicy = "forbid"   // Skip if previous running
    ConcurrencyReplace ConcurrencyPolicy = "replace"  // Kill previous, start new
)
```

### Job State Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        JOB STATE MACHINE                                 │
│                                                                          │
│                          ┌──────────┐                                   │
│                          │ Pending  │                                   │
│                          └────┬─────┘                                   │
│                               │                                         │
│              ┌────────────────┼────────────────┐                        │
│              │                │                │                        │
│              ▼                ▼                ▼                        │
│       ┌──────────┐     ┌──────────┐     ┌──────────┐                   │
│       │ScheduleErr│    │ Running  │     │ Suspended│                   │
│       └──────────┘     └────┬─────┘     └──────────┘                   │
│                             │                                           │
│              ┌──────────────┼──────────────┐                           │
│              │              │              │                           │
│              ▼              ▼              ▼                           │
│       ┌──────────┐   ┌──────────┐   ┌──────────┐                       │
│       │ Failed   │   │ Succeeded│   │ Deadline │                       │
│       │ (retries │   │          │   │ Exceeded │                       │
│       │ exhausted)│  │          │   │          │                       │
│       └──────────┘   └──────────┘   └──────────┘                       │
│                                                                          │
│   CronJob adds:                                                          │
│   ┌──────────┐                                                          │
│   │ Scheduled│ ──► Creates Job on trigger ──► Job lifecycle above       │
│   │ (waiting)│                                                          │
│   └──────────┘                                                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

```go
type JobPhase string

const (
    JobPhasePending          JobPhase = "pending"           // Awaiting scheduling
    JobPhaseScheduled        JobPhase = "scheduled"         // Scheduled, awaiting start
    JobPhaseRunning          JobPhase = "running"           // Actively executing
    JobPhaseSucceeded        JobPhase = "succeeded"         // Completed successfully
    JobPhaseFailed           JobPhase = "failed"            // Failed (retries exhausted)
    JobPhaseDeadlineExceeded JobPhase = "deadline_exceeded" // Killed due to timeout
    JobPhaseSuspended        JobPhase = "suspended"         // Paused by user
)

type JobStatus struct {
    Phase           JobPhase      `json:"phase"`
    StartTime       *time.Time    `json:"start_time,omitempty"`
    CompletionTime  *time.Time    `json:"completion_time,omitempty"`
    Active          int           `json:"active"`           // Running pods
    Succeeded       int           `json:"succeeded"`        // Successful completions
    Failed          int           `json:"failed"`           // Failed attempts
    Conditions      []Condition   `json:"conditions,omitempty"`

    // Output capture
    ExitCode        *int          `json:"exit_code,omitempty"`
    Output          string        `json:"output,omitempty"`        // stdout (truncated)
    OutputArtifact  string        `json:"output_artifact,omitempty"` // S3 path for full output
}
```

### Job Controller

The Job Controller manages job lifecycle, separate from the Serverless autoscaler.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         JOB CONTROLLER                                   │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      JOB QUEUE                                   │   │
│   │                                                                  │   │
│   │   Jobs ordered by: priority > submission_time                    │   │
│   │                                                                  │   │
│   │   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐                       │   │
│   │   │Job 1│ │Job 2│ │Job 3│ │Job 4│ │Job 5│ ...                   │   │
│   │   │P:10 │ │P:5  │ │P:5  │ │P:1  │ │P:1  │                       │   │
│   │   └─────┘ └─────┘ └─────┘ └─────┘ └─────┘                       │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│                                    ▼                                     │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    SCHEDULER INTEGRATION                         │   │
│   │                                                                  │   │
│   │   Jobs use same scheduler as Serverless workloads:               │   │
│   │   • Data locality scoring (image cache)                          │   │
│   │   • GPU availability                                             │   │
│   │   • Cross-cluster placement                                      │   │
│   │                                                                  │   │
│   │   Additional job-specific scoring:                               │   │
│   │   • Preemption policy (can this job preempt others?)             │   │
│   │   • Spot tolerance (can run on spot instances?)                  │   │
│   │   • Deadline pressure (urgent jobs score higher)                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│                                    ▼                                     │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    EXECUTION MANAGER                             │   │
│   │                                                                  │   │
│   │   • Monitors running jobs                                        │   │
│   │   • Enforces deadlines (kill on timeout)                         │   │
│   │   • Handles retries on failure                                   │   │
│   │   • Captures output/exit codes                                   │   │
│   │   • Triggers completion callbacks                                │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│                                    ▼                                     │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    CRON SCHEDULER                                │   │
│   │                                                                  │   │
│   │   • Evaluates cron expressions                                   │   │
│   │   • Creates Job instances on trigger                             │   │
│   │   • Enforces concurrency policy                                  │   │
│   │   • Maintains run history                                        │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

```go
type JobController struct {
    workloads    *WorkloadStore
    scheduler    *Scheduler
    clusters     map[string]*ClusterAdapter
    cronScheduler *CronScheduler
}

func (c *JobController) Start(ctx context.Context) error {
    // Start cron scheduler for recurring jobs
    go c.cronScheduler.Run(ctx)

    // Process job queue
    for {
        select {
        case <-ctx.Done():
            return nil
        default:
            c.processNextJob(ctx)
        }
    }
}

func (c *JobController) processNextJob(ctx context.Context) {
    // Get next pending job
    job, err := c.workloads.GetNextPendingJob(ctx)
    if err != nil || job == nil {
        time.Sleep(time.Second)
        return
    }

    // Schedule job
    placement, err := c.scheduler.ScheduleJob(ctx, job)
    if err != nil {
        c.handleSchedulingFailure(ctx, job, err)
        return
    }

    // Execute job
    c.executeJob(ctx, job, placement)
}

func (c *JobController) executeJob(ctx context.Context, job *Workload, placement *PlacementDecision) {
    adapter := c.clusters[placement.ClusterID]

    // Create job pod (not a long-running deployment)
    podID, err := adapter.CreateJobPod(ctx, job)
    if err != nil {
        c.handleExecutionFailure(ctx, job, err)
        return
    }

    // Monitor job completion
    go c.monitorJob(ctx, job, podID, adapter)
}

func (c *JobController) monitorJob(ctx context.Context, job *Workload, podID string, adapter *ClusterAdapter) {
    deadline := time.Now().Add(job.Spec.Job.ActiveDeadline)

    for {
        select {
        case <-ctx.Done():
            return

        case <-time.After(5 * time.Second):
            status, err := adapter.GetPodStatus(ctx, podID)
            if err != nil {
                continue
            }

            switch status.Phase {
            case "Succeeded":
                c.handleJobSuccess(ctx, job, status)
                return

            case "Failed":
                c.handleJobFailure(ctx, job, status)
                return
            }

            // Check deadline
            if time.Now().After(deadline) {
                adapter.KillPod(ctx, podID)
                c.handleDeadlineExceeded(ctx, job)
                return
            }
        }
    }
}

// Cron scheduler for recurring jobs
type CronScheduler struct {
    cronJobs map[string]*CronEntry
    mu       sync.RWMutex
}

type CronEntry struct {
    Workload    *Workload
    Schedule    cron.Schedule
    NextRun     time.Time
    LastRun     *time.Time
    RunHistory  []JobRun
}

func (s *CronScheduler) Run(ctx context.Context) {
    ticker := time.NewTicker(time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case now := <-ticker.C:
            s.evaluateTriggers(ctx, now)
        }
    }
}

func (s *CronScheduler) evaluateTriggers(ctx context.Context, now time.Time) {
    s.mu.RLock()
    defer s.mu.RUnlock()

    for _, entry := range s.cronJobs {
        if now.After(entry.NextRun) {
            s.triggerJob(ctx, entry)
            entry.NextRun = entry.Schedule.Next(now)
            entry.LastRun = &now
        }
    }
}
```

### Job API

```go
// Job-specific API endpoints
// POST /v1/jobs                        # Submit job
// GET  /v1/jobs/{id}                   # Get job status
// GET  /v1/jobs/{id}/logs              # Stream job logs
// GET  /v1/jobs/{id}/output            # Get job output
// POST /v1/jobs/{id}/cancel            # Cancel running job
// POST /v1/jobs/{id}/retry             # Retry failed job

// CronJob-specific endpoints
// POST /v1/cronjobs                    # Create recurring job
// GET  /v1/cronjobs/{id}               # Get cronjob config
// PUT  /v1/cronjobs/{id}               # Update schedule
// POST /v1/cronjobs/{id}/suspend       # Pause scheduling
// POST /v1/cronjobs/{id}/resume        # Resume scheduling
// POST /v1/cronjobs/{id}/trigger       # Manually trigger run
// GET  /v1/cronjobs/{id}/runs          # List run history

func (api *HivemindAPI) SubmitJob(ctx context.Context, req SubmitJobRequest) (*Workload, error) {
    workload := &Workload{
        ID:        generateJobID(req.ProjectID),
        ProjectID: req.ProjectID,
        Name:      req.Name,
        Kind:      WorkloadKindJob,
        Spec: WorkloadSpec{
            Image:   req.Image,
            CPU:     req.CPU,
            Memory:  req.Memory,
            GPU:     req.GPU,
            Env:     req.Env,
            Job: &JobSpec{
                Parallelism:    req.Parallelism,
                Completions:    req.Completions,
                BackoffLimit:   req.BackoffLimit,
                ActiveDeadline: req.Timeout,
            },
        },
        Status: WorkloadStatus{
            Phase: WorkloadPhasePending,
        },
    }

    if err := api.workloads.Create(ctx, workload); err != nil {
        return nil, err
    }

    // Job controller will pick this up from the queue
    return workload, nil
}

func (api *HivemindAPI) GetJobOutput(ctx context.Context, jobID string) (*JobOutput, error) {
    job, err := api.workloads.Get(ctx, jobID)
    if err != nil {
        return nil, err
    }

    if job.Kind != WorkloadKindJob {
        return nil, errors.New("workload is not a job")
    }

    return &JobOutput{
        ExitCode: job.Status.Job.ExitCode,
        Output:   job.Status.Job.Output,
        Artifact: job.Status.Job.OutputArtifact,
    }, nil
}
```

### Job Examples

```yaml
# One-time training job
kind: job
name: train-model-v2
spec:
  image: sha256:abc123
  cpu: 8
  memory: 64Gi
  gpu:
    type: h100_sxm
    count: 8
  env:
    DATASET: s3://bucket/data
    OUTPUT: s3://bucket/models/v2
  job:
    parallelism: 1
    completions: 1
    backoff_limit: 2
    active_deadline: 24h
    ttl_after_done: 1h

---
# Recurring data sync
kind: cronjob
name: sync-embeddings
spec:
  image: sha256:def456
  cpu: 4
  memory: 16Gi
  job:
    schedule: "0 */6 * * *"    # Every 6 hours
    timezone: "UTC"
    concurrency_policy: forbid  # Skip if previous still running
    active_deadline: 2h
    success_history_limit: 5
    failure_history_limit: 3

---
# Parallel batch inference
kind: job
name: batch-inference
spec:
  image: sha256:ghi789
  cpu: 4
  memory: 32Gi
  gpu:
    type: a100_80gb
    count: 1
  job:
    parallelism: 10           # 10 concurrent pods
    completions: 100          # Process 100 batches total
    completion_mode: indexed  # Each pod gets index 0-99
    active_deadline: 4h
```

---

## Part 2: Persistent Instances

### Instance Model

Persistent Instances are long-running, user-controlled workloads with SSH access. They can be:
- **Persistent**: Always-on until user stops/deletes
- **Timed**: Automatically terminates after a set duration (lease model)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       PERSISTENT INSTANCE                                │
│                                                                          │
│   Unlike Serverless (scale 0→N) or Jobs (run to completion),            │
│   Instances are:                                                         │
│                                                                          │
│   • User-controlled lifecycle (start/stop/delete)                       │
│   • Single replica per instance                                          │
│   • SSH accessible                                                       │
│   • Persistent workspace storage                                         │
│   • Stable network identity                                              │
│   • Optional: timed lease (auto-terminate after duration)               │
│                                                                          │
│   Use cases:                                                             │
│   • Interactive development environment                                  │
│   • Jupyter notebooks with GPU                                          │
│   • Long-running training with checkpoints                              │
│   • Debugging/experimentation                                           │
│   • Time-boxed compute rentals                                          │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    INSTANCE LIFECYCLE                            │   │
│   │                                                                  │   │
│   │   PERSISTENT MODE:                                               │   │
│   │   User creates ──► Running ──► User stops ──► Stopped            │   │
│   │        │              │              │            │              │   │
│   │        │              │              │            ▼              │   │
│   │        │              │              │      User starts          │   │
│   │        │              │              │            │              │   │
│   │        │              ▼              │            │              │   │
│   │        │         SSH access          └────────────┘              │   │
│   │        │         HTTP ports                                      │   │
│   │        │         Workspace persists                              │   │
│   │        │                                                         │   │
│   │        └──► User deletes ──► Terminated (workspace deleted)      │   │
│   │                                                                  │   │
│   │   TIMED MODE:                                                    │   │
│   │   User creates (duration: 4h) ──► Running ──┬──► Lease expires   │   │
│   │        │                             │      │         │          │   │
│   │        │                             │      │         ▼          │   │
│   │        │                        SSH access  │    Terminated      │   │
│   │        │                                    │    (auto-cleanup)  │   │
│   │        │                                    │                    │   │
│   │        └──► User can extend lease ──────────┘                    │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### InstanceSpec

```go
type InstanceSpec struct {
    // SSH access
    SSHEnabled      bool              `json:"ssh_enabled"`
    SSHKeys         []SSHKey          `json:"ssh_keys,omitempty"`
    SSHPort         int               `json:"ssh_port"`            // Default: 22

    // Workspace storage (persists across stop/start)
    Workspace       *WorkspaceSpec    `json:"workspace,omitempty"`

    // Networking
    Network         *InstanceNetwork  `json:"network,omitempty"`

    // Exposed ports (beyond SSH)
    Ports           []PortSpec        `json:"ports,omitempty"`

    // Lifecycle control
    Lifecycle       *InstanceLifecycle `json:"lifecycle,omitempty"`

    // Init script (runs on first start)
    InitScript      string            `json:"init_script,omitempty"`
}

type SSHKey struct {
    Name      string `json:"name"`
    PublicKey string `json:"public_key"`  // ssh-rsa AAAA... or ssh-ed25519 AAAA...
}

type WorkspaceSpec struct {
    Size         int64  `json:"size"`          // Bytes
    MountPath    string `json:"mount_path"`    // Default: /home/user
    SnapshotID   string `json:"snapshot_id,omitempty"` // Restore from snapshot
}

type InstanceNetwork struct {
    // Stable hostname: {instance_id}.instances.hivemind.dev
    StableHostname  bool   `json:"stable_hostname"`

    // Optional: dedicated IP (costs extra)
    DedicatedIP     bool   `json:"dedicated_ip"`

    // Firewall rules
    IngressRules    []IngressRule `json:"ingress_rules,omitempty"`
}

type PortSpec struct {
    Name        string `json:"name"`
    Port        int    `json:"port"`
    Protocol    string `json:"protocol"`  // tcp, udp
    Public      bool   `json:"public"`    // Expose via Router
}

// InstanceLifecycle controls when instances automatically stop or terminate
type InstanceLifecycle struct {
    // Mode determines instance behavior
    Mode            LifecycleMode     `json:"mode"`              // persistent, timed

    // TIMED MODE: Instance terminates after this duration
    // Example: "4h", "24h", "7d"
    Duration        time.Duration     `json:"duration,omitempty"`

    // TIMED MODE: Whether workspace is preserved after lease expires
    // If true: workspace saved, can create new instance from snapshot
    // If false: workspace deleted on termination
    PreserveWorkspace bool            `json:"preserve_workspace,omitempty"`

    // TIMED MODE: Allow user to extend the lease
    Extendable      bool              `json:"extendable,omitempty"`

    // TIMED MODE: Maximum total duration (including extensions)
    MaxDuration     time.Duration     `json:"max_duration,omitempty"`

    // PERSISTENT MODE: Auto-stop on SSH inactivity
    IdleTimeout     time.Duration     `json:"idle_timeout,omitempty"`

    // PERSISTENT MODE: Scheduled stop time
    ScheduledStop   string            `json:"scheduled_stop,omitempty"` // Cron syntax

    // BOTH MODES: Cost limit (stop/terminate when exceeded)
    MaxCostUSD      float64           `json:"max_cost_usd,omitempty"`
}

type LifecycleMode string

const (
    LifecycleModePersistent LifecycleMode = "persistent"  // User controls start/stop/delete
    LifecycleModeTimed      LifecycleMode = "timed"       // Auto-terminate after duration
)

type InstancePhase string

const (
    InstancePhasePending     InstancePhase = "pending"      // Being created
    InstancePhaseStarting    InstancePhase = "starting"     // Container starting
    InstancePhaseRunning     InstancePhase = "running"      // Ready for SSH
    InstancePhaseStopping    InstancePhase = "stopping"     // Graceful shutdown
    InstancePhaseStopped     InstancePhase = "stopped"      // Not running, workspace persists
    InstancePhaseExpiring    InstancePhase = "expiring"     // Lease ending soon (warning state)
    InstancePhaseTerminating InstancePhase = "terminating"  // Being deleted
)

type InstanceStatus struct {
    Phase           InstancePhase     `json:"phase"`
    SSHEndpoint     string            `json:"ssh_endpoint,omitempty"`     // hostname:port
    PublicIP        string            `json:"public_ip,omitempty"`
    InternalIP      string            `json:"internal_ip,omitempty"`
    Hostname        string            `json:"hostname,omitempty"`
    StartedAt       *time.Time        `json:"started_at,omitempty"`
    LastActivity    *time.Time        `json:"last_activity,omitempty"`
    Ports           []PortStatus      `json:"ports,omitempty"`
    WorkspaceUsed   int64             `json:"workspace_used,omitempty"`   // Bytes

    // Timed instance fields
    ExpiresAt       *time.Time        `json:"expires_at,omitempty"`       // When lease ends
    TimeRemaining   *time.Duration    `json:"time_remaining,omitempty"`   // Convenience field
    ExtensionsUsed  int               `json:"extensions_used,omitempty"`  // Number of extensions
    TotalRuntime    time.Duration     `json:"total_runtime,omitempty"`    // Cumulative runtime
}
```

### Timed Instance Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     TIMED INSTANCE LIFECYCLE                             │
│                                                                          │
│   User creates instance with duration: 4h                               │
│       │                                                                  │
│       ▼                                                                  │
│   ┌─────────┐     ┌─────────┐                                           │
│   │ Pending │────►│ Running │◄─────────────────────────────┐            │
│   └─────────┘     └────┬────┘                              │            │
│                        │                                    │            │
│                        │ T - 15 min                         │            │
│                        ▼                                    │            │
│                   ┌──────────┐                              │            │
│                   │ Expiring │  ◄── Warning notification    │            │
│                   │ (warning)│      sent to user            │            │
│                   └────┬─────┘                              │            │
│                        │                                    │            │
│           ┌────────────┼────────────┐                       │            │
│           │            │            │                       │            │
│           ▼            │            ▼                       │            │
│    User extends        │     Lease expires                  │            │
│    (if allowed)        │            │                       │            │
│           │            │            ▼                       │            │
│           │            │    ┌─────────────┐                 │            │
│           │            │    │Terminating  │                 │            │
│           │            │    │(grace period│                 │            │
│           │            │    │ 5 min)      │                 │            │
│           │            │    └──────┬──────┘                 │            │
│           │            │           │                        │            │
│           │            │           ▼                        │            │
│           │            │    ┌─────────────┐                 │            │
│           │            │    │ Terminated  │                 │            │
│           │            │    │             │                 │            │
│           │            │    │ workspace:  │                 │            │
│           │            │    │ preserved   │                 │            │
│           │            │    │ or deleted  │                 │            │
│           │            │    └─────────────┘                 │            │
│           │            │                                    │            │
│           └────────────┴────────────────────────────────────┘            │
│                                                                          │
│   Extension adds more time (up to max_duration):                        │
│   POST /v1/instances/{id}/extend?duration=2h                            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### SSH Access Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SSH ACCESS ARCHITECTURE                           │
│                                                                          │
│   User                                                                   │
│     │                                                                    │
│     │ ssh user@{instance_id}.instances.hivemind.dev                     │
│     │                                                                    │
│     ▼                                                                    │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      SSH GATEWAY                                 │   │
│   │                                                                  │   │
│   │   • Terminates SSH connection                                    │   │
│   │   • Authenticates against project SSH keys                       │   │
│   │   • Resolves instance ID to backend location                     │   │
│   │   • Proxies connection to instance                               │   │
│   │   • Updates last_activity for idle tracking                      │   │
│   │                                                                  │   │
│   │   Deployment: Regional (same regions as Router)                  │   │
│   │   Technology: Go + golang.org/x/crypto/ssh                       │   │
│   │                                                                  │   │
│   └──────────────────────────┬──────────────────────────────────────┘   │
│                              │                                          │
│                              │ Internal network (mTLS)                  │
│                              │                                          │
│                              ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      INSTANCE POD                                │   │
│   │                                                                  │   │
│   │   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐       │   │
│   │   │   sshd        │  │   User        │  │   Workspace   │       │   │
│   │   │   (port 22)   │  │   Container   │  │   Volume      │       │   │
│   │   │               │  │               │  │               │       │   │
│   │   │   Accepts     │  │   User's      │  │   /home/user  │       │   │
│   │   │   proxy conn  │  │   image       │  │   persists    │       │   │
│   │   └───────────────┘  └───────────────┘  └───────────────┘       │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### SSH Gateway

```go
package sshgateway

type SSHGateway struct {
    config     *SSHGatewayConfig
    instances  *InstanceStore
    signer     ssh.Signer
}

type SSHGatewayConfig struct {
    ListenAddr    string
    HostKey       string        // Path to host private key
    IdleTimeout   time.Duration
}

func (g *SSHGateway) Start(ctx context.Context) error {
    config := &ssh.ServerConfig{
        PublicKeyCallback: g.authenticateKey,
    }

    privateKey, _ := os.ReadFile(g.config.HostKey)
    signer, _ := ssh.ParsePrivateKey(privateKey)
    config.AddHostKey(signer)

    listener, err := net.Listen("tcp", g.config.ListenAddr)
    if err != nil {
        return err
    }

    for {
        conn, err := listener.Accept()
        if err != nil {
            continue
        }
        go g.handleConnection(conn, config)
    }
}

func (g *SSHGateway) authenticateKey(conn ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
    // Parse instance ID from username: user@{instance_id}.instances.hivemind.dev
    // Username format: "user" or "{project_id}:{instance_name}"
    instanceID := parseInstanceID(conn.User())

    // Get instance
    instance, err := g.instances.Get(context.Background(), instanceID)
    if err != nil {
        return nil, fmt.Errorf("instance not found")
    }

    // Check if instance is running
    if instance.Status.Phase != InstancePhaseRunning && instance.Status.Phase != InstancePhaseExpiring {
        return nil, fmt.Errorf("instance not running")
    }

    // For timed instances, check if lease has expired
    if instance.Spec.Instance.Lifecycle.Mode == LifecycleModeTimed {
        if time.Now().After(*instance.Status.ExpiresAt) {
            return nil, fmt.Errorf("instance lease has expired")
        }
    }

    // Validate SSH key against instance's authorized keys
    keyFingerprint := ssh.FingerprintSHA256(key)
    for _, authorizedKey := range instance.Spec.Instance.SSHKeys {
        parsed, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(authorizedKey.PublicKey))
        if ssh.FingerprintSHA256(parsed) == keyFingerprint {
            return &ssh.Permissions{
                Extensions: map[string]string{
                    "instance_id": instanceID,
                    "project_id":  instance.ProjectID,
                },
            }, nil
        }
    }

    return nil, fmt.Errorf("key not authorized")
}

func (g *SSHGateway) handleConnection(netConn net.Conn, config *ssh.ServerConfig) {
    defer netConn.Close()

    // SSH handshake
    sshConn, chans, reqs, err := ssh.NewServerConn(netConn, config)
    if err != nil {
        return
    }
    defer sshConn.Close()

    instanceID := sshConn.Permissions.Extensions["instance_id"]

    // Get instance backend address
    instance, _ := g.instances.Get(context.Background(), instanceID)
    backendAddr := fmt.Sprintf("%s:22", instance.Status.InternalIP)

    // Connect to backend
    backendConn, err := net.Dial("tcp", backendAddr)
    if err != nil {
        return
    }
    defer backendConn.Close()

    // Proxy SSH connection
    go ssh.DiscardRequests(reqs)

    for newChannel := range chans {
        g.proxyChannel(newChannel, backendConn, instance)
    }
}

func (g *SSHGateway) proxyChannel(newChannel ssh.NewChannel, backendConn net.Conn, instance *Workload) {
    // Accept channel from client
    clientChannel, clientRequests, _ := newChannel.Accept()
    defer clientChannel.Close()

    // Create channel to backend
    backendSSH, _ := ssh.Dial("tcp", backendConn.RemoteAddr().String(), &ssh.ClientConfig{
        User:            "root",
        HostKeyCallback: ssh.InsecureIgnoreHostKey(),
    })
    backendChannel, backendRequests, _ := backendSSH.OpenChannel(newChannel.ChannelType(), newChannel.ExtraData())
    defer backendChannel.Close()

    // Bidirectional proxy
    go io.Copy(clientChannel, backendChannel)
    go io.Copy(backendChannel, clientChannel)

    // Proxy requests
    go func() {
        for req := range clientRequests {
            backendChannel.SendRequest(req.Type, req.WantReply, req.Payload)
        }
    }()

    for req := range backendRequests {
        clientChannel.SendRequest(req.Type, req.WantReply, req.Payload)
    }

    // Update last activity
    g.instances.UpdateLastActivity(context.Background(), instance.ID)
}
```

### Web Terminal (Alternative to SSH Client)

For users who don't have an SSH client or prefer browser-based access.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        WEB TERMINAL ARCHITECTURE                         │
│                                                                          │
│   Browser                                                                │
│     │                                                                    │
│     │ wss://console.hivemind.dev/terminal/{instance_id}                 │
│     │                                                                    │
│     ▼                                                                    │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    TERMINAL SERVICE                              │   │
│   │                                                                  │   │
│   │   • WebSocket server                                             │   │
│   │   • JWT authentication (project token)                           │   │
│   │   • xterm.js frontend                                            │   │
│   │   • Translates WebSocket ←→ SSH                                  │   │
│   │                                                                  │   │
│   └──────────────────────────┬──────────────────────────────────────┘   │
│                              │                                          │
│                              │ SSH via SSH Gateway                      │
│                              │                                          │
│                              ▼                                          │
│                         Instance Pod                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

```go
package terminal

type TerminalService struct {
    sshGateway   *SSHGateway
    upgrader     websocket.Upgrader
}

func (s *TerminalService) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
    // Authenticate JWT
    token := r.Header.Get("Authorization")
    claims, err := validateJWT(token)
    if err != nil {
        http.Error(w, "unauthorized", 401)
        return
    }

    instanceID := chi.URLParam(r, "instance_id")

    // Verify instance belongs to project
    instance, err := s.instances.Get(r.Context(), instanceID)
    if err != nil || instance.ProjectID != claims.ProjectID {
        http.Error(w, "not found", 404)
        return
    }

    // Upgrade to WebSocket
    ws, err := s.upgrader.Upgrade(w, r, nil)
    if err != nil {
        return
    }
    defer ws.Close()

    // Create SSH session
    sshSession, err := s.createSSHSession(instance)
    if err != nil {
        ws.WriteMessage(websocket.TextMessage, []byte("Failed to connect: "+err.Error()))
        return
    }
    defer sshSession.Close()

    // Proxy WebSocket ←→ SSH
    go s.wsToSSH(ws, sshSession)
    s.sshToWS(sshSession, ws)
}

func (s *TerminalService) wsToSSH(ws *websocket.Conn, ssh *ssh.Session) {
    stdin, _ := ssh.StdinPipe()
    for {
        _, msg, err := ws.ReadMessage()
        if err != nil {
            return
        }

        // Parse xterm.js message
        var termMsg TerminalMessage
        json.Unmarshal(msg, &termMsg)

        switch termMsg.Type {
        case "input":
            stdin.Write([]byte(termMsg.Data))
        case "resize":
            ssh.WindowChange(termMsg.Rows, termMsg.Cols)
        }
    }
}

func (s *TerminalService) sshToWS(ssh *ssh.Session, ws *websocket.Conn) {
    stdout, _ := ssh.StdoutPipe()
    buf := make([]byte, 4096)
    for {
        n, err := stdout.Read(buf)
        if err != nil {
            return
        }
        ws.WriteMessage(websocket.TextMessage, buf[:n])
    }
}
```

### Instance Controller

```go
type InstanceController struct {
    workloads    *WorkloadStore
    scheduler    *Scheduler
    clusters     map[string]*ClusterAdapter
    sshGateway   *SSHGateway
    storage      *WorkspaceStorage
    notifier     *NotificationService
}

func (c *InstanceController) CreateInstance(ctx context.Context, req CreateInstanceRequest) (*Workload, error) {
    // Provision workspace storage
    workspaceID, err := c.storage.CreateWorkspace(ctx, WorkspaceCreateRequest{
        ProjectID: req.ProjectID,
        Size:      req.Workspace.Size,
    })
    if err != nil {
        return nil, err
    }

    // Determine lifecycle mode
    lifecycle := &InstanceLifecycle{
        Mode: LifecycleModePersistent,
    }
    if req.Duration != nil && *req.Duration > 0 {
        lifecycle = &InstanceLifecycle{
            Mode:              LifecycleModeTimed,
            Duration:          *req.Duration,
            PreserveWorkspace: req.PreserveWorkspaceOnExpiry,
            Extendable:        req.AllowExtensions,
            MaxDuration:       req.MaxDuration,
        }
    } else if req.IdleTimeout != nil {
        lifecycle.IdleTimeout = *req.IdleTimeout
    }

    workload := &Workload{
        ID:        generateInstanceID(req.ProjectID),
        ProjectID: req.ProjectID,
        Name:      req.Name,
        Kind:      WorkloadKindInstance,
        Spec: WorkloadSpec{
            Image:  req.Image,
            CPU:    req.CPU,
            Memory: req.Memory,
            GPU:    req.GPU,
            Instance: &InstanceSpec{
                SSHEnabled: true,
                SSHKeys:    req.SSHKeys,
                Workspace: &WorkspaceSpec{
                    Size:      req.Workspace.Size,
                    MountPath: "/home/user",
                },
                Network: &InstanceNetwork{
                    StableHostname: true,
                },
                Lifecycle: lifecycle,
            },
            Volumes: []VolumeSpec{
                {
                    Name:      "workspace",
                    VolumeID:  workspaceID,
                    MountPath: "/home/user",
                },
            },
        },
        Status: WorkloadStatus{
            Phase: WorkloadPhasePending,
        },
    }

    if err := c.workloads.Create(ctx, workload); err != nil {
        return nil, err
    }

    // Start instance immediately
    go c.startInstance(ctx, workload)

    return workload, nil
}

func (c *InstanceController) startInstance(ctx context.Context, instance *Workload) {
    // Schedule placement
    placement, err := c.scheduler.Schedule(ctx, instance)
    if err != nil {
        c.workloads.UpdateStatus(ctx, instance.ID, WorkloadStatus{
            Phase:   WorkloadPhaseFailed,
            Message: fmt.Sprintf("scheduling failed: %v", err),
        })
        return
    }

    instance.Placement = placement

    // Deploy to cluster
    adapter := c.clusters[placement.ClusterID]
    podIP, err := adapter.DeployInstance(ctx, instance)
    if err != nil {
        c.workloads.UpdateStatus(ctx, instance.ID, WorkloadStatus{
            Phase:   WorkloadPhaseFailed,
            Message: fmt.Sprintf("deployment failed: %v", err),
        })
        return
    }

    // Generate SSH endpoint
    sshEndpoint := fmt.Sprintf("%s.instances.hivemind.dev", instance.ID)

    // Calculate expiry for timed instances
    var expiresAt *time.Time
    if instance.Spec.Instance.Lifecycle.Mode == LifecycleModeTimed {
        expiry := time.Now().Add(instance.Spec.Instance.Lifecycle.Duration)
        expiresAt = &expiry
    }

    now := time.Now()
    c.workloads.UpdateStatus(ctx, instance.ID, WorkloadStatus{
        Phase:       InstancePhaseRunning,
        InternalIP:  podIP,
        SSHEndpoint: sshEndpoint,
        Hostname:    sshEndpoint,
        StartedAt:   &now,
        ExpiresAt:   expiresAt,
    })

    // Register with SSH gateway
    c.sshGateway.RegisterInstance(instance.ID, podIP)
}

func (c *InstanceController) ExtendInstance(ctx context.Context, instanceID string, additionalDuration time.Duration) error {
    instance, err := c.workloads.Get(ctx, instanceID)
    if err != nil {
        return err
    }

    lifecycle := instance.Spec.Instance.Lifecycle
    if lifecycle.Mode != LifecycleModeTimed {
        return errors.New("only timed instances can be extended")
    }

    if !lifecycle.Extendable {
        return errors.New("this instance does not allow extensions")
    }

    // Calculate new expiry
    currentExpiry := *instance.Status.ExpiresAt
    newExpiry := currentExpiry.Add(additionalDuration)

    // Check against max duration
    if lifecycle.MaxDuration > 0 {
        maxExpiry := instance.Status.StartedAt.Add(lifecycle.MaxDuration)
        if newExpiry.After(maxExpiry) {
            return fmt.Errorf("extension would exceed maximum duration of %s", lifecycle.MaxDuration)
        }
    }

    // Update status
    instance.Status.ExpiresAt = &newExpiry
    instance.Status.ExtensionsUsed++

    // If was in expiring state, return to running
    if instance.Status.Phase == InstancePhaseExpiring {
        instance.Status.Phase = InstancePhaseRunning
    }

    return c.workloads.Update(ctx, instance)
}

func (c *InstanceController) StopInstance(ctx context.Context, instanceID string) error {
    instance, err := c.workloads.Get(ctx, instanceID)
    if err != nil {
        return err
    }

    // Timed instances cannot be stopped, only terminated
    if instance.Spec.Instance.Lifecycle.Mode == LifecycleModeTimed {
        return errors.New("timed instances cannot be stopped; they can only be terminated or extended")
    }

    // Update status to stopping
    c.workloads.UpdateStatus(ctx, instanceID, WorkloadStatus{
        Phase: InstancePhaseStopping,
    })

    // Gracefully stop the pod (workspace persists)
    adapter := c.clusters[instance.Placement.ClusterID]
    if err := adapter.StopInstance(ctx, instance); err != nil {
        return err
    }

    // Unregister from SSH gateway
    c.sshGateway.UnregisterInstance(instanceID)

    c.workloads.UpdateStatus(ctx, instanceID, WorkloadStatus{
        Phase: InstancePhaseStopped,
    })

    return nil
}

func (c *InstanceController) StartInstance(ctx context.Context, instanceID string) error {
    instance, err := c.workloads.Get(ctx, instanceID)
    if err != nil {
        return err
    }

    if instance.Status.Phase != InstancePhaseStopped {
        return errors.New("instance must be stopped to start")
    }

    // Re-deploy (same workspace volume)
    go c.startInstance(ctx, instance)
    return nil
}

func (c *InstanceController) DeleteInstance(ctx context.Context, instanceID string) error {
    instance, err := c.workloads.Get(ctx, instanceID)
    if err != nil {
        return err
    }

    // Stop if running
    if instance.Status.Phase == InstancePhaseRunning || instance.Status.Phase == InstancePhaseExpiring {
        c.terminateInstance(ctx, instance)
    }

    // Delete workspace storage (unless preserved)
    shouldPreserve := instance.Spec.Instance.Lifecycle.Mode == LifecycleModeTimed &&
        instance.Spec.Instance.Lifecycle.PreserveWorkspace

    if !shouldPreserve && instance.Spec.Instance.Workspace != nil {
        c.storage.DeleteWorkspace(ctx, instance.Spec.Volumes[0].VolumeID)
    }

    // Delete workload record
    return c.workloads.Delete(ctx, instanceID)
}

func (c *InstanceController) terminateInstance(ctx context.Context, instance *Workload) {
    c.workloads.UpdateStatus(ctx, instance.ID, WorkloadStatus{
        Phase: InstancePhaseTerminating,
    })

    // Unregister from SSH gateway
    c.sshGateway.UnregisterInstance(instance.ID)

    // Kill the pod
    adapter := c.clusters[instance.Placement.ClusterID]
    adapter.KillInstance(ctx, instance)
}

// Lifecycle monitors
func (c *InstanceController) RunLifecycleMonitors(ctx context.Context) {
    go c.runIdleChecker(ctx)
    go c.runLeaseChecker(ctx)
}

// Auto-stop based on idle timeout (persistent mode)
func (c *InstanceController) runIdleChecker(ctx context.Context) {
    ticker := time.NewTicker(time.Minute)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            c.checkIdleInstances(ctx)
        }
    }
}

func (c *InstanceController) checkIdleInstances(ctx context.Context) {
    instances, _ := c.workloads.ListByKind(ctx, WorkloadKindInstance)

    for _, instance := range instances {
        if instance.Status.Phase != InstancePhaseRunning {
            continue
        }

        lifecycle := instance.Spec.Instance.Lifecycle
        if lifecycle.Mode != LifecycleModePersistent || lifecycle.IdleTimeout == 0 {
            continue
        }

        lastActivity := instance.Status.LastActivity
        if lastActivity == nil {
            lastActivity = instance.Status.StartedAt
        }

        if time.Since(*lastActivity) > lifecycle.IdleTimeout {
            log.Printf("Auto-stopping idle instance: %s", instance.ID)
            c.StopInstance(ctx, instance.ID)
        }
    }
}

// Auto-terminate based on lease expiry (timed mode)
func (c *InstanceController) runLeaseChecker(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case now := <-ticker.C:
            c.checkLeaseExpiry(ctx, now)
        }
    }
}

func (c *InstanceController) checkLeaseExpiry(ctx context.Context, now time.Time) {
    instances, _ := c.workloads.ListByKind(ctx, WorkloadKindInstance)

    for _, instance := range instances {
        if instance.Spec.Instance.Lifecycle.Mode != LifecycleModeTimed {
            continue
        }

        if instance.Status.Phase != InstancePhaseRunning && instance.Status.Phase != InstancePhaseExpiring {
            continue
        }

        expiresAt := instance.Status.ExpiresAt
        if expiresAt == nil {
            continue
        }

        timeRemaining := expiresAt.Sub(now)

        // Warning: 15 minutes before expiry
        if timeRemaining <= 15*time.Minute && instance.Status.Phase == InstancePhaseRunning {
            instance.Status.Phase = InstancePhaseExpiring
            instance.Status.TimeRemaining = &timeRemaining
            c.workloads.Update(ctx, instance)

            // Send notification
            c.notifier.NotifyLeaseExpiring(ctx, instance, timeRemaining)
        }

        // Terminate: lease expired
        if timeRemaining <= 0 {
            log.Printf("Terminating expired instance: %s", instance.ID)

            // Grace period: 5 minutes to save work
            c.notifier.NotifyLeaseExpired(ctx, instance)
            time.Sleep(5 * time.Minute)

            c.DeleteInstance(ctx, instance.ID)
        }
    }
}
```

### Instance API

```go
// Instance-specific API endpoints
// POST /v1/instances                       # Create instance
// GET  /v1/instances/{id}                  # Get instance status
// POST /v1/instances/{id}/start            # Start stopped instance (persistent only)
// POST /v1/instances/{id}/stop             # Stop running instance (persistent only)
// POST /v1/instances/{id}/restart          # Restart instance
// POST /v1/instances/{id}/extend           # Extend lease (timed only)
// DELETE /v1/instances/{id}                # Delete instance and workspace
// GET  /v1/instances/{id}/ssh-command      # Get SSH connection command
// POST /v1/instances/{id}/ssh-keys         # Add SSH key
// DELETE /v1/instances/{id}/ssh-keys/{name} # Remove SSH key
// POST /v1/instances/{id}/snapshot         # Create workspace snapshot
// GET  /v1/instances/{id}/metrics          # Get instance metrics (CPU, GPU, etc.)
// GET  /v1/instances/{id}/time-remaining   # Get remaining lease time (timed only)

func (api *HivemindAPI) CreateInstance(ctx context.Context, req CreateInstanceRequest) (*Workload, error) {
    return api.instanceController.CreateInstance(ctx, req)
}

func (api *HivemindAPI) ExtendInstance(ctx context.Context, instanceID string, duration time.Duration) error {
    return api.instanceController.ExtendInstance(ctx, instanceID, duration)
}

func (api *HivemindAPI) GetSSHCommand(ctx context.Context, instanceID string) (*SSHCommand, error) {
    instance, err := api.workloads.Get(ctx, instanceID)
    if err != nil {
        return nil, err
    }

    if instance.Status.Phase != InstancePhaseRunning && instance.Status.Phase != InstancePhaseExpiring {
        return nil, errors.New("instance not running")
    }

    return &SSHCommand{
        Command:  fmt.Sprintf("ssh user@%s", instance.Status.SSHEndpoint),
        Endpoint: instance.Status.SSHEndpoint,
        Port:     22,
        Username: "user",
    }, nil
}

func (api *HivemindAPI) GetTimeRemaining(ctx context.Context, instanceID string) (*TimeRemainingResponse, error) {
    instance, err := api.workloads.Get(ctx, instanceID)
    if err != nil {
        return nil, err
    }

    if instance.Spec.Instance.Lifecycle.Mode != LifecycleModeTimed {
        return nil, errors.New("instance is not timed")
    }

    remaining := time.Until(*instance.Status.ExpiresAt)
    if remaining < 0 {
        remaining = 0
    }

    return &TimeRemainingResponse{
        ExpiresAt:       *instance.Status.ExpiresAt,
        TimeRemaining:   remaining,
        Extendable:      instance.Spec.Instance.Lifecycle.Extendable,
        ExtensionsUsed:  instance.Status.ExtensionsUsed,
        MaxDuration:     instance.Spec.Instance.Lifecycle.MaxDuration,
    }, nil
}
```

### Instance Examples

```yaml
# Persistent development instance (no auto-terminate)
kind: instance
name: dev-workspace
spec:
  image: hivemind/pytorch:2.0-cuda12
  cpu: 8
  memory: 64Gi
  gpu:
    type: a100_80gb
    count: 1
  instance:
    ssh_enabled: true
    ssh_keys:
      - name: laptop
        public_key: "ssh-ed25519 AAAA... user@laptop"
    workspace:
      size: 500Gi
      mount_path: /home/user
    network:
      stable_hostname: true
    ports:
      - name: jupyter
        port: 8888
        public: true
    lifecycle:
      mode: persistent
      idle_timeout: 4h        # Stop if no SSH activity for 4h

---
# Timed instance: 4-hour GPU rental
kind: instance
name: training-session
spec:
  image: hivemind/pytorch:2.0-cuda12
  cpu: 32
  memory: 256Gi
  gpu:
    type: h100_sxm
    count: 8
  instance:
    ssh_enabled: true
    ssh_keys:
      - name: team-key
        public_key: "ssh-ed25519 AAAA..."
    workspace:
      size: 1Ti
    lifecycle:
      mode: timed
      duration: 4h                 # Auto-terminate after 4 hours
      preserve_workspace: true     # Keep workspace for later
      extendable: true             # Allow extensions
      max_duration: 24h            # Maximum total time

---
# Short-term timed instance: quick experiment
kind: instance
name: quick-test
spec:
  image: hivemind/pytorch:2.0-cuda12
  cpu: 4
  memory: 32Gi
  gpu:
    type: a100_80gb
    count: 1
  instance:
    ssh_enabled: true
    ssh_keys:
      - name: my-key
        public_key: "ssh-ed25519 AAAA..."
    workspace:
      size: 100Gi
    lifecycle:
      mode: timed
      duration: 1h                 # Just need an hour
      preserve_workspace: false    # Delete workspace when done
      extendable: false            # No extensions
```

---

## Integration with Existing Components

### Router Changes

The Router handles HTTP traffic for all workload types but with different behaviors:

```go
func (r *Router) handleRequest(ctx context.Context, req *http.Request) (*http.Response, error) {
    appID := extractAppID(req)
    workload, err := r.workloads.Get(ctx, appID)
    if err != nil {
        return nil, err
    }

    switch workload.Kind {
    case WorkloadKindServerless:
        // Existing behavior: queue during cold start, autoscale
        return r.handleServerlessRequest(ctx, req, workload)

    case WorkloadKindJob:
        // Jobs don't receive HTTP traffic through Router
        return nil, errors.New("jobs do not accept HTTP requests")

    case WorkloadKindInstance:
        // Route to running instance (no queuing, no autoscale)
        return r.handleInstanceRequest(ctx, req, workload)

    default:
        return nil, errors.New("unknown workload kind")
    }
}

func (r *Router) handleInstanceRequest(ctx context.Context, req *http.Request, workload *Workload) (*http.Response, error) {
    phase := workload.Status.Phase
    if phase != InstancePhaseRunning && phase != InstancePhaseExpiring {
        return nil, &HTTPError{
            Code:    503,
            Message: "Instance not running. Start the instance first.",
        }
    }

    // For timed instances in expiring state, add warning header
    if phase == InstancePhaseExpiring {
        // Add header to warn client
    }

    // Direct proxy to instance (no queueing)
    return r.proxy(ctx, req, workload.Status.InternalIP)
}
```

### Scheduler Changes

The scheduler handles all workload types with type-specific scoring:

```go
func (s *Scheduler) Schedule(ctx context.Context, workload *Workload) (*PlacementDecision, error) {
    switch workload.Kind {
    case WorkloadKindServerless:
        return s.scheduleServerless(ctx, workload)

    case WorkloadKindJob, WorkloadKindCronJob:
        return s.scheduleJob(ctx, workload)

    case WorkloadKindInstance:
        return s.scheduleInstance(ctx, workload)

    default:
        return nil, errors.New("unknown workload kind")
    }
}

func (s *Scheduler) scheduleJob(ctx context.Context, workload *Workload) (*PlacementDecision, error) {
    // Job-specific considerations:
    // - Spot instance tolerance (can use cheaper spot for jobs)
    // - No need for sticky placement (jobs are ephemeral)
    // - Deadline pressure scoring (urgent jobs get priority)

    ctx := &SchedulingContext{
        Workload:        workload,
        SpotTolerant:    true,  // Jobs can run on spot
        PreemptionClass: "job", // Can be preempted by instances/serverless
    }

    return s.findBestPlacement(ctx)
}

func (s *Scheduler) scheduleInstance(ctx context.Context, workload *Workload) (*PlacementDecision, error) {
    // Instance-specific considerations:
    // - Prefer on-demand (not spot) for stability
    // - Consider workspace storage locality
    // - Sticky placement (restart on same node if possible)
    // - Timed instances might tolerate spot for cost savings

    spotTolerant := false
    if workload.Spec.Instance.Lifecycle.Mode == LifecycleModeTimed {
        // Timed instances can use spot if duration is short
        spotTolerant = workload.Spec.Instance.Lifecycle.Duration <= 4*time.Hour
    }

    ctx := &SchedulingContext{
        Workload:        workload,
        SpotTolerant:    spotTolerant,
        PreemptionClass: "instance",      // Higher priority than jobs
        StickyNode:      workload.Status.NodeID, // Prefer same node on restart
    }

    return s.findBestPlacement(ctx)
}
```

### Agent Changes

The Agent needs to support workspace volume management for Instances:

```go
// Storage module extension for workspace volumes
func (m *StorageModule) MountWorkspace(ctx context.Context, req WorkspaceMountRequest) error {
    // Workspace volumes are persistent block storage (different from JuiceFS shared storage)
    // Use cloud provider's block storage (EBS, Persistent Disk, etc.)

    return m.blockStorage.Mount(ctx, BlockMountRequest{
        VolumeID:   req.VolumeID,
        MountPath:  req.MountPath,
        FSType:     "ext4",
        ReadOnly:   false,
    })
}
```

---

## API Summary

### Unified Workload API

```yaml
# Serverless (existing)
POST /v1/workloads                      # Create serverless workload
GET  /v1/workloads/{id}                 # Get status
PUT  /v1/workloads/{id}                 # Update config
DELETE /v1/workloads/{id}               # Delete

# Jobs
POST /v1/jobs                           # Submit job
GET  /v1/jobs/{id}                      # Get job status
GET  /v1/jobs/{id}/logs                 # Stream logs
GET  /v1/jobs/{id}/output               # Get output/artifacts
POST /v1/jobs/{id}/cancel               # Cancel job
POST /v1/jobs/{id}/retry                # Retry failed job

# CronJobs
POST /v1/cronjobs                       # Create recurring job
GET  /v1/cronjobs/{id}                  # Get config
PUT  /v1/cronjobs/{id}                  # Update schedule
POST /v1/cronjobs/{id}/suspend          # Pause
POST /v1/cronjobs/{id}/resume           # Resume
POST /v1/cronjobs/{id}/trigger          # Manual trigger
GET  /v1/cronjobs/{id}/runs             # Run history

# Instances
POST /v1/instances                      # Create instance
GET  /v1/instances/{id}                 # Get status
POST /v1/instances/{id}/start           # Start (persistent only)
POST /v1/instances/{id}/stop            # Stop (persistent only)
POST /v1/instances/{id}/restart         # Restart
POST /v1/instances/{id}/extend          # Extend lease (timed only)
DELETE /v1/instances/{id}               # Delete
GET  /v1/instances/{id}/ssh-command     # Get SSH command
POST /v1/instances/{id}/ssh-keys        # Add SSH key
DELETE /v1/instances/{id}/ssh-keys/{n}  # Remove SSH key
POST /v1/instances/{id}/snapshot        # Snapshot workspace
GET  /v1/instances/{id}/time-remaining  # Lease time (timed only)
```

---

## New Components Required

| Component | Purpose | Technology | DST Required |
|-----------|---------|------------|--------------|
| **Job Controller** | Job queue, execution, cron scheduling | Zig | Yes (queue ordering, retry logic) |
| **SSH Gateway** | SSH connection proxy | Go | No |
| **Terminal Service** | WebSocket → SSH translation | Go | No |
| **Workspace Storage** | Persistent block storage management | Go | No |
| **Notification Service** | Lease expiry warnings | Go | No |

---

## Migration Considerations

### Phase 4.5: Add Job Support

1. Extend `WorkloadSpec` with `Kind` and `JobSpec`
2. Implement Job Controller
3. Add job-specific scheduler scoring
4. Implement job API endpoints
5. Update CLI with `hivemind job submit`, `hivemind job logs`, etc.

### Phase 4.6: Add Instance Support

1. Extend `WorkloadSpec` with `InstanceSpec`
2. Deploy SSH Gateway in each region
3. Implement Instance Controller with lifecycle management
4. Add workspace storage integration
5. Implement Terminal Service (optional, for web access)
6. Implement notification service for timed instance warnings
7. Update CLI with `hivemind instance create`, `hivemind instance ssh`, etc.

---

## CLI Examples

```bash
# Submit a job
hivemind job submit \
  --name train-v2 \
  --image sha256:abc123 \
  --gpu h100:8 \
  --timeout 24h \
  --env DATASET=s3://bucket/data

# Watch job progress
hivemind job logs train-v2 --follow

# Get job output
hivemind job output train-v2

# Create a recurring job
hivemind cronjob create \
  --name daily-sync \
  --schedule "0 0 * * *" \
  --image sha256:def456

# Create a persistent instance
hivemind instance create \
  --name dev-workspace \
  --image hivemind/pytorch:2.0 \
  --gpu a100:1 \
  --workspace 500Gi \
  --idle-timeout 4h \
  --ssh-key ~/.ssh/id_ed25519.pub

# Create a timed instance (4-hour lease)
hivemind instance create \
  --name training-session \
  --image hivemind/pytorch:2.0 \
  --gpu h100:8 \
  --workspace 1Ti \
  --duration 4h \
  --extendable \
  --preserve-workspace \
  --ssh-key ~/.ssh/id_ed25519.pub

# Check remaining time on timed instance
hivemind instance time-remaining training-session
# Output: 2h 15m remaining (expires at 2025-01-15 16:00 UTC)

# Extend timed instance
hivemind instance extend training-session --duration 2h
# Output: Extended by 2h. New expiry: 2025-01-15 18:00 UTC

# SSH into instance
hivemind instance ssh dev-workspace
# Or directly:
ssh user@inst-abc123.instances.hivemind.dev

# Stop persistent instance (preserves workspace)
hivemind instance stop dev-workspace

# Start persistent instance
hivemind instance start dev-workspace

# Delete instance (deletes workspace unless --preserve-workspace was set)
hivemind instance delete dev-workspace
```

---

## Billing Considerations

| Workload Type | Billing Model |
|---------------|---------------|
| **Serverless** | Per-request + GPU-seconds active |
| **Job** | GPU-seconds from start to completion |
| **Instance (persistent)** | GPU-hours while running (stopped = no charge) |
| **Instance (timed)** | Prepaid for duration (extensions billed incrementally) |

For timed instances, consider:
- Prepaid block pricing (e.g., 4-hour block at discount)
- Extension pricing (per-hour at regular rate)
- Unused time is non-refundable (incentivizes accurate duration estimates)

---

## Open Questions

1. **Workspace storage backend**: EBS? Cloud provider block storage? Or extend JuiceFS?
2. **SSH key management**: Per-instance keys only, or project-level authorized_keys?
3. **Instance hibernation**: Should stopped instances hibernate (save memory state) or just stop?
4. **Job preemption**: Can urgent serverless requests preempt running jobs?
5. **Timed instance pricing**: Prepaid blocks vs. pay-as-you-go with cap?
6. **Instance migration**: Can instances live-migrate between nodes for maintenance?
7. **Timed instance grace period**: How long before forced termination after expiry warning?

---

## Related Documents

- [HIVEMIND.md](HIVEMIND.md) - Base control plane design
- [ROUTER.md](ROUTER.md) - Request routing (serverless focus)
- [AGENT.md](AGENT.md) - Node agent capabilities
- [PROVIDERS.md](PROVIDERS.md) - Multi-provider pool model
