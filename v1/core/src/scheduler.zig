const std = @import("std");
const msg = @import("message.zig");
const sm_mod = @import("state_machine.zig");
const StateMachine = sm_mod.StateMachine;
const NodeCapacity = sm_mod.NodeCapacity;
const Prng = @import("prng.zig").Prng;

// ---------------------------------------------------------------------------
// Scheduler -- reads local state machine, produces placement decisions.
//
// Runs on the leader replica. Scans for pending pods and assigns them to
// nodes with available capacity using weighted scoring adapted from thalamus.
//
// Does NOT submit consensus commands directly. Returns ScheduleAction values
// that the caller submits through the VRR protocol.
// ---------------------------------------------------------------------------

pub const MAX_BIND_ACTIONS: usize = msg.BIND_BATCH_MAX;
pub const MAX_SCALE_DOWN_ACTIONS: usize = 16;

pub const ScheduleAction = struct {
    pod_id: u64,
    node_id: u64,
};

pub const ScaleDownAction = struct {
    deployment_id: u64,
    desired_replicas: u32,
};

pub const ScheduleResult = struct {
    actions: [MAX_BIND_ACTIONS]ScheduleAction,
    count: usize,
    scale_downs: [MAX_SCALE_DOWN_ACTIONS]ScaleDownAction,
    scale_down_count: usize,
};

pub const Scheduler = struct {
    prng: Prng,

    pub fn init(seed: u64) Scheduler {
        return .{ .prng = Prng.init(seed) };
    }

    pub fn initInPlace(self: *Scheduler, seed: u64) void {
        self.prng = Prng.init(seed);
    }

    /// Scan the state machine for pending pods and produce placement decisions.
    /// Also checks for idle deployments that should scale to zero.
    pub fn tick(self: *Scheduler, state: *const StateMachine, current_tick: u64) ScheduleResult {
        var result = ScheduleResult{
            .actions = undefined,
            .count = 0,
            .scale_downs = undefined,
            .scale_down_count = 0,
        };

        for (state.deployments[0..state.deployment_count]) |*dep| {
            if (!dep.active) continue;
            if (dep.paused) continue;

            var pod_buf: [MAX_BIND_ACTIONS]u64 = undefined;
            const pending_count = state.getPendingPods(dep.id, &pod_buf);
            if (pending_count > 0) {
                for (pod_buf[0..pending_count]) |pod_id| {
                    if (result.count >= MAX_BIND_ACTIONS) break;

                    const pod = state.findPod(pod_id) orelse continue;
                    const node_id = self.findBestNodeWithActions(state, pod, dep.id, result.actions[0..result.count]) orelse continue;

                    result.actions[result.count] = .{
                        .pod_id = pod_id,
                        .node_id = node_id,
                    };
                    result.count += 1;
                }
                continue;
            }

            // Scale-to-zero check for idle deployments with no pending pods
            if (dep.scale_to_zero_after_ms == 0) continue;
            if (dep.replicas == 0) continue;
            if (dep.last_request_tick == 0) continue;

            const idle_ticks = current_tick -| dep.last_request_tick;
            if (idle_ticks > dep.scale_to_zero_after_ms) {
                if (result.scale_down_count < MAX_SCALE_DOWN_ACTIONS) {
                    result.scale_downs[result.scale_down_count] = .{
                        .deployment_id = dep.id,
                        .desired_replicas = 0,
                    };
                    result.scale_down_count += 1;
                }
            }
        }

        return result;
    }

    fn findBestNodeWithActions(
        self: *Scheduler,
        state: *const StateMachine,
        pod: *const sm_mod.Pod,
        deployment_id: u64,
        actions: []const ScheduleAction,
    ) ?u64 {
        var candidates: [sm_mod.MAX_NODES]NodeCapacity = undefined;
        const candidate_count: usize = self.findCandidateNodes(state, pod, deployment_id, &candidates);
        var fit: usize = 0;
        for (candidates[0..candidate_count]) |cap| {
            var adjusted = cap;
            for (actions) |action| {
                if (action.node_id != cap.node_id) continue;
                const scheduled_pod = state.findPod(action.pod_id) orelse continue;
                adjusted.available_cpu = adjusted.available_cpu -| scheduled_pod.cpu_millicores;
                adjusted.available_mem = adjusted.available_mem -| scheduled_pod.memory_megabytes;
                adjusted.available_gpu = adjusted.available_gpu -| scheduled_pod.gpu_count;
            }
            if (pod.cpu_millicores > 0 and adjusted.available_cpu < pod.cpu_millicores) continue;
            if (pod.memory_megabytes > 0 and adjusted.available_mem < pod.memory_megabytes) continue;
            if (pod.gpu_count > 0 and adjusted.available_gpu < pod.gpu_count) continue;
            candidates[fit] = adjusted;
            fit += 1;
        }
        if (fit == 0) return null;
        if (fit == 1) return candidates[0].node_id;
        return self.weightedSelect(candidates[0..fit], pod.gpu_count);
    }

    /// Find the best node for a pod using weighted scoring.
    fn findBestNode(
        self: *Scheduler,
        state: *const StateMachine,
        pod: *const sm_mod.Pod,
        deployment_id: u64,
    ) ?u64 {
        return self.findBestNodeWithActions(state, pod, deployment_id, &[_]ScheduleAction{});
    }

    fn findCandidateNodes(
        self: *Scheduler,
        state: *const StateMachine,
        pod: *const sm_mod.Pod,
        deployment_id: u64,
        candidates: []NodeCapacity,
    ) usize {
        _ = self;
        const gpu_needed = pod.gpu_count;
        const cpu_only = pod.gpu_type == .none and gpu_needed == 0;

        var candidate_count: usize = 0;

        if (cpu_only) {
            for (state.nodes[0..state.node_count]) |*node| {
                if (!node.active or node.status != .ready) continue;
                if (state.isKillswitched(node.id, deployment_id)) continue;
                if (candidate_count >= candidates.len) break;
                candidates[candidate_count] = state.getNodeCapacity(node.id) orelse continue;
                candidate_count += 1;
            }
        } else {
            candidate_count = state.getNodesWithGpu(pod.gpu_type, gpu_needed, candidates);

            var filtered: usize = 0;
            for (candidates[0..candidate_count]) |cap| {
                if (!state.isKillswitched(cap.node_id, deployment_id)) {
                    candidates[filtered] = cap;
                    filtered += 1;
                }
            }
            candidate_count = filtered;
        }

        var fit: usize = 0;
        for (candidates[0..candidate_count]) |cap| {
            if (pod.cpu_millicores > 0 and cap.available_cpu < pod.cpu_millicores) continue;
            if (pod.memory_megabytes > 0 and cap.available_mem < pod.memory_megabytes) continue;
            candidates[fit] = cap;
            fit += 1;
        }
        candidate_count = fit;

        if (cpu_only) {
            var cpu_node_count: usize = 0;
            for (candidates[0..candidate_count]) |cap| {
                if (cap.total_gpu != 0) continue;
                candidates[cpu_node_count] = cap;
                cpu_node_count += 1;
            }
            if (cpu_node_count > 0) candidate_count = cpu_node_count;
        }

        return candidate_count;
    }

    /// Weighted random selection proportional to available capacity.
    /// Nodes with more headroom are preferred (spreads load, bin-packing friendly).
    fn weightedSelect(self: *Scheduler, candidates: []const NodeCapacity, gpu_needed: u8) ?u64 {
        if (candidates.len == 0) return null;

        var total_weight: u64 = 0;
        for (candidates) |cap| {
            const headroom: u64 = if (cap.available_gpu > gpu_needed)
                cap.available_gpu - gpu_needed
            else
                0;
            total_weight += headroom + 1; // +1 ensures non-zero weight
        }

        if (total_weight == 0) return candidates[0].node_id;

        var pick = self.prng.bounded(total_weight);
        for (candidates) |cap| {
            const headroom: u64 = if (cap.available_gpu > gpu_needed)
                cap.available_gpu - gpu_needed
            else
                0;
            const weight = headroom + 1;
            if (pick < weight) return cap.node_id;
            pick -= weight;
        }

        return candidates[candidates.len - 1].node_id;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "scheduler: assigns pending pod to node with capacity" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    const node_result = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    const node_id = node_result.ok.entity_id;

    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "llm"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "llm:v1"),
        .replicas = 2,
        .gpu_type = .h100_sxm,
        .gpu_count = 2,
    } });

    var scheduler = Scheduler.init(100);
    const result = scheduler.tick(state, 0);

    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(node_id, result.actions[0].node_id);
    try std.testing.expectEqual(node_id, result.actions[1].node_id);
}

test "scheduler: prefers CPU-only nodes for CPU-only pods" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    const cpu_node = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "cpu-node"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .none,
        .gpu_count = 0,
    } }).ok.entity_id;

    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .t4,
        .gpu_count = 1,
    } });

    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "cpu-service"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "cpu:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
        .gpu_type = .none,
        .gpu_count = 0,
    } });

    var scheduler = Scheduler.init(100);
    const result = scheduler.tick(state, 0);

    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(cpu_node, result.actions[0].node_id);
}

test "scheduler: falls back to GPU nodes for CPU-only pods when no CPU node fits" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "tiny-cpu-node"),
        .cpu_millicores = 250,
        .memory_megabytes = 8192,
        .gpu_type = .none,
        .gpu_count = 0,
    } });

    const gpu_node = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .t4,
        .gpu_count = 1,
    } }).ok.entity_id;

    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "cpu-service"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "cpu:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
        .gpu_type = .none,
        .gpu_count = 0,
    } });

    var scheduler = Scheduler.init(100);
    const result = scheduler.tick(state, 0);

    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(gpu_node, result.actions[0].node_id);
}

test "scheduler: skips pods when no capacity" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "small"),
        .gpu_type = .h100_sxm,
        .gpu_count = 1,
    } });

    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "big"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "big:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 4,
    } });

    var scheduler = Scheduler.init(100);
    const result = scheduler.tick(state, 0);

    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "scheduler: respects killswitch" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    const node_result = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "llm"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "llm:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 1,
    } });
    const dep_id = dep_result.ok.entity_id;

    _ = state.apply(.{ .set_killswitch = .{
        .node_id = node_id,
        .deployment_id = dep_id,
        .active = true,
    } });

    var scheduler = Scheduler.init(100);
    const result = scheduler.tick(state, 0);

    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "scheduler: deterministic with same seed" {
    const allocator = std.testing.allocator;

    const run_once = struct {
        fn go(alloc: std.mem.Allocator, seed: u64) ScheduleResult {
            const state = alloc.create(StateMachine) catch unreachable;
            defer alloc.destroy(state);
            state.initInPlace(42);

            _ = state.apply(.{ .register_node = .{
                .node_name = msg.strToFixed(64, "n1"),
                .gpu_type = .h100_sxm,
                .gpu_count = 8,
            } });
            _ = state.apply(.{ .register_node = .{
                .node_name = msg.strToFixed(64, "n2"),
                .gpu_type = .h100_sxm,
                .gpu_count = 8,
            } });
            _ = state.apply(.{ .create_deployment = .{
                .name = msg.strToFixed(64, "det"),
                .namespace = msg.strToFixed(64, "default"),
                .image = msg.strToFixed(256, "det:v1"),
                .replicas = 3,
                .gpu_type = .h100_sxm,
                .gpu_count = 1,
            } });

            var sched = Scheduler.init(seed);
            return sched.tick(state, 0);
        }
    };

    const r1 = run_once.go(allocator, 777);
    const r2 = run_once.go(allocator, 777);

    try std.testing.expectEqual(r1.count, r2.count);
    for (0..r1.count) |i| {
        try std.testing.expectEqual(r1.actions[i].node_id, r2.actions[i].node_id);
        try std.testing.expectEqual(r1.actions[i].pod_id, r2.actions[i].pod_id);
    }
}

test "scheduler: scale-to-zero for idle deployment" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });

    const dep_result = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "idle-svc"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "svc:v1"),
        .replicas = 1,
        .scale_to_zero_after_ms = 5000,
    } });
    const dep_id = dep_result.ok.entity_id;

    // Simulate last request at tick 1000
    state.deployments[state.deployment_count - 1].last_request_tick = 1000;

    var scheduler = Scheduler.init(100);

    // At tick 3000 (2s idle), should NOT trigger scale-down yet
    const r1 = scheduler.tick(state, 3000);
    try std.testing.expectEqual(@as(usize, 0), r1.scale_down_count);

    // First bind the pending pod so there are no pending pods
    // (scale-to-zero only checks when pending_count == 0)
    const r1_actions = r1.count;
    if (r1_actions > 0) {
        _ = state.apply(.{ .bind_pod_to_node = .{
            .pod_id = r1.actions[0].pod_id,
            .node_id = r1.actions[0].node_id,
        } });
    }

    // At tick 7000 (6s idle, > 5s threshold), should trigger scale-down
    const r2 = scheduler.tick(state, 7000);
    try std.testing.expectEqual(@as(usize, 1), r2.scale_down_count);
    try std.testing.expectEqual(dep_id, r2.scale_downs[0].deployment_id);
    try std.testing.expectEqual(@as(u32, 0), r2.scale_downs[0].desired_replicas);
}

test "scheduler: no scale-to-zero when disabled" {
    const allocator = std.testing.allocator;
    const state = try allocator.create(StateMachine);
    defer allocator.destroy(state);
    state.initInPlace(42);

    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });

    _ = state.apply(.{
        .create_deployment = .{
            .name = msg.strToFixed(64, "always-on"),
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "svc:v1"),
            .replicas = 1,
            .scale_to_zero_after_ms = 0, // disabled
        },
    });

    state.deployments[state.deployment_count - 1].last_request_tick = 1000;

    var scheduler = Scheduler.init(100);

    // Bind the pending pod first
    const r0 = scheduler.tick(state, 0);
    if (r0.count > 0) {
        _ = state.apply(.{ .bind_pod_to_node = .{
            .pod_id = r0.actions[0].pod_id,
            .node_id = r0.actions[0].node_id,
        } });
    }

    // Even at very high tick, no scale-down because scale_to_zero_after_ms == 0
    const r1 = scheduler.tick(state, 999_999);
    try std.testing.expectEqual(@as(usize, 0), r1.scale_down_count);
}

test "scheduler: returns 50 bind actions for 50 pending pods" {
    var state = StateMachine.init(900);
    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "cpu-node"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } });
    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "nginx"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 50,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } });
    var scheduler = Scheduler.init(901);
    const result = scheduler.tick(&state, 0);
    try std.testing.expectEqual(@as(usize, 50), result.count);
}

test "scheduler: returns 50 bind actions across 50 single-replica deployments" {
    var state = StateMachine.init(902);
    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "cpu-node"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } });
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&name, "dep-{d}", .{i}) catch unreachable;
        _ = state.apply(.{ .create_deployment = .{
            .name = name,
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "nginx"),
            .replicas = 1,
            .cpu_millicores = 10,
            .memory_megabytes = 16,
        } });
    }
    var scheduler = Scheduler.init(903);
    const result = scheduler.tick(&state, 0);
    try std.testing.expectEqual(@as(usize, 50), result.count);
}

test "scheduler: tentative capacity prevents same-tick overcommit" {
    var state = StateMachine.init(904);
    _ = state.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "tiny"),
        .cpu_millicores = 150,
        .memory_megabytes = 512,
    } });
    _ = state.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "nginx"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 2,
        .cpu_millicores = 100,
        .memory_megabytes = 16,
    } });
    var scheduler = Scheduler.init(905);
    const result = scheduler.tick(&state, 0);
    try std.testing.expectEqual(@as(usize, 1), result.count);
}
