const std = @import("std");
const msg = @import("../message.zig");
const prng_mod = @import("../prng.zig");
const Prng = prng_mod.Prng;
const Ratio = prng_mod.Ratio;
const StateChecker = @import("checker.zig").StateChecker;
const test_harness = @import("test_harness.zig");
const TestCluster = test_harness.TestCluster;
const FederatedGossipHarness = test_harness.FederatedGossipHarness;
const FederatedOriginConfig = test_harness.FederatedOriginConfig;

/// VOPR - Viewstamped Operation Protocol Replay
///
/// Two-phase deterministic simulation:
///   Phase 1 (Safety): Inject faults, send requests, check invariants every tick.
///   Phase 2 (Liveness): Heal all faults, verify cluster converges within bounded ticks.
pub const VoprConfig = struct {
    seed: u64 = 42,
    replica_count: u8 = 3,
    safety_ticks: u64 = 500,
    request_count: u32 = 20,
    liveness_ticks: u64 = 200,

    // Fault injection probabilities (ratio: numerator/denominator per tick)
    partition_probability: Ratio = Ratio.init(2, 100),
    heal_probability: Ratio = Ratio.init(5, 100),
    crash_probability: Ratio = Ratio.zero(),
    pause_probability: Ratio = Ratio.zero(),
    asymmetric_partition_probability: Ratio = Ratio.zero(),

    // Network faults
    drop_rate: Ratio = Ratio.zero(),
    replay_rate: Ratio = Ratio.zero(),
    path_max_capacity: u8 = 0, // 0 = unlimited

    // Stability: minimum ticks a fault persists (prevents rapid flapping)
    partition_stability: u16 = 0,
    heal_stability: u16 = 0,
    crash_stability: u16 = 0,
    pause_stability: u16 = 0,

    // Storage faults
    disk_read_fault_rate: Ratio = Ratio.zero(),
    disk_write_fault_rate: Ratio = Ratio.zero(),

    // Workload
    deployment_count: u8 = 0,
    worker_count: u8 = 0,
    agent_pod_crash_probability: Ratio = Ratio.zero(),
};

pub const VoprResult = struct {
    seed: u64,
    phase1_ticks: u64,
    phase2_ticks: u64,
    requests_submitted: u32,
    checker_summary: StateChecker.Summary,
    outcome: Outcome,
    convergence_ticks: u64, // ticks from heal to convergence (0 if never)
    messages_sent: u64,
    messages_bytes: u64,

    pub const Outcome = enum {
        passed,
        safety_violation,
        liveness_failure,
    };
};

fn prepareLivenessPhase(tc: *TestCluster, config: VoprConfig) void {
    tc.network.drop_rate = Ratio.zero();
    tc.network.replay_rate = Ratio.zero();
    tc.network.path_max_capacity = 0;
    tc.network.partition_stable_until = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);
    tc.network.heal_stable_until = 0;
    tc.network.partitioned = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.REPLICA_COUNT_MAX]bool);

    for (0..config.replica_count) |i| {
        // Clear transient disk faults first. Production/systemd restart does not
        // wipe durable state; only an explicit operator action would. Retrying
        // recovery with faults disabled models the healed network phase.
        tc.disks[i].read_fault_rate = Ratio.zero();
        tc.disks[i].write_fault_rate = Ratio.zero();
        tc.disks[i].fail_next_write = false;
        tc.disks[i].fail_next_sync = false;
        if (!tc.replica_running[i] or tc.replicas[i].storage_failed) {
            tc.crashReplica(@intCast(i));
        }
    }
}

pub fn run(allocator: std.mem.Allocator, config: VoprConfig) !VoprResult {
    var prng = Prng.init(config.seed +% 0xF00D);

    const tc = try TestCluster.init(allocator, config.replica_count, config.seed);
    defer tc.deinit();

    // Configure network with fault parameters
    tc.network.drop_rate = config.drop_rate;
    tc.network.replay_rate = config.replay_rate;
    tc.network.path_max_capacity = config.path_max_capacity;
    tc.network.partition_stability = @intCast(config.partition_stability);
    tc.network.heal_stability = @intCast(config.heal_stability);

    // Configure storage faults
    for (0..config.replica_count) |i| {
        tc.disks[i].read_fault_rate = config.disk_read_fault_rate;
        tc.disks[i].write_fault_rate = config.disk_write_fault_rate;
        // Seed each disk's fault PRNG differently
        tc.disks[i].fault_prng = Prng.init(config.seed +% 0xD15C +% @as(u64, i));
    }

    // Add simulated agents
    for (0..config.worker_count) |i| {
        var name_buf: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&name_buf, "agent-{d}", .{i}) catch {};
        tc.addSimWorker(msg.fixedToSlice(&name_buf), 8);
    }

    // Submit initial deployments
    for (0..config.deployment_count) |i| {
        var dep_name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&dep_name, "dep-{d}", .{i}) catch {};
        tc.request(0, .{ .create_deployment = .{
            .name = dep_name,
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "app:v1"),
            .replicas = 2,
            .gpu_type = .h100_sxm,
            .gpu_count = 1,
        } });
    }

    var requests_submitted: u32 = 0;
    var phase1_ticks: u64 = 0;

    // Crash/pause stability tracking
    var crash_stable_until: [msg.REPLICA_COUNT_MAX]i64 = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);
    var pause_until: [msg.REPLICA_COUNT_MAX]i64 = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);

    // Phase 1: Safety -- inject faults and workload
    var tick_count: u64 = 0;
    while (tick_count < config.safety_ticks) : (tick_count += 1) {
        const now: i64 = @intCast(tick_count);

        // Fault injection: partitions (symmetric)
        if (prng.chance(config.partition_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            tc.partition(target);
        }
        // Fault injection: asymmetric partitions
        if (prng.chance(config.asymmetric_partition_probability)) {
            const from: u8 = prng.intBounded(u8, config.replica_count);
            const to: u8 = prng.intBounded(u8, config.replica_count);
            if (from != to) tc.network.partitionOneWay(from, to);
        }
        // Heal
        if (prng.chance(config.heal_probability)) {
            tc.heal();
        }
        // Crash (with stability)
        if (prng.chance(config.crash_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            if (now >= crash_stable_until[target]) {
                tc.crashReplica(target);
                crash_stable_until[target] = now + @as(i64, config.crash_stability);
            }
        }
        // Pause (freeze replica for N ticks, memory preserved)
        if (prng.chance(config.pause_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            if (pause_until[target] <= now) {
                const pause_duration = config.pause_stability + @as(u16, @intCast(prng.bounded(50)));
                pause_until[target] = now + @as(i64, pause_duration);
                tc.partition(target);
            }
        }
        // Resume paused replicas
        for (0..config.replica_count) |i| {
            if (pause_until[i] > 0 and now >= pause_until[i]) {
                pause_until[i] = 0;
                tc.network.healOne(@intCast(i));
            }
        }

        // Workload injection
        if (requests_submitted < config.request_count) {
            const interval = if (config.request_count > 0) config.safety_ticks / @as(u64, config.request_count) else 0;
            if (interval == 0 or tick_count % interval == 0) {
                // Find current leader
                var leader_id: u8 = 0;
                for (0..config.replica_count) |i| {
                    if (tc.isLeader(@intCast(i))) {
                        leader_id = @intCast(i);
                        break;
                    }
                }
                var node_name: [64]u8 = std.mem.zeroes([64]u8);
                _ = std.fmt.bufPrint(&node_name, "vopr-node-{d}", .{requests_submitted}) catch {};
                tc.request(leader_id, .{ .register_node = .{
                    .node_name = node_name,
                    .gpu_type = .h100_sxm,
                    .gpu_count = 8,
                } });
                requests_submitted += 1;
            }
        }

        tc.tick();
        tc.restartStorageFailed();
        tc.tickWorkers();

        phase1_ticks = tick_count + 1;

        if (tc.checker.safety_violations > 0) {
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = 0,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .safety_violation,
                .convergence_ticks = 0,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }
    }

    // Phase 2: Liveness -- heal all faults and verify convergence
    prepareLivenessPhase(tc, config);
    tc.heal();
    var phase2_ticks: u64 = 0;
    tick_count = 0;
    while (tick_count < config.liveness_ticks) : (tick_count += 1) {
        tc.tick();
        tc.restartStorageFailed();
        tc.tickWorkers();
        phase2_ticks = tick_count + 1;

        if (tc.checker.safety_violations > 0) {
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = phase2_ticks,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .safety_violation,
                .convergence_ticks = 0,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }

        if (tc.checkConvergence() == null) {
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = phase2_ticks,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .passed,
                .convergence_ticks = phase2_ticks,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }
    }

    return .{
        .seed = config.seed,
        .phase1_ticks = phase1_ticks,
        .phase2_ticks = phase2_ticks,
        .requests_submitted = requests_submitted,
        .checker_summary = tc.checker.summary(),
        .outcome = .liveness_failure,
        .convergence_ticks = 0,
        .messages_sent = tc.network.stats.totalMessages(),
        .messages_bytes = tc.network.stats.totalBytes(),
    };
}

const trace_mod = @import("trace.zig");
pub const TraceCollector = trace_mod.TraceCollector;

/// Run simulation with full event trace to stderr + optional TraceCollector.
/// Used by `fuzz replay --verbose` to debug failing seeds.
pub fn run_traced(allocator: std.mem.Allocator, config: VoprConfig) !VoprResult {
    return run_traced_with_collector(allocator, config, null);
}

/// Run with trace collector for JSON output.
pub fn run_traced_collected(allocator: std.mem.Allocator, config: VoprConfig, collector: *TraceCollector) !VoprResult {
    return run_traced_with_collector(allocator, config, collector);
}

fn run_traced_with_collector(allocator: std.mem.Allocator, config: VoprConfig, collector: ?*TraceCollector) !VoprResult {
    var prng = Prng.init(config.seed +% 0xF00D);

    const tc = try TestCluster.init(allocator, config.replica_count, config.seed);
    defer tc.deinit();

    // Configure network and storage faults (must match run() for determinism)
    tc.network.drop_rate = config.drop_rate;
    tc.network.replay_rate = config.replay_rate;
    tc.network.path_max_capacity = config.path_max_capacity;
    tc.network.partition_stability = @intCast(config.partition_stability);
    tc.network.heal_stability = @intCast(config.heal_stability);
    for (0..config.replica_count) |i| {
        tc.disks[i].read_fault_rate = config.disk_read_fault_rate;
        tc.disks[i].write_fault_rate = config.disk_write_fault_rate;
        tc.disks[i].fault_prng = Prng.init(config.seed +% 0xD15C +% @as(u64, i));
    }

    if (collector) |c| c.addInit(config.replica_count, config.seed);

    for (0..config.worker_count) |i| {
        var name_buf: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&name_buf, "agent-{d}", .{i}) catch {};
        tc.addSimWorker(msg.fixedToSlice(&name_buf), 8);
    }

    for (0..config.deployment_count) |i| {
        var dep_name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&dep_name, "dep-{d}", .{i}) catch {};
        tc.request(0, .{ .create_deployment = .{
            .name = dep_name,
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "app:v1"),
            .replicas = 2,
            .gpu_type = .h100_sxm,
            .gpu_count = 1,
        } });
    }

    var requests_submitted: u32 = 0;
    var phase1_ticks: u64 = 0;
    const prev_violations = tc.checker.safety_violations;

    // Crash/pause stability tracking (must match run() for determinism)
    var crash_stable_until: [msg.REPLICA_COUNT_MAX]i64 = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);
    var pause_until: [msg.REPLICA_COUNT_MAX]i64 = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);

    trace("=== PHASE 1: SAFETY ({d} ticks) ===\n", .{config.safety_ticks});

    var tick_count: u64 = 0;
    while (tick_count < config.safety_ticks) : (tick_count += 1) {
        const now: i64 = @intCast(tick_count);

        // Fault injection: partitions (symmetric)
        if (prng.chance(config.partition_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            tc.partition(target);
            trace("T={d:>4} PARTITION replica={d}\n", .{ tick_count, target });
            if (collector) |c| c.addPartition(tick_count, target);
        }
        // Fault injection: asymmetric partitions
        if (prng.chance(config.asymmetric_partition_probability)) {
            const from: u8 = prng.intBounded(u8, config.replica_count);
            const to: u8 = prng.intBounded(u8, config.replica_count);
            if (from != to) {
                tc.network.partitionOneWay(from, to);
                trace("T={d:>4} ASYMMETRIC_PARTITION {d}->{d}\n", .{ tick_count, from, to });
            }
        }
        // Heal
        if (prng.chance(config.heal_probability)) {
            tc.heal();
            trace("T={d:>4} HEAL all\n", .{tick_count});
            if (collector) |c| c.addHeal(tick_count);
        }
        // Crash (with stability)
        if (prng.chance(config.crash_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            if (now >= crash_stable_until[target]) {
                const pre_view = tc.replicas[target].view_number;
                const pre_op = tc.replicas[target].op_number;
                const pre_commit = tc.replicas[target].commit_min;
                tc.crashReplica(target);
                crash_stable_until[target] = now + @as(i64, config.crash_stability);
                trace("T={d:>4} CRASH replica={d} (pre: view={d} op={d} commit={d})\n", .{
                    tick_count, target, pre_view, pre_op, pre_commit,
                });
                trace("T={d:>4} RECOVERED replica={d} (post: view={d} op={d} commit={d})\n", .{
                    tick_count,                      target,
                    tc.replicas[target].view_number, tc.replicas[target].op_number,
                    tc.replicas[target].commit_min,
                });
                if (collector) |c| c.push(.{ .tick = tick_count, .kind = .{ .crash = .{
                    .replica = target,
                    .pre_view = pre_view,
                    .pre_op = pre_op,
                    .pre_commit = pre_commit,
                    .post_view = tc.replicas[target].view_number,
                    .post_op = tc.replicas[target].op_number,
                    .post_commit = tc.replicas[target].commit_min,
                } } });
            }
        }
        // Pause (freeze replica for N ticks, memory preserved)
        if (prng.chance(config.pause_probability)) {
            const target: u8 = prng.intBounded(u8, config.replica_count);
            if (pause_until[target] <= now) {
                const pause_duration = config.pause_stability + @as(u16, @intCast(prng.bounded(50)));
                pause_until[target] = now + @as(i64, pause_duration);
                tc.partition(target);
                trace("T={d:>4} PAUSE replica={d} for {d} ticks\n", .{ tick_count, target, pause_duration });
            }
        }
        // Resume paused replicas
        for (0..config.replica_count) |i| {
            if (pause_until[i] > 0 and now >= pause_until[i]) {
                pause_until[i] = 0;
                tc.network.healOne(@intCast(i));
                trace("T={d:>4} RESUME replica={d}\n", .{ tick_count, i });
            }
        }

        // Workload
        if (requests_submitted < config.request_count) {
            const interval = if (config.request_count > 0) config.safety_ticks / @as(u64, config.request_count) else 0;
            if (interval == 0 or tick_count % interval == 0) {
                var leader_id: u8 = 0;
                for (0..config.replica_count) |i| {
                    if (tc.isLeader(@intCast(i))) {
                        leader_id = @intCast(i);
                        break;
                    }
                }
                var node_name: [64]u8 = std.mem.zeroes([64]u8);
                _ = std.fmt.bufPrint(&node_name, "vopr-node-{d}", .{requests_submitted}) catch {};
                tc.request(leader_id, .{ .register_node = .{
                    .node_name = node_name,
                    .gpu_type = .h100_sxm,
                    .gpu_count = 8,
                } });
                requests_submitted += 1;
                trace("T={d:>4} REQUEST leader={d} req={d}\n", .{ tick_count, leader_id, requests_submitted });
                if (collector) |c| c.addRequest(tick_count, leader_id, requests_submitted);
            }
        }

        tc.tick();
        tc.restartStorageFailed();
        tc.tickWorkers();

        phase1_ticks = tick_count + 1;

        // Periodic state dump (every 50 ticks)
        if (tick_count % 50 == 0) {
            traceClusterState(tc, tick_count);
            if (collector) |c| c.addState(tick_count, &tc.replicas, tc.replica_count);
        }

        // Check for new violations
        if (tc.checker.safety_violations > prev_violations) {
            trace("\n!!! SAFETY VIOLATION at T={d} !!!\n", .{tick_count});
            traceClusterState(tc, tick_count);
            traceJournalState(tc);
            if (collector) |c| {
                c.addState(tick_count, &tc.replicas, tc.replica_count);
                c.addViolation(tick_count, 0, "safety violation detected");
                for (0..tc.replica_count) |i| {
                    c.addJournal(tick_count, @intCast(i), tc.replicas[i]);
                }
            }
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = 0,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .safety_violation,
                .convergence_ticks = 0,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }
    }

    trace("\n=== PHASE 2: LIVENESS ({d} ticks) ===\n", .{config.liveness_ticks});
    prepareLivenessPhase(tc, config);
    tc.heal();
    var phase2_ticks: u64 = 0;
    tick_count = 0;

    while (tick_count < config.liveness_ticks) : (tick_count += 1) {
        tc.tick();
        tc.restartStorageFailed();
        tc.tickWorkers();
        phase2_ticks = tick_count + 1;

        if (tc.checker.safety_violations > prev_violations) {
            trace("\n!!! SAFETY VIOLATION at P2 T={d} !!!\n", .{tick_count});
            traceClusterState(tc, config.safety_ticks + tick_count);
            traceJournalState(tc);
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = phase2_ticks,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .safety_violation,
                .convergence_ticks = 0,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }

        if (tc.checkConvergence() == null) {
            trace("T={d:>4} CONVERGED\n", .{config.safety_ticks + tick_count});
            return .{
                .seed = config.seed,
                .phase1_ticks = phase1_ticks,
                .phase2_ticks = phase2_ticks,
                .requests_submitted = requests_submitted,
                .checker_summary = tc.checker.summary(),
                .outcome = .passed,
                .convergence_ticks = phase2_ticks,
                .messages_sent = tc.network.stats.totalMessages(),
                .messages_bytes = tc.network.stats.totalBytes(),
            };
        }
    }

    trace("LIVENESS TIMEOUT\n", .{});
    traceClusterState(tc, config.safety_ticks + config.liveness_ticks);
    traceJournalState(tc);
    return .{
        .seed = config.seed,
        .phase1_ticks = phase1_ticks,
        .phase2_ticks = phase2_ticks,
        .requests_submitted = requests_submitted,
        .checker_summary = tc.checker.summary(),
        .outcome = .liveness_failure,
        .convergence_ticks = 0,
        .messages_sent = tc.network.stats.totalMessages(),
        .messages_bytes = tc.network.stats.totalBytes(),
    };
}

fn traceClusterState(tc: *const TestCluster, tick: u64) void {
    trace("T={d:>4} STATE", .{tick});
    for (0..tc.replica_count) |i| {
        const r = tc.replicas[i];
        const status_char: u8 = switch (r.status) {
            .normal => 'N',
            .view_change => 'V',
            .recovering => 'R',
        };
        const leader: u8 = if (r.isLeader() and r.status == .normal) '*' else ' ';
        trace(" | r{d}{c}{c} v={d} op={d} cm={d} cmax={d}", .{
            i, leader, status_char, r.view_number, r.op_number, r.commit_min, r.commit_max,
        });
    }
    trace("\n", .{});
}

fn traceJournalState(tc: *const TestCluster) void {
    trace("JOURNAL DUMP:\n", .{});
    for (0..tc.replica_count) |i| {
        const r = tc.replicas[i];
        trace("  replica {d}: op={d} commit_min={d} commit_max={d} slots=[", .{ i, r.op_number, r.commit_min, r.commit_max });
        // Show an early repair window plus the tail near commit_min.
        const start = if (r.op_number > 80 and r.commit_min > 80) 45 else if (r.commit_min > 10) r.commit_min - 10 else 1;
        const end = if (r.op_number > 80 and r.commit_min > 80) 80 else r.op_number + 5;
        var j = start;
        while (j <= end and j > 0) : (j += 1) {
            if (r.journalGet(j) != null) {
                trace("{d} ", .{j});
            } else {
                trace("({d}) ", .{j}); // missing
            }
        }
        trace("]\n", .{});
    }
}

fn trace(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// VOPR test scenarios
// ---------------------------------------------------------------------------

fn advanceClusterAndWorkers(tc: *TestCluster, ticks: u64) void {
    for (0..ticks) |_| {
        tc.tick();
        tc.tickWorkers();
    }
}

fn findNormalLeader(tc: *const TestCluster, excluded: ?u8) ?u8 {
    for (0..tc.replica_count) |i| {
        const id: u8 = @intCast(i);
        if (excluded) |skip| {
            if (id == skip) continue;
        }
        if (!tc.replica_running[i]) continue;
        if (tc.replicas[i].status == .normal and
            tc.isLeader(id) and
            !tc.replicas[i].repair_pending and
            !tc.replicas[i].transfer_pending)
        {
            return id;
        }
    }
    return null;
}

fn waitForNormalLeader(tc: *TestCluster, excluded: ?u8, ticks: u64) ?u8 {
    for (0..ticks) |_| {
        if (findNormalLeader(tc, excluded)) |leader| return leader;
        tc.tick();
        tc.tickWorkers();
    }
    return null;
}

fn waitForFullConvergence(tc: *TestCluster, ticks: u64) bool {
    for (0..ticks) |_| {
        if (tc.checkConvergence() == null) return true;
        tc.tick();
        tc.tickWorkers();
    }
    return tc.checkConvergence() == null;
}

test "vopr: passes with no faults" {
    const result = try run(std.testing.allocator, .{
        .seed = 42,
        .replica_count = 3,
        .safety_ticks = 200,
        .request_count = 5,
        .partition_probability = Ratio.zero(),
        .heal_probability = Ratio.zero(),
        .liveness_ticks = 100,
    });
    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: passes with partition faults" {
    const seeds = [_]u64{ 10, 20, 30, 40, 50 };
    for (seeds) |seed| {
        const result = try run(std.testing.allocator, .{
            .seed = seed,
            .replica_count = 3,
            .safety_ticks = 100,
            .request_count = 5,
            .partition_probability = Ratio.init(3, 100),
            .heal_probability = Ratio.init(8, 100),
            .liveness_ticks = 200,
        });
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: agents + deployments + faults" {
    const result = try run(std.testing.allocator, .{
        .seed = 42,
        .replica_count = 3,
        .safety_ticks = 300,
        .request_count = 10,
        .deployment_count = 3,
        .worker_count = 5,
        .partition_probability = Ratio.init(2, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .agent_pod_crash_probability = Ratio.init(3, 100),
        .liveness_ticks = 500,
    });
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: journal wrap-around with many requests" {
    const result = try run(std.testing.allocator, .{
        .seed = 42,
        .replica_count = 3,
        .safety_ticks = 1000,
        .request_count = 300,
        .partition_probability = Ratio.zero(),
        .heal_probability = Ratio.zero(),
        .liveness_ticks = 300,
    });
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: deterministic replay" {
    const seed: u64 = 555;
    const r1 = try run(std.testing.allocator, .{ .seed = seed, .safety_ticks = 200, .request_count = 10 });
    const r2 = try run(std.testing.allocator, .{ .seed = seed, .safety_ticks = 200, .request_count = 10 });

    try std.testing.expectEqual(r1.outcome, r2.outcome);
    try std.testing.expectEqual(r1.checker_summary.commits_checked, r2.checker_summary.commits_checked);
    try std.testing.expectEqual(r1.requests_submitted, r2.requests_submitted);
}

test "vopr: 5-node with partitions and crashes" {
    const seeds = [_]u64{ 42, 100, 200, 300, 400 };
    for (seeds) |seed| {
        const result = try run(std.testing.allocator, .{
            .seed = seed,
            .replica_count = 5,
            .safety_ticks = 300,
            .request_count = 20,
            .partition_probability = Ratio.init(3, 100),
            .heal_probability = Ratio.init(8, 100),
            .crash_probability = Ratio.init(1, 100),
            .liveness_ticks = 500,
        });
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: 5-node agents + deployments + faults" {
    const result = try run(std.testing.allocator, .{
        .seed = 42,
        .replica_count = 5,
        .safety_ticks = 400,
        .request_count = 15,
        .deployment_count = 3,
        .worker_count = 5,
        .partition_probability = Ratio.init(2, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 600,
    });
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: heavy crash faults with disk recovery" {
    const seeds = [_]u64{ 10, 20, 30, 40, 50 };
    for (seeds) |seed| {
        const result = try run(std.testing.allocator, .{
            .seed = seed,
            .replica_count = 3,
            .safety_ticks = 300,
            .request_count = 30,
            .crash_probability = Ratio.init(3, 100),
            .heal_probability = Ratio.init(10, 100),
            .liveness_ticks = 400,
        });
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: cross-origin gossip propagation preserves identity and freshness" {
    const gossip_mod = @import("../gossip.zig");
    const GossipState = gossip_mod.GossipState;
    const GossipPeer = gossip_mod.GossipPeer;
    const PeerCapacity = gossip_mod.PeerCapacity;

    const region_a = try TestCluster.init(std.testing.allocator, 3, 42);
    defer region_a.deinit();

    const region_b = try TestCluster.init(std.testing.allocator, 3, 99);
    defer region_b.deinit();

    var gossip_a = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = region_a.replicas[0],
        .encryption = null,
    };

    var gossip_b = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-eu-west-2"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "eu-west-2"),
            .locality = msg.strToFixed(32, "europe"),
            .continent = msg.strToFixed(32, "eu"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = region_b.replicas[0],
        .encryption = null,
    };

    for (0..200) |i| {
        if (i == 10) {
            region_a.request(0, .{ .register_node = .{
                .node_name = msg.strToFixed(64, "gpu-node-a1"),
                .cpu_millicores = 32000,
                .gpu_type = .h100_sxm,
                .gpu_count = 8,
                .provider = msg.strToFixed(32, "aws"),
                .region = msg.strToFixed(32, "us-east-1"),
            } });
        }
        if (i == 20) {
            region_a.request(0, .{ .create_deployment = .{
                .name = msg.strToFixed(64, "model-a"),
                .namespace = msg.strToFixed(64, "default"),
                .image = msg.strToFixed(256, "model:v1"),
                .replicas = 1,
                .gpu_type = .h100_sxm,
                .gpu_count = 2,
            } });
        }
        region_a.tick();
        region_b.tick();
    }

    var buf: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
    gossip_a.buildSnapshotPublic(&buf, 5000);
    gossip_b.handleMessagePublic(&buf, 5000);

    try std.testing.expectEqualStrings("aws-us-east-1", msg.fixedToSlice(&gossip_b.cache[0].origin_id));
    try std.testing.expectEqualStrings("aws", msg.fixedToSlice(&gossip_b.cache[0].provider));
    try std.testing.expectEqualStrings("us-east-1", msg.fixedToSlice(&gossip_b.cache[0].region));
    try std.testing.expectEqualStrings("us-east", msg.fixedToSlice(&gossip_b.cache[0].locality));
    try std.testing.expectEqualStrings("na", msg.fixedToSlice(&gossip_b.cache[0].continent));
    try std.testing.expect(gossip_b.cache[0].cpu_total_millicores >= 32000);
    try std.testing.expect(gossip_b.cache[0].node_count >= 1);
    try std.testing.expect(gossip_b.cache[0].active_deployments >= 1);
    try std.testing.expect(gossip_b.isOriginFresh("aws-us-east-1", 5000));

    try std.testing.expect(!gossip_b.isOriginFresh("aws-us-east-1", 36000));

    gossip_a.buildSnapshotPublic(&buf, 36000);
    gossip_b.handleMessagePublic(&buf, 36000);
    try std.testing.expect(gossip_b.isOriginFresh("aws-us-east-1", 36000));

    try std.testing.expectEqual(@as(u64, 0), region_a.checker.safety_violations);
    try std.testing.expectEqual(@as(u64, 0), region_b.checker.safety_violations);
}

test "vopr: gossip under partitions" {
    const gossip_mod = @import("../gossip.zig");
    const GossipState = gossip_mod.GossipState;
    const GossipPeer = gossip_mod.GossipPeer;
    const PeerCapacity = gossip_mod.PeerCapacity;

    const region_a = try TestCluster.init(std.testing.allocator, 3, 77);
    defer region_a.deinit();

    var gossip_a = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = region_a.replicas[0],
        .encryption = null,
    };

    var gossip_b = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-eu-west-2"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "eu-west-2"),
            .locality = msg.strToFixed(32, "europe"),
            .continent = msg.strToFixed(32, "eu"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    var prng_local = Prng.init(77);

    // Register nodes and create deployments
    region_a.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-1"),
        .cpu_millicores = 16000,
        .gpu_type = .a100_80,
        .gpu_count = 4,
        .provider = msg.strToFixed(32, "aws"),
        .region = msg.strToFixed(32, "us-east-1"),
    } });

    for (0..3) |i| {
        var dep_name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&dep_name, "app-{d}", .{i}) catch {};
        region_a.request(0, .{ .create_deployment = .{
            .name = dep_name,
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "app:v1"),
            .replicas = 1,
        } });
    }

    // Run with partitions, periodically gossip to B
    var gossip_count: u32 = 0;
    for (0..500) |tick| {
        // Partition injection
        if (prng_local.bounded(100) < 3) {
            const target: u8 = prng_local.intBounded(u8, 3);
            region_a.partition(target);
        }
        if (prng_local.bounded(100) < 8) {
            region_a.heal();
        }

        region_a.tick();

        // Gossip every ~50 ticks from whoever is leader
        if (tick % 50 == 0) {
            // Point gossip_a at current leader's replica
            for (0..3) |i| {
                if (region_a.isLeader(@intCast(i))) {
                    gossip_a.replica = region_a.replicas[i];
                    break;
                }
            }

            var buf: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
            const now: i64 = @intCast(tick * 10); // 10ms per tick
            gossip_a.buildSnapshotPublic(&buf, now);
            gossip_b.handleMessagePublic(&buf, now);
            gossip_count += 1;
        }
    }

    // Verify gossip reached B
    try std.testing.expect(gossip_count >= 9);
    try std.testing.expectEqualStrings("aws-us-east-1", msg.fixedToSlice(&gossip_b.cache[0].origin_id));
    try std.testing.expectEqualStrings("us-east-1", msg.fixedToSlice(&gossip_b.cache[0].region));
    try std.testing.expectEqualStrings("us-east", msg.fixedToSlice(&gossip_b.cache[0].locality));
    try std.testing.expect(gossip_b.cache[0].node_count >= 1);
    try std.testing.expect(gossip_b.cache[0].active_deployments >= 1);
    try std.testing.expect(gossip_b.cache[0].cpu_total_millicores >= 16000);

    // A100_80 is gpu_type index 2
    try std.testing.expect(gossip_b.cache[0].gpu_total[2] >= 4);

    try std.testing.expectEqual(@as(u64, 0), region_a.checker.safety_violations);
}

test "vopr: distinct origins in same region remain distinct in gossip cache" {
    const gossip_mod = @import("../gossip.zig");
    const GossipState = gossip_mod.GossipState;
    const GossipPeer = gossip_mod.GossipPeer;
    const PeerCapacity = gossip_mod.PeerCapacity;

    const aws_cluster = try TestCluster.init(std.testing.allocator, 1, 123);
    defer aws_cluster.deinit();
    const crusoe_cluster = try TestCluster.init(std.testing.allocator, 1, 456);
    defer crusoe_cluster.deinit();

    aws_cluster.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "aws-node"),
        .cpu_millicores = 32000,
        .gpu_type = .t4,
        .gpu_count = 1,
        .provider = msg.strToFixed(32, "aws"),
        .region = msg.strToFixed(32, "us-east-1"),
    } });
    crusoe_cluster.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "crusoe-node"),
        .cpu_millicores = 64000,
        .gpu_type = .l40s,
        .gpu_count = 2,
        .provider = msg.strToFixed(32, "crusoe"),
        .region = msg.strToFixed(32, "us-east-1"),
    } });

    for (0..40) |_| {
        aws_cluster.tick();
        crusoe_cluster.tick();
    }

    var receiver = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "receiver-europe"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "eu-west-2"),
            .locality = msg.strToFixed(32, "europe"),
            .continent = msg.strToFixed(32, "eu"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    var gossip_aws = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = aws_cluster.replicas[0],
        .encryption = null,
    };

    var gossip_crusoe = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "crusoe-us-east-1"),
            .provider = msg.strToFixed(32, "crusoe"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = crusoe_cluster.replicas[0],
        .encryption = null,
    };

    var buf_aws: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
    var buf_crusoe: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
    gossip_aws.buildSnapshotPublic(&buf_aws, 1000);
    gossip_crusoe.buildSnapshotPublic(&buf_crusoe, 1000);
    receiver.handleMessagePublic(&buf_aws, 1000);
    receiver.handleMessagePublic(&buf_crusoe, 1000);

    try std.testing.expectEqualStrings("aws-us-east-1", msg.fixedToSlice(&receiver.cache[0].origin_id));
    try std.testing.expectEqualStrings("crusoe-us-east-1", msg.fixedToSlice(&receiver.cache[1].origin_id));
    try std.testing.expectEqualStrings("us-east-1", msg.fixedToSlice(&receiver.cache[0].region));
    try std.testing.expectEqualStrings("us-east-1", msg.fixedToSlice(&receiver.cache[1].region));
    try std.testing.expectEqualStrings("aws", msg.fixedToSlice(&receiver.cache[0].provider));
    try std.testing.expectEqualStrings("crusoe", msg.fixedToSlice(&receiver.cache[1].provider));
    try std.testing.expect(receiver.cache[1].cpu_total_millicores > receiver.cache[0].cpu_total_millicores);

    try std.testing.expectEqual(@as(u64, 0), aws_cluster.checker.safety_violations);
    try std.testing.expectEqual(@as(u64, 0), crusoe_cluster.checker.safety_violations);
}

test "vopr: federated gossip exposes multi-locality advisory state across seed sweep" {
    const seeds = [_]u64{ 0xA11, 0xB22, 0xC33, 0xD44, 0xE55 };

    for (seeds) |seed| {
        var federation = FederatedGossipHarness.init(std.testing.allocator);
        defer federation.deinit();

        const us_east_aws = try federation.addOrigin(.{
            .seed = seed,
            .origin_id = "aws-us-east-1",
            .provider = "aws",
            .region = "us-east-1",
            .locality = "us-east",
            .continent = "na",
            .node_name = "aws-us-east-node",
            .cpu_millicores = 32000,
            .gpu_type = .t4,
            .gpu_count = 1,
            .deployment_name = "cpu-us-east",
            .deployment_replicas = 1,
            .deployment_cpu_millicores = 2000,
        });
        _ = us_east_aws;
        const us_east_crusoe = try federation.addOrigin(.{
            .seed = seed +% 1,
            .origin_id = "crusoe-us-east-1",
            .provider = "crusoe",
            .region = "us-east-1",
            .locality = "us-east",
            .continent = "na",
            .node_name = "crusoe-us-east-node",
            .cpu_millicores = 64000,
            .gpu_type = .l40s,
            .gpu_count = 2,
            .deployment_name = "gpu-us-east",
            .deployment_replicas = 1,
            .deployment_gpu_type = .l40s,
            .deployment_gpu_count = 1,
        });
        _ = us_east_crusoe;
        const us_central = try federation.addOrigin(.{
            .seed = seed +% 2,
            .origin_id = "crusoe-texas",
            .provider = "crusoe",
            .region = "us-south-1",
            .locality = "us-central",
            .continent = "na",
            .node_name = "crusoe-texas-node",
            .cpu_millicores = 48000,
            .gpu_type = .a100_80,
            .gpu_count = 4,
            .deployment_name = "gpu-us-central",
            .deployment_replicas = 1,
            .deployment_gpu_type = .a100_80,
            .deployment_gpu_count = 1,
        });
        _ = us_central;
        const europe = try federation.addOrigin(.{
            .seed = seed +% 3,
            .origin_id = "aws-eu-west-2",
            .provider = "aws",
            .region = "eu-west-2",
            .locality = "europe",
            .continent = "eu",
            .node_name = "aws-eu-node",
            .cpu_millicores = 24000,
            .gpu_type = .a10g,
            .gpu_count = 1,
            .deployment_name = "cpu-europe",
            .deployment_replicas = 1,
            .deployment_cpu_millicores = 1000,
        });

        federation.broadcastAll(5000);

        try std.testing.expectEqual(@as(usize, 2), federation.countFreshOriginsByLocality(europe, "us-east", 5000));
        try std.testing.expectEqual(@as(usize, 1), federation.countFreshOriginsByLocality(europe, "us-central", 5000));

        const crusoe_peer = federation.findPeer(europe, "crusoe-us-east-1") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("crusoe", msg.fixedToSlice(&crusoe_peer.provider));
        try std.testing.expectEqualStrings("us-east", msg.fixedToSlice(&crusoe_peer.locality));
        try std.testing.expect(crusoe_peer.cpu_total_millicores >= 64000);
        try std.testing.expect(crusoe_peer.gpu_total[@intFromEnum(msg.GpuType.l40s)] >= 2);

        const central_peer = federation.findPeer(europe, "crusoe-texas") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("us-central", msg.fixedToSlice(&central_peer.locality));
        try std.testing.expect(central_peer.gpu_total[@intFromEnum(msg.GpuType.a100_80)] >= 4);

        for (federation.origins[0..federation.origin_count]) |*origin| {
            try std.testing.expectEqual(@as(u64, 0), origin.cluster.checker.safety_violations);
        }
    }
}

test "vopr: federated gossip same-locality failover inputs survive stale preferred origin across seed sweep" {
    const seeds = [_]u64{ 0x111, 0x222, 0x333, 0x444, 0x555 };

    for (seeds) |seed| {
        var federation = FederatedGossipHarness.init(std.testing.allocator);
        defer federation.deinit();

        _ = try federation.addOrigin(.{
            .seed = seed,
            .origin_id = "aws-us-east-1",
            .provider = "aws",
            .region = "us-east-1",
            .locality = "us-east",
            .continent = "na",
            .node_name = "preferred-us-east",
            .cpu_millicores = 32000,
            .gpu_type = .t4,
            .gpu_count = 1,
            .deployment_name = "preferred-model",
            .deployment_replicas = 1,
            .deployment_cpu_millicores = 1000,
        });
        const fallback = try federation.addOrigin(.{
            .seed = seed +% 1,
            .origin_id = "crusoe-us-east-1",
            .provider = "crusoe",
            .region = "us-east-1",
            .locality = "us-east",
            .continent = "na",
            .node_name = "fallback-us-east",
            .cpu_millicores = 64000,
            .gpu_type = .l40s,
            .gpu_count = 2,
            .deployment_name = "fallback-model",
            .deployment_replicas = 1,
            .deployment_gpu_type = .l40s,
            .deployment_gpu_count = 1,
        });
        const europe = try federation.addOrigin(.{
            .seed = seed +% 2,
            .origin_id = "aws-eu-west-2",
            .provider = "aws",
            .region = "eu-west-2",
            .locality = "europe",
            .continent = "eu",
            .node_name = "observer-europe",
            .cpu_millicores = 24000,
            .gpu_type = .a10g,
            .gpu_count = 1,
            .deployment_name = "observer-model",
            .deployment_replicas = 1,
            .deployment_cpu_millicores = 1000,
        });

        federation.broadcastAll(5000);
        try std.testing.expectEqual(@as(usize, 2), federation.countFreshOriginsByLocality(europe, "us-east", 5000));

        federation.broadcastSubsetToReceiver(&[_]usize{fallback}, europe, 36000);

        try std.testing.expectEqual(@as(usize, 1), federation.countFreshOriginsByLocality(europe, "us-east", 36000));
        try std.testing.expect(!federation.origins[europe].gossip.isOriginFresh("aws-us-east-1", 36000));
        try std.testing.expect(federation.origins[europe].gossip.isOriginFresh("crusoe-us-east-1", 36000));

        const fallback_peer = federation.findPeer(europe, "crusoe-us-east-1") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("crusoe", msg.fixedToSlice(&fallback_peer.provider));
        try std.testing.expect(fallback_peer.cpu_total_millicores >= 64000);

        for (federation.origins[0..federation.origin_count]) |*origin| {
            try std.testing.expectEqual(@as(u64, 0), origin.cluster.checker.safety_violations);
        }
    }
}

fn addSelectorObserver(federation: *FederatedGossipHarness, seed: u64) !usize {
    return federation.addOrigin(.{
        .seed = seed,
        .origin_id = "selector-observer",
        .provider = "router",
        .region = "global",
        .locality = "global",
        .continent = "global",
        .node_name = "selector-observer-node",
        .cpu_millicores = 16000,
    });
}

test "vopr: federated selector local proof chooses best fresh origin in preferred locality" {
    var federation = FederatedGossipHarness.init(std.testing.allocator);
    defer federation.deinit();

    const observer = try addSelectorObserver(&federation, 0x5100);
    _ = try federation.addOrigin(.{
        .seed = 0x5101,
        .origin_id = "aws-us-east-1",
        .provider = "aws",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "aws-us-east-node",
        .cpu_millicores = 32000,
        .deployment_name = "preferred-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });
    _ = try federation.addOrigin(.{
        .seed = 0x5102,
        .origin_id = "crusoe-us-east-1",
        .provider = "crusoe",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "crusoe-us-east-node",
        .cpu_millicores = 64000,
        .deployment_name = "fallback-cpu",
        .deployment_replicas = 4,
        .deployment_cpu_millicores = 1000,
    });
    _ = try federation.addOrigin(.{
        .seed = 0x5103,
        .origin_id = "crusoe-texas",
        .provider = "crusoe",
        .region = "us-south-1",
        .locality = "us-central",
        .continent = "na",
        .node_name = "crusoe-texas-node",
        .cpu_millicores = 48000,
        .deployment_name = "central-cpu",
        .deployment_replicas = 2,
        .deployment_cpu_millicores = 1000,
    });
    _ = try federation.addOrigin(.{
        .seed = 0x5104,
        .origin_id = "aws-eu-west-2",
        .provider = "aws",
        .region = "eu-west-2",
        .locality = "europe",
        .continent = "eu",
        .node_name = "aws-eu-node",
        .cpu_millicores = 24000,
        .deployment_name = "europe-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });

    federation.broadcastAll(5000);

    const allowed = [_][]const u8{ "us-east", "us-central", "europe" };
    const fallback = [_][]const u8{ "us-east", "us-central", "europe" };
    const decision = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-us-east-1",
        .preferred_locality = "us-east",
        .allowed_localities = &allowed,
        .residency_mode = .prefer,
        .fallback_order = &fallback,
        .required_cpu_millicores = 1000,
    }, 5000);

    try std.testing.expect(decision.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.same_locality_best, decision.reason);
    try std.testing.expectEqualStrings("aws-us-east-1", msg.fixedToSlice(&decision.origin_id));
}

test "vopr: federated selector local proof performs same-locality failover when preferred origin goes stale" {
    var federation = FederatedGossipHarness.init(std.testing.allocator);
    defer federation.deinit();

    const observer = try addSelectorObserver(&federation, 0x5200);
    _ = try federation.addOrigin(.{
        .seed = 0x5201,
        .origin_id = "aws-us-east-1",
        .provider = "aws",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "aws-us-east-node",
        .cpu_millicores = 32000,
        .deployment_name = "preferred-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });
    const fallback_origin = try federation.addOrigin(.{
        .seed = 0x5202,
        .origin_id = "crusoe-us-east-1",
        .provider = "crusoe",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "crusoe-us-east-node",
        .cpu_millicores = 64000,
        .deployment_name = "fallback-cpu",
        .deployment_replicas = 2,
        .deployment_cpu_millicores = 1000,
    });
    _ = try federation.addOrigin(.{
        .seed = 0x5203,
        .origin_id = "aws-eu-west-2",
        .provider = "aws",
        .region = "eu-west-2",
        .locality = "europe",
        .continent = "eu",
        .node_name = "aws-eu-node",
        .cpu_millicores = 24000,
        .deployment_name = "europe-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });

    federation.broadcastAll(5000);
    federation.broadcastSubsetToReceiver(&[_]usize{fallback_origin}, observer, 36000);

    const allowed = [_][]const u8{ "us-east", "us-central", "europe" };
    const fallback = [_][]const u8{ "us-east", "us-central", "europe" };
    const decision = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-us-east-1",
        .preferred_locality = "us-east",
        .allowed_localities = &allowed,
        .residency_mode = .prefer,
        .fallback_order = &fallback,
        .required_cpu_millicores = 1000,
    }, 36000);

    try std.testing.expect(decision.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.same_locality_failover, decision.reason);
    try std.testing.expectEqualStrings("crusoe-us-east-1", msg.fixedToSlice(&decision.origin_id));
}

test "vopr: federated selector local proof falls back across localities only when policy allows" {
    var federation = FederatedGossipHarness.init(std.testing.allocator);
    defer federation.deinit();

    const observer = try addSelectorObserver(&federation, 0x5300);
    _ = try federation.addOrigin(.{
        .seed = 0x5301,
        .origin_id = "aws-us-east-1",
        .provider = "aws",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "aws-us-east-node",
        .cpu_millicores = 32000,
        .deployment_name = "east-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });
    const central = try federation.addOrigin(.{
        .seed = 0x5302,
        .origin_id = "crusoe-texas",
        .provider = "crusoe",
        .region = "us-south-1",
        .locality = "us-central",
        .continent = "na",
        .node_name = "crusoe-texas-node",
        .cpu_millicores = 48000,
        .deployment_name = "central-cpu",
        .deployment_replicas = 2,
        .deployment_cpu_millicores = 1000,
    });
    const europe = try federation.addOrigin(.{
        .seed = 0x5303,
        .origin_id = "aws-eu-west-2",
        .provider = "aws",
        .region = "eu-west-2",
        .locality = "europe",
        .continent = "eu",
        .node_name = "aws-eu-node",
        .cpu_millicores = 24000,
        .deployment_name = "europe-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });

    federation.broadcastAll(5000);
    federation.broadcastSubsetToReceiver(&[_]usize{ central, europe }, observer, 36000);

    const allowed = [_][]const u8{ "us-east", "us-central", "europe" };
    const fallback = [_][]const u8{ "us-east", "us-central", "europe" };
    const decision_central = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-us-east-1",
        .preferred_locality = "us-east",
        .allowed_localities = &allowed,
        .residency_mode = .prefer,
        .fallback_order = &fallback,
        .required_cpu_millicores = 1000,
    }, 36000);

    try std.testing.expect(decision_central.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.cross_locality_fallback, decision_central.reason);
    try std.testing.expectEqualStrings("crusoe-texas", msg.fixedToSlice(&decision_central.origin_id));

    federation.broadcastSubsetToReceiver(&[_]usize{europe}, observer, 72000);
    const decision_europe = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-us-east-1",
        .preferred_locality = "us-east",
        .allowed_localities = &allowed,
        .residency_mode = .prefer,
        .fallback_order = &fallback,
        .required_cpu_millicores = 1000,
    }, 72000);

    try std.testing.expect(decision_europe.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.cross_locality_fallback, decision_europe.reason);
    try std.testing.expectEqualStrings("aws-eu-west-2", msg.fixedToSlice(&decision_europe.origin_id));
}

test "vopr: federated selector local proof enforces strict residency" {
    var federation = FederatedGossipHarness.init(std.testing.allocator);
    defer federation.deinit();

    const observer = try addSelectorObserver(&federation, 0x5400);
    const europe = try federation.addOrigin(.{
        .seed = 0x5401,
        .origin_id = "aws-eu-west-2",
        .provider = "aws",
        .region = "eu-west-2",
        .locality = "europe",
        .continent = "eu",
        .node_name = "aws-eu-node",
        .cpu_millicores = 24000,
        .deployment_name = "europe-cpu",
        .deployment_replicas = 1,
        .deployment_cpu_millicores = 1000,
    });
    const us_east = try federation.addOrigin(.{
        .seed = 0x5402,
        .origin_id = "aws-us-east-1",
        .provider = "aws",
        .region = "us-east-1",
        .locality = "us-east",
        .continent = "na",
        .node_name = "aws-us-east-node",
        .cpu_millicores = 32000,
        .deployment_name = "east-cpu",
        .deployment_replicas = 2,
        .deployment_cpu_millicores = 1000,
    });

    federation.broadcastAll(5000);

    const europe_only = [_][]const u8{"europe"};
    const decision_ok = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-eu-west-2",
        .preferred_locality = "europe",
        .allowed_localities = &europe_only,
        .residency_mode = .strict,
        .fallback_order = &europe_only,
        .required_cpu_millicores = 1000,
    }, 5000);

    try std.testing.expect(decision_ok.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.same_locality_best, decision_ok.reason);
    try std.testing.expectEqualStrings("aws-eu-west-2", msg.fixedToSlice(&decision_ok.origin_id));

    federation.broadcastSubsetToReceiver(&[_]usize{us_east}, observer, 36000);

    const decision_blocked = federation.selectOrigin(observer, .{
        .preferred_origin_id = "aws-eu-west-2",
        .preferred_locality = "europe",
        .allowed_localities = &europe_only,
        .residency_mode = .strict,
        .fallback_order = &europe_only,
        .required_cpu_millicores = 1000,
    }, 36000);

    try std.testing.expect(!decision_blocked.found);
    try std.testing.expectEqual(FederatedGossipHarness.RoutingReason.residency_restricted, decision_blocked.reason);
    _ = europe;
}

test "vopr: simulated agent reconnect preserves node id" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 9001);
    defer tc.deinit();

    tc.addSimWorker("solo", 4);

    for (0..80) |_| {
        tc.tick();
        tc.tickWorkers();
    }
    try std.testing.expect(tc.state_machines[0].node_count >= 1);
    const id0 = tc.state_machines[0].nodes[0].id;

    tc.disconnectSimWorker(0);

    for (0..80) |_| {
        tc.tick();
        tc.tickWorkers();
    }

    try std.testing.expectEqual(@as(usize, 1), tc.state_machines[0].node_count);
    try std.testing.expectEqual(id0, tc.state_machines[0].nodes[0].id);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.safety_violations);
}

test "vopr: create deployment retains image pull auth fields" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 9002);
    defer tc.deinit();

    var cmd: msg.CreateDeploymentCmd = .{
        .name = msg.strToFixed(64, "private"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "registry.io/model:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 1,
    };
    cmd.image_pull_username = msg.strToFixed(64, "user");
    cmd.image_pull_password = msg.strToFixed(256, "pass");
    cmd.image_pull_password_is_secret = 1;

    tc.request(0, .{ .create_deployment = cmd });

    var waited: usize = 0;
    while (waited < 400) : (waited += 1) {
        tc.tick();
        if (tc.state_machines[0].findDeploymentByName("private") != null) break;
    }

    const dep = tc.state_machines[0].findDeploymentByName("private").?;
    try std.testing.expectEqualStrings("user", msg.fixedToSlice(&dep.image_pull_username));
    try std.testing.expectEqualStrings("pass", msg.fixedToSlice(&dep.image_pull_password));
    try std.testing.expectEqual(@as(u8, 1), dep.image_pull_password_is_secret);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.safety_violations);
}

test "vopr: live-style leader stop elects new leader and restarted node rejoins" {
    const tc = try TestCluster.init(std.testing.allocator, 5, 0xF4110E);
    defer tc.deinit();

    tc.addSimWorker("failover-worker-0", 8);
    tc.addSimWorker("failover-worker-1", 8);
    advanceClusterAndWorkers(tc, 120);

    const leader_before = waitForNormalLeader(tc, null, 600) orelse return error.TestUnexpectedResult;
    tc.request(leader_before, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "failover-cpu"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "simulated:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } });
    advanceClusterAndWorkers(tc, 200);

    const committed_before = tc.replicas[leader_before].commit_min;
    tc.stopReplica(leader_before);

    const leader_after = waitForNormalLeader(tc, leader_before, 1200) orelse return error.TestUnexpectedResult;
    try std.testing.expect(leader_after != leader_before);

    try std.testing.expect(tc.state_machines[leader_after].findDeploymentByName("failover-cpu") != null);
    const node_count_after_election = tc.state_machines[leader_after].node_count;
    tc.request(leader_after, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "post-failover-node"),
        .cpu_millicores = 2000,
        .memory_megabytes = 2048,
    } });
    advanceClusterAndWorkers(tc, 500);

    try std.testing.expect(tc.state_machines[leader_after].node_count > node_count_after_election);
    try std.testing.expectEqual(msg.Status.normal, tc.replicas[leader_after].status);

    tc.startReplica(leader_before);
    try std.testing.expect(waitForFullConvergence(tc, 1600));
    for (0..tc.replica_count) |i| {
        try std.testing.expect(tc.replicas[i].commit_min >= committed_before);
    }
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
}

test "vopr: seed sweep survives repeated leader and follower process kills" {
    const seeds = [_]u64{ 0xA101, 0xA202, 0xA303 };

    for (seeds) |seed| {
        const tc = try TestCluster.init(std.testing.allocator, 5, seed);
        defer tc.deinit();

        tc.addSimWorker("kill-worker-0", 4);
        tc.addSimWorker("kill-worker-1", 4);
        advanceClusterAndWorkers(tc, 120);

        var round: u8 = 0;
        while (round < 3) : (round += 1) {
            const leader = waitForNormalLeader(tc, null, 1200) orelse return error.TestUnexpectedResult;
            tc.request(leader, .{ .noop = {} });
            advanceClusterAndWorkers(tc, 80);

            const stopped = if (round == 1) (leader + 2) % tc.replica_count else leader;
            tc.stopReplica(stopped);
            advanceClusterAndWorkers(tc, 220);

            if (stopped == leader) {
                const next_leader = waitForNormalLeader(tc, leader, 1200) orelse return error.TestUnexpectedResult;
                try std.testing.expect(next_leader != leader);
                tc.request(next_leader, .{ .noop = {} });
            } else {
                const same_leader = waitForNormalLeader(tc, null, 200) orelse return error.TestUnexpectedResult;
                tc.request(same_leader, .{ .noop = {} });
            }

            advanceClusterAndWorkers(tc, 160);
            tc.startReplica(stopped);
            advanceClusterAndWorkers(tc, 320);
            try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
        }

        try std.testing.expect(waitForFullConvergence(tc, 1600));
        try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
    }
}

test "vopr: duplicate in-flight bind request is deduped before commit" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 9003);
    defer tc.deinit();

    tc.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-a"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } });
    tc.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-b"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } });
    tc.request(0, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } });

    var waited: usize = 0;
    while (waited < 400) : (waited += 1) {
        tc.tick();
        if (tc.state_machines[0].node_count >= 2 and tc.state_machines[0].pod_count >= 1) break;
    }

    try std.testing.expect(tc.state_machines[0].node_count >= 2);
    try std.testing.expect(tc.state_machines[0].pod_count >= 1);

    const pod_id = tc.state_machines[0].pods[0].id;
    const node_a = tc.state_machines[0].nodes[0].id;
    const node_b = tc.state_machines[0].nodes[1].id;

    var leader_id: u8 = 0;
    while (leader_id < 3 and !tc.replicas[leader_id].isLeader()) : (leader_id += 1) {}
    try std.testing.expect(leader_id < 3);

    const op_before = tc.replicas[leader_id].op_number;
    const dup_client_id: u128 = 0xABCD_0000_0000_0000_0000_0000_0000_0001;
    const dup_request_id: u128 = 0xABCD_0000_0000_0000_0000_0000_0000_0002;

    tc.replicas[leader_id].onMessage(leader_id, .{ .request = .{
        .client_id = dup_client_id,
        .request_id = dup_request_id,
        .command = .{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_a } },
    } });
    tc.replicas[leader_id].onMessage(leader_id, .{ .request = .{
        .client_id = dup_client_id,
        .request_id = dup_request_id,
        .command = .{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_b } },
    } });

    try std.testing.expectEqual(op_before + 1, tc.replicas[leader_id].op_number);

    waited = 0;
    while (waited < 400) : (waited += 1) {
        tc.tick();
        if (tc.state_machines[0].pods[0].node_id != 0) break;
    }

    try std.testing.expectEqual(node_a, tc.state_machines[0].pods[0].node_id);
    try std.testing.expect(tc.state_machines[0].pods[0].node_id != node_b);
    try std.testing.expect(tc.state_machines[0].pods[0].node_id != 0);
    try std.testing.expectEqual(msg.PodPhase.scheduled, tc.state_machines[0].pods[0].phase);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.safety_violations);
}

test "vopr: 100-seed sweep no safety violations" {
    for (0..100) |seed| {
        const result = try run(std.testing.allocator, .{
            .seed = seed,
            .replica_count = 3,
            .safety_ticks = 150,
            .request_count = 10,
            .partition_probability = Ratio.init(2, 100),
            .heal_probability = Ratio.init(5, 100),
            .crash_probability = Ratio.init(1, 100),
            .liveness_ticks = 200,
        });
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: seeds 10 228 362 committed-carry safety regressions" {
    const seeds = [_]u64{ 10, 228, 362 };
    for (seeds) |seed| {
        const result = try run(std.testing.allocator, .{
            .seed = seed,
            .replica_count = 5,
            .safety_ticks = 500,
            .request_count = 20,
            .partition_probability = Ratio.init(3, 100),
            .heal_probability = Ratio.init(8, 100),
            .crash_probability = Ratio.init(1, 100),
            .pause_probability = Ratio.init(1, 100),
            .asymmetric_partition_probability = Ratio.init(1, 100),
            .drop_rate = Ratio.init(2, 100),
            .replay_rate = Ratio.init(1, 100),
            .path_max_capacity = 16,
            .partition_stability = 20,
            .heal_stability = 10,
            .crash_stability = 30,
            .pause_stability = 15,
            .disk_read_fault_rate = Ratio.init(1, 1000),
            .disk_write_fault_rate = Ratio.init(1, 1000),
            .deployment_count = 3,
            .worker_count = 4,
            .agent_pod_crash_probability = Ratio.init(1, 100),
            .liveness_ticks = 2000,
        });

        try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: seed 6239 idle follower catch-up liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 6239,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 3844 leader candidate fetch liveness diagnostic" {
    const result = try run(std.testing.allocator, .{
        .seed = 3844,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 7957 prepare-rejoin safety regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 7957,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(2, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seeds 3250 7393 8146 8820 stale leader commit-floor regressions" {
    const cases = [_]struct {
        seed: u64,
        replica_count: u8,
        partition_numerator: u32,
        crash_numerator: u32,
    }{
        .{ .seed = 3250, .replica_count = 5, .partition_numerator = 6, .crash_numerator = 1 },
        .{ .seed = 7393, .replica_count = 7, .partition_numerator = 3, .crash_numerator = 1 },
        .{ .seed = 8146, .replica_count = 5, .partition_numerator = 3, .crash_numerator = 4 },
        .{ .seed = 8820, .replica_count = 5, .partition_numerator = 3, .crash_numerator = 1 },
    };

    for (cases) |case| {
        const result = try run(std.testing.allocator, .{
            .seed = case.seed,
            .replica_count = case.replica_count,
            .safety_ticks = 500,
            .request_count = 20,
            .partition_probability = Ratio.init(case.partition_numerator, 100),
            .heal_probability = Ratio.init(8, 100),
            .crash_probability = Ratio.init(case.crash_numerator, 100),
            .pause_probability = Ratio.init(1, 100),
            .asymmetric_partition_probability = Ratio.init(1, 100),
            .drop_rate = Ratio.init(2, 100),
            .replay_rate = Ratio.init(1, 100),
            .path_max_capacity = 16,
            .partition_stability = 20,
            .heal_stability = 10,
            .crash_stability = 30,
            .pause_stability = 15,
            .disk_read_fault_rate = Ratio.init(1, 1000),
            .disk_write_fault_rate = Ratio.init(1, 1000),
            .deployment_count = 3,
            .worker_count = 4,
            .agent_pod_crash_probability = Ratio.init(1, 100),
            .liveness_ticks = 2000,
        });

        try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
        try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
    }
}

test "vopr: seed 8896 repair ignores follower-only higher tail regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 8896,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 1317 bounded start-view tail liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 1317,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 112 repair regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 112,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 44 liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 44,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 7 follower repair regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 7,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 15 start-view safety regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 15,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 16 committed-tail repair liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 16,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 186 start-view gap liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 186,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 182 crash-rejoin liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 182,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 160,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 58 follower gap transfer liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 58,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 59 stale leader commit-floor liveness regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 59,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 169 follower rejoin from leader traffic regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 169,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 216 stale suffix commit safety regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 216,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 364 crashed follower rejoin invariant regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 364,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seed 283 start-view carry safety regression" {
    const result = try run(std.testing.allocator, .{
        .seed = 283,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });

    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

fn runStartViewRegressionSeed(seed: u64) !void {
    const result = try run(std.testing.allocator, .{
        .seed = seed,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .partition_probability = Ratio.init(3, 100),
        .heal_probability = Ratio.init(8, 100),
        .crash_probability = Ratio.init(1, 100),
        .pause_probability = Ratio.init(1, 100),
        .asymmetric_partition_probability = Ratio.init(1, 100),
        .drop_rate = Ratio.init(2, 100),
        .replay_rate = Ratio.init(1, 100),
        .path_max_capacity = 16,
        .partition_stability = 20,
        .heal_stability = 10,
        .crash_stability = 30,
        .pause_stability = 15,
        .disk_read_fault_rate = Ratio.init(1, 1000),
        .disk_write_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
        .liveness_ticks = 2000,
    });
    try std.testing.expectEqual(VoprResult.Outcome.passed, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.checker_summary.safety_violations);
}

test "vopr: seeds 121 42 58 StartView-only adoption regressions" {
    for ([_]u64{ 121, 42, 58 }) |seed| try runStartViewRegressionSeed(seed);
}

test "vopr: seeds 22 129 pending StartView persistence regressions" {
    for ([_]u64{ 22, 129 }) |seed| try runStartViewRegressionSeed(seed);
}

test "vopr: batch bind schedules 50 pods with one scheduler command" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xB17D50);
    defer tc.deinit();

    const leader_id: u8 = 0;
    tc.request(leader_id, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } });
    tc.advance(80);

    tc.request(leader_id, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "nginx"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 50,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } });
    tc.advance(400);

    const dep_id = tc.state_machines[leader_id].deployments[0].id;
    var scheduled: usize = 0;
    for (tc.state_machines[leader_id].pods[0..tc.state_machines[leader_id].pod_count]) |pod| {
        if (!pod.active or pod.deployment_id != dep_id) continue;
        if (pod.phase == .scheduled) scheduled += 1;
    }

    try std.testing.expectEqual(@as(usize, 50), scheduled);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
}
