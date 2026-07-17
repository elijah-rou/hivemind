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
const view_candidate = @import("../view_change_candidate.zig");

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
                .allocator = allocator,
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
            self.replicas[i].deinit();
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

    /// Restart replicas that fail-stopped on storage (systemd Restart=always).
    pub fn restartStorageFailed(self: *TestCluster) void {
        for (0..self.replica_count) |i| {
            if (self.replicas[i].storage_failed) {
                self.crashReplica(@intCast(i));
            }
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

    /// Submit a client request with explicit identity (for dedup/replay tests).
    pub fn requestWithIdentity(
        self: *TestCluster,
        to: u8,
        client_id: u128,
        request_id: msg.RequestId,
        command: msg.Command,
    ) void {
        if (to >= self.replica_count or !self.replica_running[to]) return;
        self.replicas[to].onMessage(to, .{ .request = .{
            .client_id = client_id,
            .request_id = request_id,
            .command = command,
        } });
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

    /// Simulate a crash: wipe in-memory state, discard unsynced disk writes,
    /// then recover from durable disk state.
    pub fn crashReplica(self: *TestCluster, id: u8) void {
        const i: usize = id;

        self.disks[i].crash();
        self.state_machines[i].initInPlace(self.state_machines[i].seed);

        self.replicas[i].resetInPlace(.{
            .allocator = self.allocator,
            .replica_id = id,
            .replica_count = self.replica_count,
            .io = self.sim_ios[i].io(),
            .state_machine = self.state_machines[i],
            .disk = self.disks[i].diskInterface(),
        });

        const recovered = self.replicas[i].recoverFromDisk() catch {
            // Corrupt local durable prefix: production exits nonzero. Keep this
            // simulated replica offline. Liveness clears transient faults and
            // retries recovery without wiping; an operator wipe is a separate
            // explicit outcome, not the default healed-network path.
            self.replicas[i].storage_failed = true;
            self.replica_running[i] = false;
            self.network.queues[i].count = 0;
            return;
        };

        // Validate recovered committed prefix against canonical history before
        // advancing the checker watermark (no direct reset).
        if (recovered) {
            self.checker.observeRecovery(id, self.replicas[i]);
        }

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

    try tc.disks[0].writeMetadata(.{
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
        try tc.disks[0].writeSlot(slot, &entry);
    }
    try tc.disks[0].sync();

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

const ReplyCapture = struct {
    count: usize = 0,
    last_err: ?msg.ErrorCode = null,
    last_client_id: u128 = 0,
    last_request_id: msg.RequestId = 0,
    last_ok: bool = false,

    fn reply(ctx: *anyopaque, client_id: u128, request_id: msg.RequestId, result: msg.Result) void {
        const self: *ReplyCapture = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_client_id = client_id;
        self.last_request_id = request_id;
        switch (result) {
            .ok => {
                self.last_ok = true;
                self.last_err = null;
            },
            .err => |e| {
                self.last_ok = false;
                self.last_err = e;
            },
        }
    }
};

test "durable storage: follower slot-write failure emits no PrepareOk" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD001);
    defer tc.deinit();
    tc.advance(50);

    const leader: u8 = 0;
    try std.testing.expect(tc.replicas[leader].isLeader());

    // Fail the next journal write on follower 1 before preparing.
    tc.disks[1].fail_next_write = true;
    const syncs_before = tc.disks[1].syncs;
    tc.request(leader, .{ .noop = {} });
    tc.advance(30);

    try std.testing.expect(tc.replicas[1].storage_failed);
    try std.testing.expectEqual(syncs_before, tc.disks[1].syncs);
    // Follower must not have contributed a durable PrepareOk vote for op 1.
    const slot = replica_mod.journalSlot(1);
    const from_bit = @as(u16, 1) << 1;
    try std.testing.expect((tc.replicas[leader].prepare_ok_from[slot] & from_bit) == 0);
}

test "durable storage: sync failure cannot form acknowledged quorum" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD002);
    defer tc.deinit();
    tc.advance(50);

    // Leader sync fails after staging the prepare.
    tc.disks[0].fail_next_sync = true;
    tc.request(0, .{ .noop = {} });
    tc.advance(5);

    try std.testing.expect(tc.replicas[0].storage_failed);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), tc.replicas[0].commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), tc.replicas[1].commit_min);
}

test "durable storage: metadata-only sync failure emits no client reply" {
    // First barrier durably prepares; the second (commit-metadata) sync fails.
    // No client reply may escape after the metadata barrier fails.
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xD003);
    defer tc.deinit();

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    // Allow exactly one successful sync (prepare barrier), fail the next (commit meta).
    tc.disks[0].fail_at_sync_count = 1;
    tc.request(0, .{ .noop = {} });
    tc.tick();

    try std.testing.expect(tc.replicas[0].storage_failed);
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(tc.replicas[0].op_number >= 1);
    // Durable commit metadata must not have advanced.
    if (tc.disks[0].readMetadata()) |meta| {
        try std.testing.expectEqual(@as(msg.OpNumber, 0), meta.commit_min);
    }
}

test "durable storage: crash acknowledging quorum recovers committed command" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD004);
    defer tc.deinit();
    tc.advance(50);

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    const client_id: u128 = 0xC1;
    const request_id: msg.RequestId = 9;
    tc.requestWithIdentity(0, client_id, request_id, .{ .noop = {} });
    tc.advance(40);
    try std.testing.expect(capture.count >= 1);
    try std.testing.expect(capture.last_ok);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].commit_min);

    // Crash the acknowledging quorum immediately after the client reply.
    tc.crashReplica(0);
    tc.crashReplica(1);
    tc.crashReplica(2);
    tc.advance(200);

    var recovered: msg.OpNumber = 0;
    for (0..tc.replica_count) |i| {
        if (tc.replica_running[i]) recovered = @max(recovered, tc.replicas[i].commit_min);
    }
    try std.testing.expect(recovered >= 1);
}

test "durable storage: corrupt committed slot fails recovery" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xD005);
    defer tc.deinit();
    tc.request(0, .{ .noop = {} });
    tc.advance(20);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].commit_min);

    // Remove the durable committed slot while leaving metadata commit_min=1.
    const slot = replica_mod.journalSlot(1);
    try tc.disks[0].clearSlot(slot);
    try tc.disks[0].sync();

    tc.state_machines[0].initInPlace(tc.state_machines[0].seed);
    tc.replicas[0].resetInPlace(.{
        .allocator = tc.allocator,
        .replica_id = 0,
        .replica_count = 1,
        .io = tc.sim_ios[0].io(),
        .state_machine = tc.state_machines[0],
        .disk = tc.disks[0].diskInterface(),
    });
    try std.testing.expectError(error.CorruptJournal, tc.replicas[0].recoverFromDisk());
}

test "group commit: burst stages then one sync publishes acknowledgements" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0x6C01);
    defer tc.deinit();

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    const syncs_before = tc.disks[0].syncs;
    const burst: usize = 8;
    var i: usize = 0;
    while (i < burst) : (i += 1) {
        tc.request(0, .{ .noop = {} });
    }
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(syncs_before, tc.disks[0].syncs);

    tc.tick();
    // Prepare barrier + commit barrier => at most 2 syncs for the batch, not N.
    const syncs_after = tc.disks[0].syncs;
    try std.testing.expect(syncs_after > syncs_before);
    try std.testing.expect(syncs_after - syncs_before <= 2);
    try std.testing.expectEqual(burst, capture.count);
    try std.testing.expectEqual(@as(msg.OpNumber, burst), tc.replicas[0].commit_min);
}

test "group commit: write failure publishes nothing" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0x6C02);
    defer tc.deinit();
    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    tc.disks[0].fail_next_write = true;
    tc.request(0, .{ .noop = {} });
    tc.tick();
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(tc.replicas[0].storage_failed);
}

test "no-snapshot retention keeps ops 1 through 14 and floor zero across crash" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0x14F100);
    defer tc.deinit();

    for (0..14) |_| {
        tc.request(0, .{ .noop = {} });
        tc.tick();
    }
    tc.advance(10);
    try std.testing.expectEqual(@as(msg.OpNumber, 14), tc.replicas[0].commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), tc.replicas[0].retention_floor);
    var op: msg.OpNumber = 1;
    while (op <= 14) : (op += 1) {
        try std.testing.expect(tc.replicas[0].journalHas(op));
        try std.testing.expect(tc.disks[0].readSlot(replica_mod.journalSlot(op)) != null);
    }

    tc.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, 14), tc.replicas[0].op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), tc.replicas[0].retention_floor);
    op = 1;
    while (op <= 14) : (op += 1) try std.testing.expect(tc.replicas[0].journalHas(op));
}

test "three replicas durably commit lifetime boundary and recover at tip 1024" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x1024B0AD);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;

    var op: msg.OpNumber = 1;
    while (op <= replica_mod.LOG_SIZE_MAX) : (op += 1) {
        tc.request(0, .{ .noop = {} });
        tc.tick();
    }
    tc.advance(20);

    for (0..3) |replica_index| {
        const replica = tc.replicas[replica_index];
        try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), replica.op_number);
        try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), replica.commit_min);
        op = 1;
        while (op <= replica_mod.LOG_SIZE_MAX) : (op += 1) {
            try std.testing.expect(replica.journalHas(op));
            try std.testing.expect(replica.isDurablePrepare(op));
        }
    }

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;
    const tip_checksum = tc.replicas[0].journalGet(replica_mod.LOG_SIZE_MAX).?.checksum;
    tc.requestWithIdentity(0, 0x1025, 1, .{ .noop = {} });
    tc.tick();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.last_err == .log_full);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].op_number);
    try std.testing.expectEqual(tip_checksum, tc.replicas[0].journalGet(replica_mod.LOG_SIZE_MAX).?.checksum);

    tc.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].commit_min);
    try std.testing.expect(tc.replicas[0].isDurablePrepare(replica_mod.LOG_SIZE_MAX));
    tc.advance(500);
    for (0..3) |replica_index| {
        try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[replica_index].op_number);
        try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[replica_index].commit_min);
        try std.testing.expectEqual(tip_checksum, tc.replicas[replica_index].journalGet(replica_mod.LOG_SIZE_MAX).?.checksum);
    }
}

test "journal retention: log_full before overwrite and restart reconstructs state" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0x7E01);
    defer tc.deinit();

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    const deploy_client: u128 = 0xD00D;
    const deploy_req: msg.RequestId = 1;
    tc.requestWithIdentity(0, deploy_client, deploy_req, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "keep"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "img:1"),
        .replicas = 0,
    } });
    tc.advance(10);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].commit_min);
    const dep_id = tc.state_machines[0].deployments[0].id;

    // Fill remaining retained-log capacity with noops.
    var op: msg.OpNumber = 2;
    while (op <= replica_mod.LOG_SIZE_MAX) : (op += 1) {
        tc.request(0, .{ .noop = {} });
        if (op % 64 == 0) tc.advance(4) else tc.tick();
    }
    tc.advance(20);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].commit_min);

    capture.count = 0;
    capture.last_err = null;
    tc.requestWithIdentity(0, 0xF00D, 99, .{ .noop = {} });
    tc.advance(5);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.last_err == .log_full);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].op_number);
    // Slot 1 still holds deployment op 1.
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].journal[replica_mod.journalSlot(1)].op_number);

    const prng_before = tc.state_machines[0].prng;
    tc.crashReplica(0);
    tc.advance(5);
    try std.testing.expectEqual(@as(msg.OpNumber, replica_mod.LOG_SIZE_MAX), tc.replicas[0].commit_min);
    try std.testing.expect(tc.state_machines[0].findDeployment(dep_id) != null);
    try std.testing.expectEqual(prng_before.state, tc.state_machines[0].prng.state);

    // Replay pre-crash create_deployment identity must not create a second deployment.
    const dep_count_before = tc.state_machines[0].deployment_count;
    capture.count = 0;
    tc.requestWithIdentity(0, deploy_client, deploy_req, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "keep"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "img:1"),
        .replicas = 0,
    } });
    tc.advance(5);
    try std.testing.expectEqual(dep_count_before, tc.state_machines[0].deployment_count);
}

test "durable storage: duplicate reply waits for commit barrier" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xD0D0);
    defer tc.deinit();

    var capture = ReplyCapture{};
    tc.replicas[0].client_reply_ctx = &capture;
    tc.replicas[0].client_reply_fn = ReplyCapture.reply;

    const client_id: u128 = 0xBEEF;
    const request_id: msg.RequestId = 7;
    const slot = replica_mod.journalSlot(1);

    // Synthesize the unpublished-commit window: client table already updated
    // (pre-fix behavior) while pending_reply still awaits the barrier.
    tc.replicas[0].client_table[0] = .{
        .client_id = client_id,
        .request_id = request_id,
        .result = .{ .ok = .{ .entity_id = 0 } },
        .active = true,
    };
    tc.replicas[0].client_count = 1;
    tc.replicas[0].pending_reply[slot] = true;
    tc.replicas[0].pending_reply_client_id[slot] = client_id;
    tc.replicas[0].pending_reply_request_id[slot] = request_id;
    tc.replicas[0].pending_reply_result[slot] = .{ .ok = .{ .entity_id = 0 } };
    tc.replicas[0].journal_occupied[slot] = true;
    tc.replicas[0].journal[slot] = .{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = client_id,
        .request_id = request_id,
        .parent_checksum = 0,
        .checksum = 0,
    };
    tc.replicas[0].journal[slot].checksum = tc.replicas[0].journal[slot].computeChecksum();
    tc.replicas[0].commit_min = 1;
    tc.replicas[0].commit_max = 1;
    tc.replicas[0].op_number = 1;
    tc.replicas[0].metadata_dirty = true;

    capture.count = 0;
    tc.requestWithIdentity(0, client_id, request_id, .{ .noop = {} });
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    // Barrier publishes the pending reply; a later duplicate may replay.
    tc.tick();
    try std.testing.expect(capture.count >= 1);
    try std.testing.expect(capture.last_ok);

    capture.count = 0;
    tc.requestWithIdentity(0, client_id, request_id, .{ .noop = {} });
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.last_ok);
}

test "durable storage: StartView PrepareOk waits for barrier" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x57A1);
    defer tc.deinit();
    tc.advance(50);
    try std.testing.expect(tc.replicas[0].isLeader());

    var entry = msg.LogEntry{
        .view_number = tc.replicas[0].view_number,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry.checksum = entry.computeChecksum();

    var sv = msg.StartViewMsg{
        .view_number = tc.replicas[0].view_number,
        .selected_last_normal_view = tc.replicas[0].last_normal_view,
        .op_number = 1,
        .tip_checksum = entry.checksum,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = entry;

    // Install via StartView without ticking (no durability barrier yet).
    tc.replicas[1].status = .view_change;
    tc.deliver(1, 0, .{ .start_view = sv });
    const slot = replica_mod.journalSlot(1);
    try std.testing.expect(tc.replicas[1].journalHas(1));
    try std.testing.expect(tc.replicas[1].pending_start_view.active);
    try std.testing.expect(tc.replicas[1].status == .view_change);
    try std.testing.expect(!tc.replicas[1].pending_prepare_ok[slot]);
    try std.testing.expect(tc.replicas[1].journal_dirty[slot]);

    // PrepareOk must not reach the leader until the follower flushes.
    const from_bit = @as(u16, 1) << 1;
    try std.testing.expect((tc.replicas[0].prepare_ok_from[slot] & from_bit) == 0);

    tc.tick();
    tc.deliverAll();
    try std.testing.expect(!tc.replicas[1].pending_prepare_ok[slot]);
    try std.testing.expect(!tc.replicas[1].journal_dirty[slot]);
}

test "follower StartView durable watermark relation table installs only after barrier" {
    const Case = struct { name: []const u8, follower_commit: u64, leader_commit: u64, tip: u64, accepted: bool };
    const cases = [_]Case{
        .{ .name = "Cf below Cl below S", .follower_commit = 0, .leader_commit = 1, .tip = 2, .accepted = true },
        .{ .name = "Cf equals Cl", .follower_commit = 1, .leader_commit = 1, .tip = 2, .accepted = true },
        .{ .name = "Cl below Cf below S", .follower_commit = 2, .leader_commit = 1, .tip = 3, .accepted = true },
        .{ .name = "Cf equals S", .follower_commit = 2, .leader_commit = 1, .tip = 2, .accepted = true },
        .{ .name = "Cf above S", .follower_commit = 3, .leader_commit = 1, .tip = 2, .accepted = false },
    };

    for (cases, 0..) |case, case_index| {
        _ = case.name;
        const tc = try TestCluster.init(std.testing.allocator, 3, 0x5A70 + case_index);
        defer tc.deinit();
        const follower = tc.replicas[1];
        follower.status = .view_change;
        follower.view_number = 3;
        follower.last_normal_view = 2;

        var entries: [3]msg.LogEntry = undefined;
        var parent: u64 = 0;
        for (&entries, 0..) |*entry, index| {
            entry.* = .{
                .view_number = 2,
                .op_number = index + 1,
                .command = .{ .noop = {} },
                .client_id = 0x5000 + index,
                .request_id = 0x6000 + index,
                .parent_checksum = parent,
            };
            entry.checksum = entry.computeChecksum();
            parent = entry.checksum;
        }

        var op: u64 = 1;
        while (op <= case.follower_commit) : (op += 1) {
            follower.journalPut(entries[op - 1]);
            const slot = replica_mod.journalSlot(op);
            follower.journal_dirty[slot] = false;
            follower.durable_prepare_op[slot] = op;
            follower.durable_prepare_checksum[slot] = entries[op - 1].checksum;
        }
        follower.op_number = case.follower_commit;
        follower.commit_min = case.follower_commit;
        follower.commit_max = case.follower_commit;
        follower.durable_prepare_through = case.follower_commit;

        var sv = msg.StartViewMsg{
            .view_number = 3,
            .selected_last_normal_view = 2,
            .op_number = case.tip,
            .tip_checksum = entries[case.tip - 1].checksum,
            .commit_min = case.leader_commit,
            .retention_floor = 0,
        };
        op = case.follower_commit + 1;
        while (op <= case.tip) : (op += 1) {
            sv.log_entries[sv.log_entry_count] = entries[op - 1];
            sv.log_entry_count += 1;
        }

        follower.onMessage(0, .{ .start_view = sv });
        if (!case.accepted) {
            try std.testing.expect(!follower.pending_start_view.active);
            try std.testing.expectEqual(case.follower_commit, follower.commit_min);
            continue;
        }
        try std.testing.expect(follower.pending_start_view.active);
        try std.testing.expectEqual(view_candidate.PendingStartViewRole.follower, follower.pending_start_view.role);
        try std.testing.expectEqual(msg.Status.view_change, follower.status);
        try std.testing.expectEqual(case.follower_commit, follower.commit_min);
        follower.tick();
        try std.testing.expectEqual(msg.Status.normal, follower.status);
        try std.testing.expectEqual(case.tip, follower.op_number);
        try std.testing.expectEqual(@max(case.follower_commit, case.leader_commit), follower.commit_min);
        try std.testing.expectEqual(entries[case.tip - 1].checksum, follower.journalGet(case.tip).?.checksum);
    }
}

test "follower StartView slot metadata and sync failures preserve volatile coherence" {
    inline for (.{ "slot", "metadata", "sync" }, 0..) |fault_kind, case_index| {
        const tc = try TestCluster.init(std.testing.allocator, 3, 0x5AF0 + case_index);
        defer tc.deinit();
        const follower = tc.replicas[1];
        follower.status = .view_change;
        follower.view_number = 3;

        var entry = msg.LogEntry{ .view_number = 2, .op_number = 1, .client_id = 4, .request_id = 1 };
        entry.checksum = entry.computeChecksum();
        var sv = msg.StartViewMsg{
            .view_number = 3,
            .selected_last_normal_view = 2,
            .op_number = 1,
            .tip_checksum = entry.checksum,
            .commit_min = 0,
            .log_entry_count = 1,
        };
        sv.log_entries[0] = entry;
        follower.onMessage(0, .{ .start_view = sv });
        try std.testing.expect(follower.pending_start_view.active);
        try std.testing.expectEqual(@as(msg.OpNumber, 1), follower.op_number);
        try std.testing.expectEqual(follower.op_number, follower.pending_start_view.op_number);

        if (std.mem.eql(u8, fault_kind, "slot")) {
            tc.disks[1].fail_next_write = true;
        } else if (std.mem.eql(u8, fault_kind, "metadata")) {
            for (0..replica_mod.LOG_SIZE_MAX) |slot| follower.journal_dirty[slot] = false;
            tc.disks[1].fail_next_write = true;
        } else {
            tc.disks[1].fail_next_sync = true;
        }

        const prepare_ok_tag = @intFromEnum(msg.Tag.prepare_ok);
        const before = tc.network.stats.sent[prepare_ok_tag];
        follower.tick();
        try std.testing.expect(follower.storage_failed);
        try std.testing.expectEqual(msg.Status.view_change, follower.status);
        try std.testing.expect(follower.pending_start_view.active);
        try std.testing.expectEqual(@as(msg.OpNumber, 1), follower.op_number);
        try std.testing.expectEqual(entry.checksum, follower.journalGet(1).?.checksum);
        try std.testing.expectEqual(before, tc.network.stats.sent[prepare_ok_tag]);
    }
}

test "recovered concurrent laggards keep candidate past generic timeout" {
    const tc = try TestCluster.init(std.testing.allocator, 5, 0xCA7D1DA7E);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;

    var first = msg.LogEntry{ .view_number = 4, .op_number = 1, .client_id = 1, .request_id = 1 };
    first.checksum = first.computeChecksum();
    var second = msg.LogEntry{ .view_number = 4, .op_number = 2, .client_id = 1, .request_id = 2, .parent_checksum = first.checksum };
    second.checksum = second.computeChecksum();
    const sv = msg.StartViewMsg{
        .view_number = 5,
        .selected_last_normal_view = 4,
        .op_number = 2,
        .tip_checksum = second.checksum,
        .commit_min = 0,
    };

    for ([_]usize{ 1, 2 }) |replica_index| {
        const follower = tc.replicas[replica_index];
        follower.status = .view_change;
        follower.view_number = 5;
        follower.recovered_from_disk = true;
        follower.onMessage(0, .{ .start_view = sv });
        try std.testing.expect(follower.pending_view_selection);
        try std.testing.expect(!follower.pending_start_view.active);
    }

    tc.current_tick = 60;
    for ([_]usize{ 1, 2 }) |replica_index| {
        const follower = tc.replicas[replica_index];
        follower.tick();
        try std.testing.expectEqual(@as(msg.ViewNumber, 5), follower.view_number);
        try std.testing.expect(follower.pending_view_selection);
        try std.testing.expect(!follower.pending_start_view.active);
    }
}

test "follower fetches omitted StartView tail only from certificate-bound appended leader" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x5A71);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;

    var entries: [3]msg.LogEntry = undefined;
    var parent: u64 = 0;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{
            .view_number = 2,
            .op_number = index + 1,
            .command = .{ .noop = {} },
            .client_id = 0x7100 + index,
            .request_id = 0x7200 + index,
            .parent_checksum = parent,
        };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
    }

    const leader = tc.replicas[0];
    leader.status = .normal;
    leader.view_number = 3;
    leader.last_normal_view = 3;
    leader.selected_target_view = 3;
    leader.selected_source = 0;
    leader.selected_last_normal_view = 2;
    leader.selected_tip_op = 2;
    leader.selected_tip_checksum = entries[1].checksum;
    leader.selected_commit_bound = 1;
    for (entries) |entry| leader.journalPut(entry);
    leader.op_number = 3;

    const follower = tc.replicas[1];
    follower.status = .view_change;
    follower.view_number = 3;
    const sv = msg.StartViewMsg{
        .view_number = 3,
        .selected_last_normal_view = 2,
        .op_number = 2,
        .tip_checksum = entries[1].checksum,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 0,
    };
    follower.onMessage(0, .{ .start_view = sv });
    try std.testing.expect(follower.pending_view_selection);
    try std.testing.expect(!follower.pending_start_view.active);

    // Wrong source and wrong certificate cannot seed the candidate.
    follower.onMessage(2, .{ .send_prepare = .{
        .view_number = 3,
        .entry = entries[0],
        .selected_source = 0,
        .selected_last_normal_view = 2,
        .selected_tip_op = 2,
        .selected_tip_checksum = entries[1].checksum,
        .selected_commit_bound = 1,
    } });
    follower.onMessage(0, .{ .send_prepare = .{
        .view_number = 3,
        .entry = entries[0],
        .selected_source = 0,
        .selected_last_normal_view = 2,
        .selected_tip_op = 2,
        .selected_tip_checksum = entries[1].checksum,
        .selected_commit_bound = 0,
    } });
    follower.onMessage(0, .{ .prepare = .{
        .view_number = 3,
        .op_number = 1,
        .commit_min = 1,
        .retention_floor = 0,
        .entry = entries[0],
    } });
    try std.testing.expectEqual(@as(usize, 0), follower.view_change_candidate.present_count);
    try std.testing.expectEqual(msg.Status.view_change, follower.status);
    try std.testing.expect(!follower.journalHas(1));

    // The leader has appended op 3, but serves only the frozen selected prefix.
    tc.deliverAll();
    try std.testing.expect(follower.pending_start_view.active);
    try std.testing.expectEqual(@as(msg.OpNumber, 3), leader.op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), follower.pending_start_view.op_number);
    follower.tick();
    try std.testing.expectEqual(msg.Status.normal, follower.status);
    try std.testing.expectEqual(entries[1].checksum, follower.journalGet(2).?.checksum);
    try std.testing.expect(!follower.journalHas(3));
}

test "follower StartView crash before barrier keeps old state and after barrier recovers candidate" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x5A72);
    defer tc.deinit();
    var entry = msg.LogEntry{
        .view_number = 2,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 0x7300,
        .request_id = 0x7400,
        .parent_checksum = 0,
    };
    entry.checksum = entry.computeChecksum();
    var sv = msg.StartViewMsg{
        .view_number = 3,
        .selected_last_normal_view = 2,
        .op_number = 1,
        .tip_checksum = entry.checksum,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = entry;

    const follower = tc.replicas[1];
    follower.status = .view_change;
    follower.view_number = 3;
    follower.onMessage(0, .{ .start_view = sv });
    try std.testing.expect(follower.pending_start_view.active);
    tc.crashReplica(1);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), tc.replicas[1].op_number);
    try std.testing.expect(!tc.replicas[1].journalHas(1));

    tc.replicas[1].status = .view_change;
    tc.replicas[1].view_number = 3;
    tc.replicas[1].onMessage(0, .{ .start_view = sv });
    tc.replicas[1].tick();
    try std.testing.expectEqual(msg.Status.normal, tc.replicas[1].status);
    tc.crashReplica(1);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[1].op_number);
    try std.testing.expectEqual(entry.checksum, tc.replicas[1].journalGet(1).?.checksum);
}

test "durable storage: replaced op cannot re-ack on stale durable watermark" {
    // Follower durably holds uncommitted op 1 (checksum A). StartView replaces
    // that op with checksum B. A duplicate Prepare must not PrepareOk before the
    // replacement syncs — a monotonic op watermark is not enough.
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD10A);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;
    tc.advance(50);
    try std.testing.expect(tc.replicas[0].isLeader());

    var original = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    original.checksum = original.computeChecksum();

    // Install a durable-but-uncommitted prepare on follower 1.
    tc.replicas[1].journalPut(original);
    tc.replicas[1].op_number = 1;
    tc.replicas[1].commit_min = 0;
    tc.replicas[1].commit_max = 0;
    tc.tick(); // durability barrier for the staged journal write
    try std.testing.expect(!tc.replicas[1].journal_dirty[replica_mod.journalSlot(1)]);
    try std.testing.expect(tc.replicas[1].durable_prepare_through >= 1);
    try std.testing.expect(tc.disks[1].readSlot(replica_mod.journalSlot(1)) != null);

    var replacement = msg.LogEntry{
        .view_number = 3, // view % 3 == 0 keeps replica 0 as leader
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 99,
        .request_id = 99,
        .parent_checksum = 0,
    };
    replacement.checksum = replacement.computeChecksum();
    try std.testing.expect(replacement.checksum != original.checksum);

    var sv = msg.StartViewMsg{
        .view_number = 3,
        .selected_last_normal_view = 0,
        .op_number = 1,
        .tip_checksum = replacement.checksum,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = replacement;

    // Leader must be able to accept a PrepareOk for op 1 if one is wrongly sent.
    tc.replicas[0].view_number = 3;
    tc.replicas[0].last_normal_view = 3;
    tc.replicas[0].op_number = 1;
    tc.replicas[0].commit_min = 0;
    tc.replicas[0].commit_max = 0;
    tc.replicas[0].journalPut(replacement);
    tc.replicas[0].journal_dirty[replica_mod.journalSlot(1)] = false;
    const slot = replica_mod.journalSlot(1);
    tc.replicas[0].prepare_ok_from[slot] = 0;
    tc.replicas[0].prepare_ok_counts[slot] = 0;

    tc.deliver(1, 0, .{ .start_view = sv });
    try std.testing.expectEqual(replacement.checksum, tc.replicas[1].journalGet(1).?.checksum);
    try std.testing.expect(tc.replicas[1].journal_dirty[slot]);
    try std.testing.expect(tc.replicas[1].durable_prepare_through >= 1);

    // Fail sync for the replacement, then inject a duplicate Prepare.
    tc.disks[1].fail_next_sync = true;
    tc.deliver(1, 0, .{ .prepare = .{
        .view_number = 3,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .entry = replacement,
    } });
    tc.tick(); // deliverAll then flush (sync fails)

    try std.testing.expect(tc.replicas[1].storage_failed);
    const from_bit = @as(u16, 1) << 1;
    try std.testing.expect((tc.replicas[0].prepare_ok_from[slot] & from_bit) == 0);
    try std.testing.expectEqual(@as(u8, 0), tc.replicas[0].prepare_ok_counts[slot]);
}

test "recovery rejects metadata commit_max above op_number" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xA17A);
    defer tc.deinit();

    try tc.disks[0].writeMetadata(.{
        .view_number = 1,
        .last_normal_view = 1,
        .op_number = 2,
        .commit_min = 2,
        .commit_max = 5,
    });
    try tc.disks[0].sync();

    tc.state_machines[0].initInPlace(tc.state_machines[0].seed);
    tc.replicas[0].resetInPlace(.{
        .allocator = tc.allocator,
        .replica_id = 0,
        .replica_count = 1,
        .io = tc.sim_ios[0].io(),
        .state_machine = tc.state_machines[0],
        .disk = tc.disks[0].diskInterface(),
    });
    try std.testing.expectError(error.CorruptMetadata, tc.replicas[0].recoverFromDisk());
}

test "StartView rejects conflicting committed prefix" {
    // A StartView that conflicts with a locally committed op must not replace it.
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x57C0);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;
    tc.advance(50);
    try std.testing.expect(tc.replicas[0].isLeader());

    var committed = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    committed.checksum = committed.computeChecksum();

    // Install a locally committed prefix on follower 1.
    tc.replicas[1].journalPut(committed);
    tc.replicas[1].journal_dirty[replica_mod.journalSlot(1)] = false;
    tc.replicas[1].op_number = 1;
    tc.replicas[1].commit_min = 1;
    tc.replicas[1].commit_max = 1;
    tc.replicas[1].status = .view_change;
    tc.replicas[1].view_number = 0;

    var conflicting = committed;
    conflicting.client_id = 42;
    conflicting.request_id = 42;
    conflicting.view_number = 3;
    conflicting.checksum = conflicting.computeChecksum();
    try std.testing.expect(conflicting.checksum != committed.checksum);

    var sv = msg.StartViewMsg{
        .view_number = 3,
        .selected_last_normal_view = 0,
        .op_number = 1,
        .tip_checksum = conflicting.checksum,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = conflicting;

    tc.deliver(1, 0, .{ .start_view = sv });

    try std.testing.expectEqual(committed.checksum, tc.replicas[1].journalGet(1).?.checksum);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[1].commit_min);
    try std.testing.expect(tc.replicas[1].status == .view_change);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), tc.replicas[1].view_number);
}

test "view change rejects conflicting committed DVC values" {
    // Two DVCs reporting different committed identities for the same op must
    // not let the new leader install either value and leave view_change.
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD7C1);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;
    tc.advance(50);
    try std.testing.expect(tc.replicas[0].isLeader());

    var entry_a = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry_a.checksum = entry_a.computeChecksum();

    var entry_b = entry_a;
    entry_b.client_id = 99;
    entry_b.request_id = 99;
    entry_b.checksum = entry_b.computeChecksum();
    try std.testing.expect(entry_a.checksum != entry_b.checksum);

    // Local committed prefix on the prospective new leader (view 3 → replica 0).
    tc.replicas[0].journalPut(entry_a);
    tc.replicas[0].journal_dirty[replica_mod.journalSlot(1)] = false;
    tc.replicas[0].op_number = 1;
    tc.replicas[0].commit_min = 1;
    tc.replicas[0].commit_max = 1;
    tc.replicas[0].view_number = 3;
    tc.replicas[0].last_normal_view = 0;
    tc.replicas[0].status = .view_change;
    tc.replicas[0].do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
    tc.replicas[0].do_vc_total = 0;

    var dvc0 = msg.DoViewChangeMsg{
        .view_number = 3,
        .replica_id = 0,
        .last_normal_view = 0,
        .op_number = 1,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    dvc0.log_entries[0] = entry_a;

    var dvc1 = msg.DoViewChangeMsg{
        .view_number = 3,
        .replica_id = 1,
        .last_normal_view = 2,
        .op_number = 1,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    dvc1.log_entries[0] = entry_b;

    var dvc2 = msg.DoViewChangeMsg{
        .view_number = 3,
        .replica_id = 2,
        .last_normal_view = 0,
        .op_number = 1,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    dvc2.log_entries[0] = entry_a;

    // Quorum of DVCs with a committed-identity conflict between 0 and 1.
    tc.replicas[0].do_vc_msgs[0] = dvc0;
    tc.replicas[0].do_vc_received[0] = true;
    tc.replicas[0].do_vc_msgs[1] = dvc1;
    tc.replicas[0].do_vc_received[1] = true;
    tc.replicas[0].do_vc_msgs[2] = dvc2;
    tc.replicas[0].do_vc_received[2] = true;
    tc.replicas[0].do_vc_total = 3;

    // Trigger selection via a duplicate DVC delivery (already counted).
    tc.deliver(0, 1, .{ .do_view_change = dvc1 });

    try std.testing.expect(tc.replicas[0].status == .view_change);
    try std.testing.expectEqual(entry_a.checksum, tc.replicas[0].journalGet(1).?.checksum);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].commit_min);
}

test "view change rejects equal-rank conflicting tips" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xE0A1);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var a = msg.LogEntry{ .view_number = 2, .op_number = 1, .client_id = 1, .request_id = 1 };
    a.checksum = a.computeChecksum();
    var b = a;
    b.client_id = 2;
    b.checksum = b.computeChecksum();
    var d0 = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 2, .op_number = 1, .log_entry_count = 1 };
    d0.log_entries[0] = a;
    var d1 = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 1, .log_entry_count = 1 };
    d1.log_entries[0] = b;

    tc.deliver(0, 0, .{ .do_view_change = d0 });
    tc.deliver(0, 1, .{ .do_view_change = d1 });
    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expect(!leader.pending_view_selection);
}

fn stageTwoEntryLeaderStartView(tc: *TestCluster) [2]msg.LogEntry {
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var entries: [2]msg.LogEntry = undefined;
    entries[0] = .{ .view_number = 2, .op_number = 1, .client_id = 1, .request_id = 1 };
    entries[0].checksum = entries[0].computeChecksum();
    entries[1] = .{ .view_number = 2, .op_number = 2, .client_id = 1, .request_id = 2, .parent_checksum = entries[0].checksum };
    entries[1].checksum = entries[1].computeChecksum();

    var selected = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 2, .log_entry_count = 2 };
    selected.log_entries[0] = entries[1];
    selected.log_entries[1] = entries[0];
    const empty = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 0 };
    tc.deliver(0, 0, .{ .do_view_change = empty });
    tc.deliver(0, 1, .{ .do_view_change = selected });
    return entries;
}

test "view change selects one source chain instead of mixing per-op candidates" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x51A6E);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var a1 = msg.LogEntry{ .view_number = 2, .op_number = 1, .client_id = 1, .request_id = 1 };
    a1.checksum = a1.computeChecksum();
    var a2 = msg.LogEntry{ .view_number = 2, .op_number = 2, .client_id = 1, .request_id = 2, .parent_checksum = a1.checksum };
    a2.checksum = a2.computeChecksum();
    var b1 = a1;
    b1.client_id = 9;
    b1.checksum = b1.computeChecksum();

    var selected = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 2, .log_entry_count = 2 };
    selected.log_entries[0] = a2;
    selected.log_entries[1] = a1;
    var other = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 1, .log_entry_count = 1 };
    other.log_entries[0] = b1;

    const start_view_tag = @intFromEnum(msg.Tag.start_view);
    const prepare_tag = @intFromEnum(msg.Tag.prepare);
    const start_view_before = tc.network.stats.sent[start_view_tag];
    const prepare_before = tc.network.stats.sent[prepare_tag];
    tc.deliver(0, 0, .{ .do_view_change = other });
    tc.deliver(0, 1, .{ .do_view_change = selected });
    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.persisting_start_view, leader.view_change_candidate.phase);
    try std.testing.expectEqual(start_view_before, tc.network.stats.sent[start_view_tag]);
    try std.testing.expectEqual(prepare_before, tc.network.stats.sent[prepare_tag]);
    tc.requestWithIdentity(0, 99, 99, .{ .noop = {} });
    try std.testing.expectEqual(@as(msg.OpNumber, 2), leader.op_number);
    try std.testing.expectEqual(leader.op_number, leader.pending_start_view.op_number);
    try std.testing.expectEqual(prepare_before, tc.network.stats.sent[prepare_tag]);
    try std.testing.expectEqual(a1.checksum, leader.journalGet(1).?.checksum);
    try std.testing.expectEqual(a2.checksum, leader.journalGet(2).?.checksum);

    leader.tick();
    try std.testing.expectEqual(msg.Status.normal, leader.status);
    try std.testing.expectEqual(start_view_before + 2, tc.network.stats.sent[start_view_tag]);
    try std.testing.expectEqual(prepare_before, tc.network.stats.sent[prepare_tag]);
    leader.tick();
    try std.testing.expectEqual(start_view_before + 2, tc.network.stats.sent[start_view_tag]);
}

test "leader StartView slot metadata and sync failures preserve volatile coherence" {
    inline for (.{ "slot", "metadata", "sync" }, 0..) |fault_kind, case_index| {
        const tc = try TestCluster.init(std.testing.allocator, 3, 0xD001 + case_index);
        defer tc.deinit();
        const leader = tc.replicas[0];
        _ = stageTwoEntryLeaderStartView(tc);
        const start_view_tag = @intFromEnum(msg.Tag.start_view);
        const before = tc.network.stats.sent[start_view_tag];
        if (std.mem.eql(u8, fault_kind, "slot")) {
            tc.disks[0].fail_next_write = true;
        } else if (std.mem.eql(u8, fault_kind, "metadata")) {
            for (0..replica_mod.LOG_SIZE_MAX) |slot| leader.journal_dirty[slot] = false;
            tc.disks[0].fail_next_write = true;
        } else {
            tc.disks[0].fail_next_sync = true;
        }

        try std.testing.expectEqual(leader.op_number, leader.pending_start_view.op_number);
        leader.tick();
        try std.testing.expect(leader.storage_failed);
        try std.testing.expectEqual(leader.op_number, leader.pending_start_view.op_number);
        try std.testing.expectEqual(msg.Status.view_change, leader.status);
        try std.testing.expect(leader.pending_start_view.active);
        try std.testing.expectEqual(view_candidate.ViewSelectionPhase.persisting_start_view, leader.view_change_candidate.phase);
        try std.testing.expectEqual(before, tc.network.stats.sent[start_view_tag]);
    }
}

test "leader StartView volatile mode uses the same one-shot publication path" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD003);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.disk = null;
    _ = stageTwoEntryLeaderStartView(tc);
    const start_view_tag = @intFromEnum(msg.Tag.start_view);
    const before = tc.network.stats.sent[start_view_tag];

    leader.tick();
    try std.testing.expectEqual(msg.Status.normal, leader.status);
    try std.testing.expect(!leader.pending_start_view.active);
    try std.testing.expectEqual(before + 2, tc.network.stats.sent[start_view_tag]);
    leader.tick();
    try std.testing.expectEqual(before + 2, tc.network.stats.sent[start_view_tag]);
}

test "leader StartView defers higher view and timeout until durable publication" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xD004);
    defer tc.deinit();
    const leader = tc.replicas[0];
    _ = stageTwoEntryLeaderStartView(tc);
    const start_view_tag = @intFromEnum(msg.Tag.start_view);
    const before = tc.network.stats.sent[start_view_tag];

    tc.current_tick = @intCast(leader.view_change_candidate.metadata.deadline_tick + 1);
    tc.deliver(0, 1, .{ .start_view_change = .{ .view_number = 6, .replica_id = 2 } });
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), leader.deferred_view_target);
    tc.deliver(0, 2, .{ .start_view_change = .{ .view_number = 5, .replica_id = 2 } });
    try std.testing.expectEqual(@as(msg.ViewNumber, 3), leader.view_number);
    try std.testing.expectEqual(@as(msg.ViewNumber, 5), leader.deferred_view_target);
    try std.testing.expect(leader.pending_start_view.active);

    leader.tick();
    try std.testing.expectEqual(before + 2, tc.network.stats.sent[start_view_tag]);
    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 5), leader.view_number);
    try std.testing.expect(!leader.pending_start_view.active);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, leader.view_change_candidate.phase);
}

test "leader StartView crash before sync recovers old state and after sync recovers selected tip" {
    const pre = try TestCluster.init(std.testing.allocator, 3, 0xD005);
    defer pre.deinit();
    _ = stageTwoEntryLeaderStartView(pre);
    try std.testing.expect(pre.replicas[0].pending_start_view.active);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), pre.replicas[0].op_number);
    try std.testing.expectEqual(pre.replicas[0].op_number, pre.replicas[0].pending_start_view.op_number);
    pre.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), pre.replicas[0].op_number);
    try std.testing.expect(pre.replicas[0].journalGet(1) == null);

    const post = try TestCluster.init(std.testing.allocator, 3, 0xD006);
    defer post.deinit();
    const entries = stageTwoEntryLeaderStartView(post);
    post.replicas[0].tick();
    try std.testing.expectEqual(entries[1].checksum, post.disks[0].readSlot(replica_mod.journalSlot(2)).?.checksum);
    post.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), post.replicas[0].op_number);
    try std.testing.expectEqual(entries[1].checksum, post.replicas[0].journalGet(2).?.checksum);
}

test "DVC source rank is independent from commit watermark" {
    inline for (.{ "higher last-normal view", "higher op at equal last-normal view" }, 0..) |case_name, case_index| {
        _ = case_name;
        const tc = try TestCluster.init(std.testing.allocator, 3, 0xC0BB17 + case_index);
        defer tc.deinit();
        const leader = tc.replicas[0];
        leader.status = .view_change;
        leader.view_number = 3;

        var committed = msg.LogEntry{ .view_number = 1, .op_number = 1, .client_id = 2, .request_id = 1 };
        committed.checksum = committed.computeChecksum();
        var extension = msg.LogEntry{ .view_number = 2, .op_number = 2, .client_id = 3, .request_id = 2, .parent_checksum = committed.checksum };
        extension.checksum = extension.computeChecksum();

        const selected_lnv: msg.ViewNumber = if (case_index == 0) 2 else 1;
        var selected = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = selected_lnv, .op_number = 2, .commit_min = 0, .log_entry_count = 2 };
        selected.log_entries[0] = extension;
        selected.log_entries[1] = committed;
        var committed_source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 2, .last_normal_view = 1, .op_number = 1, .commit_min = 1, .log_entry_count = 1 };
        committed_source.log_entries[0] = committed;

        tc.deliver(0, 1, .{ .do_view_change = selected });
        tc.deliver(0, 2, .{ .do_view_change = committed_source });

        try std.testing.expect(leader.pending_start_view.active);
        try std.testing.expectEqual(@as(u8, 1), leader.pending_start_view.source_replica);
        try std.testing.expectEqual(@as(msg.OpNumber, 1), leader.pending_start_view.commit_min);
        try std.testing.expectEqual(@as(msg.OpNumber, 2), leader.pending_start_view.op_number);
        try std.testing.expectEqual(extension.checksum, leader.journalGet(2).?.checksum);
    }
}

test "DVC selected source tip below quorum commit bound aborts" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xC0BB19);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var committed = msg.LogEntry{ .view_number = 1, .op_number = 1, .client_id = 2, .request_id = 1 };
    committed.checksum = committed.computeChecksum();
    const empty_high_rank = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 0, .commit_min = 0 };
    var committed_source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 2, .last_normal_view = 1, .op_number = 1, .commit_min = 1, .log_entry_count = 1 };
    committed_source.log_entries[0] = committed;

    tc.deliver(0, 1, .{ .do_view_change = empty_high_rank });
    tc.deliver(0, 2, .{ .do_view_change = committed_source });

    try std.testing.expect(!leader.pending_start_view.active);
    try std.testing.expect(!leader.pending_view_selection);
    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 3), leader.view_number);
}

test "five rotating leaders replace speculative prepares with committed StartView chain" {
    for (0..5) |leader_index| {
        const tc = try TestCluster.init(std.testing.allocator, 5, 0xC0A017 + leader_index);
        defer tc.deinit();
        const leader = tc.replicas[leader_index];
        const target_view: msg.ViewNumber = 5 + leader_index;
        leader.status = .view_change;
        leader.view_number = target_view;

        var committed = msg.LogEntry{ .view_number = 0, .op_number = 1, .client_id = 10, .request_id = 1 };
        committed.checksum = committed.computeChecksum();
        var speculative = msg.LogEntry{ .view_number = leader_index + 1, .op_number = 2, .client_id = 20 + leader_index, .request_id = 2, .parent_checksum = committed.checksum };
        speculative.checksum = speculative.computeChecksum();
        var selected = msg.LogEntry{ .view_number = 4, .op_number = 2, .client_id = 99, .request_id = 2, .parent_checksum = committed.checksum };
        selected.checksum = selected.computeChecksum();
        try std.testing.expect(speculative.checksum != selected.checksum);

        leader.journalPut(committed);
        leader.journalPut(speculative);
        leader.op_number = 2;
        leader.commit_min = 1;
        leader.commit_max = 1;
        leader.durable_prepare_op[replica_mod.journalSlot(1)] = 1;
        leader.durable_prepare_checksum[replica_mod.journalSlot(1)] = committed.checksum;
        leader.durable_prepare_op[replica_mod.journalSlot(2)] = 2;
        leader.durable_prepare_checksum[replica_mod.journalSlot(2)] = speculative.checksum;

        const source_id: u8 = @intCast((leader_index + 1) % 5);
        const third_id: u8 = @intCast((leader_index + 2) % 5);
        var source = msg.DoViewChangeMsg{ .view_number = target_view, .replica_id = source_id, .last_normal_view = 4, .op_number = 2, .commit_min = 1, .log_entry_count = 2 };
        source.log_entries[0] = selected;
        source.log_entries[1] = committed;
        var local = msg.DoViewChangeMsg{ .view_number = target_view, .replica_id = @intCast(leader_index), .last_normal_view = 3, .op_number = 2, .commit_min = 1, .log_entry_count = 2 };
        local.log_entries[0] = speculative;
        local.log_entries[1] = committed;
        var third = msg.DoViewChangeMsg{ .view_number = target_view, .replica_id = third_id, .last_normal_view = 2, .op_number = 1, .commit_min = 1, .log_entry_count = 1 };
        third.log_entries[0] = committed;

        tc.deliver(@intCast(leader_index), @intCast(leader_index), .{ .do_view_change = local });
        tc.deliver(@intCast(leader_index), third_id, .{ .do_view_change = third });
        tc.deliver(@intCast(leader_index), source_id, .{ .do_view_change = source });

        try std.testing.expect(leader.pending_start_view.active);
        try std.testing.expectEqual(selected.checksum, leader.journalGet(2).?.checksum);
        try std.testing.expectEqual(@as(msg.OpNumber, 1), leader.commit_min);
        leader.tick();
        try std.testing.expectEqual(msg.Status.normal, leader.status);
        try std.testing.expectEqual(target_view, leader.view_number);
        try std.testing.expectEqual(selected.checksum, leader.journalGet(2).?.checksum);
    }
}

test "validated StartView replaces conflicting uncommitted durable prepare and survives crash" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0x1A7E25EC7);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var prepared = msg.LogEntry{ .view_number = 1, .op_number = 1, .client_id = 1, .request_id = 1 };
    prepared.checksum = prepared.computeChecksum();
    var conflicting = prepared;
    conflicting.view_number = 2;
    conflicting.client_id = 2;
    conflicting.checksum = conflicting.computeChecksum();
    leader.journalPut(prepared);
    leader.op_number = 1;
    const slot = replica_mod.journalSlot(1);
    leader.durable_prepare_op[slot] = 1;
    leader.durable_prepare_checksum[slot] = prepared.checksum;

    var source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 1, .log_entry_count = 1 };
    source.log_entries[0] = conflicting;
    var intersection = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 1, .log_entry_count = 1 };
    intersection.log_entries[0] = prepared;
    tc.deliver(0, 0, .{ .do_view_change = intersection });
    tc.deliver(0, 1, .{ .do_view_change = source });

    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 3), leader.view_number);
    try std.testing.expect(leader.pending_start_view.active);
    try std.testing.expectEqual(conflicting.checksum, leader.journalGet(1).?.checksum);
    try std.testing.expectEqual(@as(u64, 0), leader.durable_prepare_checksum[slot]);

    leader.tick();
    try std.testing.expectEqual(msg.Status.normal, leader.status);
    try std.testing.expectEqual(conflicting.checksum, leader.durable_prepare_checksum[slot]);
    tc.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), tc.replicas[0].op_number);
    try std.testing.expectEqual(conflicting.checksum, tc.replicas[0].journalGet(1).?.checksum);
}

test "incomplete selected suffix repairs backward by exact content identity" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xB0A0D);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var entries: [10]msg.LogEntry = undefined;
    var parent: u64 = 0;
    for (&entries, 0..) |*entry, i| {
        entry.* = .{ .view_number = 2, .op_number = i + 1, .client_id = 1, .request_id = i + 1, .parent_checksum = parent };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
        tc.replicas[1].journalPut(entry.*);
    }
    tc.replicas[1].op_number = 10;
    tc.replicas[1].last_normal_view = 2;
    tc.replicas[1].view_number = 3;
    tc.replicas[1].status = .view_change;

    var source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 10, .log_entry_count = 8 };
    for (0..8) |i| source.log_entries[i] = entries[9 - i];
    for (1..11) |op| msg.bitsetSet(&source.present_bitset, op % replica_mod.LOG_SIZE_MAX);
    // Replica 2 retains the exact interior ancestors but contributes no DVC hint.
    tc.replicas[2].journalPut(entries[0]);
    tc.replicas[2].journalPut(entries[1]);
    tc.replicas[2].op_number = 2;
    const empty = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 0 };
    tc.deliver(0, 0, .{ .do_view_change = empty });
    tc.deliver(0, 1, .{ .do_view_change = source });

    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expect(leader.pending_view_selection);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), leader.selected_next_op);
    try std.testing.expectEqual(entries[1].checksum, leader.selected_expected_checksum);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.op_number);
    try std.testing.expectEqual(@as(usize, 8), leader.view_change_candidate.present_count);

    var wrong_identity = entries[1];
    wrong_identity.client_id +%= 1;
    wrong_identity.checksum = wrong_identity.computeChecksum();
    tc.deliver(0, 1, .{ .send_prepare = .{
        .view_number = 3, .entry = wrong_identity, .selected_source = 1,
        .selected_last_normal_view = 2, .selected_tip_op = 10,
        .selected_tip_checksum = entries[9].checksum,
        .expected_entry_checksum = entries[1].checksum,
    } });
    try std.testing.expectEqual(@as(msg.OpNumber, 2), leader.selected_next_op);
    try std.testing.expectEqual(@as(usize, 8), leader.view_change_candidate.present_count);

    tc.deliver(0, 2, .{ .send_prepare = .{
        .view_number = 3, .entry = entries[1], .selected_source = 1,
        .selected_last_normal_view = 2, .selected_tip_op = 10,
        .selected_tip_checksum = entries[9].checksum,
        .expected_entry_checksum = entries[1].checksum,
    } });
    try std.testing.expectEqual(@as(msg.OpNumber, 1), leader.selected_next_op);
    try std.testing.expectEqual(entries[0].checksum, leader.selected_expected_checksum);

    var wrong_parent = entries[0];
    wrong_parent.client_id +%= 1;
    wrong_parent.checksum = wrong_parent.computeChecksum();
    tc.deliver(0, 1, .{ .send_prepare = .{
        .view_number = 3, .entry = wrong_parent, .selected_source = 1,
        .selected_last_normal_view = 2, .selected_tip_op = 10,
        .selected_tip_checksum = entries[9].checksum,
        .expected_entry_checksum = entries[0].checksum,
    } });
    try std.testing.expectEqual(@as(msg.OpNumber, 1), leader.selected_next_op);

    const syncs_before = tc.disks[0].syncs;
    tc.deliver(0, 2, .{ .send_prepare = .{
        .view_number = 3, .entry = entries[0], .selected_source = 1,
        .selected_last_normal_view = 2, .selected_tip_op = 10,
        .selected_tip_checksum = entries[9].checksum,
        .expected_entry_checksum = entries[0].checksum,
    } });
    try std.testing.expect(leader.pending_start_view.active);
    leader.tick();
    try std.testing.expectEqual(syncs_before + 1, tc.disks[0].syncs);
    try std.testing.expectEqual(msg.Status.normal, leader.status);
    try std.testing.expectEqual(entries[9].checksum, leader.journalGet(10).?.checksum);
}

test "selected source mutation aborts candidate without changing active journal" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xC4AD);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var entries: [10]msg.LogEntry = undefined;
    var parent: u64 = 0;
    for (&entries, 0..) |*entry, i| {
        entry.* = .{ .view_number = 2, .op_number = i + 1, .client_id = 1, .request_id = i + 1, .parent_checksum = parent };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
    }
    var source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 10, .log_entry_count = 8 };
    for (0..8) |i| source.log_entries[i] = entries[9 - i];
    const empty = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 0 };
    tc.deliver(0, 0, .{ .do_view_change = empty });
    tc.deliver(0, 1, .{ .do_view_change = source });
    try std.testing.expect(leader.pending_view_selection);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.op_number);

    source.log_entries[0].client_id = 99;
    source.log_entries[0].checksum = source.log_entries[0].computeChecksum();
    tc.deliver(0, 1, .{ .do_view_change = source });

    try std.testing.expectEqual(@as(msg.ViewNumber, 4), leader.view_number);
    try std.testing.expect(!leader.pending_view_selection);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, leader.view_change_candidate.phase);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.op_number);
    try std.testing.expect(leader.journalGet(10) == null);
}

test "selected source crash times out candidate without changing active journal" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xC2A5);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var entries: [10]msg.LogEntry = undefined;
    var parent: u64 = 0;
    for (&entries, 0..) |*entry, i| {
        entry.* = .{ .view_number = 2, .op_number = i + 1, .client_id = 1, .request_id = i + 1, .parent_checksum = parent };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
    }
    var source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 10, .log_entry_count = 8 };
    for (0..8) |i| source.log_entries[i] = entries[9 - i];
    const empty = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 0 };
    tc.deliver(0, 0, .{ .do_view_change = empty });
    tc.deliver(0, 1, .{ .do_view_change = source });
    try std.testing.expect(leader.pending_view_selection);

    tc.stopReplica(1);
    tc.current_tick = @intCast(leader.view_change_candidate.metadata.deadline_tick);
    leader.tick();

    try std.testing.expectEqual(@as(msg.ViewNumber, 4), leader.view_number);
    try std.testing.expect(!leader.pending_view_selection);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, leader.view_change_candidate.phase);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.op_number);
}

test "candidate allocation failure advances view without active mutation" {
    const tc = try TestCluster.init(std.testing.allocator, 3, 0xA110C);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;

    var entry = msg.LogEntry{ .view_number = 2, .op_number = 1, .client_id = 1, .request_id = 1 };
    entry.checksum = entry.computeChecksum();
    var source = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 1, .last_normal_view = 2, .op_number = 1, .log_entry_count = 1 };
    source.log_entries[0] = entry;
    const empty = msg.DoViewChangeMsg{ .view_number = 3, .replica_id = 0, .last_normal_view = 1, .op_number = 0 };

    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    leader.allocator = fixed.allocator();
    tc.deliver(0, 0, .{ .do_view_change = empty });
    tc.deliver(0, 1, .{ .do_view_change = source });
    leader.allocator = tc.allocator;

    try std.testing.expectEqual(@as(msg.ViewNumber, 4), leader.view_number);
    try std.testing.expect(!leader.pending_view_selection);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, leader.view_change_candidate.phase);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.op_number);
    try std.testing.expect(leader.journalGet(1) == null);
}

test "Replica candidate ownership survives crash reset and frees on teardown" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xCAAD1DA7E);
    defer tc.deinit();
    const replica = tc.replicas[0];
    replica.view_change_candidate = try view_candidate.ViewChangeCandidate.allocate(replica.allocator, .{
        .source_replica = 0,
        .target_view = 1,
        .source_last_normal_view = 0,
        .base_op = 1,
        .tip_op = 1,
        .tip_checksum = 1,
        .commit_bound = 0,
        .deadline_tick = 10,
    });
    try std.testing.expect(replica.view_change_candidate.entries.len == 1);

    tc.crashReplica(0);
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, tc.replicas[0].view_change_candidate.phase);
    try std.testing.expectEqual(@as(usize, 0), tc.replicas[0].view_change_candidate.entries.len);
    try std.testing.expect(tc.replicas[0].view_change_candidate.allocator != null);
}

test "Replica candidate deinit reset and allocation failure are leak free" {
    const tc = try TestCluster.init(std.testing.allocator, 1, 0xA110CA7E);
    defer tc.deinit();
    const replica = tc.replicas[0];

    replica.deinit();
    replica.deinit();
    try std.testing.expect(replica.view_change_candidate.allocator == null);
    replica.initInPlace(.{
        .allocator = tc.allocator,
        .replica_id = 0,
        .replica_count = 1,
        .io = tc.sim_ios[0].io(),
        .state_machine = tc.state_machines[0],
        .disk = tc.disks[0].diskInterface(),
    });

    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    replica.view_change_candidate.reset();
    replica.allocator = fixed.allocator();
    replica.view_change_candidate = .{ .allocator = replica.allocator };
    try std.testing.expectError(error.OutOfMemory, view_candidate.ViewChangeCandidate.allocate(replica.allocator, .{
        .source_replica = 0,
        .target_view = 1,
        .source_last_normal_view = 0,
        .base_op = 1,
        .tip_op = 1,
        .tip_checksum = 1,
        .commit_bound = 0,
        .deadline_tick = 10,
    }));
    try std.testing.expectEqual(view_candidate.ViewSelectionPhase.idle, replica.view_change_candidate.phase);

    replica.resetInPlace(.{
        .allocator = tc.allocator,
        .replica_id = 0,
        .replica_count = 1,
        .io = tc.sim_ios[0].io(),
        .state_machine = tc.state_machines[0],
        .disk = tc.disks[0].diskInterface(),
    });
    try std.testing.expect(replica.view_change_candidate.allocator != null);
}
