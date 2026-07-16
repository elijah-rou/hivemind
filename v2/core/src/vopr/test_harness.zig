const std = @import("std");
const Io = std.Io;
const msg = @import("../message.zig");
const net_mod = @import("simulated_net.zig");
const replica_mod = @import("../replica.zig");
const StateMachine = @import("../state_machine.zig").StateMachine;
const SimulatedIo = @import("simulated_io.zig").SimulatedIo;
const Prng = @import("../prng.zig").Prng;
const StateChecker = @import("checker.zig").StateChecker;
const SimulatedDisk = @import("../disk.zig").SimulatedDisk;
const gossip_mod = @import("../gossip.zig");

/// Lightweight test harness for a VRR cluster with integrated state checking.
/// Every tick validates consensus safety invariants via the StateChecker.
pub const TestCluster = struct {
    allocator: std.mem.Allocator,
    prng: Prng,
    current_tick: i64,
    network: *net_mod.SimulatedNetwork,
    sim_ios: [msg.REPLICA_COUNT_MAX]SimulatedIo,
    state_machines: [msg.REPLICA_COUNT_MAX]*StateMachine,
    replicas: [msg.REPLICA_COUNT_MAX]*replica_mod.Replica,
    disks: [msg.REPLICA_COUNT_MAX]SimulatedDisk,
    replica_running: [msg.REPLICA_COUNT_MAX]bool,
    checker: StateChecker,
    replica_count: u8,

    // Simulated agents
    sim_agents: [MAX_SIM_AGENTS]SimWorker,
    sim_worker_count: usize,

    pub fn init(allocator: std.mem.Allocator, replica_count: u8, seed: u64) !*TestCluster {
        const tc = try allocator.create(TestCluster);
        tc.allocator = allocator;
        tc.prng = Prng.init(seed);
        tc.current_tick = 0;
        tc.replica_count = replica_count;
        tc.replica_running = [_]bool{false} ** msg.REPLICA_COUNT_MAX;
        tc.checker = StateChecker.init(replica_count);
        tc.sim_agents = undefined;
        tc.sim_worker_count = 0;

        tc.network = try allocator.create(net_mod.SimulatedNetwork);
        tc.network.initInPlace(seed, replica_count, &tc.current_tick);

        for (0..replica_count) |i| {
            const id: u8 = @intCast(i);
            tc.sim_ios[i] = SimulatedIo.init(&tc.prng, &tc.current_tick, tc.network, id);
            tc.state_machines[i] = try allocator.create(StateMachine);
            tc.state_machines[i].initInPlace(seed +% i);
            tc.disks[i] = SimulatedDisk.init();
            tc.replicas[i] = try allocator.create(replica_mod.Replica);
            tc.replicas[i].initInPlace(.{
                .replica_id = id,
                .replica_count = replica_count,
                .io = tc.sim_ios[i].io(),
                .state_machine = tc.state_machines[i],
                .disk = tc.disks[i].diskInterface(),
            });
            tc.replica_running[i] = true;
        }
        return tc;
    }

    pub fn deinit(self: *TestCluster) void {
        for (0..self.replica_count) |i| {
            self.allocator.destroy(self.replicas[i]);
            self.allocator.destroy(self.state_machines[i]);
        }
        self.allocator.destroy(self.network);
        self.allocator.destroy(self);
    }

    /// Advance time by one tick, deliver messages, tick replicas, check state.
    pub fn tick(self: *TestCluster) void {
        self.current_tick += 1;
        self.deliverAll();
        for (0..self.replica_count) |i| {
            if (!self.replica_running[i]) continue;
            self.replicas[i].tick();
        }
        // Run state checker after every tick
        for (0..self.replica_count) |i| {
            if (!self.replica_running[i]) continue;
            self.checker.check(@intCast(i), self.replicas[i]);
        }
    }

    /// Advance time by n ticks.
    pub fn advance(self: *TestCluster, n: u64) void {
        for (0..n) |_| self.tick();
    }

    /// Deliver all ready messages to all replicas via the Io vtable.
    pub fn deliverAll(self: *TestCluster) void {
        var buf: [net_mod.MESSAGE_SIZE_MAX + 1]u8 = undefined;
        var delivered: usize = 0;
        while (delivered < 256) {
            var any = false;
            for (0..self.replica_count) |i| {
                if (!self.replica_running[i]) continue;
                const io = self.sim_ios[i].io();
                var bufs = [_][]u8{&buf};
                const n = io.vtable.netRead(io.userdata, @intCast(i), &bufs) catch continue;
                if (n <= 1) continue;
                const from = buf[0];
                const message = msg.deserialize(buf[1..n]) catch continue;
                self.replicas[i].onMessage(from, message);
                any = true;
                delivered += 1;
            }
            if (!any) break;
        }
    }

    /// Directly deliver a message to a specific replica (bypasses network).
    pub fn deliver(self: *TestCluster, to: u8, from: u8, message: msg.Message) void {
        self.replicas[to].onMessage(from, message);
    }

    /// Submit a client request to a replica.
    /// Respects network partitions: if the target is fully partitioned
    /// (cannot reach any other replica), the request is dropped.
    pub fn request(self: *TestCluster, to: u8, command: msg.Command) void {
        if (to >= self.replica_count or !self.replica_running[to]) return;
        var reachable = self.replica_count <= 1;
        if (!reachable) {
            for (0..self.replica_count) |i| {
                if (i == to or !self.replica_running[i]) continue;
                if (!self.network.partitioned[to][@intCast(i)]) {
                    reachable = true;
                    break;
                }
            }
        }
        if (!reachable) return;

        self.replicas[to].onMessage(to, .{ .request = .{
            .client_id = self.prng.next(),
            .request_id = self.prng.next(),
            .command = command,
        } });
    }

    pub fn partition(self: *TestCluster, replica_id: u8) void {
        self.network.partition(replica_id);
    }

    pub fn heal(self: *TestCluster) void {
        self.network.healAll();
    }

    /// Simulate process stop: replica no longer ticks or receives messages.
    /// Disk survives; queued inbound messages are dropped like closed TCP sockets.
    pub fn stopReplica(self: *TestCluster, id: u8) void {
        if (id >= self.replica_count) return;
        self.replica_running[id] = false;
        for (0..self.replica_count) |i| {
            self.network.partitioned[id][@intCast(i)] = true;
            self.network.partitioned[@intCast(i)][id] = true;
        }
        self.network.queues[id].count = 0;
    }

    /// Simulate process restart after a stop: memory is rebuilt from disk and
    /// the replica rejoins through view change.
    pub fn startReplica(self: *TestCluster, id: u8) void {
        if (id >= self.replica_count) return;
        self.replica_running[id] = true;
        self.crashReplica(id);
        for (0..self.replica_count) |i| {
            if (!self.replica_running[i]) continue;
            self.network.partitioned[id][@intCast(i)] = false;
            self.network.partitioned[@intCast(i)][id] = false;
        }
    }

    /// Simulate a crash: wipe in-memory state, reset state machine,
    /// then recover from disk. The disk survives the crash.
    pub fn crashReplica(self: *TestCluster, id: u8) void {
        const i: usize = id;

        self.state_machines[i].initInPlace(self.state_machines[i].seed);

        self.replicas[i].initInPlace(.{
            .replica_id = id,
            .replica_count = self.replica_count,
            .io = self.sim_ios[i].io(),
            .state_machine = self.state_machines[i],
            .disk = self.disks[i].diskInterface(),
        });

        _ = self.replicas[i].recoverFromDisk();

        // After crash, multi-node replicas must enter view_change to rejoin
        // safely, even if disk recovery failed and initInPlace left status=normal.
        // Keep leader activity at the current tick; recovered replicas use the
        // shorter recovery timeout inside Replica.tick().
        if (self.replica_count > 1) {
            self.replicas[i].status = .view_change;
            self.replicas[i].last_leader_activity = self.current_tick;
        }

        self.replica_running[i] = true;
        self.network.queues[i].count = 0;
    }

    /// Assert zero safety violations were detected.
    pub fn assertSafe(self: *const TestCluster) void {
        const s = self.checker.summary();
        if (s.safety_violations > 0) {
            std.debug.panic("StateChecker detected {d} safety violation(s)", .{s.safety_violations});
        }
    }

    /// Check if all replicas have converged. Returns null if converged.
    pub fn checkConvergence(self: *const TestCluster) ?[]const u8 {
        var ptrs: [msg.REPLICA_COUNT_MAX]*const replica_mod.Replica = undefined;
        for (0..self.replica_count) |i| {
            ptrs[i] = self.replicas[i];
        }
        return self.checker.checkConvergence(&ptrs, self.replica_count);
    }

    // -----------------------------------------------------------------------
    // Simulated agents
    // -----------------------------------------------------------------------

    pub const MAX_SIM_AGENTS: usize = 16;
    pub const AGENT_HEARTBEAT_INTERVAL: i64 = 50;
    pub const AGENT_START_DELAY_TICKS: i64 = 5;

    pub const SimPod = struct {
        pod_id: u64 = 0,
        phase: msg.PodPhase = .pending,
        started_at_tick: i64 = 0,
        active: bool = false,
    };

    pub const SimWorker = struct {
        prng: Prng,
        node_name: [64]u8 = std.mem.zeroes([64]u8),
        registered: bool = false,
        node_id: u64 = 0,
        last_heartbeat_tick: i64 = 0,
        pods: [32]SimPod = [_]SimPod{.{}} ** 32,
        pod_count: usize = 0,
        gpu_count: u8 = 8,
        target_replica: u8 = 0,
    };

    pub fn addSimWorker(self: *TestCluster, name: []const u8, gpu_count: u8) void {
        if (self.sim_worker_count >= MAX_SIM_AGENTS) return;
        const idx = self.sim_worker_count;
        self.sim_agents[idx] = .{
            .prng = Prng.init(self.prng.next()),
            .node_name = msg.strToFixed(64, name),
            .gpu_count = gpu_count,
            .target_replica = @intCast(idx % self.replica_count),
        };
        self.sim_worker_count += 1;
    }

    pub fn tickWorkers(self: *TestCluster) void {
        for (0..self.sim_worker_count) |i| {
            self.tickOneWorker(i);
        }
    }

    /// Simulate an agent TCP drop: control plane stops treating the slot as connected,
    /// and the next `tickWorkers` pass will submit a fresh registration (new VRR request id).
    pub fn disconnectSimWorker(self: *TestCluster, worker_idx: usize) void {
        if (worker_idx >= self.sim_worker_count) return;
        const target: usize = self.sim_agents[worker_idx].target_replica;
        self.replicas[target].onWorkerDisconnect(worker_idx);
        self.sim_agents[worker_idx].registered = false;
        self.sim_agents[worker_idx].node_id = 0;
    }

    fn tickOneWorker(self: *TestCluster, worker_idx: usize) void {
        var agent = &self.sim_agents[worker_idx];
        const target: usize = agent.target_replica;
        if (!self.replica_running[target]) return;

        // Register on first tick
        if (!agent.registered) {
            self.replicas[target].onWorkerRegister(worker_idx, .{
                .hostname = agent.node_name,
                .cpu_millicores = 32000,
                .memory_megabytes = 65536,
                .gpu_type = .h100_sxm,
                .gpu_count = agent.gpu_count,
            });
            agent.registered = true;
            agent.last_heartbeat_tick = self.current_tick;
            return;
        }

        // Advance pods: scheduled -> running after delay
        for (&agent.pods) |*pod| {
            if (!pod.active) continue;
            if (pod.phase == .scheduled and
                self.current_tick - pod.started_at_tick >= AGENT_START_DELAY_TICKS)
            {
                pod.phase = .running;
                self.replicas[target].onWorkerPodStatus(worker_idx, .{
                    .pod_id = pod.pod_id,
                    .old_phase = .scheduled,
                    .new_phase = .running,
                });
            }
        }

        // Heartbeat
        if (self.current_tick - agent.last_heartbeat_tick >= AGENT_HEARTBEAT_INTERVAL) {
            var running: u16 = 0;
            for (agent.pods[0..agent.pod_count]) |pod| {
                if (pod.active and pod.phase == .running) running += 1;
            }
            self.replicas[target].onWorkerHeartbeat(worker_idx, .{
                .timestamp = @intCast(self.current_tick),
                .pods_running = running,
            });
            agent.last_heartbeat_tick = self.current_tick;
        }

        const nid = self.replicas[target].getWorkerNodeId(worker_idx);
        if (nid != 0) {
            agent.node_id = nid;
        }
    }

    /// Called by the VOPR after a BindPodToNode commits.
    /// Assigns the pod to the matching simulated agent.
    pub fn notifyAgentPodBound(self: *TestCluster, pod_id: u64, node_id: u64) void {
        for (0..self.sim_worker_count) |i| {
            const agent = &self.sim_agents[i];
            if (!agent.registered) continue;

            if (agent.node_id == node_id and agent.node_id != 0) {
                if (agent.pod_count < 32) {
                    self.sim_agents[i].pods[agent.pod_count] = .{
                        .pod_id = pod_id,
                        .phase = .scheduled,
                        .started_at_tick = self.current_tick,
                        .active = true,
                    };
                    self.sim_agents[i].pod_count += 1;
                }
                return;
            }
        }
    }

    // Accessors
    pub fn status(self: *const TestCluster, i: u8) msg.Status {
        return self.replicas[i].status;
    }
    pub fn view(self: *const TestCluster, i: u8) msg.ViewNumber {
        return self.replicas[i].view_number;
    }
    pub fn commit(self: *const TestCluster, i: u8) msg.OpNumber {
        return self.replicas[i].commit_min;
    }
    pub fn op(self: *const TestCluster, i: u8) msg.OpNumber {
        return self.replicas[i].op_number;
    }
    pub fn isLeader(self: *const TestCluster, i: u8) bool {
        return self.replicas[i].isLeader();
    }
    pub fn nodes(self: *const TestCluster, i: u8) usize {
        return self.state_machines[i].node_count;
    }
    pub fn pods(self: *const TestCluster, i: u8) usize {
        return self.state_machines[i].pod_count;
    }
};

pub const FederatedOriginConfig = struct {
    seed: u64,
    replica_count: u8 = 3,
    origin_id: []const u8,
    provider: []const u8,
    region: []const u8,
    locality: []const u8,
    continent: []const u8,
    node_name: []const u8,
    cpu_millicores: u32,
    gpu_type: msg.GpuType = .none,
    gpu_count: u8 = 0,
    deployment_name: ?[]const u8 = null,
    deployment_replicas: u32 = 0,
    deployment_cpu_millicores: u32 = 0,
    deployment_gpu_type: msg.GpuType = .none,
    deployment_gpu_count: u8 = 0,
};

pub const FederatedGossipHarness = struct {
    pub const MAX_ORIGINS: usize = 8;

    pub const RoutingResidencyMode = enum {
        strict,
        prefer,
        global,
    };

    pub const RoutingReason = enum {
        same_locality_best,
        same_locality_failover,
        cross_locality_fallback,
        residency_restricted,
        no_locality_candidates,
    };

    pub const RoutingPolicy = struct {
        preferred_origin_id: ?[]const u8 = null,
        preferred_locality: []const u8,
        allowed_localities: []const []const u8,
        residency_mode: RoutingResidencyMode,
        fallback_order: []const []const u8,
        required_cpu_millicores: u32 = 0,
        required_gpu_type: msg.GpuType = .none,
        required_gpu_count: u8 = 0,
    };

    pub const RoutingDecision = struct {
        found: bool,
        reason: RoutingReason,
        origin_id: [32]u8 = std.mem.zeroes([32]u8),
        locality: [32]u8 = std.mem.zeroes([32]u8),
    };

    pub const Origin = struct {
        cluster: *TestCluster,
        gossip: gossip_mod.GossipState,
    };

    allocator: std.mem.Allocator,
    origins: [MAX_ORIGINS]Origin = undefined,
    origin_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FederatedGossipHarness {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FederatedGossipHarness) void {
        for (self.origins[0..self.origin_count]) |*origin| {
            origin.cluster.deinit();
        }
    }

    pub fn addOrigin(self: *FederatedGossipHarness, config: FederatedOriginConfig) !usize {
        if (self.origin_count >= MAX_ORIGINS) return error.NoSpaceLeft;

        const cluster = try TestCluster.init(self.allocator, config.replica_count, config.seed);
        errdefer cluster.deinit();

        cluster.request(0, .{ .register_node = .{
            .node_name = msg.strToFixed(64, config.node_name),
            .cpu_millicores = config.cpu_millicores,
            .gpu_type = config.gpu_type,
            .gpu_count = config.gpu_count,
            .provider = msg.strToFixed(32, config.provider),
            .region = msg.strToFixed(32, config.region),
        } });

        if (config.deployment_name) |deployment_name| {
            cluster.request(0, .{ .create_deployment = .{
                .name = msg.strToFixed(64, deployment_name),
                .namespace = msg.strToFixed(64, "default"),
                .image = msg.strToFixed(256, "simulated:v1"),
                .replicas = config.deployment_replicas,
                .cpu_millicores = config.deployment_cpu_millicores,
                .gpu_type = config.deployment_gpu_type,
                .gpu_count = config.deployment_gpu_count,
            } });
        }

        cluster.advance(160);

        const idx = self.origin_count;
        self.origins[idx] = .{
            .cluster = cluster,
            .gossip = .{
                .fd = -1,
                .identity = .{
                    .origin_id = msg.strToFixed(32, config.origin_id),
                    .provider = msg.strToFixed(32, config.provider),
                    .region = msg.strToFixed(32, config.region),
                    .locality = msg.strToFixed(32, config.locality),
                    .continent = msg.strToFixed(32, config.continent),
                },
                .peers = [_]gossip_mod.GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
                .peer_count = 0,
                .cache = [_]gossip_mod.PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
                .last_broadcast_ms = 0,
                .replica = pickLeaderReplica(cluster),
                .encryption = null,
            },
        };
        self.origin_count += 1;
        return idx;
    }

    pub fn advanceAll(self: *FederatedGossipHarness, ticks: u64) void {
        for (0..ticks) |_| {
            for (self.origins[0..self.origin_count]) |*origin| {
                origin.cluster.tick();
            }
        }
    }

    pub fn refreshLeaders(self: *FederatedGossipHarness) void {
        for (self.origins[0..self.origin_count]) |*origin| {
            origin.gossip.replica = pickLeaderReplica(origin.cluster);
        }
    }

    pub fn broadcastAll(self: *FederatedGossipHarness, now_ms: i64) void {
        self.refreshLeaders();
        for (0..self.origin_count) |sender_idx| {
            var snapshot: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
            self.origins[sender_idx].gossip.buildSnapshotPublic(&snapshot, now_ms);
            for (0..self.origin_count) |receiver_idx| {
                if (receiver_idx == sender_idx) continue;
                self.origins[receiver_idx].gossip.handleMessagePublic(&snapshot, now_ms);
            }
        }
    }

    pub fn broadcastSubsetToReceiver(self: *FederatedGossipHarness, sender_indices: []const usize, receiver_idx: usize, now_ms: i64) void {
        std.debug.assert(receiver_idx < self.origin_count);
        self.refreshLeaders();
        for (sender_indices) |sender_idx| {
            std.debug.assert(sender_idx < self.origin_count);
            if (sender_idx == receiver_idx) continue;
            var snapshot: [gossip_mod.MESSAGE_SIZE]u8 = std.mem.zeroes([gossip_mod.MESSAGE_SIZE]u8);
            self.origins[sender_idx].gossip.buildSnapshotPublic(&snapshot, now_ms);
            self.origins[receiver_idx].gossip.handleMessagePublic(&snapshot, now_ms);
        }
    }

    pub fn countFreshOriginsByLocality(self: *const FederatedGossipHarness, receiver_idx: usize, locality: []const u8, now_ms: i64) usize {
        std.debug.assert(receiver_idx < self.origin_count);
        const gossip = &self.origins[receiver_idx].gossip;
        var count: usize = 0;
        for (&gossip.cache) |*peer| {
            if (peer.last_seen_ms == 0) continue;
            const peer_locality = msg.fixedToSlice(&peer.locality);
            if (!std.mem.eql(u8, peer_locality, locality)) continue;
            const peer_origin_id = msg.fixedToSlice(&peer.origin_id);
            if (!gossip.isOriginFresh(peer_origin_id, now_ms)) continue;
            count += 1;
        }
        return count;
    }

    pub fn findPeer(self: *const FederatedGossipHarness, receiver_idx: usize, origin_id: []const u8) ?*const gossip_mod.PeerCapacity {
        std.debug.assert(receiver_idx < self.origin_count);
        const gossip = &self.origins[receiver_idx].gossip;
        for (&gossip.cache) |*peer| {
            if (peer.last_seen_ms == 0) continue;
            const peer_origin_id = msg.fixedToSlice(&peer.origin_id);
            if (std.mem.eql(u8, peer_origin_id, origin_id)) return peer;
        }
        return null;
    }

    pub fn selectOrigin(self: *const FederatedGossipHarness, receiver_idx: usize, policy: RoutingPolicy, now_ms: i64) RoutingDecision {
        std.debug.assert(receiver_idx < self.origin_count);
        std.debug.assert(policy.allowed_localities.len > 0);
        std.debug.assert(policy.fallback_order.len > 0);

        const gossip = &self.origins[receiver_idx].gossip;
        var saw_restricted_candidate = false;

        for (&gossip.cache) |*peer| {
            if (!isFreshPeer(gossip, peer, now_ms)) continue;
            if (!hardwareSatisfied(peer, policy)) continue;
            const locality = msg.fixedToSlice(&peer.locality);
            if (!localityAllowed(policy.allowed_localities, locality)) {
                saw_restricted_candidate = true;
            }
        }

        for (policy.fallback_order) |fallback_locality| {
            if (!localityAllowed(policy.allowed_localities, fallback_locality)) continue;

            var best: ?*const gossip_mod.PeerCapacity = null;
            for (&gossip.cache) |*peer| {
                if (!isFreshPeer(gossip, peer, now_ms)) continue;
                if (!hardwareSatisfied(peer, policy)) continue;
                const locality = msg.fixedToSlice(&peer.locality);
                if (!std.mem.eql(u8, locality, fallback_locality)) continue;

                if (best == null or betterCandidate(peer, best.?, policy)) {
                    best = peer;
                }
            }

            if (best) |selected| {
                const selected_origin_id = msg.fixedToSlice(&selected.origin_id);
                const selected_locality = msg.fixedToSlice(&selected.locality);
                if (std.mem.eql(u8, selected_locality, policy.preferred_locality)) {
                    if (policy.preferred_origin_id) |preferred_origin_id| {
                        if (!std.mem.eql(u8, selected_origin_id, preferred_origin_id) and
                            !preferredOriginEligible(gossip, preferred_origin_id, policy, now_ms))
                        {
                            return .{
                                .found = true,
                                .reason = .same_locality_failover,
                                .origin_id = selected.origin_id,
                                .locality = selected.locality,
                            };
                        }
                    }
                    return .{
                        .found = true,
                        .reason = .same_locality_best,
                        .origin_id = selected.origin_id,
                        .locality = selected.locality,
                    };
                }

                return .{
                    .found = true,
                    .reason = .cross_locality_fallback,
                    .origin_id = selected.origin_id,
                    .locality = selected.locality,
                };
            }
        }

        return .{
            .found = false,
            .reason = if (policy.residency_mode == .strict and saw_restricted_candidate)
                .residency_restricted
            else
                .no_locality_candidates,
        };
    }

    fn preferredOriginEligible(gossip: *const gossip_mod.GossipState, preferred_origin_id: []const u8, policy: RoutingPolicy, now_ms: i64) bool {
        for (&gossip.cache) |*peer| {
            if (!isFreshPeer(gossip, peer, now_ms)) continue;
            const origin_id = msg.fixedToSlice(&peer.origin_id);
            if (!std.mem.eql(u8, origin_id, preferred_origin_id)) continue;
            const locality = msg.fixedToSlice(&peer.locality);
            if (!localityAllowed(policy.allowed_localities, locality)) return false;
            return hardwareSatisfied(peer, policy);
        }
        return false;
    }

    fn betterCandidate(candidate: *const gossip_mod.PeerCapacity, incumbent: *const gossip_mod.PeerCapacity, policy: RoutingPolicy) bool {
        if (candidate.queue_depth != incumbent.queue_depth) {
            return candidate.queue_depth < incumbent.queue_depth;
        }

        const candidate_capacity = candidateCapacityScore(candidate, policy);
        const incumbent_capacity = candidateCapacityScore(incumbent, policy);
        if (candidate_capacity != incumbent_capacity) {
            return candidate_capacity > incumbent_capacity;
        }

        return std.mem.order(u8, msg.fixedToSlice(&candidate.origin_id), msg.fixedToSlice(&incumbent.origin_id)) == .lt;
    }

    fn candidateCapacityScore(peer: *const gossip_mod.PeerCapacity, policy: RoutingPolicy) u64 {
        if (policy.required_gpu_count > 0) {
            return peer.gpu_available[@intFromEnum(policy.required_gpu_type)];
        }
        return peer.cpu_available_millicores;
    }

    fn hardwareSatisfied(peer: *const gossip_mod.PeerCapacity, policy: RoutingPolicy) bool {
        if (policy.required_cpu_millicores > 0 and peer.cpu_available_millicores < policy.required_cpu_millicores) {
            return false;
        }
        if (policy.required_gpu_count > 0 and peer.gpu_available[@intFromEnum(policy.required_gpu_type)] < policy.required_gpu_count) {
            return false;
        }
        return true;
    }

    fn localityAllowed(allowed_localities: []const []const u8, locality: []const u8) bool {
        for (allowed_localities) |allowed| {
            if (std.mem.eql(u8, allowed, locality)) return true;
        }
        return false;
    }

    fn isFreshPeer(gossip: *const gossip_mod.GossipState, peer: *const gossip_mod.PeerCapacity, now_ms: i64) bool {
        if (peer.last_seen_ms == 0) return false;
        return gossip.isOriginFresh(msg.fixedToSlice(&peer.origin_id), now_ms);
    }

    fn pickLeaderReplica(cluster: *TestCluster) *replica_mod.Replica {
        for (0..cluster.replica_count) |i| {
            if (cluster.isLeader(@intCast(i))) return cluster.replicas[i];
        }
        return cluster.replicas[0];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "recoverFromDisk: discards orphan journal entries above recovered op_number" {
    // Scenario: pre-crash, journal entries for ops 1..5 were written to disk
    // but the metadata flush only committed up to op=3. After crash, recovery
    // must discard the orphan entries 4..5 so they cannot be resurrected as
    // phantom committed ops during subsequent view changes.
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xBEEF);
    defer tc.deinit();

    tc.disks[0].writeMetadata(.{
        .view_number = 0,
        .last_normal_view = 0,
        .op_number = 3,
        .commit_min = 3,
        .commit_max = 3,
    });

    var parent: u64 = 0;
    var op: msg.OpNumber = 1;
    while (op <= 5) : (op += 1) {
        var entry = msg.LogEntry{
            .parent_checksum = parent,
            .view_number = 0,
            .op_number = op,
            .command = .{ .noop = {} },
            .client_id = 0,
            .request_id = 0,
        };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
        const slot = replica_mod.journalSlot(op);
        tc.disks[0].writeSlot(slot, &entry);
    }

    tc.crashReplica(0);

    try std.testing.expectEqual(@as(msg.OpNumber, 3), tc.replicas[0].op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 3), tc.replicas[0].commit_min);

    var kept: msg.OpNumber = 1;
    while (kept <= 3) : (kept += 1) {
        const slot = replica_mod.journalSlot(kept);
        try std.testing.expect(tc.replicas[0].journal_occupied[slot]);
        try std.testing.expectEqual(kept, tc.replicas[0].journal[slot].op_number);
    }

    var discarded: msg.OpNumber = 4;
    while (discarded <= 5) : (discarded += 1) {
        const slot = replica_mod.journalSlot(discarded);
        try std.testing.expect(!tc.replicas[0].journal_occupied[slot]);
    }
}

test "pipeline: healthy cluster sustains scale-matrix churn beyond old window" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xFACE);
    defer tc.deinit();

    tc.advance(50);
    const leader_id: u8 = 0;
    try std.testing.expect(tc.replicas[leader_id].isLeader());

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        tc.request(leader_id, .{ .noop = {} });
        tc.advance(5);
    }

    tc.advance(200);

    try std.testing.expect(tc.replicas[0].commit_min > 256);
    try std.testing.expect(tc.replicas[1].commit_min > 256);
    try std.testing.expect(tc.replicas[2].commit_min > 256);
    try std.testing.expectEqual(@as(u64, 0), tc.replicas[0].pipeline_guard_drops);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
}

test "scale matrix churn allows subsequent multi-deployment placement" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x5CA1E);
    defer tc.deinit();

    const leader_id: u8 = 0;
    tc.request(leader_id, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 32000,
        .memory_megabytes = 65536,
    } });
    tc.advance(80);

    tc.request(leader_id, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "single"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "docker.io/library/nginx:1.27-alpine"),
        .replicas = 0,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } });
    tc.advance(40);
    const single_id = tc.state_machines[leader_id].deployments[0].id;

    tc.request(leader_id, .{ .scale_deployment = .{
        .deployment_id = single_id,
        .desired_replicas = 50,
    } });
    tc.advance(1200);

    var old_running: usize = 0;
    for (tc.state_machines[leader_id].pods[0..tc.state_machines[leader_id].pod_count]) |pod| {
        if (!pod.active or pod.deployment_id != single_id or pod.phase != .scheduled) continue;
        tc.request(leader_id, .{ .update_pod_status = .{
            .pod_id = pod.id,
            .new_phase = .running,
        } });
        old_running += 1;
    }
    try std.testing.expect(old_running >= 45);
    tc.advance(700);

    tc.request(leader_id, .{ .scale_deployment = .{
        .deployment_id = single_id,
        .desired_replicas = 1,
    } });
    tc.advance(100);

    tc.request(leader_id, .{ .delete_deployment = .{ .deployment_id = single_id } });
    tc.advance(100);

    var created: usize = 0;
    while (created < 50) : (created += 1) {
        var name: [64]u8 = std.mem.zeroes([64]u8);
        _ = std.fmt.bufPrint(&name, "multi-{d}", .{created}) catch unreachable;
        tc.request(leader_id, .{ .create_deployment = .{
            .name = name,
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "docker.io/library/nginx:1.27-alpine"),
            .replicas = 1,
            .cpu_millicores = 10,
            .memory_megabytes = 16,
        } });
    }
    tc.advance(1400);

    var placed_new: usize = 0;
    for (tc.state_machines[leader_id].pods[0..tc.state_machines[leader_id].pod_count]) |pod| {
        if (!pod.active) continue;
        if (pod.deployment_id == single_id) continue;
        if (pod.phase == .scheduled or pod.phase == .running) placed_new += 1;
    }

    try std.testing.expectEqual(@as(usize, 50), placed_new);
    try std.testing.expectEqual(@as(u64, 0), tc.replicas[leader_id].pipeline_guard_drops);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);
}

test "cluster recovers leader after full crash restart" {
    const tc = try TestCluster.init(std.testing.allocator, 5, 0xC1EA);
    defer tc.deinit();

    tc.advance(300);

    var leader_before: ?u8 = null;
    for (0..tc.replica_count) |i| {
        const id: u8 = @intCast(i);
        if (tc.replicas[i].status == .normal and tc.isLeader(id)) {
            leader_before = id;
            break;
        }
    }
    try std.testing.expect(leader_before != null);

    tc.request(leader_before.?, .{ .noop = {} });
    tc.advance(200);

    for (0..tc.replica_count) |i| {
        tc.crashReplica(@intCast(i));
    }

    tc.advance(1200);

    var leader_after: ?u8 = null;
    for (0..tc.replica_count) |i| {
        const id: u8 = @intCast(i);
        if (tc.replicas[i].status == .normal and tc.isLeader(id)) {
            leader_after = id;
            break;
        }
    }

    try std.testing.expect(leader_after != null);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);

    tc.request(leader_after.?, .{ .noop = {} });
    tc.advance(200);

    for (0..tc.replica_count) |i| {
        try std.testing.expect(tc.replicas[i].commit_min >= 2);
    }
}

test "cluster elects leader after partitioned startup heals" {
    const tc = try TestCluster.init(std.testing.allocator, 5, 0x51A7);
    defer tc.deinit();

    for (0..tc.replica_count) |i| {
        tc.partition(@intCast(i));
    }

    tc.advance(900);
    tc.heal();
    tc.advance(1200);

    var leader_after: ?u8 = null;
    for (0..tc.replica_count) |i| {
        const id: u8 = @intCast(i);
        if (tc.replicas[i].status == .normal and tc.isLeader(id)) {
            leader_after = id;
            break;
        }
    }

    try std.testing.expect(leader_after != null);
    try std.testing.expectEqual(@as(u64, 0), tc.checker.summary().safety_violations);

    tc.request(leader_after.?, .{ .noop = {} });
    tc.advance(200);

    for (0..tc.replica_count) |i| {
        try std.testing.expect(tc.replicas[i].commit_min >= 1);
    }
}
