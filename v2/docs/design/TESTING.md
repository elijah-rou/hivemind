> **PARTIALLY IMPLEMENTED**: VOPR simulation (Zig), worker deterministic sim (Rust), standalone fuzzer (`zig build fuzz`), local smoke test, 158+ tests passing. Pending: load testing, chaos on real infrastructure.

# Hivemind Testing Strategy

> Comprehensive testing approach covering unit tests, integration tests, load tests, chaos engineering, and go/no-go criteria for each Hivemind component.

---

## Table of Contents

1. [Testing Philosophy](#testing-philosophy)
2. [Testing Pyramid](#testing-pyramid)
3. [Component Testing](#component-testing)
4. [Integration Testing](#integration-testing)
5. [Load Testing](#load-testing)
6. [Chaos Engineering](#chaos-engineering)
7. [Staging Environment](#staging-environment)
8. [Migration Testing](#migration-testing)
9. [Go/No-Go Criteria](#gono-go-criteria)
10. [CI/CD Integration](#cicd-integration)

---

## Testing Philosophy

### Principles

1. **Test at the Right Level**: Unit tests for logic, integration tests for contracts, E2E tests for critical paths
2. **Production Parity**: Staging environment mirrors production as closely as possible
3. **Shift Left**: Catch issues early in development, not in production
4. **Continuous Testing**: Tests run on every commit, not just before release
5. **Measurable Quality**: Coverage metrics, performance baselines, reliability targets

### Testing Goals by Phase

| Phase | Component | Primary Testing Focus |
|-------|-----------|----------------------|
| 1 | Router | Latency, throughput, queue behavior |
| 2 | Honeycomb | Pull performance, cache efficiency, P2P reliability |
| 3 | Beekeeper | Build isolation, cache hits, concurrent builds |
| 4 | Hivemind | Scheduling correctness, scaling behavior, failover |
| 5 | Agent | Resource reporting, module reliability, upgrade safety |

---

## Testing Pyramid

```
                    ┌───────────┐
                    │   E2E     │  Few, critical paths only
                    │   Tests   │  ~5% of tests
                    └─────┬─────┘
                          │
                    ┌─────▼─────┐
                    │Integration│  API contracts, component
                    │   Tests   │  interactions ~20% of tests
                    └─────┬─────┘
                          │
              ┌───────────▼───────────┐
              │      Unit Tests       │  Business logic, algorithms
              │                       │  ~75% of tests
              └───────────────────────┘
```

### Test Type Definitions

| Type | Scope | Speed | Isolation | When to Run |
|------|-------|-------|-----------|-------------|
| Unit | Single function/module | < 100ms | Full (mocked deps) | Every commit |
| Integration | Multiple components | < 30s | Partial (real deps) | Every PR |
| E2E | Full system | < 5min | None (real system) | Pre-deploy |
| Load | Performance | Minutes-hours | None | Weekly, pre-release |
| Chaos | Resilience | Hours | None | Weekly, pre-release |

---

## Component Testing

### Router Testing

#### Unit Tests

```rust
#[cfg(test)]
mod router_tests {
    // Queue behavior
    #[test]
    fn test_queue_enqueue_dequeue() {
        let queue = RequestQueue::new(100);
        let request = mock_request();

        queue.enqueue(request.clone());
        let dequeued = queue.dequeue();

        assert_eq!(request.id, dequeued.id);
    }

    #[test]
    fn test_queue_overflow_behavior() {
        let queue = RequestQueue::new(2);

        queue.enqueue(mock_request());
        queue.enqueue(mock_request());
        let result = queue.try_enqueue(mock_request());

        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), QueueError::Full);
    }

    // Routing logic
    #[test]
    fn test_route_selection_round_robin() {
        let router = Router::new(vec![
            backend("a", healthy()),
            backend("b", healthy()),
        ]);

        assert_eq!(router.select().id, "a");
        assert_eq!(router.select().id, "b");
        assert_eq!(router.select().id, "a");
    }

    #[test]
    fn test_route_selection_skips_unhealthy() {
        let router = Router::new(vec![
            backend("a", unhealthy()),
            backend("b", healthy()),
        ]);

        assert_eq!(router.select().id, "b");
        assert_eq!(router.select().id, "b");
    }

    // Graceful scaling
    #[test]
    fn test_graceful_shutdown_drains_queue() {
        let router = Router::new(vec![backend("a", healthy())]);
        router.enqueue(mock_request());

        let shutdown = router.initiate_shutdown();

        assert!(!shutdown.is_complete());
        router.process_one();
        assert!(shutdown.is_complete());
    }
}
```

#### Integration Tests

```rust
#[tokio::test]
async fn test_router_forwards_to_backend() {
    // Start mock backend
    let backend = MockBackend::start().await;

    // Configure router
    let router = Router::builder()
        .backend(backend.addr())
        .build()
        .await;

    // Send request through router
    let response = router.handle(Request::get("/health")).await;

    assert_eq!(response.status(), 200);
    assert_eq!(backend.request_count(), 1);
}

#[tokio::test]
async fn test_router_reports_queue_depth_to_hivemind() {
    let hivemind = MockHivemind::start().await;
    let router = Router::builder()
        .hivemind(hivemind.addr())
        .build()
        .await;

    // Enqueue requests
    for _ in 0..10 {
        router.enqueue(mock_request());
    }

    // Wait for metric report
    tokio::time::sleep(Duration::from_secs(1)).await;

    let metrics = hivemind.received_metrics();
    assert!(metrics.iter().any(|m| m.queue_depth == 10));
}
```

#### Performance Tests

| Metric | Target | Test Method |
|--------|--------|-------------|
| p50 latency | < 1ms | wrk benchmark |
| p99 latency | < 10ms | wrk benchmark |
| Throughput | > 100k req/s | wrk benchmark |
| Queue drain time | < 5s for 1000 requests | Custom benchmark |
| Memory per connection | < 10KB | Memory profiling |

```bash
# Router performance test
wrk -t12 -c400 -d60s --latency http://router:8080/health

# Expected output:
# Latency Distribution
#    50%    0.89ms
#    99%    8.23ms
# Requests/sec: 125,432
```

---

### Honeycomb Testing

#### Unit Tests

```rust
#[cfg(test)]
mod honeycomb_tests {
    // Layer storage
    #[test]
    fn test_layer_deduplication() {
        let store = LayerStore::new();
        let layer = mock_layer("sha256:abc123");

        store.put(layer.clone());
        store.put(layer.clone());

        assert_eq!(store.layer_count(), 1);
    }

    // Manifest parsing
    #[test]
    fn test_manifest_v2_parsing() {
        let json = include_str!("fixtures/manifest_v2.json");
        let manifest = Manifest::parse(json).unwrap();

        assert_eq!(manifest.schema_version, 2);
        assert_eq!(manifest.layers.len(), 3);
    }

    // Cache behavior
    #[test]
    fn test_cache_eviction_lru() {
        let cache = LayerCache::new(capacity: 2);

        cache.put("a", layer_a());
        cache.put("b", layer_b());
        cache.get("a"); // Access 'a', making 'b' LRU
        cache.put("c", layer_c()); // Should evict 'b'

        assert!(cache.contains("a"));
        assert!(!cache.contains("b"));
        assert!(cache.contains("c"));
    }
}
```

#### Integration Tests

```rust
#[tokio::test]
async fn test_docker_pull_from_honeycomb() {
    let honeycomb = Honeycomb::start().await;

    // Push image
    honeycomb.push_image("test/image:v1", mock_image()).await;

    // Pull via Docker CLI
    let output = Command::new("docker")
        .args(["pull", &format!("{}/test/image:v1", honeycomb.addr())])
        .output()
        .await?;

    assert!(output.status.success());
}

#[tokio::test]
async fn test_p2p_layer_distribution() {
    // Start multiple nodes
    let node1 = HoneycombNode::start().await;
    let node2 = HoneycombNode::start().await;
    let node3 = HoneycombNode::start().await;

    // Push layer to node1
    node1.push_layer("sha256:abc", mock_layer()).await;

    // Pull from node3 (should get from P2P swarm)
    let layer = node3.pull_layer("sha256:abc").await;

    assert!(layer.is_ok());

    // Verify P2P was used (not origin)
    let stats = node3.pull_stats("sha256:abc");
    assert!(stats.p2p_bytes > 0);
}
```

#### Performance Tests

| Metric | Target | Test Method |
|--------|--------|-------------|
| Image pull (cached) | < 5s for 5GB image | Docker pull benchmark |
| Image pull (uncached) | < 30s for 5GB image | Docker pull benchmark |
| Cache hit rate | > 80% | Prometheus metrics |
| P2P distribution | > 50% traffic offload | Network metrics |
| Registry API latency | < 100ms p99 | API benchmark |

---

### Beekeeper Testing

#### Unit Tests

```rust
#[cfg(test)]
mod beekeeper_tests {
    // Dockerfile generation
    #[test]
    fn test_dockerfile_generation_python() {
        let config = BuildConfig {
            runtime: Runtime::Python("3.11"),
            dependencies: vec!["numpy", "torch"],
            entrypoint: "main.py",
        };

        let dockerfile = generate_dockerfile(&config);

        assert!(dockerfile.contains("FROM python:3.11"));
        assert!(dockerfile.contains("pip install numpy torch"));
        assert!(dockerfile.contains("CMD [\"python\", \"main.py\"]"));
    }

    // Build queue
    #[test]
    fn test_build_queue_priority() {
        let queue = BuildQueue::new();

        queue.enqueue(build_request(priority: 1));
        queue.enqueue(build_request(priority: 10));
        queue.enqueue(build_request(priority: 5));

        assert_eq!(queue.dequeue().priority, 10);
        assert_eq!(queue.dequeue().priority, 5);
        assert_eq!(queue.dequeue().priority, 1);
    }

    // Cache key generation
    #[test]
    fn test_cache_key_deterministic() {
        let config1 = BuildConfig { /* ... */ };
        let config2 = config1.clone();

        let key1 = generate_cache_key(&config1);
        let key2 = generate_cache_key(&config2);

        assert_eq!(key1, key2);
    }
}
```

#### Integration Tests

```rust
#[tokio::test]
async fn test_full_build_pipeline() {
    let beekeeper = Beekeeper::start().await;
    let honeycomb = Honeycomb::start().await;

    // Submit build
    let build_id = beekeeper.submit_build(BuildRequest {
        source: "https://github.com/test/repo",
        dockerfile: "FROM python:3.11\nRUN pip install numpy",
        tag: "test/image:v1",
    }).await;

    // Wait for completion
    let result = beekeeper.wait_for_build(build_id).await;

    assert!(result.success);
    assert!(honeycomb.image_exists("test/image:v1").await);
}

#[tokio::test]
async fn test_build_isolation() {
    let beekeeper = Beekeeper::start().await;

    // Start two builds from different customers
    let build1 = beekeeper.submit_build(customer: "a", /* ... */).await;
    let build2 = beekeeper.submit_build(customer: "b", /* ... */).await;

    // Verify they can't access each other's files
    let logs1 = beekeeper.get_logs(build1).await;
    let logs2 = beekeeper.get_logs(build2).await;

    assert!(!logs1.contains("customer_b"));
    assert!(!logs2.contains("customer_a"));
}
```

#### Performance Tests

| Metric | Target | Test Method |
|--------|--------|-------------|
| Build time (cached) | < 30s | Benchmark suite |
| Build time (uncached) | < 5min | Benchmark suite |
| Cache hit rate | > 70% | Prometheus metrics |
| Concurrent builds | 50 per cluster | Load test |
| Build queue latency | < 10s to start | Queue metrics |

---

### Hivemind Testing

#### Unit Tests

```rust
#[cfg(test)]
mod hivemind_tests {
    // Scheduler scoring
    #[test]
    fn test_scheduler_prefers_data_locality() {
        let scheduler = Scheduler::new(weights: default_weights());

        let workload = workload_with_data_in("us-east-1");
        let clusters = vec![
            cluster("us-east-1", available: true),
            cluster("us-west-2", available: true),
        ];

        let placement = scheduler.score(&workload, &clusters);

        assert_eq!(placement.best().cluster, "us-east-1");
    }

    #[test]
    fn test_scheduler_respects_compliance_constraints() {
        let scheduler = Scheduler::new(weights: default_weights());

        let workload = workload_with_gdpr(true);
        let clusters = vec![
            cluster("us-east-1", gdpr_compliant: false),
            cluster("eu-west-1", gdpr_compliant: true),
        ];

        let placement = scheduler.score(&workload, &clusters);

        assert_eq!(placement.best().cluster, "eu-west-1");
    }

    // Autoscaler
    #[test]
    fn test_autoscaler_scales_up_on_queue_depth() {
        let autoscaler = Autoscaler::new(threshold: 10);

        let decision = autoscaler.evaluate(QueueMetrics {
            depth: 50,
            oldest_request_age: Duration::from_secs(5),
        });

        assert_eq!(decision, ScaleDecision::ScaleUp { replicas: 5 });
    }

    #[test]
    fn test_autoscaler_cooldown_prevents_flapping() {
        let autoscaler = Autoscaler::new(cooldown: Duration::from_secs(60));

        autoscaler.evaluate(/* triggers scale up */);
        let decision = autoscaler.evaluate(/* would trigger scale down */);

        assert_eq!(decision, ScaleDecision::NoChange { reason: "cooldown" });
    }

    // State machine
    #[test]
    fn test_workload_state_transitions() {
        let workload = Workload::new();

        assert_eq!(workload.state(), State::Pending);

        workload.transition(Event::Scheduled);
        assert_eq!(workload.state(), State::Scheduled);

        workload.transition(Event::ContainerStarted);
        assert_eq!(workload.state(), State::Running);

        workload.transition(Event::HealthCheckPassed);
        assert_eq!(workload.state(), State::Ready);
    }
}
```

#### Integration Tests

```rust
#[tokio::test]
async fn test_hivemind_schedules_to_agent() {
    let hivemind = Hivemind::start().await;
    let agent = Agent::start().await;

    // Register agent
    agent.register_with(hivemind.addr()).await;

    // Create workload
    let workload_id = hivemind.create_workload(WorkloadSpec {
        image: "test/image:v1",
        gpu: GpuRequirement::A100(1),
    }).await;

    // Wait for scheduling
    let workload = hivemind.wait_for_state(workload_id, State::Running).await;

    assert_eq!(workload.node, agent.node_id());
}

#[tokio::test]
async fn test_hivemind_router_integration() {
    let hivemind = Hivemind::start().await;
    let router = Router::start().await;

    // Connect router to hivemind
    router.connect_to(hivemind.addr()).await;

    // Simulate queue buildup
    for _ in 0..100 {
        router.enqueue(mock_request()).await;
    }

    // Verify hivemind receives metrics
    let metrics = hivemind.get_queue_metrics("test-workload").await;
    assert_eq!(metrics.depth, 100);

    // Verify scale decision
    let decision = hivemind.get_scale_decision("test-workload").await;
    assert!(matches!(decision, ScaleDecision::ScaleUp { .. }));
}
```

#### Performance Tests

| Metric | Target | Test Method |
|--------|--------|-------------|
| Scheduling latency | < 100ms | Benchmark |
| Scale decision latency | < 1s | Benchmark |
| API throughput | > 1000 req/s | Load test |
| State sync latency | < 5s cross-cluster | Distributed test |
| Failover time | < 30s | Chaos test |

---

### Agent Testing

#### Unit Tests

```rust
#[cfg(test)]
mod agent_tests {
    // Metrics collection
    #[test]
    fn test_gpu_metrics_collection() {
        let gpu = MockGpu::new(utilization: 75, memory_used: 40_000);
        let collector = GpuMetricsCollector::new(gpu);

        let metrics = collector.collect();

        assert_eq!(metrics.utilization_percent, 75);
        assert_eq!(metrics.memory_used_mb, 40_000);
    }

    // Module lifecycle
    #[test]
    fn test_module_startup_order() {
        let agent = Agent::new();

        agent.start_modules();

        let order = agent.module_start_order();
        assert_eq!(order, vec!["metrics", "logs", "p2p", "storage", "gpu"]);
    }

    // Health checking
    #[test]
    fn test_health_aggregation() {
        let health = HealthAggregator::new();

        health.report("metrics", HealthStatus::Healthy);
        health.report("logs", HealthStatus::Healthy);
        health.report("gpu", HealthStatus::Degraded);

        assert_eq!(health.overall(), HealthStatus::Degraded);
    }
}
```

#### Integration Tests

```rust
#[tokio::test]
async fn test_agent_reports_to_hivemind() {
    let hivemind = Hivemind::start().await;
    let agent = Agent::start().await;

    agent.register_with(hivemind.addr()).await;

    // Wait for heartbeat
    tokio::time::sleep(Duration::from_secs(5)).await;

    let node = hivemind.get_node(agent.node_id()).await;
    assert_eq!(node.status, NodeStatus::Ready);
    assert!(node.resources.gpu_count > 0);
}

#[tokio::test]
async fn test_agent_module_hot_reload() {
    let agent = Agent::start().await;

    // Disable metrics module
    agent.disable_module("metrics").await;
    assert!(!agent.module_enabled("metrics"));

    // Re-enable
    agent.enable_module("metrics").await;
    assert!(agent.module_enabled("metrics"));

    // Verify metrics flowing again
    let metrics = agent.get_local_metrics().await;
    assert!(!metrics.is_empty());
}
```

#### Performance Tests

| Metric | Target | Test Method |
|--------|--------|-------------|
| Memory footprint | < 100MB | Memory profiling |
| CPU usage (idle) | < 1% | Resource monitoring |
| Metric collection interval | 10s | Timing test |
| Log throughput | > 10k lines/s | Log benchmark |
| Startup time | < 10s | Boot timing |

---

## Integration Testing

### Cross-Component Test Matrix

| Test Scenario | Components | Priority |
|--------------|------------|----------|
| Request flow: Client → Router → Workload | Router, Agent | P0 |
| Image pull: Agent → Honeycomb | Agent, Honeycomb | P0 |
| Build and deploy | Beekeeper, Honeycomb, Hivemind, Agent | P0 |
| Scale up on queue depth | Router, Hivemind, Agent | P0 |
| Cross-cluster scheduling | Hivemind (multi), Agents | P1 |
| Failover scenarios | All components | P1 |

### Integration Test Environment

```
┌─────────────────────────────────────────────────────────────┐
│                  Integration Test Cluster                    │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │  Router  │  │Honeycomb │  │Beekeeper │  │ Hivemind │    │
│  │  (test)  │  │  (test)  │  │  (test)  │  │  (test)  │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │             │             │             │           │
│       └─────────────┴─────────────┴─────────────┘           │
│                           │                                  │
│                     ┌─────▼─────┐                            │
│                     │   Agent   │                            │
│                     │   (test)  │                            │
│                     └───────────┘                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    Test Harness                       │   │
│  │  • Deploys components                                 │   │
│  │  • Injects test data                                  │   │
│  │  • Validates assertions                               │   │
│  │  • Collects metrics                                   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Sample Integration Tests

```rust
#[tokio::test]
async fn test_full_deployment_flow() {
    let env = IntegrationEnv::start().await;

    // 1. Build image
    let build_id = env.beekeeper.submit_build(BuildRequest {
        source: test_source_code(),
        tag: "integration/test:v1",
    }).await;

    env.beekeeper.wait_for_build(build_id).await?;

    // 2. Verify image in registry
    assert!(env.honeycomb.image_exists("integration/test:v1").await);

    // 3. Deploy workload
    let workload_id = env.hivemind.create_workload(WorkloadSpec {
        image: "integration/test:v1",
        replicas: 1,
    }).await;

    // 4. Wait for running
    env.hivemind.wait_for_state(workload_id, State::Ready).await?;

    // 5. Send request through router
    let response = env.router.request(
        workload_id,
        Request::post("/predict").body(test_payload())
    ).await;

    assert_eq!(response.status(), 200);
}

#[tokio::test]
async fn test_autoscaling_flow() {
    let env = IntegrationEnv::start().await;

    // Deploy workload with 1 replica
    let workload_id = env.deploy_workload(replicas: 1).await;

    // Generate load to trigger scaling
    let load_gen = env.start_load_generator(
        workload_id,
        requests_per_second: 1000
    ).await;

    // Wait for scale up
    let scaled = env.hivemind.wait_for_replicas(
        workload_id,
        min_replicas: 2,
        timeout: Duration::from_secs(60)
    ).await;

    assert!(scaled.is_ok());

    // Stop load
    load_gen.stop().await;

    // Wait for scale down
    let scaled_down = env.hivemind.wait_for_replicas(
        workload_id,
        max_replicas: 1,
        timeout: Duration::from_secs(120)
    ).await;

    assert!(scaled_down.is_ok());
}
```

---

## Load Testing

### Load Test Scenarios

#### Router Load Test

```yaml
# k6 load test configuration
scenarios:
  baseline:
    executor: constant-arrival-rate
    rate: 10000
    duration: 5m
    preAllocatedVUs: 100

  spike:
    executor: ramping-arrival-rate
    startRate: 1000
    stages:
      - target: 50000, duration: 1m
      - target: 50000, duration: 5m
      - target: 1000, duration: 1m

  soak:
    executor: constant-arrival-rate
    rate: 5000
    duration: 1h
```

```javascript
// k6 test script
import http from 'k6/http';
import { check, sleep } from 'k6';

export default function() {
  const response = http.post(
    'http://router:8080/v1/predict',
    JSON.stringify({ input: 'test' }),
    { headers: { 'Authorization': 'Bearer ${API_KEY}' } }
  );

  check(response, {
    'status is 200': (r) => r.status === 200,
    'latency < 100ms': (r) => r.timings.duration < 100,
  });
}

export const thresholds = {
  http_req_duration: ['p(99)<500'],
  http_req_failed: ['rate<0.01'],
};
```

#### Hivemind Load Test

```rust
#[tokio::test]
async fn load_test_scheduler() {
    let hivemind = Hivemind::start().await;

    // Simulate 1000 concurrent workload creations
    let futures: Vec<_> = (0..1000)
        .map(|i| {
            let hm = hivemind.clone();
            async move {
                hm.create_workload(WorkloadSpec {
                    name: format!("load-test-{}", i),
                    image: "test:v1",
                }).await
            }
        })
        .collect();

    let start = Instant::now();
    let results = futures::future::join_all(futures).await;
    let duration = start.elapsed();

    // All should succeed
    assert!(results.iter().all(|r| r.is_ok()));

    // Should complete within 30 seconds
    assert!(duration < Duration::from_secs(30));

    // Throughput > 30 workloads/sec
    let throughput = 1000.0 / duration.as_secs_f64();
    assert!(throughput > 30.0);
}
```

### Load Test Targets

| Component | Scenario | Target | Acceptance Criteria |
|-----------|----------|--------|---------------------|
| Router | Sustained load | 100k req/s | p99 < 50ms |
| Router | Spike | 200k req/s | No errors, graceful degradation |
| Honeycomb | Concurrent pulls | 100 pulls/s | p99 < 10s |
| Beekeeper | Concurrent builds | 50 builds | All complete < 10min |
| Hivemind | Workload creation | 100/s | All scheduled < 1s |
| Agent | Metric reporting | 1000 nodes | All reported < 30s |

---

## Chaos Engineering

### Chaos Scenarios

#### Network Chaos

```yaml
# Chaos Mesh experiment
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: router-network-delay
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - hivemind
    labelSelectors:
      component: router
  delay:
    latency: 100ms
    jitter: 50ms
  duration: 5m
```

#### Pod Chaos

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: hivemind-pod-kill
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - hivemind
    labelSelectors:
      component: hivemind
  scheduler:
    cron: "*/5 * * * *"  # Every 5 minutes
```

### Chaos Test Matrix

| Chaos Type | Target | Expected Behavior | Recovery Time |
|------------|--------|-------------------|---------------|
| Pod kill | Router | Traffic reroutes, no errors | < 5s |
| Pod kill | Hivemind | Failover to standby | < 30s |
| Pod kill | Agent | Workloads continue, node marked unhealthy | < 60s |
| Network partition | Cluster A ↔ B | Cross-cluster scheduling pauses | < 30s |
| Network delay | Router → Backend | Queue builds, latency increases | N/A |
| Disk full | Honeycomb | Rejects new pushes, existing pulls work | N/A |
| CPU stress | Agent | Degraded metrics, workloads unaffected | N/A |

### Chaos Test Implementation

```rust
#[tokio::test]
async fn chaos_test_hivemind_failover() {
    let env = ChaosEnv::start().await;

    // Start primary and standby hivemind
    let primary = env.start_hivemind("primary").await;
    let standby = env.start_hivemind("standby").await;

    // Create workload
    let workload_id = primary.create_workload(/* ... */).await;

    // Kill primary
    let kill_time = Instant::now();
    env.kill_pod(primary.pod_name()).await;

    // Verify standby takes over
    let new_leader = env.wait_for_leader().await;
    let failover_time = kill_time.elapsed();

    assert_eq!(new_leader.name(), "standby");
    assert!(failover_time < Duration::from_secs(30));

    // Verify workload still accessible
    let workload = new_leader.get_workload(workload_id).await;
    assert!(workload.is_ok());
}

#[tokio::test]
async fn chaos_test_agent_network_partition() {
    let env = ChaosEnv::start().await;

    // Start agent with workload
    let agent = env.start_agent().await;
    let workload_id = env.deploy_workload_to(agent.node_id()).await;

    // Partition agent from control plane
    env.network_partition(agent.pod_name()).await;

    // Workload should continue running locally
    tokio::time::sleep(Duration::from_secs(60)).await;
    let workload_health = agent.local_workload_health(workload_id).await;
    assert!(workload_health.is_healthy());

    // Control plane should mark node as unknown
    let node_status = env.hivemind.get_node_status(agent.node_id()).await;
    assert_eq!(node_status, NodeStatus::Unknown);

    // Heal partition
    env.heal_network_partition(agent.pod_name()).await;

    // Node should recover
    let recovered = env.wait_for_node_status(
        agent.node_id(),
        NodeStatus::Ready,
        Duration::from_secs(60)
    ).await;
    assert!(recovered.is_ok());
}
```

---

## Staging Environment

### Environment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Staging Environment                       │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 Staging Cluster A                    │    │
│  │                   (us-east-1)                        │    │
│  │                                                      │    │
│  │  Router │ Honeycomb │ Beekeeper │ Hivemind │ Agents │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                     Cross-cluster                            │
│                      connection                              │
│                           │                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 Staging Cluster B                    │    │
│  │                   (eu-west-1)                        │    │
│  │                                                      │    │
│  │  Router │ Honeycomb │ Hivemind │ Agents             │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   Data Sources                       │    │
│  │  • Anonymized production traffic replay              │    │
│  │  • Synthetic workloads                               │    │
│  │  • Test customer accounts                            │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Staging vs Production Parity

| Aspect | Staging | Production | Parity |
|--------|---------|------------|--------|
| Cluster count | 2 | N | Reduced |
| Node count | 10 per cluster | 100+ per cluster | Reduced |
| GPU types | A10, A100 | A10, A100, H100 | Partial |
| Network | Same VPC config | Same | Full |
| Secrets | Separate | Separate | Full |
| Data | Anonymized | Real | Partial |
| Traffic | Synthetic + replay | Real | Partial |

### Staging Test Types

```rust
// Daily staging validation
#[tokio::test]
async fn staging_daily_validation() {
    let staging = StagingEnv::connect().await;

    // 1. Health check all components
    staging.verify_all_healthy().await?;

    // 2. Run smoke tests
    staging.run_smoke_tests().await?;

    // 3. Deploy test workload
    let workload = staging.deploy_test_workload().await?;

    // 4. Send test traffic
    staging.send_test_traffic(workload.id, requests: 1000).await?;

    // 5. Verify metrics
    let metrics = staging.collect_metrics().await;
    assert!(metrics.error_rate < 0.01);
    assert!(metrics.p99_latency < Duration::from_millis(500));

    // 6. Cleanup
    staging.delete_test_workload(workload.id).await?;
}
```

---

## Migration Testing

### Canary Testing Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                    Canary Deployment                         │
│                                                              │
│                      ┌─────────────┐                         │
│                      │   Traffic   │                         │
│                      │   Router    │                         │
│                      └──────┬──────┘                         │
│                             │                                │
│              ┌──────────────┼──────────────┐                │
│              │              │              │                │
│              ▼              │              ▼                │
│       ┌──────────┐         │       ┌──────────┐            │
│       │   Old    │◀────95%─┴─5%───▶│   New    │            │
│       │  System  │                 │  System  │            │
│       └──────────┘                 └──────────┘            │
│                                                              │
│  Canary Progression:                                         │
│  5% → 10% → 25% → 50% → 100%                                │
│                                                              │
│  Rollback Triggers:                                          │
│  • Error rate > 1%                                          │
│  • Latency p99 > 2x baseline                                │
│  • Any P1 alerts                                            │
└─────────────────────────────────────────────────────────────┘
```

### Migration Test Scenarios

#### Phase 1: Router Migration

```rust
#[tokio::test]
async fn test_router_migration_canary() {
    let env = MigrationEnv::start().await;

    // Deploy old and new routers
    let old_router = env.deploy_old_router().await;
    let new_router = env.deploy_new_router().await;

    // Configure traffic split
    env.configure_traffic_split(
        old: 95,
        new: 5
    ).await;

    // Run comparison test
    let comparison = env.run_comparison_test(
        requests: 10000,
        duration: Duration::from_secs(300)
    ).await;

    // Verify new router metrics
    assert!(comparison.new.error_rate <= comparison.old.error_rate);
    assert!(comparison.new.p99_latency <= comparison.old.p99_latency * 1.1);

    // Increase traffic
    env.configure_traffic_split(old: 50, new: 50).await;

    // Run extended comparison
    let extended = env.run_comparison_test(
        requests: 50000,
        duration: Duration::from_secs(600)
    ).await;

    assert!(extended.new.error_rate < 0.001);
}
```

#### Shadow Testing

```rust
#[tokio::test]
async fn test_hivemind_shadow_mode() {
    let env = MigrationEnv::start().await;

    // Deploy new Hivemind in shadow mode
    let shadow_hivemind = env.deploy_shadow_hivemind().await;

    // Shadow receives all scheduling requests
    // but decisions are not enacted
    env.enable_shadow_mode(shadow_hivemind.id()).await;

    // Run production traffic
    tokio::time::sleep(Duration::from_secs(3600)).await;

    // Compare decisions
    let comparison = env.compare_scheduling_decisions().await;

    // Log differences for analysis
    for diff in comparison.differences {
        log::info!(
            "Scheduling diff: workload={}, old={}, new={}, reason={}",
            diff.workload_id,
            diff.old_placement,
            diff.new_placement,
            diff.reason
        );
    }

    // Verify new scheduler makes valid decisions
    assert!(comparison.invalid_decisions.is_empty());
}
```

---

## Go/No-Go Criteria

### Phase 1: Router

| Category | Criteria | Threshold | Measurement |
|----------|----------|-----------|-------------|
| **Performance** | p99 latency | < 10ms | Load test |
| **Performance** | Throughput | > 100k req/s | Load test |
| **Reliability** | Error rate | < 0.01% | Canary |
| **Reliability** | Availability | > 99.99% | Staging soak |
| **Functionality** | Queue behavior | Correct | Integration test |
| **Functionality** | Graceful shutdown | No dropped requests | Integration test |
| **Migration** | Rollback time | < 5 minutes | Drill |

### Phase 2: Honeycomb

| Category | Criteria | Threshold | Measurement |
|----------|----------|-----------|-------------|
| **Performance** | Pull latency (cached) | < 5s | Benchmark |
| **Performance** | Pull latency (uncached) | < 30s | Benchmark |
| **Performance** | Cache hit rate | > 80% | Metrics |
| **Reliability** | Pull success rate | > 99.9% | Canary |
| **Reliability** | P2P availability | > 95% | Metrics |
| **Functionality** | OCI compliance | Pass | Conformance suite |
| **Migration** | Depot parity | All features | Feature checklist |

### Phase 3: Beekeeper

| Category | Criteria | Threshold | Measurement |
|----------|----------|-----------|-------------|
| **Performance** | Build time (cached) | < 30s | Benchmark |
| **Performance** | Build time (uncached) | < 5min | Benchmark |
| **Performance** | Concurrent builds | 50 | Load test |
| **Reliability** | Build success rate | > 99% | Canary |
| **Reliability** | Cache hit rate | > 70% | Metrics |
| **Security** | Build isolation | Verified | Security audit |
| **Migration** | Depot parity | All features | Feature checklist |

### Phase 4: Hivemind

| Category | Criteria | Threshold | Measurement |
|----------|----------|-----------|-------------|
| **Performance** | Scheduling latency | < 100ms | Benchmark |
| **Performance** | Scale decision latency | < 1s | Benchmark |
| **Reliability** | Scheduling success | > 99.9% | Canary |
| **Reliability** | Failover time | < 30s | Chaos test |
| **Functionality** | Compliance placement | Correct | Integration test |
| **Functionality** | Autoscaling accuracy | Within 20% | Shadow test |
| **Migration** | Knative parity | All features | Feature checklist |

### Phase 5: Agent

| Category | Criteria | Threshold | Measurement |
|----------|----------|-----------|-------------|
| **Performance** | Memory footprint | < 100MB | Profiling |
| **Performance** | CPU (idle) | < 1% | Monitoring |
| **Performance** | Startup time | < 10s | Benchmark |
| **Reliability** | Module availability | > 99.9% | Metrics |
| **Reliability** | Upgrade success | 100% | Canary |
| **Functionality** | Metric accuracy | Within 5% | Comparison test |
| **Migration** | DaemonSet parity | All features | Feature checklist |

### Go/No-Go Checklist

```markdown
## Pre-Migration Checklist

### Technical Readiness
- [ ] All unit tests passing (100%)
- [ ] All integration tests passing (100%)
- [ ] Load test targets met
- [ ] Chaos tests passing
- [ ] Security audit completed
- [ ] Performance baseline established

### Operational Readiness
- [ ] Runbooks written and reviewed
- [ ] On-call team trained
- [ ] Alerting configured
- [ ] Dashboards created
- [ ] Rollback procedure tested
- [ ] Communication plan ready

### Business Readiness
- [ ] Stakeholder approval
- [ ] Customer communication sent
- [ ] Support team briefed
- [ ] Maintenance window scheduled

### Go/No-Go Decision
- [ ] All P0 criteria met
- [ ] No unresolved P1 issues
- [ ] Rollback drill successful
- [ ] Team consensus achieved
```

---

## CI/CD Integration

### Pipeline Configuration

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run unit tests
        run: cargo test --lib

  integration-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    steps:
      - uses: actions/checkout@v4
      - name: Start test environment
        run: docker-compose -f docker-compose.test.yml up -d
      - name: Run integration tests
        run: cargo test --test integration
      - name: Cleanup
        run: docker-compose -f docker-compose.test.yml down

  load-tests:
    runs-on: ubuntu-latest
    needs: integration-tests
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to staging
        run: ./scripts/deploy-staging.sh
      - name: Run load tests
        run: k6 run load-tests/router.js
      - name: Verify thresholds
        run: ./scripts/verify-load-test-results.sh

  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run security scan
        run: cargo audit
      - name: Run SAST
        run: semgrep --config auto .
```

### Test Reporting

```rust
// Custom test reporter for CI
struct CiTestReporter {
    results: Vec<TestResult>,
}

impl CiTestReporter {
    fn generate_report(&self) -> TestReport {
        TestReport {
            total: self.results.len(),
            passed: self.results.iter().filter(|r| r.passed).count(),
            failed: self.results.iter().filter(|r| !r.passed).count(),
            duration: self.results.iter().map(|r| r.duration).sum(),
            coverage: self.calculate_coverage(),
            performance: self.performance_summary(),
        }
    }

    fn publish_to_dashboard(&self) {
        // Push metrics to observability platform
        metrics::gauge!("test.total", self.results.len() as f64);
        metrics::gauge!("test.passed", self.passed_count() as f64);
        metrics::gauge!("test.coverage", self.calculate_coverage());
    }
}
```

---

## Appendix: Test Data Management

### Test Fixtures

```rust
// Shared test fixtures
mod fixtures {
    pub fn mock_workload() -> Workload {
        Workload {
            id: Uuid::new_v4(),
            name: "test-workload".into(),
            image: "test/image:v1".into(),
            gpu: GpuRequirement::A100(1),
            ..Default::default()
        }
    }

    pub fn mock_node() -> Node {
        Node {
            id: Uuid::new_v4(),
            hostname: "test-node-001".into(),
            resources: NodeResources {
                cpu_cores: 64,
                memory_gb: 256,
                gpu_count: 8,
                gpu_type: GpuType::A100,
            },
            ..Default::default()
        }
    }

    pub fn mock_build_request() -> BuildRequest {
        BuildRequest {
            id: Uuid::new_v4(),
            source: "https://github.com/test/repo".into(),
            dockerfile: "FROM python:3.11".into(),
            tag: "test/image:v1".into(),
            ..Default::default()
        }
    }
}
```

### Test Data Anonymization

```rust
// Anonymize production data for testing
fn anonymize_workload(workload: &Workload) -> Workload {
    Workload {
        id: Uuid::new_v4(),
        name: format!("anon-{}", hash(&workload.name)[..8]),
        customer_id: format!("customer-{}", hash(&workload.customer_id)[..8]),
        // Preserve structure but anonymize values
        image: anonymize_image_name(&workload.image),
        environment: anonymize_env_vars(&workload.environment),
        ..workload.clone()
    }
}
```
