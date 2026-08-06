const std = @import("std");
const builtin = @import("builtin");
const msg = @import("message.zig");
const Prng = @import("prng.zig").Prng;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const root = @import("root");
    const quiet = builtin.is_test or (@hasDecl(root, "hivemind_quiet") and root.hivemind_quiet);
    if (quiet) return;
    std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// Capacity limits -- inline bounded arrays, ~16MB total for StateMachine
// ---------------------------------------------------------------------------

pub const MAX_NODES: usize = 128;
pub const MAX_DEPLOYMENTS: usize = 64;
pub const MAX_PODS: usize = 512;
pub const MAX_KILLSWITCHES: usize = 64;

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

pub const Node = struct {
    id: msg.NodeId,
    name: [64]u8,
    cpu_millicores: u32,
    memory_megabytes: u32,
    gpu_type: msg.GpuType,
    gpu_count: u8,
    provider: [32]u8,
    region: [32]u8,
    status: msg.NodeStatus,
    allocatable_cpu: u32,
    allocatable_mem: u32,
    allocatable_gpu: u8,
    active: bool,
};

pub const Deployment = struct {
    id: msg.DeploymentId,
    name: [64]u8,
    namespace: [64]u8,
    image: [256]u8,
    entrypoint: [256]u8,
    port: u16,
    replicas: u32,
    cpu_millicores: u32,
    memory_megabytes: u32,
    gpu_type: msg.GpuType,
    gpu_count: u8,
    min_replicas: u32,
    max_replicas: u32,
    scale_to_zero_after_ms: u64,
    target_queue_depth: u32,
    liveness: msg.ProbeConfig,
    readiness: msg.ProbeConfig,
    startup_timeout_ms: u32,
    juicefs_path: [128]u8,
    env_vars: [16]msg.EnvEntry,
    env_count: u8,
    image_pull_registry: [128]u8,
    image_pull_username: [64]u8,
    image_pull_password: [256]u8,
    image_pull_password_is_secret: u8,
    traffic_rules: [4]msg.TrafficRule,
    traffic_rule_count: u8,
    version: u32,
    previous_image: [256]u8,
    previous_version: u32,
    paused: bool,
    ready_replicas: u32,
    active: bool,
    last_request_tick: u64 = 0,
};

pub const Pod = struct {
    id: msg.PodId,
    deployment_id: msg.DeploymentId,
    node_id: msg.NodeId,
    name: [64]u8,
    namespace: [64]u8,
    phase: msg.PodPhase,
    cpu_millicores: u32,
    memory_megabytes: u32,
    gpu_type: msg.GpuType,
    gpu_count: u8,
    deployment_version: u32,
    active: bool,
};

pub const Killswitch = struct {
    node_id: msg.NodeId,
    deployment_id: msg.DeploymentId,
    active: bool,
};

pub const NodeCapacity = struct {
    node_id: msg.NodeId,
    total_gpu: u8,
    allocated_gpu: u8,
    available_gpu: u8,
    available_cpu: u32,
    available_mem: u32,
    gpu_type: msg.GpuType,
    region: [32]u8,
    provider: [32]u8,
    status: msg.NodeStatus,
};

pub const Backend = struct {
    pod_id: msg.PodId,
    node_id: msg.NodeId,
    deployment_id: msg.DeploymentId,
};

pub const MAX_BACKENDS: usize = 32;

const CommittedDigest = struct {
    value: u64 = 0xcbf29ce484222325,

    fn addByte(self: *CommittedDigest, byte: u8) void {
        self.value ^= byte;
        self.value *%= 0x100000001b3;
    }

    fn addValue(self: *CommittedDigest, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => self.addByte(@intFromBool(value)),
            .int => |int_info| {
                const U = std.meta.Int(.unsigned, int_info.bits);
                var bits: u128 = @intCast(@as(U, @bitCast(value)));
                for (0..@sizeOf(T)) |_| {
                    self.addByte(@truncate(bits));
                    bits >>= 8;
                }
            },
            .@"enum" => self.addValue(@intFromEnum(value)),
            .array => {
                for (value) |element| self.addValue(element);
            },
            .@"struct" => |struct_info| {
                inline for (struct_info.fields) |field| self.addValue(@field(value, field.name));
            },
            else => @compileError("unsupported committed digest type: " ++ @typeName(T)),
        }
    }

    fn addDeployment(self: *CommittedDigest, deployment: Deployment) void {
        inline for (@typeInfo(Deployment).@"struct".fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "last_request_tick")) {
                self.addValue(@field(deployment, field.name));
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Valid NodeStatus transitions
// ---------------------------------------------------------------------------

pub fn validNodeTransition(from: msg.NodeStatus, to: msg.NodeStatus) bool {
    return switch (from) {
        .provisioning => to == .starting or to == .terminated or to == .ready,
        .starting => to == .ready or to == .terminated,
        .ready => to == .unhealthy or to == .draining,
        .unhealthy => to == .ready or to == .draining,
        .draining => to == .terminating,
        .terminating => to == .terminated,
        .terminated => false,
    };
}

// ---------------------------------------------------------------------------
// State machine -- deterministic core, knows nothing about VRR
// ---------------------------------------------------------------------------

pub const StateMachine = struct {
    seed: u64,
    prng: Prng,

    nodes: [MAX_NODES]Node,
    node_count: usize,

    deployments: [MAX_DEPLOYMENTS]Deployment,
    deployment_count: usize,

    pods: [MAX_PODS]Pod,
    pod_count: usize,

    killswitches: [MAX_KILLSWITCHES]Killswitch,
    killswitch_count: usize,

    pub fn init(seed: u64) StateMachine {
        return .{
            .seed = seed,
            .prng = Prng.init(seed),
            .nodes = undefined,
            .node_count = 0,
            .deployments = undefined,
            .deployment_count = 0,
            .pods = undefined,
            .pod_count = 0,
            .killswitches = undefined,
            .killswitch_count = 0,
        };
    }

    pub fn initInPlace(self: *StateMachine, seed: u64) void {
        self.seed = seed;
        self.prng = Prng.init(seed);
        self.node_count = 0;
        self.deployment_count = 0;
        self.pod_count = 0;
        self.killswitch_count = 0;
    }

    /// Bounded digest of command-derived state. Local scheduling timestamps are
    /// excluded; PRNG state is included because it determines future IDs.
    pub fn committedDigest(self: *const StateMachine) u64 {
        std.debug.assert(self.node_count <= MAX_NODES);
        std.debug.assert(self.deployment_count <= MAX_DEPLOYMENTS);
        std.debug.assert(self.pod_count <= MAX_PODS);
        std.debug.assert(self.killswitch_count <= MAX_KILLSWITCHES);

        var digest = CommittedDigest{};
        digest.addValue(self.prng.state);
        digest.addValue(self.node_count);
        for (self.nodes[0..self.node_count]) |node| digest.addValue(node);
        digest.addValue(self.deployment_count);
        for (self.deployments[0..self.deployment_count]) |deployment| digest.addDeployment(deployment);
        digest.addValue(self.pod_count);
        for (self.pods[0..self.pod_count]) |pod| digest.addValue(pod);
        digest.addValue(self.killswitch_count);
        for (self.killswitches[0..self.killswitch_count]) |killswitch| digest.addValue(killswitch);
        return digest.value;
    }

    /// Apply a committed command. MUST produce identical results on all
    /// replicas given the same sequence of commands and the same seed.
    pub fn apply(self: *StateMachine, command: msg.Command) msg.Result {
        return switch (command) {
            .register_node => |cmd| self.handleRegisterNode(cmd),
            .deregister_node => |cmd| self.handleDeregisterNode(cmd),
            .update_node_status => |cmd| self.handleUpdateNodeStatus(cmd),
            .create_deployment => |cmd| self.handleCreateDeployment(cmd),
            .bind_pod_to_node => |cmd| self.handleBindPodToNode(cmd),
            .bind_pods_to_nodes => |cmd| self.handleBindPodsToNodes(cmd),
            .update_pod_status => |cmd| self.handleUpdatePodStatus(cmd),
            .scale_deployment => |cmd| self.handleScaleDeployment(cmd),
            .unbind_pod => |cmd| self.handleUnbindPod(cmd),
            .set_killswitch => |cmd| self.handleSetKillswitch(cmd),
            .noop => .{ .ok = .{} },
            .update_deployment => |cmd| self.handleUpdateDeployment(cmd),
            .set_traffic_split => |cmd| self.handleSetTrafficSplit(cmd),
            .rollback_deployment => |cmd| self.handleRollbackDeployment(cmd),
            .delete_deployment => |cmd| self.handleDeleteDeployment(cmd),
            .pause_deployment => |cmd| self.handlePauseDeployment(cmd),
            .resume_deployment => |cmd| self.handleResumeDeployment(cmd),
        };
    }

    // -- Node operations --

    fn findActiveNodeIndexByName(self: *const StateMachine, name: [64]u8) ?usize {
        for (0..self.node_count) |i| {
            if (!self.nodes[i].active) continue;
            if (!std.mem.eql(u8, &self.nodes[i].name, &name)) continue;
            return i;
        }
        return null;
    }

    fn handleRegisterNode(self: *StateMachine, cmd: msg.RegisterNodeCmd) msg.Result {
        if (self.findActiveNodeIndexByName(cmd.node_name)) |idx| {
            const id = self.nodes[idx].id;
            self.nodes[idx].cpu_millicores = cmd.cpu_millicores;
            self.nodes[idx].memory_megabytes = cmd.memory_megabytes;
            self.nodes[idx].gpu_type = cmd.gpu_type;
            self.nodes[idx].gpu_count = cmd.gpu_count;
            self.nodes[idx].provider = cmd.provider;
            self.nodes[idx].region = cmd.region;
            self.nodes[idx].status = .ready;
            self.nodes[idx].active = true;
            self.recomputeNodeAllocatable(idx);
            return .{ .ok = .{ .entity_id = id } };
        }

        if (self.node_count >= MAX_NODES) {
            return .{ .err = .capacity_exceeded };
        }

        const id = self.generateId();
        self.nodes[self.node_count] = .{
            .id = id,
            .name = cmd.node_name,
            .cpu_millicores = cmd.cpu_millicores,
            .memory_megabytes = cmd.memory_megabytes,
            .gpu_type = cmd.gpu_type,
            .gpu_count = cmd.gpu_count,
            .provider = cmd.provider,
            .region = cmd.region,
            .status = .ready,
            .allocatable_cpu = cmd.cpu_millicores,
            .allocatable_mem = cmd.memory_megabytes,
            .allocatable_gpu = cmd.gpu_count,
            .active = true,
        };
        self.node_count += 1;
        return .{ .ok = .{ .entity_id = id } };
    }

    fn handleDeregisterNode(self: *StateMachine, cmd: msg.DeregisterNodeCmd) msg.Result {
        const idx = self.findNodeIndex(cmd.node_id) orelse
            return .{ .err = .not_found };

        self.nodes[idx].status = .terminated;
        self.nodes[idx].active = false;
        return .{ .ok = .{ .entity_id = cmd.node_id } };
    }

    fn handleUpdateNodeStatus(self: *StateMachine, cmd: msg.UpdateNodeStatusCmd) msg.Result {
        const idx = self.findNodeIndex(cmd.node_id) orelse
            return .{ .err = .not_found };

        if (!validNodeTransition(self.nodes[idx].status, cmd.new_status)) {
            return .{ .err = .invalid_transition };
        }

        self.nodes[idx].status = cmd.new_status;
        if (cmd.new_status == .terminated) {
            self.nodes[idx].active = false;
        }
        return .{ .ok = .{ .entity_id = cmd.node_id } };
    }

    // -- Deployment operations --

    fn handleCreateDeployment(self: *StateMachine, cmd: msg.CreateDeploymentCmd) msg.Result {
        const dep_idx = self.findInactiveDeploymentIndex() orelse blk: {
            if (self.deployment_count >= MAX_DEPLOYMENTS) {
                return .{ .err = .capacity_exceeded };
            }
            const idx = self.deployment_count;
            self.deployment_count += 1;
            break :blk idx;
        };

        const dep_id = self.generateId();
        self.deployments[dep_idx] = .{
            .id = dep_id,
            .name = cmd.name,
            .namespace = cmd.namespace,
            .image = cmd.image,
            .entrypoint = cmd.entrypoint,
            .port = cmd.port,
            .replicas = cmd.replicas,
            .cpu_millicores = cmd.cpu_millicores,
            .memory_megabytes = cmd.memory_megabytes,
            .gpu_type = cmd.gpu_type,
            .gpu_count = cmd.gpu_count,
            .min_replicas = cmd.min_replicas,
            .max_replicas = cmd.max_replicas,
            .scale_to_zero_after_ms = cmd.scale_to_zero_after_ms,
            .target_queue_depth = cmd.target_queue_depth,
            .liveness = cmd.liveness,
            .readiness = cmd.readiness,
            .startup_timeout_ms = cmd.startup_timeout_ms,
            .juicefs_path = cmd.juicefs_path,
            .env_vars = cmd.env_vars,
            .env_count = cmd.env_count,
            .image_pull_registry = cmd.image_pull_registry,
            .image_pull_username = cmd.image_pull_username,
            .image_pull_password = cmd.image_pull_password,
            .image_pull_password_is_secret = cmd.image_pull_password_is_secret,
            .traffic_rules = [_]msg.TrafficRule{.{}} ** 4,
            .traffic_rule_count = 0,
            .version = 1,
            .previous_image = std.mem.zeroes([256]u8),
            .previous_version = 0,
            .paused = false,
            .ready_replicas = 0,
            .active = true,
            .last_request_tick = 0,
        };

        // Create pods for the deployment
        var i: u32 = 0;
        while (i < cmd.replicas) : (i += 1) {
            self.appendPodForDeployment(dep_id, i) catch break;
        }

        debugLog(
            "hivemind sm: create_deployment name={s} replicas={d} deployment_count={d} pod_count={d}\n",
            .{ msg.fixedToSlice(&cmd.name), cmd.replicas, self.deployment_count, self.pod_count },
        );

        return .{ .ok = .{ .entity_id = dep_id } };
    }

    // -- Pod operations --

    fn handleBindPodToNode(self: *StateMachine, cmd: msg.BindPodToNodeCmd) msg.Result {
        const pod_idx = self.findPodIndex(cmd.pod_id) orelse
            return .{ .err = .not_found };
        const node_idx = self.findNodeIndex(cmd.node_id) orelse
            return .{ .err = .not_found };

        const pod = &self.pods[pod_idx];
        const node = &self.nodes[node_idx];

        if (pod.node_id != 0 or pod.phase != .pending) {
            return .{ .err = .already_exists };
        }

        if (pod.gpu_count > 0 and node.allocatable_gpu < pod.gpu_count) {
            return .{ .err = .capacity_exceeded };
        }
        if (pod.cpu_millicores > 0 and node.allocatable_cpu < pod.cpu_millicores) {
            return .{ .err = .capacity_exceeded };
        }
        if (pod.memory_megabytes > 0 and node.allocatable_mem < pod.memory_megabytes) {
            return .{ .err = .capacity_exceeded };
        }

        if (pod.gpu_count > 0) node.allocatable_gpu -= pod.gpu_count;
        node.allocatable_cpu -= pod.cpu_millicores;
        node.allocatable_mem -= pod.memory_megabytes;

        pod.node_id = cmd.node_id;
        pod.phase = .scheduled;
        debugLog(
            "hivemind sm: bind_pod pod_id={d} node_id={d} phase=scheduled\n",
            .{ cmd.pod_id, cmd.node_id },
        );
        return .{ .ok = .{ .entity_id = cmd.pod_id } };
    }

    const BatchNodeDemand = struct {
        node_idx: usize = 0,
        cpu: u32 = 0,
        mem: u32 = 0,
        gpu: u8 = 0,
        active: bool = false,
    };

    fn handleBindPodsToNodes(self: *StateMachine, cmd: msg.BindPodsToNodesCmd) msg.Result {
        if (cmd.count == 0 or cmd.count > msg.BIND_BATCH_MAX) return .{ .err = .invalid_transition };

        var seen: [msg.BIND_BATCH_MAX]msg.PodId = [_]msg.PodId{0} ** msg.BIND_BATCH_MAX;
        var node_demands: [MAX_NODES]BatchNodeDemand = [_]BatchNodeDemand{.{}} ** MAX_NODES;
        var demand_count: usize = 0;

        for (cmd.bindings[0..cmd.count], 0..) |binding, i| {
            if (binding.pod_id == 0 or binding.node_id == 0) return .{ .err = .not_found };
            for (seen[0..i]) |pod_id| {
                if (pod_id == binding.pod_id) return .{ .err = .already_exists };
            }
            seen[i] = binding.pod_id;

            const pod_idx = self.findPodIndex(binding.pod_id) orelse return .{ .err = .not_found };
            const node_idx = self.findNodeIndex(binding.node_id) orelse return .{ .err = .not_found };
            const pod = &self.pods[pod_idx];
            const node = &self.nodes[node_idx];

            if (!pod.active or pod.node_id != 0 or pod.phase != .pending) return .{ .err = .already_exists };
            if (!node.active or node.status != .ready) return .{ .err = .invalid_transition };
            if (pod.gpu_count > 0 and node.gpu_type != pod.gpu_type) return .{ .err = .capacity_exceeded };

            var demand_idx: ?usize = null;
            for (node_demands[0..demand_count], 0..) |demand, j| {
                if (demand.active and demand.node_idx == node_idx) {
                    demand_idx = j;
                    break;
                }
            }
            const idx = demand_idx orelse blk: {
                if (demand_count >= node_demands.len) return .{ .err = .capacity_exceeded };
                node_demands[demand_count] = .{ .node_idx = node_idx, .active = true };
                demand_count += 1;
                break :blk demand_count - 1;
            };
            node_demands[idx].cpu += pod.cpu_millicores;
            node_demands[idx].mem += pod.memory_megabytes;
            node_demands[idx].gpu += pod.gpu_count;
        }

        for (node_demands[0..demand_count]) |demand| {
            const node = &self.nodes[demand.node_idx];
            if (node.allocatable_cpu < demand.cpu) return .{ .err = .capacity_exceeded };
            if (node.allocatable_mem < demand.mem) return .{ .err = .capacity_exceeded };
            if (node.allocatable_gpu < demand.gpu) return .{ .err = .capacity_exceeded };
        }

        for (node_demands[0..demand_count]) |demand| {
            const node = &self.nodes[demand.node_idx];
            node.allocatable_cpu -= demand.cpu;
            node.allocatable_mem -= demand.mem;
            node.allocatable_gpu -= demand.gpu;
        }

        for (cmd.bindings[0..cmd.count]) |binding| {
            const pod_idx = self.findPodIndex(binding.pod_id).?;
            self.pods[pod_idx].node_id = binding.node_id;
            self.pods[pod_idx].phase = .scheduled;
        }

        return .{ .ok = .{ .entity_id = cmd.count } };
    }

    fn handleUpdatePodStatus(self: *StateMachine, cmd: msg.UpdatePodStatusCmd) msg.Result {
        const pod_idx = self.findPodIndex(cmd.pod_id) orelse
            return .{ .err = .not_found };

        const pod = &self.pods[pod_idx];
        const old_phase = pod.phase;
        if (self.findDeploymentIndex(pod.deployment_id)) |dep_idx| {
            const dep = &self.deployments[dep_idx];
            if (old_phase != .running and cmd.new_phase == .running) {
                dep.ready_replicas += 1;
            } else if (old_phase == .running and cmd.new_phase != .running) {
                dep.ready_replicas = dep.ready_replicas -| 1;
            }
        }

        const should_replace = cmd.new_phase == .failed;
        const deployment_id = pod.deployment_id;
        pod.phase = cmd.new_phase;
        if (cmd.new_phase == .succeeded or cmd.new_phase == .failed) {
            if (pod.node_id != 0) {
                if (self.findNodeIndex(pod.node_id)) |node_idx| {
                    const n = &self.nodes[node_idx];
                    if (pod.gpu_count > 0) n.allocatable_gpu += pod.gpu_count;
                    n.allocatable_cpu += pod.cpu_millicores;
                    n.allocatable_mem += pod.memory_megabytes;
                }
                pod.node_id = 0;
            }
            pod.active = false;
            if (should_replace) self.ensureDeploymentReplicaCount(deployment_id);
        }
        debugLog(
            "hivemind sm: update_pod_status pod_id={d} old={s} new={s} active={any}\n",
            .{ cmd.pod_id, @tagName(old_phase), @tagName(cmd.new_phase), pod.active },
        );
        return .{ .ok = .{ .entity_id = cmd.pod_id } };
    }

    // -- Scaling --

    fn handleScaleDeployment(self: *StateMachine, cmd: msg.ScaleDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        const dep = &self.deployments[dep_idx];
        const old_replicas = dep.replicas;
        dep.replicas = cmd.desired_replicas;

        // Scale up: create new pending pods
        if (cmd.desired_replicas > old_replicas) {
            var i: u32 = old_replicas;
            while (i < cmd.desired_replicas) : (i += 1) {
                self.appendPodForDeployment(cmd.deployment_id, i) catch break;
            }
        }

        // Scale down: mark excess active pods as terminating
        if (cmd.desired_replicas < old_replicas) {
            var excess = old_replicas - cmd.desired_replicas;
            for (self.pods[0..self.pod_count]) |*pod| {
                if (excess == 0) break;
                if (!pod.active) continue;
                if (pod.deployment_id != cmd.deployment_id) continue;
                if (pod.phase == .terminating) continue;

                if (pod.phase == .running) {
                    dep.ready_replicas = dep.ready_replicas -| 1;
                }
                pod.phase = .terminating;
                pod.active = false;
                excess -= 1;
            }
        }

        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleUnbindPod(self: *StateMachine, cmd: msg.UnbindPodCmd) msg.Result {
        const pod_idx = self.findPodIndex(cmd.pod_id) orelse
            return .{ .err = .not_found };

        const pod = &self.pods[pod_idx];

        if (self.findDeploymentIndex(pod.deployment_id)) |dep_idx| {
            if (pod.phase == .running) {
                self.deployments[dep_idx].ready_replicas = self.deployments[dep_idx].ready_replicas -| 1;
            }
        }
        pod.phase = .terminating;
        pod.active = false;
        debugLog("hivemind sm: unbind_pod pod_id={d}\n", .{cmd.pod_id});
        return .{ .ok = .{ .entity_id = cmd.pod_id } };
    }

    fn handleUpdateDeployment(self: *StateMachine, cmd: msg.UpdateDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        const dep = &self.deployments[dep_idx];
        dep.previous_image = dep.image;
        dep.previous_version = dep.version;
        dep.image = cmd.image;
        dep.entrypoint = cmd.entrypoint;
        if (cmd.port != 0) dep.port = cmd.port;
        if (cmd.cpu_millicores != 0) dep.cpu_millicores = cmd.cpu_millicores;
        if (cmd.memory_megabytes != 0) dep.memory_megabytes = cmd.memory_megabytes;
        if (cmd.gpu_type != .none) dep.gpu_type = cmd.gpu_type;
        if (cmd.gpu_count != 0) dep.gpu_count = cmd.gpu_count;
        dep.env_vars = cmd.env_vars;
        dep.env_count = cmd.env_count;
        dep.version += 1;
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleSetTrafficSplit(self: *StateMachine, cmd: msg.SetTrafficSplitCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        const dep = &self.deployments[dep_idx];
        dep.traffic_rules = cmd.rules;
        dep.traffic_rule_count = cmd.rule_count;
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleRollbackDeployment(self: *StateMachine, cmd: msg.RollbackDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        const dep = &self.deployments[dep_idx];
        if (dep.previous_version == 0) return .{ .err = .invalid_transition };

        const current_image = dep.image;
        dep.image = dep.previous_image;
        dep.previous_image = current_image;
        dep.previous_version = dep.version;
        dep.version += 1;
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleDeleteDeployment(self: *StateMachine, cmd: msg.DeleteDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        const dep = &self.deployments[dep_idx];
        dep.active = false;

        for (self.pods[0..self.pod_count]) |*pod| {
            if (pod.deployment_id == cmd.deployment_id and pod.active) {
                if (pod.phase == .running) {
                    dep.ready_replicas = dep.ready_replicas -| 1;
                }
                if (pod.node_id != 0) {
                    if (self.findNodeIndex(pod.node_id)) |node_idx| {
                        const n = &self.nodes[node_idx];
                        if (pod.gpu_count > 0) n.allocatable_gpu += pod.gpu_count;
                        n.allocatable_cpu += pod.cpu_millicores;
                        n.allocatable_mem += pod.memory_megabytes;
                    }
                    pod.node_id = 0;
                }
                pod.phase = .terminating;
                pod.active = false;
            }
        }
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handlePauseDeployment(self: *StateMachine, cmd: msg.PauseDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        self.deployments[dep_idx].paused = true;
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleResumeDeployment(self: *StateMachine, cmd: msg.ResumeDeploymentCmd) msg.Result {
        const dep_idx = self.findDeploymentIndex(cmd.deployment_id) orelse
            return .{ .err = .not_found };

        self.deployments[dep_idx].paused = false;
        return .{ .ok = .{ .entity_id = cmd.deployment_id } };
    }

    fn handleSetKillswitch(self: *StateMachine, cmd: msg.SetKillswitchCmd) msg.Result {
        // Check if killswitch already exists for this pair
        for (self.killswitches[0..self.killswitch_count]) |*ks| {
            if (ks.node_id == cmd.node_id and ks.deployment_id == cmd.deployment_id) {
                ks.active = cmd.active;
                return .{ .ok = .{} };
            }
        }

        if (!cmd.active) return .{ .ok = .{} }; // no-op: deactivating non-existent

        if (self.killswitch_count >= MAX_KILLSWITCHES) {
            return .{ .err = .capacity_exceeded };
        }

        self.killswitches[self.killswitch_count] = .{
            .node_id = cmd.node_id,
            .deployment_id = cmd.deployment_id,
            .active = true,
        };
        self.killswitch_count += 1;
        return .{ .ok = .{} };
    }

    // -- Query methods (local reads for Router/Scheduler) --

    pub fn getNodeCapacity(self: *const StateMachine, node_id: u64) ?NodeCapacity {
        const idx = self.findNodeIndex(node_id) orelse return null;
        const node = &self.nodes[idx];
        if (!node.active) return null;
        return .{
            .node_id = node.id,
            .total_gpu = node.gpu_count,
            .allocated_gpu = node.gpu_count -| @min(node.allocatable_gpu, node.gpu_count),
            .available_gpu = node.allocatable_gpu,
            .available_cpu = node.allocatable_cpu,
            .available_mem = node.allocatable_mem,
            .gpu_type = node.gpu_type,
            .region = node.region,
            .provider = node.provider,
            .status = node.status,
        };
    }

    pub fn getNodesWithGpu(self: *const StateMachine, gpu_type: msg.GpuType, min_available: u8, buf: []NodeCapacity) usize {
        var count: usize = 0;
        for (self.nodes[0..self.node_count]) |*node| {
            if (!node.active) continue;
            if (node.status != .ready) continue;
            if (node.gpu_type != gpu_type) continue;
            if (node.allocatable_gpu < min_available) continue;
            if (count >= buf.len) break;
            buf[count] = .{
                .node_id = node.id,
                .total_gpu = node.gpu_count,
                .allocated_gpu = node.gpu_count -| @min(node.allocatable_gpu, node.gpu_count),
                .available_gpu = node.allocatable_gpu,
                .available_cpu = node.allocatable_cpu,
                .available_mem = node.allocatable_mem,
                .gpu_type = node.gpu_type,
                .region = node.region,
                .provider = node.provider,
                .status = node.status,
            };
            count += 1;
        }
        return count;
    }

    pub fn isKillswitched(self: *const StateMachine, node_id: u64, deployment_id: u64) bool {
        for (self.killswitches[0..self.killswitch_count]) |ks| {
            if (!ks.active) continue;
            if (ks.node_id == 0 and ks.deployment_id == 0) return true;
            if (ks.node_id == node_id and ks.deployment_id == 0) return true;
            if (ks.node_id == 0 and ks.deployment_id == deployment_id) return true;
            if (ks.node_id == node_id and ks.deployment_id == deployment_id) return true;
        }
        return false;
    }

    pub fn getPendingPods(self: *const StateMachine, deployment_id: u64, buf: []u64) usize {
        var count: usize = 0;
        for (self.pods[0..self.pod_count]) |*pod| {
            if (!pod.active) continue;
            if (pod.deployment_id != deployment_id) continue;
            if (pod.phase != .pending) continue;
            if (count >= buf.len) break;
            buf[count] = pod.id;
            count += 1;
        }
        return count;
    }

    pub fn getActivePodCount(self: *const StateMachine, deployment_id: u64) u32 {
        var count: u32 = 0;
        for (self.pods[0..self.pod_count]) |*pod| {
            if (!pod.active) continue;
            if (pod.deployment_id != deployment_id) continue;
            count += 1;
        }
        return count;
    }

    pub fn getDeployment(self: *const StateMachine, id: u64) ?*const Deployment {
        const idx = self.findDeploymentIndex(id) orelse return null;
        return &self.deployments[idx];
    }

    /// Get running/scheduled backends for a deployment (routing table).
    pub fn getBackends(self: *const StateMachine, deployment_id: u64, buf: []Backend) usize {
        var count: usize = 0;
        for (self.pods[0..self.pod_count]) |*pod| {
            if (!pod.active) continue;
            if (pod.deployment_id != deployment_id) continue;
            if (pod.node_id == 0) continue;
            if (pod.phase != .scheduled and pod.phase != .running) continue;
            if (count >= buf.len) break;
            buf[count] = .{
                .pod_id = pod.id,
                .node_id = pod.node_id,
                .deployment_id = pod.deployment_id,
            };
            count += 1;
        }
        return count;
    }

    /// Find deployment by name (for routing by app name).
    pub fn findDeploymentByName(self: *const StateMachine, name: []const u8) ?*const Deployment {
        for (self.deployments[0..self.deployment_count]) |*dep| {
            if (!dep.active) continue;
            if (std.mem.eql(u8, msg.fixedToSlice(&dep.name), name)) return dep;
        }
        return null;
    }

    // -- Public lookup helpers --

    pub fn findPod(self: *const StateMachine, id: u64) ?*const Pod {
        const idx = self.findPodIndex(id) orelse return null;
        return &self.pods[idx];
    }

    pub fn findDeployment(self: *const StateMachine, id: u64) ?*const Deployment {
        const idx = self.findDeploymentIndex(id) orelse return null;
        return &self.deployments[idx];
    }

    pub fn findDeploymentMut(self: *StateMachine, id: u64) ?*Deployment {
        const idx = self.findDeploymentIndex(id) orelse return null;
        return &self.deployments[idx];
    }

    pub fn findNode(self: *const StateMachine, id: u64) ?*const Node {
        const idx = self.findNodeIndex(id) orelse return null;
        return &self.nodes[idx];
    }

    // -- Internal lookup helpers --

    fn findNodeIndex(self: *const StateMachine, id: u64) ?usize {
        for (self.nodes[0..self.node_count], 0..) |node, i| {
            if (node.id == id) return i;
        }
        return null;
    }

    fn findPodIndex(self: *const StateMachine, id: u64) ?usize {
        for (self.pods[0..self.pod_count], 0..) |pod, i| {
            if (pod.id == id) return i;
        }
        return null;
    }

    fn findInactivePodIndex(self: *const StateMachine) ?usize {
        for (self.pods[0..self.pod_count], 0..) |pod, i| {
            if (!pod.active and pod.node_id == 0) return i;
        }
        return null;
    }

    fn findDeploymentIndex(self: *const StateMachine, id: u64) ?usize {
        for (self.deployments[0..self.deployment_count], 0..) |dep, i| {
            if (dep.id == id) return i;
        }
        return null;
    }

    fn findInactiveDeploymentIndex(self: *const StateMachine) ?usize {
        for (self.deployments[0..self.deployment_count], 0..) |dep, i| {
            if (!dep.active) return i;
        }
        return null;
    }

    pub fn generateId(self: *StateMachine) u64 {
        return self.prng.next();
    }

    fn recomputeNodeAllocatable(self: *StateMachine, node_idx: usize) void {
        const node_id = self.nodes[node_idx].id;
        self.nodes[node_idx].allocatable_cpu = self.nodes[node_idx].cpu_millicores;
        self.nodes[node_idx].allocatable_mem = self.nodes[node_idx].memory_megabytes;
        self.nodes[node_idx].allocatable_gpu = self.nodes[node_idx].gpu_count;

        for (self.pods[0..self.pod_count]) |*pod| {
            if (!pod.active or pod.node_id != node_id) continue;
            self.nodes[node_idx].allocatable_cpu -|= pod.cpu_millicores;
            self.nodes[node_idx].allocatable_mem -|= pod.memory_megabytes;
            if (pod.gpu_count > 0) self.nodes[node_idx].allocatable_gpu -|= pod.gpu_count;
        }
    }

    fn appendPodForDeployment(self: *StateMachine, deployment_id: msg.DeploymentId, ordinal: u32) !void {
        const pod_idx = self.findInactivePodIndex() orelse blk: {
            if (self.pod_count >= MAX_PODS) return error.CapacityExceeded;
            const idx = self.pod_count;
            self.pod_count += 1;
            break :blk idx;
        };
        const dep_idx = self.findDeploymentIndex(deployment_id) orelse return error.NotFound;
        const dep = &self.deployments[dep_idx];
        if (!dep.active) return error.NotFound;

        const pod_id = self.generateId();
        var pod_name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&pod_name, "{s}-{d}", .{
            msg.fixedToSlice(&dep.name), ordinal,
        }) catch {};

        self.pods[pod_idx] = .{
            .id = pod_id,
            .deployment_id = deployment_id,
            .node_id = 0,
            .name = pod_name,
            .namespace = dep.namespace,
            .phase = .pending,
            .cpu_millicores = dep.cpu_millicores,
            .memory_megabytes = dep.memory_megabytes,
            .gpu_type = dep.gpu_type,
            .gpu_count = dep.gpu_count,
            .deployment_version = dep.version,
            .active = true,
        };
    }

    fn ensureDeploymentReplicaCount(self: *StateMachine, deployment_id: msg.DeploymentId) void {
        const dep_idx = self.findDeploymentIndex(deployment_id) orelse return;
        const dep = &self.deployments[dep_idx];
        if (!dep.active or dep.paused) return;

        var active_count = self.getActivePodCount(deployment_id);
        while (active_count < dep.replicas) : (active_count += 1) {
            self.appendPodForDeployment(deployment_id, active_count) catch return;
        }
    }

    // -- Query helpers --

    pub fn activeNodeCount(self: *const StateMachine) usize {
        var count: usize = 0;
        for (self.nodes[0..self.node_count]) |node| {
            if (node.active) count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "determinism: same seed same results" {
    const allocator = std.testing.allocator;
    const a = try allocator.create(StateMachine);
    defer allocator.destroy(a);
    const b = try allocator.create(StateMachine);
    defer allocator.destroy(b);
    a.initInPlace(42);
    b.initInPlace(42);

    const cmd = msg.Command{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } };

    const r1 = a.apply(cmd);
    const r2 = b.apply(cmd);

    try std.testing.expectEqual(r1.ok.entity_id, r2.ok.entity_id);
    try std.testing.expectEqual(a.node_count, b.node_count);
}

test "committed digest excludes local timestamps and includes deterministic future state" {
    const allocator = std.testing.allocator;
    const a = try allocator.create(StateMachine);
    defer allocator.destroy(a);
    const b = try allocator.create(StateMachine);
    defer allocator.destroy(b);
    a.initInPlace(77);
    b.initInPlace(77);

    const command = msg.Command{ .create_deployment = .{
        .name = msg.strToFixed(64, "digest"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "image:v1"),
        .replicas = 1,
    } };
    _ = a.apply(command);
    _ = b.apply(command);
    try std.testing.expectEqual(a.committedDigest(), b.committedDigest());

    b.deployments[0].last_request_tick = 999;
    try std.testing.expectEqual(a.committedDigest(), b.committedDigest());
    _ = b.prng.next();
    try std.testing.expect(a.committedDigest() != b.committedDigest());
}

test "register node and deregister" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1);

    const result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "test-node"),
        .cpu_millicores = 2000,
        .memory_megabytes = 4096,
    } });

    const node_id = result.ok.entity_id;
    try std.testing.expectEqual(@as(usize, 1), sm.node_count);
    try std.testing.expectEqual(msg.NodeStatus.ready, sm.findNode(node_id).?.status);

    const dereg = sm.apply(.{ .deregister_node = .{ .node_id = node_id } });
    try std.testing.expectEqual(node_id, dereg.ok.entity_id);
    try std.testing.expect(!sm.findNode(node_id).?.active);
}

test "register same hostname while node is active returns existing id" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7);

    const name = msg.strToFixed(64, "reconnect-node");

    const r1 = sm.apply(.{ .register_node = .{
        .node_name = name,
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    const id1 = r1.ok.entity_id;

    const r2 = sm.apply(.{ .register_node = .{
        .node_name = name,
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    try std.testing.expectEqual(id1, r2.ok.entity_id);
    try std.testing.expectEqual(@as(usize, 1), sm.node_count);
}

test "create deployment stores image pull credentials" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(123);

    var cmd: msg.CreateDeploymentCmd = .{
        .name = msg.strToFixed(64, "svc"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "registry.io/app:v2"),
        .replicas = 1,
        .gpu_type = .none,
        .gpu_count = 0,
    };
    cmd.image_pull_registry = msg.strToFixed(128, "registry.io");
    cmd.image_pull_username = msg.strToFixed(64, "aws");
    cmd.image_pull_password = msg.strToFixed(256, "token");
    cmd.image_pull_password_is_secret = 1;

    const dep_id = (sm.apply(.{ .create_deployment = cmd })).ok.entity_id;
    const dep = sm.findDeployment(dep_id).?;
    try std.testing.expectEqualStrings("registry.io", msg.fixedToSlice(&dep.image_pull_registry));
    try std.testing.expectEqualStrings("aws", msg.fixedToSlice(&dep.image_pull_username));
    try std.testing.expectEqualStrings("token", msg.fixedToSlice(&dep.image_pull_password));
    try std.testing.expectEqual(@as(u8, 1), dep.image_pull_password_is_secret);
}

test "invalid node status transition rejected" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1);

    const result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "n1"),
        .cpu_millicores = 1000,
        .memory_megabytes = 2048,
    } });
    const node_id = result.ok.entity_id;

    // ready -> terminated is not valid (must drain first)
    const bad = sm.apply(.{ .update_node_status = .{
        .node_id = node_id,
        .new_status = .terminated,
    } });
    try std.testing.expectEqual(msg.ErrorCode.invalid_transition, bad.err);
}

test "create deployment produces pods" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(99);

    const result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "web"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx:latest"),
        .replicas = 3,
        .cpu_millicores = 500,
        .memory_megabytes = 256,
    } });
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(usize, 3), sm.pod_count);
    try std.testing.expectEqual(@as(usize, 1), sm.deployment_count);
}

test "bind pod deducts GPU capacity from node" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .cpu_millicores = 32000,
        .memory_megabytes = 65536,
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "llm"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "llm:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 2,
    } });
    const dep_id = dep_result.ok.entity_id;

    var pod_buf: [8]u64 = undefined;
    const pending = sm.getPendingPods(dep_id, &pod_buf);
    try std.testing.expectEqual(@as(usize, 1), pending);
    const pod_id = pod_buf[0];

    const bind_result = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });
    try std.testing.expect(bind_result == .ok);

    const cap = sm.getNodeCapacity(node_id).?;
    try std.testing.expectEqual(@as(u8, 6), cap.available_gpu);
    try std.testing.expectEqual(@as(u8, 2), cap.allocated_gpu);
}

test "bind pod deducts CPU and memory from node" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "cpu-node"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "svc"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "svc:v1"),
        .replicas = 1,
        .cpu_millicores = 2000,
        .memory_megabytes = 4096,
    } });

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    const bind = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_id } });
    try std.testing.expect(bind == .ok);

    const cap = sm.getNodeCapacity(node_id).?;
    try std.testing.expectEqual(@as(u32, 6000), cap.available_cpu);
    try std.testing.expectEqual(@as(u32, 12288), cap.available_mem);
}

test "bind pod fails when CPU capacity insufficient" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "tiny"),
        .cpu_millicores = 1000,
        .memory_megabytes = 4096,
    } });

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "hungry"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "hungry:v1"),
        .replicas = 1,
        .cpu_millicores = 4000,
        .memory_megabytes = 1024,
    } });

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    const bind = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_result.ok.entity_id } });
    try std.testing.expectEqual(msg.ErrorCode.capacity_exceeded, bind.err);
}

test "bind pod fails when memory capacity insufficient" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "low-mem"),
        .cpu_millicores = 16000,
        .memory_megabytes = 512,
    } });

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "ramhungry"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "ram:v1"),
        .replicas = 1,
        .cpu_millicores = 1000,
        .memory_megabytes = 8192,
    } });

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    const bind = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_result.ok.entity_id } });
    try std.testing.expectEqual(msg.ErrorCode.capacity_exceeded, bind.err);
}

test "terminal pod status refunds CPU and memory after unbind" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "cpu-node"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "svc"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "svc:v1"),
        .replicas = 1,
        .cpu_millicores = 3000,
        .memory_megabytes = 8192,
    } });

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_id } });
    _ = sm.apply(.{ .unbind_pod = .{ .pod_id = pod_buf[0] } });
    try std.testing.expectEqual(@as(u32, 5000), sm.getNodeCapacity(node_id).?.available_cpu);
    try std.testing.expectEqual(@as(u32, 8192), sm.getNodeCapacity(node_id).?.available_mem);

    _ = sm.apply(.{ .update_pod_status = .{ .pod_id = pod_buf[0], .new_phase = .succeeded } });

    const cap = sm.getNodeCapacity(node_id).?;
    try std.testing.expectEqual(@as(u32, 8000), cap.available_cpu);
    try std.testing.expectEqual(@as(u32, 16384), cap.available_mem);
}

test "bind pod rejects already-bound pod" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_a = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-a"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } }).ok.entity_id;
    const node_b = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-b"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } }).ok.entity_id;

    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } });

    const pod_id = sm.pods[0].id;
    const first = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_a } });
    try std.testing.expect(first == .ok);

    const second = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_b } });
    try std.testing.expectEqual(msg.ErrorCode.already_exists, second.err);
    try std.testing.expectEqual(node_a, sm.pods[0].node_id);
}

test "bind pod fails when GPU capacity insufficient" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "small-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 1,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "big"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "big:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 4,
    } });

    var pod_buf: [8]u64 = undefined;
    const pending_count = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    try std.testing.expectEqual(@as(usize, 1), pending_count);

    const bind = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_id } });
    try std.testing.expectEqual(msg.ErrorCode.capacity_exceeded, bind.err);
}

test "terminal pod status returns GPU capacity after unbind" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "llm"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "llm:v1"),
        .replicas = 1,
        .gpu_type = .h100_sxm,
        .gpu_count = 2,
    } });

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_result.ok.entity_id, &pod_buf);
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_buf[0], .node_id = node_id } });
    try std.testing.expectEqual(@as(u8, 6), sm.getNodeCapacity(node_id).?.available_gpu);

    _ = sm.apply(.{ .unbind_pod = .{ .pod_id = pod_buf[0] } });
    try std.testing.expectEqual(@as(u8, 6), sm.getNodeCapacity(node_id).?.available_gpu);
    _ = sm.apply(.{ .update_pod_status = .{ .pod_id = pod_buf[0], .new_phase = .succeeded } });
    try std.testing.expectEqual(@as(u8, 8), sm.getNodeCapacity(node_id).?.available_gpu);
}

test "scale deployment creates new pods" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "web"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "web:v1"),
        .replicas = 2,
    } });
    const dep_id = dep_result.ok.entity_id;
    try std.testing.expectEqual(@as(usize, 2), sm.pod_count);

    _ = sm.apply(.{ .scale_deployment = .{ .deployment_id = dep_id, .desired_replicas = 5 } });
    try std.testing.expectEqual(@as(usize, 5), sm.pod_count);
    try std.testing.expectEqual(@as(u32, 5), sm.getDeployment(dep_id).?.replicas);
}

test "failed deployment pod creates replacement pending pod" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-a"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } }).ok.entity_id;

    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "resilient"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "resilient:v1"),
        .replicas = 2,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } }).ok.entity_id;

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_id, &pod_buf);
    const failed_pod_id = pod_buf[0];

    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = failed_pod_id, .node_id = node_id } });
    const fail = sm.apply(.{ .update_pod_status = .{ .pod_id = failed_pod_id, .new_phase = .failed } });
    try std.testing.expect(fail == .ok);

    try std.testing.expectEqual(@as(u32, 2), sm.getActivePodCount(dep_id));
    try std.testing.expectEqual(@as(usize, 2), sm.pod_count);
    try std.testing.expect(sm.findPod(failed_pod_id) == null);
    try std.testing.expectEqual(@as(u32, 8000), sm.getNodeCapacity(node_id).?.available_cpu);

    const pending = sm.getPendingPods(dep_id, &pod_buf);
    try std.testing.expectEqual(@as(usize, 2), pending);
}

test "running pod status updates ready replicas and unbind refunds it" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "ready-node"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
    } }).ok.entity_id;

    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "ready-app"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "ready:v1"),
        .replicas = 1,
    } }).ok.entity_id;

    var pod_buf: [8]u64 = undefined;
    _ = sm.getPendingPods(dep_id, &pod_buf);
    const pod_id = pod_buf[0];

    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });
    try std.testing.expectEqual(@as(u32, 0), sm.getDeployment(dep_id).?.ready_replicas);

    _ = sm.apply(.{ .update_pod_status = .{ .pod_id = pod_id, .new_phase = .running } });
    try std.testing.expectEqual(@as(u32, 1), sm.getDeployment(dep_id).?.ready_replicas);

    _ = sm.apply(.{ .unbind_pod = .{ .pod_id = pod_id } });
    try std.testing.expectEqual(@as(u32, 0), sm.getDeployment(dep_id).?.ready_replicas);
}

test "killswitch blocks node-deployment pair" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    try std.testing.expect(!sm.isKillswitched(1, 1));

    _ = sm.apply(.{ .set_killswitch = .{ .node_id = 1, .deployment_id = 1, .active = true } });
    try std.testing.expect(sm.isKillswitched(1, 1));
    try std.testing.expect(!sm.isKillswitched(2, 1));

    _ = sm.apply(.{ .set_killswitch = .{ .node_id = 99, .deployment_id = 0, .active = true } });
    try std.testing.expect(sm.isKillswitched(99, 1));
    try std.testing.expect(sm.isKillswitched(99, 2));
}

test "getNodesWithGpu filters by type and availability" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    _ = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "h100-node"),
        .gpu_type = .h100_sxm,
        .gpu_count = 8,
    } });
    _ = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "a100-node"),
        .gpu_type = .a100_80,
        .gpu_count = 4,
    } });
    _ = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "small-h100"),
        .gpu_type = .h100_sxm,
        .gpu_count = 1,
    } });

    var buf: [10]NodeCapacity = undefined;

    const count = sm.getNodesWithGpu(.h100_sxm, 2, &buf);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 8), buf[0].available_gpu);

    const count2 = sm.getNodesWithGpu(.h100_sxm, 1, &buf);
    try std.testing.expectEqual(@as(usize, 2), count2);
}

test "update deployment bumps version and saves previous image" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "web"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "web:v1"),
        .replicas = 1,
    } });
    const dep_id = dep_result.ok.entity_id;

    const update_result = sm.apply(.{ .update_deployment = .{
        .deployment_id = dep_id,
        .image = msg.strToFixed(256, "web:v2"),
        .entrypoint = msg.strToFixed(256, "serve"),
        .port = 9090,
    } });
    try std.testing.expect(update_result == .ok);

    const dep = sm.findDeployment(dep_id).?;
    try std.testing.expectEqual(@as(u32, 2), dep.version);
    try std.testing.expectEqual(@as(u16, 9090), dep.port);
    try std.testing.expectEqualStrings("web:v2", msg.fixedToSlice(&dep.image));
    try std.testing.expectEqualStrings("web:v1", msg.fixedToSlice(&dep.previous_image));
}

test "update deployment not found" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const result = sm.apply(.{ .update_deployment = .{ .deployment_id = 999 } });
    try std.testing.expectEqual(msg.ErrorCode.not_found, result.err);
}

test "pause and resume deployment" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "svc"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "svc:v1"),
        .replicas = 1,
    } });
    const dep_id = dep_result.ok.entity_id;

    _ = sm.apply(.{ .pause_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(sm.findDeployment(dep_id).?.paused);

    _ = sm.apply(.{ .resume_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(!sm.findDeployment(dep_id).?.paused);
}

test "rollback deployment swaps image back" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "app"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "app:v1"),
        .replicas = 1,
    } });
    const dep_id = dep_result.ok.entity_id;

    // Rollback with no previous version fails
    const fail = sm.apply(.{ .rollback_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expectEqual(msg.ErrorCode.invalid_transition, fail.err);

    // Update to v2
    _ = sm.apply(.{ .update_deployment = .{
        .deployment_id = dep_id,
        .image = msg.strToFixed(256, "app:v2"),
    } });

    // Rollback to v1
    const rb = sm.apply(.{ .rollback_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(rb == .ok);

    const dep = sm.findDeployment(dep_id).?;
    try std.testing.expectEqualStrings("app:v1", msg.fixedToSlice(&dep.image));
    try std.testing.expectEqual(@as(u32, 3), dep.version);
}

test "delete deployment marks inactive and drains pods" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "doomed"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "doomed:v1"),
        .replicas = 2,
    } });
    const dep_id = dep_result.ok.entity_id;
    try std.testing.expectEqual(@as(usize, 2), sm.pod_count);

    const del = sm.apply(.{ .delete_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(del == .ok);
    try std.testing.expect(!sm.findDeployment(dep_id).?.active);

    // All pods should be inactive/terminating
    try std.testing.expectEqual(@as(u32, 0), sm.getActivePodCount(dep_id));
}

test "delete deployment releases bound gpu capacity when marking pods inactive" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const node_result = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "gpu-node"),
        .cpu_millicores = 8000,
        .memory_megabytes = 16384,
        .gpu_type = .t4,
        .gpu_count = 1,
        .provider = std.mem.zeroes([32]u8),
        .region = std.mem.zeroes([32]u8),
    } });
    const node_id = node_result.ok.entity_id;

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "gpu-doomed"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "gpu-doomed:v1"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
        .gpu_type = .t4,
        .gpu_count = 1,
    } });
    const dep_id = dep_result.ok.entity_id;
    const pod_id = sm.pods[0].id;

    const bind = sm.apply(.{ .bind_pod_to_node = .{
        .pod_id = pod_id,
        .node_id = node_id,
    } });
    try std.testing.expect(bind == .ok);
    try std.testing.expectEqual(@as(u8, 0), sm.getNodeCapacity(node_id).?.available_gpu);

    const del = sm.apply(.{ .delete_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(del == .ok);
    try std.testing.expectEqual(@as(u8, 1), sm.getNodeCapacity(node_id).?.available_gpu);

    _ = sm.apply(.{ .update_pod_status = .{ .pod_id = pod_id, .new_phase = .succeeded } });
    const cap = sm.getNodeCapacity(node_id).?;
    try std.testing.expectEqual(@as(u8, 1), cap.available_gpu);
    try std.testing.expectEqual(@as(u32, 8000), cap.available_cpu);
    try std.testing.expectEqual(@as(u32, 16384), cap.available_mem);
}

test "set traffic split updates rules" {
    const allocator = std.testing.allocator;
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(42);

    const dep_result = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "canary"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "canary:v1"),
        .replicas = 1,
    } });
    const dep_id = dep_result.ok.entity_id;

    var rules: [4]msg.TrafficRule = [_]msg.TrafficRule{.{}} ** 4;
    rules[0] = .{ .version = 1, .weight = 90 };
    rules[1] = .{ .version = 2, .weight = 10 };

    const result = sm.apply(.{ .set_traffic_split = .{
        .deployment_id = dep_id,
        .rules = rules,
        .rule_count = 2,
    } });
    try std.testing.expect(result == .ok);

    const dep = sm.findDeployment(dep_id).?;
    try std.testing.expectEqual(@as(u8, 2), dep.traffic_rule_count);
    try std.testing.expectEqual(@as(u8, 90), dep.traffic_rules[0].weight);
    try std.testing.expectEqual(@as(u8, 10), dep.traffic_rules[1].weight);
}

test "batch bind schedules all pods and deducts aggregate CPU memory" {
    var sm = StateMachine.init(77);
    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "batch-node"),
        .cpu_millicores = 1000,
        .memory_megabytes = 2048,
    } }).ok.entity_id;
    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "batch"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 3,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } }).ok.entity_id;

    var pod_buf: [3]u64 = undefined;
    const pending = sm.getPendingPods(dep_id, &pod_buf);
    try std.testing.expectEqual(@as(usize, 3), pending);

    var cmd = msg.BindPodsToNodesCmd{ .count = 3 };
    for (pod_buf[0..3], 0..) |pod_id, i| cmd.bindings[i] = .{ .pod_id = pod_id, .node_id = node_id };

    const result = sm.apply(.{ .bind_pods_to_nodes = cmd });
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(u64, 3), result.ok.entity_id);
    try std.testing.expectEqual(@as(u32, 700), sm.getNodeCapacity(node_id).?.available_cpu);
    try std.testing.expectEqual(@as(u32, 1664), sm.getNodeCapacity(node_id).?.available_mem);
    for (pod_buf[0..3]) |pod_id| {
        const pod = sm.findPod(pod_id).?;
        try std.testing.expectEqual(node_id, pod.node_id);
        try std.testing.expectEqual(msg.PodPhase.scheduled, pod.phase);
    }
}

test "batch bind rejects duplicate pod without mutation" {
    var sm = StateMachine.init(78);
    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "batch-node"),
        .cpu_millicores = 1000,
        .memory_megabytes = 2048,
    } }).ok.entity_id;
    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "batch"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 2,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } }).ok.entity_id;

    var pod_buf: [2]u64 = undefined;
    _ = sm.getPendingPods(dep_id, &pod_buf);
    var cmd = msg.BindPodsToNodesCmd{ .count = 2 };
    cmd.bindings[0] = .{ .pod_id = pod_buf[0], .node_id = node_id };
    cmd.bindings[1] = .{ .pod_id = pod_buf[0], .node_id = node_id };

    const result = sm.apply(.{ .bind_pods_to_nodes = cmd });
    try std.testing.expectEqual(msg.ErrorCode.already_exists, result.err);
    try std.testing.expectEqual(@as(u32, 1000), sm.getNodeCapacity(node_id).?.available_cpu);
    try std.testing.expectEqual(msg.PodPhase.pending, sm.findPod(pod_buf[0]).?.phase);
}

test "batch bind rejects aggregate capacity overflow without mutation" {
    var sm = StateMachine.init(79);
    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "tiny"),
        .cpu_millicores = 150,
        .memory_megabytes = 512,
    } }).ok.entity_id;
    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "batch"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 2,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } }).ok.entity_id;

    var pod_buf: [2]u64 = undefined;
    _ = sm.getPendingPods(dep_id, &pod_buf);
    var cmd = msg.BindPodsToNodesCmd{ .count = 2 };
    for (pod_buf[0..2], 0..) |pod_id, i| cmd.bindings[i] = .{ .pod_id = pod_id, .node_id = node_id };

    const result = sm.apply(.{ .bind_pods_to_nodes = cmd });
    try std.testing.expectEqual(msg.ErrorCode.capacity_exceeded, result.err);
    try std.testing.expectEqual(@as(u32, 150), sm.getNodeCapacity(node_id).?.available_cpu);
    try std.testing.expectEqual(msg.PodPhase.pending, sm.findPod(pod_buf[0]).?.phase);
    try std.testing.expectEqual(msg.PodPhase.pending, sm.findPod(pod_buf[1]).?.phase);
}

test "deleted deployments and pods free fixed state-machine slots" {
    var sm = StateMachine.init(20260503);

    var ids: [MAX_DEPLOYMENTS]u64 = undefined;
    for (0..MAX_DEPLOYMENTS) |i| {
        const result = sm.apply(.{ .create_deployment = .{
            .name = msg.strToFixed(64, "slot-reuse"),
            .image = msg.strToFixed(256, "nginx"),
            .replicas = 1,
            .cpu_millicores = 10,
            .memory_megabytes = 16,
        } });
        try std.testing.expect(result == .ok);
        ids[i] = result.ok.entity_id;
    }

    try std.testing.expectEqual(msg.ErrorCode.capacity_exceeded, sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "full"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 1,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } }).err);

    for (ids) |id| {
        const deleted = sm.apply(.{ .delete_deployment = .{ .deployment_id = id } });
        try std.testing.expect(deleted == .ok);
    }

    for (0..MAX_DEPLOYMENTS) |_| {
        const result = sm.apply(.{ .create_deployment = .{
            .name = msg.strToFixed(64, "slot-reuse-2"),
            .image = msg.strToFixed(256, "nginx"),
            .replicas = 1,
            .cpu_millicores = 10,
            .memory_megabytes = 16,
        } });
        try std.testing.expect(result == .ok);
    }

    try std.testing.expectEqual(@as(usize, MAX_DEPLOYMENTS), sm.deployment_count);
    try std.testing.expectEqual(@as(usize, MAX_DEPLOYMENTS), sm.pod_count);
}

test "node reconnect recomputes capacity from active pods only" {
    var sm = StateMachine.init(202605031);
    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "reconnect-node"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } }).ok.entity_id;

    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "reconnect-cap"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 2,
        .cpu_millicores = 100,
        .memory_megabytes = 64,
    } }).ok.entity_id;

    var pod_buf: [8]u64 = undefined;
    const pending = sm.getPendingPods(dep_id, &pod_buf);
    try std.testing.expectEqual(@as(usize, 2), pending);
    for (pod_buf[0..pending]) |pod_id| {
        const bind = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });
        try std.testing.expect(bind == .ok);
    }
    try std.testing.expectEqual(@as(u32, 800), sm.getNodeCapacity(node_id).?.available_cpu);

    const deleted = sm.apply(.{ .delete_deployment = .{ .deployment_id = dep_id } });
    try std.testing.expect(deleted == .ok);
    try std.testing.expectEqual(@as(u32, 1000), sm.getNodeCapacity(node_id).?.available_cpu);

    const reconnect = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "reconnect-node"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } });
    try std.testing.expect(reconnect == .ok);
    try std.testing.expectEqual(node_id, reconnect.ok.entity_id);
    try std.testing.expectEqual(@as(u32, 1000), sm.getNodeCapacity(node_id).?.available_cpu);
}
