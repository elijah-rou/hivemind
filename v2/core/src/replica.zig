const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const msg = @import("message.zig");

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const root = @import("root");
    const quiet = builtin.is_test or (@hasDecl(root, "hivemind_quiet") and root.hivemind_quiet);
    if (quiet) return;
    std.debug.print(fmt, args);
}
const io_mod = @import("vopr/simulated_io.zig");
const net_mod = @import("vopr/simulated_net.zig");
const sm_mod = @import("state_machine.zig");
const StateMachine = @import("state_machine.zig").StateMachine;
const sched = @import("scheduler.zig");
const disk_mod = @import("disk.zig");
const latency = @import("latency.zig");
pub const DiskInterface = disk_mod.DiskInterface;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const LOG_SIZE_MAX: usize = msg.LOG_BITSET_BITS;
pub const CLIENT_TABLE_MAX: usize = 64;
pub const MAX_WORKERS: usize = 128;
pub const HEARTBEAT_INTERVAL: i64 = 100;
pub const VIEW_CHANGE_TIMEOUT: i64 = 2000;
pub const RECOVERED_VIEW_CHANGE_TIMEOUT: i64 = 50;
pub const REPAIR_BATCH_MAX: usize = 8;
const DEFAULT_STOP_GRACE_MS: u64 = 30_000;
const WORKER_DISPATCH_RETRY_INTERVAL: i64 = 5000;
/// Bound on deferred stop-pod side effects waiting for a durability barrier.
const MAX_PENDING_STOPS: usize = sm_mod.MAX_PODS;
/// Max flush loop iterations per tick (prepare barrier + commit barrier).
const FLUSH_BARRIER_MAX: u8 = 4;

pub fn journalSlot(op: msg.OpNumber) usize {
    std.debug.assert(op > 0);
    return @intCast(op % LOG_SIZE_MAX);
}

// ---------------------------------------------------------------------------
// Client table entry for request deduplication
// ---------------------------------------------------------------------------

const ClientEntry = struct {
    client_id: u128,
    request_id: msg.RequestId,
    result: msg.Result,
    active: bool,
};

const StopDispatch = struct {
    worker_idx: usize,
    pod_id: u64,
    grace_period_ms: u64,
};

// ---------------------------------------------------------------------------
// Callback function pointer types for production listeners.
// These are optional -- null in simulation, set in production.
// ---------------------------------------------------------------------------

pub const PeerSendFn = *const fn (ctx: *anyopaque, to: u8, data: []const u8) void;
pub const ClientReplyFn = *const fn (ctx: *anyopaque, client_id: u128, request_id: msg.RequestId, result: msg.Result) void;
pub const PodScheduledFn = *const fn (ctx: *anyopaque, pod_id: u64, deployment_id: u64) void;
pub const WorkerSendFn = *const fn (ctx: *anyopaque, worker_idx: usize, data: []const u8) void;

// ---------------------------------------------------------------------------
// VRR Replica
// ---------------------------------------------------------------------------

pub const ReplicaConfig = struct {
    replica_id: u8,
    replica_count: u8,
    io: Io,
    state_machine: *StateMachine,
    disk: ?DiskInterface = null,
    // Optional production callbacks (null in simulation)
    peer_send_ctx: ?*anyopaque = null,
    peer_send_fn: ?PeerSendFn = null,
    client_reply_ctx: ?*anyopaque = null,
    client_reply_fn: ?ClientReplyFn = null,
    pod_scheduled_ctx: ?*anyopaque = null,
    pod_scheduled_fn: ?PodScheduledFn = null,
    worker_send_ctx: ?*anyopaque = null,
    worker_send_fn: ?WorkerSendFn = null,
};

pub const WorkerConnection = struct {
    node_id: u64 = 0,
    hostname: [64]u8 = std.mem.zeroes([64]u8),
    connected: bool = false,
    last_heartbeat_tick: i64 = 0,
    last_dispatch_retry_tick: i64 = 0,
    gpu_type: msg.GpuType = .none,
    gpu_count: u8 = 0,
    pending_register: bool = false,
    /// Monotonic per-slot id so agent re-registrations bypass the VRR client dedup table.
    register_seq: u64 = 0,
};

pub const Replica = struct {
    // Configuration
    replica_id: u8,
    replica_count: u8,
    quorum_size: u8,
    /// Minimum nacks required to truncate an uncommitted op during view change.
    /// Safety invariant: quorum_nack_prepare + quorum_size > replica_count.
    quorum_nack_prepare: u8,

    // VRR protocol state
    status: msg.Status,
    view_number: msg.ViewNumber,
    /// The last view in which this replica was in normal status.
    last_normal_view: msg.ViewNumber,
    op_number: msg.OpNumber,
    commit_min: msg.OpNumber,
    /// Highest op known to be committed (from leader). May be > commit_min
    /// when we know ops are committed but haven't executed them yet.
    commit_max: msg.OpNumber,
    /// Cluster-wide minimum commit_min: lowest committed op any replica needs.
    retention_floor: msg.OpNumber,
    replica_commit_min: [msg.REPLICA_COUNT_MAX]msg.OpNumber,

    // Slot-indexed journal: slot = op % LOG_SIZE_MAX, O(1) lookup
    journal: [LOG_SIZE_MAX]msg.LogEntry,
    journal_occupied: [LOG_SIZE_MAX]bool,

    // PrepareOk tracking: number of acks per log slot
    prepare_ok_counts: [LOG_SIZE_MAX]u8,
    // Bitset per slot: which replicas have sent PrepareOk (prevents double-counting)
    prepare_ok_from: [LOG_SIZE_MAX]u16,

    // Client table for deduplication
    client_table: [CLIENT_TABLE_MAX]ClientEntry,
    client_count: usize,

    // View change state
    start_vc_count: [msg.REPLICA_COUNT_MAX]bool,
    start_vc_total: u8,
    do_vc_received: [msg.REPLICA_COUNT_MAX]bool,
    do_vc_msgs: [msg.REPLICA_COUNT_MAX]msg.DoViewChangeMsg,
    do_vc_total: u8,

    // I/O -- the single injectable interface
    io: Io,
    state_machine: *StateMachine,
    scheduler: sched.Scheduler,

    // Log repair after view change
    repair_pending: bool,
    /// present_bitsets from DVCs, used for targeted RequestPrepare
    repair_present: [msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64,
    /// Tracks which replicas have responded with SendStatus during repair.
    repair_status_received: [msg.REPLICA_COUNT_MAX]bool,
    repair_status_count: u8,

    // Follower state transfer: fetching missed ops from leader
    transfer_pending: bool,
    transfer_target_op: msg.OpNumber,

    // Persistence tracking
    journal_dirty: [LOG_SIZE_MAX]bool,
    metadata_dirty: bool,
    disk: ?DiskInterface,
    /// Fail-stop: disk write/sync failed; no further consensus/client/worker traffic.
    storage_failed: bool,

    // Deferred protocol/client publication until covering durability barrier
    pending_prepare_broadcast: [LOG_SIZE_MAX]bool,
    pending_prepare_ok: [LOG_SIZE_MAX]bool,
    pending_prepare_ok_to: [LOG_SIZE_MAX]u8,
    pending_reply: [LOG_SIZE_MAX]bool,
    pending_reply_client_id: [LOG_SIZE_MAX]u128,
    pending_reply_request_id: [LOG_SIZE_MAX]msg.RequestId,
    pending_reply_result: [LOG_SIZE_MAX]msg.Result,
    pending_effect: [LOG_SIZE_MAX]bool,
    pending_stops: [MAX_PENDING_STOPS]StopDispatch,
    pending_stop_ops: [MAX_PENDING_STOPS]msg.OpNumber,
    pending_stop_count: usize,
    /// Highest op whose Prepare was acknowledged locally after a barrier.
    durable_prepare_through: msg.OpNumber,

    // Tick-based timers
    last_heartbeat: i64,
    last_leader_activity: i64,

    // Crash recovery state
    recovered_from_disk: bool,

    // Serialization buffer
    send_buf: [net_mod.MESSAGE_SIZE_MAX]u8,

    // Peer socket handles: peer_handles[replica_id] = socket fd.
    // In simulation: fake handle = replica_id. In production: real TCP fd.
    peer_handles: [msg.REPLICA_COUNT_MAX]std.Io.net.Socket.Handle,

    // Agent connections (out-of-band from VRR)
    workers: [MAX_WORKERS]WorkerConnection,
    worker_count: usize,
    /// Retained-log saturation: requests rejected with log_full.
    log_full_rejections: u64,
    /// Legacy alias used by metrics/tests; same counter as log_full_rejections.
    pipeline_guard_drops: u64,
    storage_failures: u64,

    // Optional production callbacks
    peer_send_ctx: ?*anyopaque,
    peer_send_fn: ?PeerSendFn,
    client_reply_ctx: ?*anyopaque,
    client_reply_fn: ?ClientReplyFn,
    pod_scheduled_ctx: ?*anyopaque,
    pod_scheduled_fn: ?PodScheduledFn,
    worker_send_ctx: ?*anyopaque,
    worker_send_fn: ?WorkerSendFn,

    pub fn init(config: ReplicaConfig) Replica {
        std.debug.assert(config.replica_count >= 1 and config.replica_count <= msg.REPLICA_COUNT_MAX);
        const f = (config.replica_count - 1) / 2;

        return .{
            .replica_id = config.replica_id,
            .replica_count = config.replica_count,
            .quorum_size = @intCast(f + 1),
            .quorum_nack_prepare = @intCast(config.replica_count - f),
            .status = .normal,
            .view_number = 0,
            .last_normal_view = 0,
            .op_number = 0,
            .commit_min = 0,
            .commit_max = 0,
            .retention_floor = 0,
            .replica_commit_min = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber),
            .journal = undefined,
            .journal_occupied = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8),
            .prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16),
            .client_table = undefined,
            .client_count = 0,
            .start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool),
            .start_vc_total = 0,
            .do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool),
            .do_vc_msgs = undefined,
            .do_vc_total = 0,
            .repair_pending = false,
            .repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64),
            .repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool),
            .repair_status_count = 0,
            .transfer_pending = false,
            .transfer_target_op = 0,
            .journal_dirty = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .metadata_dirty = false,
            .disk = config.disk,
            .storage_failed = false,
            .pending_prepare_broadcast = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .pending_prepare_ok_to = std.mem.zeroes([LOG_SIZE_MAX]u8),
            .pending_reply = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .pending_reply_client_id = std.mem.zeroes([LOG_SIZE_MAX]u128),
            .pending_reply_request_id = std.mem.zeroes([LOG_SIZE_MAX]msg.RequestId),
            .pending_reply_result = undefined,
            .pending_effect = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .pending_stops = undefined,
            .pending_stop_ops = undefined,
            .pending_stop_count = 0,
            .durable_prepare_through = 0,
            .io = config.io,
            .state_machine = config.state_machine,
            .scheduler = sched.Scheduler.init(@as(u64, config.replica_id) +% 0x5C4ED),
            .last_heartbeat = 0,
            .last_leader_activity = 0,
            .recovered_from_disk = false,
            .send_buf = undefined,
            .peer_handles = defaultPeerHandles(),
            .workers = [_]WorkerConnection{.{}} ** MAX_WORKERS,
            .worker_count = 0,
            .log_full_rejections = 0,
            .pipeline_guard_drops = 0,
            .storage_failures = 0,
            .peer_send_ctx = config.peer_send_ctx,
            .peer_send_fn = config.peer_send_fn,
            .client_reply_ctx = config.client_reply_ctx,
            .client_reply_fn = config.client_reply_fn,
            .pod_scheduled_ctx = config.pod_scheduled_ctx,
            .pod_scheduled_fn = config.pod_scheduled_fn,
            .worker_send_ctx = config.worker_send_ctx,
            .worker_send_fn = config.worker_send_fn,
        };
    }

    /// Initialize in-place on heap-allocated pointer.
    pub fn initInPlace(self: *Replica, config: ReplicaConfig) void {
        std.debug.assert(config.replica_count >= 1 and config.replica_count <= msg.REPLICA_COUNT_MAX);
        const f = (config.replica_count - 1) / 2;
        self.replica_id = config.replica_id;
        self.replica_count = config.replica_count;
        self.quorum_size = @intCast(f + 1);
        self.quorum_nack_prepare = @intCast(config.replica_count - f);
        self.status = .normal;
        self.view_number = 0;
        self.last_normal_view = 0;
        self.op_number = 0;
        self.commit_min = 0;
        self.commit_max = 0;
        self.retention_floor = 0;
        self.replica_commit_min = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber);
        self.journal_occupied = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);
        self.client_count = 0;
        self.start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.start_vc_total = 0;
        self.do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.do_vc_total = 0;
        self.repair_pending = false;
        self.repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64);
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
        self.transfer_pending = false;
        self.transfer_target_op = 0;
        self.journal_dirty = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.metadata_dirty = false;
        self.disk = config.disk;
        self.storage_failed = false;
        self.pending_prepare_broadcast = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok_to = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.pending_reply = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_reply_client_id = std.mem.zeroes([LOG_SIZE_MAX]u128);
        self.pending_reply_request_id = std.mem.zeroes([LOG_SIZE_MAX]msg.RequestId);
        self.pending_effect = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_stop_count = 0;
        self.durable_prepare_through = 0;
        self.io = config.io;
        self.state_machine = config.state_machine;
        self.scheduler = sched.Scheduler.init(@as(u64, config.replica_id) +% 0x5C4ED);
        self.last_heartbeat = 0;
        self.last_leader_activity = 0;
        self.recovered_from_disk = false;
        self.peer_handles = defaultPeerHandles();
        self.workers = [_]WorkerConnection{.{}} ** MAX_WORKERS;
        self.worker_count = 0;
        self.log_full_rejections = 0;
        self.pipeline_guard_drops = 0;
        self.storage_failures = 0;
        self.peer_send_ctx = config.peer_send_ctx;
        self.peer_send_fn = config.peer_send_fn;
        self.client_reply_ctx = config.client_reply_ctx;
        self.client_reply_fn = config.client_reply_fn;
        self.pod_scheduled_ctx = config.pod_scheduled_ctx;
        self.pod_scheduled_fn = config.pod_scheduled_fn;
        self.worker_send_ctx = config.worker_send_ctx;
        self.worker_send_fn = config.worker_send_fn;
    }

    /// Recover state from disk after a crash. Restores metadata and journal
    /// entries, then sets status to view_change to rejoin the cluster.
    /// Returns false when no durable metadata exists. Returns error on
    /// corrupt/missing committed prefix.
    pub fn recoverFromDisk(self: *Replica) !bool {
        var disk = self.disk orelse return false;

        const meta = disk.readMetadata() orelse return false;
        self.view_number = meta.view_number;
        self.last_normal_view = meta.last_normal_view;
        self.op_number = meta.op_number;
        self.commit_min = meta.commit_min;
        self.commit_max = meta.commit_max;
        self.retention_floor = self.commit_min;
        self.replica_commit_min = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber);
        self.replica_commit_min[self.replica_id] = self.commit_min;
        self.durable_prepare_through = self.op_number;

        // Restore journal entries from disk
        self.journal_occupied = std.mem.zeroes([LOG_SIZE_MAX]bool);
        for (0..LOG_SIZE_MAX) |i| {
            if (disk.readSlot(i)) |entry| {
                if (entry.op_number > 0 and entry.valid()) {
                    self.journal[i] = entry;
                    self.journal_occupied[i] = true;
                }
            }
        }

        // Discard journal entries above recovered op_number (written to disk
        // before metadata was flushed, so they're orphaned after crash).
        for (0..LOG_SIZE_MAX) |i| {
            if (self.journal_occupied[i] and self.journal[i].op_number > self.op_number) {
                self.journal_occupied[i] = false;
            }
        }

        try self.rebuildCommittedState(self.commit_min);
        self.recovered_from_disk = true;

        // Multi-node: enter view_change to rejoin cluster safely.
        // Recovered replicas use a shorter rejoin timeout while they are still
        // catch-up candidates, but should not trigger an immediate election on
        // the next tick.
        if (self.replica_count > 1) {
            self.status = .view_change;
            self.last_leader_activity = io_mod.nowTick(self.io);
        }
        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);
        self.journal_dirty = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.metadata_dirty = false;
        self.pending_prepare_broadcast = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_reply = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_effect = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_stop_count = 0;
        self.repair_pending = false;
        self.transfer_pending = false;
        self.transfer_target_op = 0;
        self.start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.start_vc_total = 0;
        self.do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.do_vc_total = 0;

        return true;
    }

    // -----------------------------------------------------------------------
    // Leader identity
    // -----------------------------------------------------------------------

    fn leaderForView(self: *const Replica, view_number: msg.ViewNumber) u8 {
        return @intCast(view_number % self.replica_count);
    }

    pub fn leader(self: *const Replica) u8 {
        return self.leaderForView(self.view_number);
    }

    pub fn isLeader(self: *const Replica) bool {
        return self.leader() == self.replica_id;
    }

    /// Cluster-wide safe-to-prune floor for gossip/DVC metadata.
    fn effectiveRetentionFloor(self: *const Replica) msg.OpNumber {
        return @min(self.retention_floor, self.commit_min);
    }

    /// Highest floor retained by a quorum. A silent replica must not pin the
    /// leader forever, but the leader also must not wrap past entries that only
    /// it has retained. Any future quorum intersects this retained quorum.
    fn pipelineRetentionFloor(self: *const Replica) msg.OpNumber {
        var floors = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber);
        var count: usize = 0;
        while (count < self.replica_count) : (count += 1) {
            floors[count] = self.replica_commit_min[count];
        }
        floors[self.replica_id] = self.commit_min;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var best = i;
            var j = i + 1;
            while (j < count) : (j += 1) {
                if (floors[j] > floors[best]) best = j;
            }
            const tmp = floors[i];
            floors[i] = floors[best];
            floors[best] = tmp;
        }

        return floors[self.quorum_size - 1];
    }

    fn recomputeRetentionFloor(self: *Replica) void {
        var floor = self.replica_commit_min[0];
        var i: usize = 1;
        while (i < self.replica_count) : (i += 1) {
            floor = @min(floor, self.replica_commit_min[i]);
        }
        self.retention_floor = floor;
    }

    fn noteReplicaCommitMin(self: *Replica, replica_id: u8, their_commit_min: msg.OpNumber) void {
        if (replica_id >= self.replica_count) return;
        if (their_commit_min > self.replica_commit_min[replica_id]) {
            self.replica_commit_min[replica_id] = their_commit_min;
        }
        self.recomputeRetentionFloor();
    }

    fn maxReplicaCommitMin(self: *const Replica) msg.OpNumber {
        var floor = self.replica_commit_min[0];
        var i: usize = 1;
        while (i < self.replica_count) : (i += 1) {
            floor = @max(floor, self.replica_commit_min[i]);
        }
        return floor;
    }

    fn maybeResumeRepair(self: *Replica) void {
        if (!self.isLeader()) return;
        if (self.status != .normal) return;
        if (self.repair_pending) return;
        if (self.maxReplicaCommitMin() <= self.commit_min) return;

        self.repair_pending = true;
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
    }

    // -----------------------------------------------------------------------
    // Tick -- called every simulation/real tick
    // -----------------------------------------------------------------------

    pub fn tick(self: *Replica) void {
        if (self.storage_failed) return;

        const now_tick = io_mod.nowTick(self.io);

        // Initialize timestamps on first tick (production uses wall-clock ms,
        // starting from 0 would cause immediate view change timeout)
        if (self.last_heartbeat == 0) self.last_heartbeat = now_tick;
        if (self.last_leader_activity == 0) self.last_leader_activity = now_tick;

        // Commit progress may become unblocked by repaired log entries without
        // a new quorum event arriving on the same tick. Drain any already-known
        // committed prefix opportunistically while in normal mode.
        if (self.status == .normal and self.commit_max > self.commit_min) {
            self.advanceCommitMin();
        }

        switch (self.status) {
            .normal => {
                if (self.isLeader()) {
                    if (now_tick - self.last_heartbeat >= HEARTBEAT_INTERVAL) {
                        self.sendCommitHeartbeat();
                        self.last_heartbeat = now_tick;

                        if (!self.repair_pending) {
                            self.resendUncommittedPrepares();
                        }
                    }
                    if (self.repair_pending) {
                        self.tickRepair();
                    } else {
                        self.tickScheduler();
                    }
                } else {
                    if (self.transfer_pending) {
                        self.tickTransfer();
                    } else if (now_tick - self.last_leader_activity >= HEARTBEAT_INTERVAL and
                        now_tick - self.last_heartbeat >= HEARTBEAT_INTERVAL)
                    {
                        self.sendTo(self.leader(), .{ .request_status = .{
                            .view_number = self.view_number,
                        } });
                        self.last_heartbeat = now_tick;
                    }
                    if (now_tick - self.last_leader_activity >= VIEW_CHANGE_TIMEOUT) {
                        self.initiateViewChange();
                    }
                }
            },
            .view_change => {
                const timeout = if (self.recovered_from_disk)
                    RECOVERED_VIEW_CHANGE_TIMEOUT
                else
                    VIEW_CHANGE_TIMEOUT * 2;
                if (now_tick - self.last_leader_activity >= timeout) {
                    self.initiateViewChange();
                }
            },
            .recovering => {},
        }

        self.flushDurableState();
    }

    // -----------------------------------------------------------------------
    // Message dispatch
    // -----------------------------------------------------------------------

    pub fn onMessage(self: *Replica, from: u8, message: msg.Message) void {
        if (self.storage_failed) return;
        switch (message) {
            .request => |m| self.onRequest(from, m),
            .prepare => |m| self.onPrepare(from, m),
            .prepare_ok => |m| self.onPrepareOk(from, m),
            .commit => |m| self.onCommit(from, m),
            .start_view_change => |m| self.onStartViewChange(from, m),
            .do_view_change => |m| self.onDoViewChange(from, m),
            .start_view => |m| self.onStartView(from, m),
            .request_prepare => |m| self.onRequestPrepare(from, m),
            .send_prepare => |m| self.onSendPrepare(from, m),
            .request_status => |m| self.onRequestStatus(from, m),
            .send_status => |m| self.onSendStatus(from, m),
            .reply => {},
        }
    }

    // -----------------------------------------------------------------------
    // Normal operation
    // -----------------------------------------------------------------------

    fn onRequest(self: *Replica, _: u8, request: msg.RequestMsg) void {
        if (self.status != .normal) return;
        if (!self.isLeader()) return;
        if (self.repair_pending) return;
        if (self.storage_failed) return;

        // Client table dedup
        if (self.findClient(request.client_id)) |entry| {
            if (entry.request_id >= request.request_id) {
                // Replay committed result without mutating the journal.
                if (self.client_reply_fn) |cb| {
                    cb(self.client_reply_ctx.?, request.client_id, request.request_id, entry.result);
                }
                return;
            }
        }

        // In-flight dedup: the scheduler can propose the same bind repeatedly
        // before the first one commits. Reject duplicate (client_id,
        // request_id) pairs already present in the uncommitted journal so one
        // pod cannot be rebound and dispatched to multiple workers.
        if (self.hasPendingRequest(request.client_id, request.request_id)) return;

        // Lifetime retained-log guard: without snapshots, never append past
        // LOG_SIZE_MAX committed/accepted operations (no circular overwrite).
        if (self.op_number + 1 > LOG_SIZE_MAX) {
            self.log_full_rejections += 1;
            self.pipeline_guard_drops = self.log_full_rejections;
            if (self.client_reply_fn) |cb| {
                cb(self.client_reply_ctx.?, request.client_id, request.request_id, .{ .err = .log_full });
            }
            return;
        }

        self.op_number += 1;
        const assigned_ms = io_mod.nowTick(self.io);
        latency.record(.{ .phase = "op_assigned", .op = latency.commandName(request.command), .deployment_id = latency.deploymentId(request.command), .pod_id = latency.podId(request.command), .name = latency.commandNameField(request.command), .start_ms = assigned_ms, .end_ms = assigned_ms, .source = "core/src/replica.zig" });
        var entry = msg.LogEntry{
            .view_number = self.view_number,
            .op_number = self.op_number,
            .command = request.command,
            .client_id = request.client_id,
            .request_id = request.request_id,
            .parent_checksum = self.lastChecksum(),
        };
        entry.checksum = entry.computeChecksum();
        self.journalPut(entry);
        self.metadata_dirty = true;

        const slot = journalSlot(self.op_number);
        self.pending_prepare_broadcast[slot] = true;
        // Self vote and Prepare broadcast wait for the durability barrier.
        self.prepare_ok_counts[slot] = 0;
        self.prepare_ok_from[slot] = 0;
    }

    fn onPrepare(self: *Replica, from: u8, prepare: msg.PrepareMsg) void {
        if (self.status == .recovering) return;
        if (from != self.leaderForView(prepare.view_number)) return;

        // If we see a Prepare from a higher view, we missed the view change.
        if (prepare.view_number > self.view_number) {
            // A higher-view leader may only safely reuse our committed prefix.
            // Any locally-held uncommitted suffix could be divergent.
            self.truncateAbove(self.commit_min);
            self.view_number = prepare.view_number;
            self.op_number = self.commit_min;
            self.commit_max = self.commit_min;
        }

        if (prepare.view_number != self.view_number) return;
        if (self.isLeader()) return;

        if (self.status == .view_change) {
            // Rejoining via Prepare must discard any uncommitted local suffix.
            // Preserving entries above our own commit_min can let a stale value
            // get committed under the new view before the leader repairs us.
            self.truncateAbove(self.commit_min);
            self.op_number = self.commit_min;
            self.commit_max = self.commit_min;
            self.status = .normal;
            self.last_normal_view = self.view_number;
            self.recovered_from_disk = false;
        }

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.noteReplicaCommitMin(from, prepare.commit_min);
        self.retention_floor = prepare.retention_floor;

        if (!prepare.entry.valid()) return;

        if (prepare.op_number <= self.op_number and prepare.op_number > self.commit_min) {
            if (self.journalGet(prepare.op_number)) |existing| {
                if (existing.checksum != prepare.entry.checksum) {
                    self.truncateAbove(prepare.op_number - 1);
                    self.op_number = @max(self.logHighOp(), self.commit_min);
                    self.commit_max = @min(self.commit_max, self.op_number);
                }
            }
        }

        if (!self.entryFitsLog(prepare.entry)) return;

        if (prepare.op_number == self.op_number + 1) {
            // Pipeline depth guard: reject prepare that would wrap past the
            // leader-advertised retained floor.
            if (prepare.op_number - prepare.retention_floor >= LOG_SIZE_MAX) return;
            // Lifetime cap: never accept an op beyond LOG_SIZE_MAX without snapshots.
            if (prepare.op_number > LOG_SIZE_MAX) return;

            self.op_number = prepare.op_number;
            self.journalPut(prepare.entry);
            self.metadata_dirty = true;

            const slot = journalSlot(prepare.op_number);
            self.pending_prepare_ok[slot] = true;
            self.pending_prepare_ok_to[slot] = from;

            if (self.transfer_pending and self.op_number >= self.transfer_target_op) {
                self.transfer_pending = false;
            }
        } else if (prepare.op_number <= self.op_number and prepare.op_number > self.commit_min) {
            if (self.journalGet(prepare.op_number)) |existing| {
                if (existing.checksum == prepare.entry.checksum) {
                    const slot = journalSlot(prepare.op_number);
                    // Re-ack only after the entry is known durable locally.
                    if (prepare.op_number <= self.durable_prepare_through) {
                        self.sendTo(from, .{ .prepare_ok = .{
                            .view_number = self.view_number,
                            .op_number = prepare.op_number,
                            .replica_id = self.replica_id,
                            .commit_min = self.commit_min,
                        } });
                    } else {
                        self.pending_prepare_ok[slot] = true;
                        self.pending_prepare_ok_to[slot] = from;
                    }
                }
            }
        } else if (prepare.op_number > self.op_number + 1) {
            if (!self.transfer_pending or prepare.op_number > self.transfer_target_op) {
                self.transfer_pending = true;
                self.transfer_target_op = prepare.op_number;
            }
        }

        if (self.hasLogGaps()) {
            self.transfer_pending = true;
            self.transfer_target_op = @max(self.transfer_target_op, self.op_number);
        }
    }

    fn onPrepareOk(self: *Replica, from: u8, ok: msg.PrepareOkMsg) void {
        if (self.status != .normal) return;
        if (!self.isLeader()) return;
        if (ok.view_number != self.view_number) return;

        self.noteReplicaCommitMin(from, ok.commit_min);

        if (ok.op_number > self.commit_min and ok.op_number <= self.op_number) {
            if (self.journalHas(ok.op_number)) {
                const slot = journalSlot(ok.op_number);
                const from_bit = @as(u16, 1) << @intCast(from);
                // Dedup: only count each replica's ack once
                if (self.prepare_ok_from[slot] & from_bit == 0) {
                    self.prepare_ok_from[slot] |= from_bit;
                    self.prepare_ok_counts[slot] += 1;
                }
            }
        }

        self.advanceCommit();
        self.maybeResumeRepair();
    }

    fn onCommit(self: *Replica, from: u8, commit_msg: msg.CommitMsg) void {
        if (self.status == .recovering) return;
        if (from != self.leaderForView(commit_msg.view_number)) return;

        if (commit_msg.view_number > self.view_number) {
            // A higher-view leader may only safely reuse our committed prefix.
            // Any locally-held uncommitted suffix could be divergent.
            self.truncateAbove(self.commit_min);
            self.view_number = commit_msg.view_number;
            self.op_number = self.commit_min;
            self.commit_max = self.commit_min;
        }

        if (commit_msg.view_number != self.view_number) return;
        if (self.isLeader()) return;

        if (self.status == .view_change) {
            // Rejoining via Commit must discard any uncommitted local suffix.
            // Otherwise a stale tail can become locally committed before repair.
            self.truncateAbove(self.commit_min);
            self.op_number = self.commit_min;
            self.commit_max = self.commit_min;
            self.status = .normal;
            self.last_normal_view = self.view_number;
            self.recovered_from_disk = false;
        }

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.noteReplicaCommitMin(from, commit_msg.commit_min);
        self.retention_floor = commit_msg.retention_floor;

        const target = @max(commit_msg.commit_min, commit_msg.commit_max);
        if (target > self.commit_min) {
            if (commit_msg.commit_checksum != 0) {
                const target_entry = self.journalGet(target) orelse {
                    self.transfer_pending = true;
                    self.transfer_target_op = @max(self.transfer_target_op, target);
                    return;
                };
                if (target_entry.checksum != commit_msg.commit_checksum) {
                    self.truncateAbove(target - 1);
                    self.op_number = @max(self.logHighOp(), self.commit_min);
                    self.commit_max = @min(self.commit_max, self.op_number);
                    self.transfer_pending = true;
                    self.transfer_target_op = @max(self.transfer_target_op, target);
                    return;
                }
            }
            self.commitUpTo(target);
        }

        if (commit_msg.op_number > self.op_number) {
            if (!self.transfer_pending or commit_msg.op_number > self.transfer_target_op) {
                self.transfer_pending = true;
                self.transfer_target_op = commit_msg.op_number;
            }
        }

        if (self.hasLogGaps()) {
            self.transfer_pending = true;
            self.transfer_target_op = @max(self.transfer_target_op, @max(self.op_number, commit_msg.op_number));
        }
    }

    // -----------------------------------------------------------------------
    // View change
    // -----------------------------------------------------------------------

    fn initiateViewChange(self: *Replica) void {
        const new_view = self.view_number + 1;

        self.status = .view_change;
        self.view_number = new_view;
        self.repair_pending = false;
        self.repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64);
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
        self.transfer_pending = false;
        self.transfer_target_op = 0;
        self.last_leader_activity = io_mod.nowTick(self.io);

        self.start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.start_vc_total = 0;
        self.do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.do_vc_total = 0;

        self.start_vc_count[self.replica_id] = true;
        self.start_vc_total = 1;

        self.sendToAll(.{ .start_view_change = .{
            .view_number = new_view,
            .replica_id = self.replica_id,
        } });

        self.maybeDoViewChange();
    }

    fn onStartViewChange(self: *Replica, _: u8, svc: msg.StartViewChangeMsg) void {
        if (svc.view_number < self.view_number) return;

        if (svc.view_number > self.view_number) {
            self.status = .view_change;
            self.view_number = svc.view_number;
            self.last_leader_activity = io_mod.nowTick(self.io);
            self.start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
            self.start_vc_total = 0;
            self.do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
            self.do_vc_total = 0;
            self.start_vc_count[self.replica_id] = true;
            self.start_vc_total = 1;

            self.sendToAll(.{ .start_view_change = .{
                .view_number = svc.view_number,
                .replica_id = self.replica_id,
            } });
        }

        if (!self.start_vc_count[svc.replica_id]) {
            self.start_vc_count[svc.replica_id] = true;
            self.start_vc_total += 1;
        }

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.maybeDoViewChange();
    }

    fn maybeDoViewChange(self: *Replica) void {
        const f = (self.replica_count - 1) / 2;
        if (self.start_vc_total < f + 1) return;

        const dvc = self.buildDvc();
        const new_leader: u8 = @intCast(self.view_number % self.replica_count);
        self.sendTo(new_leader, .{ .do_view_change = dvc });

        if (new_leader == self.replica_id) {
            if (!self.do_vc_received[self.replica_id]) {
                self.do_vc_received[self.replica_id] = true;
                self.do_vc_msgs[self.replica_id] = dvc;
                self.do_vc_total += 1;
            }
            self.maybeStartView();
        }
    }

    fn onDoViewChange(self: *Replica, _: u8, dvc: msg.DoViewChangeMsg) void {
        if (self.status != .view_change) return;
        if (dvc.view_number != self.view_number) return;

        const new_leader: u8 = @intCast(self.view_number % self.replica_count);
        if (new_leader != self.replica_id) return;

        if (!self.do_vc_received[dvc.replica_id]) {
            self.do_vc_received[dvc.replica_id] = true;
            self.do_vc_msgs[dvc.replica_id] = dvc;
            self.do_vc_total += 1;
        }

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.maybeStartView();
    }

    fn maybeStartView(self: *Replica) void {
        if (self.do_vc_total < self.quorum_size) return;

        // Nack protocol: for each uncommitted op, count how many DVCs
        // DON'T have it. If nacks >= quorum_nack_prepare, the op could NOT
        // have been committed, so truncate.

        // Step 1: Find max_commit and max_op across all DVCs.
        var max_commit: msg.OpNumber = 0;
        var max_op: msg.OpNumber = 0;
        var carried_retention_floor = self.effectiveRetentionFloor();
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            max_commit = @max(max_commit, self.do_vc_msgs[i].commit_min);
            max_op = @max(max_op, self.do_vc_msgs[i].op_number);
            carried_retention_floor = @min(carried_retention_floor, self.do_vc_msgs[i].retention_floor);
        }

        // Step 2: Install committed entries. Only replicas that themselves
        // report an op as committed may contribute its value here. Otherwise a
        // higher-view but uncommitted suffix entry could overwrite a value that
        // another replica proved committed via commit_min.
        var committed_source_lnv = std.mem.zeroes([LOG_SIZE_MAX]msg.ViewNumber);
        var committed_source_op = std.mem.zeroes([LOG_SIZE_MAX]msg.OpNumber);
        var committed_source_set = std.mem.zeroes([LOG_SIZE_MAX]bool);
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            const dvc = &self.do_vc_msgs[i];
            for (dvc.log_entries[0..dvc.log_entry_count]) |entry| {
                if (!entry.valid()) continue;
                if (entry.op_number > max_commit) continue;
                if (entry.op_number > dvc.commit_min) continue;

                const slot = journalSlot(entry.op_number);
                const should_install = !committed_source_set[slot] or
                    committed_source_op[slot] != entry.op_number or
                    dvc.last_normal_view >= committed_source_lnv[slot];
                if (!should_install) continue;

                self.journalPut(entry);
                committed_source_set[slot] = true;
                committed_source_op[slot] = entry.op_number;
                committed_source_lnv[slot] = dvc.last_normal_view;
            }
        }

        // Collect present_bitsets from DVCs for targeted repair later
        self.repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64);
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            self.repair_present[i] = self.do_vc_msgs[i].present_bitset;
        }

        // Step 3: For each uncommitted op, run nack protocol.
        var highest_kept = max_commit;
        var repair_target = highest_kept;
        var op = max_commit + 1;
        while (op <= max_op) : (op += 1) {
            var nacks: u8 = 0;
            var candidate_entries: [msg.REPLICA_COUNT_MAX]msg.LogEntry = undefined;
            var candidate_counts: [msg.REPLICA_COUNT_MAX]u8 = std.mem.zeroes([msg.REPLICA_COUNT_MAX]u8);
            var candidate_lnvs: [msg.REPLICA_COUNT_MAX]msg.ViewNumber = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.ViewNumber);
            var candidate_len: usize = 0;

            for (0..self.replica_count) |i| {
                if (!self.do_vc_received[i]) continue;
                var has_bitsets = false;
                for (self.do_vc_msgs[i].present_bitset) |word| {
                    if (word != 0) has_bitsets = true;
                }
                for (self.do_vc_msgs[i].nack_bitset) |word| {
                    if (word != 0) has_bitsets = true;
                }

                const has_op = if (has_bitsets)
                    msg.bitsetGet(&self.do_vc_msgs[i].present_bitset, @intCast(op % LOG_SIZE_MAX))
                else
                    self.dvcHasOp(i, op);

                if (has_op) {
                    const candidate_lnv = self.do_vc_msgs[i].last_normal_view;
                    for (self.do_vc_msgs[i].log_entries[0..self.do_vc_msgs[i].log_entry_count]) |entry| {
                        if (entry.op_number == op and entry.valid()) {
                            var matched = false;
                            var idx: usize = 0;
                            while (idx < candidate_len) : (idx += 1) {
                                if (candidate_entries[idx].checksum == entry.checksum) {
                                    candidate_counts[idx] += 1;
                                    candidate_lnvs[idx] = @max(candidate_lnvs[idx], candidate_lnv);
                                    matched = true;
                                    break;
                                }
                            }
                            if (!matched) {
                                candidate_entries[candidate_len] = entry;
                                candidate_counts[candidate_len] = 1;
                                candidate_lnvs[candidate_len] = candidate_lnv;
                                candidate_len += 1;
                            }
                            break;
                        }
                    }
                } else {
                    nacks += 1;
                }
            }

            if (nacks >= self.quorum_nack_prepare) break;

            var selected: ?msg.LogEntry = null;
            var selected_support: u8 = 0;
            var selected_lnv: msg.ViewNumber = 0;
            var idx: usize = 0;
            while (idx < candidate_len) : (idx += 1) {
                if (selected == null or
                    candidate_lnvs[idx] > selected_lnv or
                    (candidate_lnvs[idx] == selected_lnv and candidate_counts[idx] > selected_support))
                {
                    selected = candidate_entries[idx];
                    selected_support = candidate_counts[idx];
                    selected_lnv = candidate_lnvs[idx];
                }
            }

            // If quorum nacks could not rule the op out, preserve the best
            // old-view candidate rather than dropping the slot. Requiring a
            // full current DVC checksum quorum is too strong: a previously
            // committed/prepared value may intersect the new DVC quorum in only
            // one replica.
            const entry = selected orelse {
                repair_target = max_op;
                break;
            };

            if (entry.op_number != highest_kept + 1) {
                repair_target = max_op;
                break;
            }

            self.journalPut(entry);
            highest_kept = op;
            repair_target = highest_kept;
        }

        if (highest_kept > max_commit) {
            var ack_op = max_commit + 1;
            while (ack_op <= highest_kept) : (ack_op += 1) {
                if (self.journalHas(ack_op)) {
                    const slot = journalSlot(ack_op);
                    self.prepare_ok_counts[slot] = 1;
                    self.prepare_ok_from[slot] = @as(u16, 1) << @intCast(self.replica_id);
                }
            }
        }

        // Step 4: Truncate divergent entries above highest_kept, then set op_number.
        // Committed entries (op_number <= commit_min) are preserved by truncateAbove.
        // op_number must be >= commit_min to maintain the invariant.
        self.truncateAbove(highest_kept);
        self.op_number = @max(repair_target, self.commit_min);

        if (max_commit > self.commit_min) {
            self.commitUpTo(max_commit);
        }
        self.commit_max = self.commit_min;

        // Seed retention floor from DVC messages
        {
            var i: usize = 0;
            while (i < self.replica_count) : (i += 1) {
                self.replica_commit_min[i] = carried_retention_floor;
            }
            i = 0;
            while (i < self.replica_count) : (i += 1) {
                if (!self.do_vc_received[i]) continue;
                self.replica_commit_min[i] = self.do_vc_msgs[i].commit_min;
            }
            self.replica_commit_min[self.replica_id] = self.commit_min;
            self.recomputeRetentionFloor();
        }

        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);

        // Count self as having acked all locally-present uncommitted entries.
        var ack_op = self.commit_min + 1;
        while (ack_op <= self.op_number) : (ack_op += 1) {
            if (self.journalHas(ack_op)) {
                const slot = journalSlot(ack_op);
                self.prepare_ok_counts[slot] = 1;
                self.prepare_ok_from[slot] = @as(u16, 1) << @intCast(self.replica_id);
            }
        }

        self.status = .normal;
        self.last_normal_view = self.view_number;
        const now_tick = io_mod.nowTick(self.io);
        self.last_heartbeat = now_tick;
        self.last_leader_activity = now_tick;

        self.sendToAllOthers(.{ .start_view = self.buildStartView() });

        // Always enter repair phase after view change
        self.repair_pending = true;
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
    }

    // -----------------------------------------------------------------------
    // Worker protocol (out-of-band from VRR)
    // -----------------------------------------------------------------------

    pub fn onWorkerRegister(self: *Replica, worker_idx: usize, register: msg.WorkerRegisterMsg) void {
        if (worker_idx >= MAX_WORKERS) return;

        const prior_seq: u64 = if (worker_idx < self.worker_count) self.workers[worker_idx].register_seq else 0;
        const next_seq = prior_seq + 1;

        self.workers[worker_idx] = .{
            .hostname = register.hostname,
            .connected = true,
            .last_heartbeat_tick = io_mod.nowTick(self.io),
            .last_dispatch_retry_tick = 0,
            .gpu_type = register.gpu_type,
            .gpu_count = register.gpu_count,
            .pending_register = true,
            .register_seq = next_seq,
        };
        if (worker_idx >= self.worker_count) {
            self.worker_count = worker_idx + 1;
        }

        if (self.isLeader() and self.status == .normal and !self.repair_pending) {
            const client_id: u128 = 0xA6E0_0000_0000_0000 | @as(u128, worker_idx);
            const now_tick: u128 = @intCast(@max(0, io_mod.nowTick(self.io)));
            const request_id = (now_tick << 32) | @as(u128, next_seq);
            self.onRequest(self.replica_id, .{
                .client_id = client_id,
                .request_id = request_id,
                .command = .{ .register_node = .{
                    .node_name = register.hostname,
                    .cpu_millicores = register.cpu_millicores,
                    .memory_megabytes = register.memory_megabytes,
                    .gpu_type = register.gpu_type,
                    .gpu_count = register.gpu_count,
                    .provider = register.provider,
                    .region = register.region,
                } },
            });
        }
    }

    pub fn onWorkerDisconnect(self: *Replica, worker_idx: usize) void {
        if (worker_idx >= self.worker_count) return;
        self.workers[worker_idx].connected = false;
    }

    pub fn getWorkerNodeId(self: *const Replica, worker_idx: usize) u64 {
        if (worker_idx >= self.worker_count) return 0;
        return self.workers[worker_idx].node_id;
    }

    pub fn onWorkerHeartbeat(self: *Replica, worker_idx: usize, heartbeat: msg.WorkerHeartbeatMsg) void {
        if (worker_idx >= self.worker_count) return;
        if (!self.workers[worker_idx].connected) return;

        _ = heartbeat;
        const now_tick = io_mod.nowTick(self.io);
        self.workers[worker_idx].last_heartbeat_tick = now_tick;

        if (self.isLeader() and self.status == .normal and !self.repair_pending and
            self.workers[worker_idx].node_id != 0 and
            now_tick - self.workers[worker_idx].last_dispatch_retry_tick >= WORKER_DISPATCH_RETRY_INTERVAL)
        {
            self.dispatchScheduledPodsForWorker(worker_idx);
            self.workers[worker_idx].last_dispatch_retry_tick = now_tick;
        }
    }

    pub fn onWorkerPodStatus(self: *Replica, worker_idx: usize, status_msg: msg.WorkerPodStatusMsg) void {
        if (worker_idx >= self.worker_count) return;
        if (!self.workers[worker_idx].connected) return;

        const received_ms = io_mod.nowTick(self.io);
        latency.record(.{ .phase = "core_status_received", .op = "update_pod_status", .pod_id = status_msg.pod_id, .start_ms = received_ms, .end_ms = received_ms, .source = "core/src/replica.zig" });

        if (self.isLeader() and self.status == .normal and !self.repair_pending) {
            const client_id: u128 = 0xA6E0_0000_0000_0000 | @as(u128, worker_idx) << 32 | @as(u128, status_msg.pod_id);
            self.onRequest(self.replica_id, .{
                .client_id = client_id,
                .request_id = @as(u128, status_msg.pod_id) << 64 | @as(u128, @intFromEnum(status_msg.new_phase)),
                .command = .{ .update_pod_status = .{
                    .pod_id = status_msg.pod_id,
                    .new_phase = status_msg.new_phase,
                } },
            });
        }
    }

    pub fn findWorkerForNode(self: *const Replica, node_id: u64) ?usize {
        for (0..self.worker_count) |i| {
            if (self.workers[i].connected and self.workers[i].node_id == node_id) {
                return i;
            }
        }
        return null;
    }

    fn dispatchCommittedBind(self: *Replica, pod_id: u64, node_id: u64, op_name: []const u8) void {
        const bind_ms = io_mod.nowTick(self.io);
        const bound_pod = self.state_machine.findPod(pod_id);
        latency.record(.{ .phase = "bind_commit", .op = op_name, .deployment_id = if (bound_pod) |p| p.deployment_id else 0, .pod_id = pod_id, .name = if (bound_pod) |p| msg.fixedToSlice(&p.name) else "", .start_ms = bind_ms, .end_ms = bind_ms, .source = "core/src/replica.zig" });
        self.dispatchPodToWorker(pod_id, node_id);

        if (self.pod_scheduled_fn) |cb| {
            if (bound_pod) |p| {
                cb(self.pod_scheduled_ctx.?, pod_id, p.deployment_id);
            }
        }
    }

    pub fn dispatchPodToWorker(self: *Replica, pod_id: u64, node_id: u64) void {
        const worker_idx = self.findWorkerForNode(node_id) orelse {
            debugLog("hivemind replica: no worker for node_id={d} pod_id={d}\n", .{ node_id, pod_id });
            return;
        };
        const pod = self.state_machine.findPod(pod_id) orelse return;
        const dep = self.state_machine.findDeployment(pod.deployment_id) orelse return;

        const send_fn = self.worker_send_fn orelse {
            debugLog("hivemind replica: worker_send_fn missing for pod_id={d}\n", .{pod_id});
            return;
        };
        const ctx = self.worker_send_ctx orelse {
            debugLog("hivemind replica: worker_send_ctx missing for pod_id={d}\n", .{pod_id});
            return;
        };

        // Build StartPod frame (variable-length due to env vars):
        // [4-byte len][tag=0x02][pod_id:u64][dep_id:u64][image:256][entrypoint:256]
        // [port:u16][gpu_count:u8][gpu_type:u8][cpu:u32][mem:u32][juicefs_path:128]
        // [liveness_path:64][readiness_path:64]
        // [env_count:u8][env_count x (name:64 + value:256 + is_secret:u8)]
        // Optional registry auth trailer (only if deployment has credentials):
        //   [0x01][registry:128][username:64][password:256][password_is_secret:u8]
        const max_env: usize = 16;
        const fixed_size: usize = 8 + 8 + 256 + 256 + 2 + 1 + 1 + 4 + 4 + 128 + 64 + 64 + 1;
        const env_entry_size: usize = 64 + 256 + 1;
        const registry_auth_block: usize = 1 + 128 + 64 + 256 + 1;
        const max_payload = fixed_size + (max_env * env_entry_size) + registry_auth_block;
        var payload: [max_payload]u8 = undefined;
        var pos: usize = 0;

        // pod_id
        @memcpy(payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, pod_id)));
        pos += 8;
        // deployment_id
        @memcpy(payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, pod.deployment_id)));
        pos += 8;
        // image
        @memcpy(payload[pos..][0..256], &dep.image);
        pos += 256;
        // entrypoint
        @memcpy(payload[pos..][0..256], &dep.entrypoint);
        pos += 256;
        // port
        @memcpy(payload[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, dep.port)));
        pos += 2;
        // gpu_count
        payload[pos] = dep.gpu_count;
        pos += 1;
        // gpu_type
        payload[pos] = @intFromEnum(dep.gpu_type);
        pos += 1;
        // cpu_millicores
        @memcpy(payload[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, dep.cpu_millicores)));
        pos += 4;
        // memory_megabytes
        @memcpy(payload[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, dep.memory_megabytes)));
        pos += 4;
        // juicefs_path
        @memcpy(payload[pos..][0..128], &dep.juicefs_path);
        pos += 128;
        // liveness path
        @memcpy(payload[pos..][0..64], &dep.liveness.path);
        pos += 64;
        // readiness path
        @memcpy(payload[pos..][0..64], &dep.readiness.path);
        pos += 64;
        // env_count
        payload[pos] = dep.env_count;
        pos += 1;
        // env vars
        for (dep.env_vars[0..dep.env_count]) |env| {
            @memcpy(payload[pos..][0..64], &env.name);
            pos += 64;
            @memcpy(payload[pos..][0..256], &env.value);
            pos += 256;
            payload[pos] = if (env.is_secret_ref) 1 else 0;
            pos += 1;
        }

        const has_registry_auth = blk: {
            for (&dep.image_pull_registry) |b| if (b != 0) break :blk true;
            for (&dep.image_pull_username) |b| if (b != 0) break :blk true;
            for (&dep.image_pull_password) |b| if (b != 0) break :blk true;
            break :blk false;
        };

        if (has_registry_auth) {
            payload[pos] = 0x01;
            pos += 1;
            @memcpy(payload[pos..][0..128], &dep.image_pull_registry);
            pos += 128;
            @memcpy(payload[pos..][0..64], &dep.image_pull_username);
            pos += 64;
            @memcpy(payload[pos..][0..256], &dep.image_pull_password);
            pos += 256;
            payload[pos] = dep.image_pull_password_is_secret;
            pos += 1;
        }

        // Frame it: [4-byte len][2-byte version][tag][payload]
        const conn = @import("connection.zig");
        const frame_header = conn.FRAME_HEADER;
        const frame_buf_size = frame_header + max_payload;
        var frame: [frame_buf_size]u8 = undefined;
        const frame_len: u32 = @intCast(2 + 1 + pos); // version + tag + payload
        @memcpy(frame[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, frame_len)));
        @memcpy(frame[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, conn.PROTOCOL_VERSION)));
        frame[6] = @intFromEnum(msg.WorkerTag.start_pod);
        @memcpy(frame[frame_header..][0..pos], payload[0..pos]);

        debugLog(
            "hivemind replica: dispatch pod_id={d} dep_id={d} node_id={d} worker_idx={d}\n",
            .{ pod_id, pod.deployment_id, node_id, worker_idx },
        );
        const send_start = io_mod.nowTick(self.io);
        send_fn(ctx, worker_idx, frame[0 .. frame_header + pos]);
        const send_end = io_mod.nowTick(self.io);
        latency.record(.{ .phase = "dispatch_send", .op = "start_pod", .deployment_id = pod.deployment_id, .pod_id = pod_id, .name = msg.fixedToSlice(&pod.name), .start_ms = send_start, .end_ms = send_end, .source = "core/src/replica.zig" });
    }

    fn dispatchPodsForWorker(self: *Replica, worker_idx: usize) void {
        self.dispatchPodsForWorkerMatching(worker_idx, true);
    }

    fn dispatchScheduledPodsForWorker(self: *Replica, worker_idx: usize) void {
        self.dispatchPodsForWorkerMatching(worker_idx, false);
    }

    fn dispatchPodsForWorkerMatching(self: *Replica, worker_idx: usize, include_running: bool) void {
        if (worker_idx >= self.worker_count) return;
        if (!self.workers[worker_idx].connected) return;

        const node_id = self.workers[worker_idx].node_id;
        if (node_id == 0) return;

        for (self.state_machine.pods[0..self.state_machine.pod_count]) |pod| {
            if (!pod.active) continue;
            if (pod.node_id != node_id) continue;
            switch (pod.phase) {
                .pending, .scheduled => self.dispatchPodToWorker(pod.id, node_id),
                .running => if (include_running) self.dispatchPodToWorker(pod.id, node_id),
                .succeeded, .failed, .terminating => {},
            }
        }
    }

    fn dispatchStopPodToWorker(self: *Replica, worker_idx: usize, pod_id: u64, grace_period_ms: u64) void {
        if (worker_idx >= self.worker_count or !self.workers[worker_idx].connected) return;

        const send_fn = self.worker_send_fn orelse return;
        const ctx = self.worker_send_ctx orelse return;

        const conn = @import("connection.zig");
        var frame: [conn.FRAME_HEADER + 16]u8 = undefined;
        const frame_len: u32 = @intCast(2 + 1 + 16);
        @memcpy(frame[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, frame_len)));
        @memcpy(frame[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, conn.PROTOCOL_VERSION)));
        frame[6] = @intFromEnum(msg.WorkerTag.stop_pod);
        @memcpy(frame[7..15], &std.mem.toBytes(std.mem.nativeToLittle(u64, pod_id)));
        @memcpy(frame[15..23], &std.mem.toBytes(std.mem.nativeToLittle(u64, grace_period_ms)));
        send_fn(ctx, worker_idx, frame[0..23]);
    }

    fn appendStopDispatch(self: *const Replica, worker_idx: usize, pod_id: u64, out: []StopDispatch, count: *usize) void {
        _ = self;
        if (count.* >= out.len) return;
        out[count.*] = .{
            .worker_idx = worker_idx,
            .pod_id = pod_id,
            .grace_period_ms = DEFAULT_STOP_GRACE_MS,
        };
        count.* += 1;
    }

    fn collectStopDispatches(self: *const Replica, command: msg.Command, out: []StopDispatch) usize {
        var count: usize = 0;
        switch (command) {
            .delete_deployment => |cmd| {
                for (self.state_machine.pods[0..self.state_machine.pod_count]) |pod| {
                    if (!pod.active) continue;
                    if (pod.deployment_id != cmd.deployment_id) continue;
                    if (pod.node_id == 0) continue;
                    const worker_idx = self.findWorkerForNode(pod.node_id) orelse continue;
                    self.appendStopDispatch(worker_idx, pod.id, out, &count);
                }
            },
            .unbind_pod => |cmd| {
                const pod = self.state_machine.findPod(cmd.pod_id) orelse return 0;
                if (pod.active and pod.node_id != 0) {
                    const worker_idx = self.findWorkerForNode(pod.node_id) orelse return 0;
                    self.appendStopDispatch(worker_idx, pod.id, out, &count);
                }
            },
            .scale_deployment => |cmd| {
                const dep = self.state_machine.findDeployment(cmd.deployment_id) orelse return 0;
                if (cmd.desired_replicas >= dep.replicas) return 0;
                var excess = dep.replicas - cmd.desired_replicas;
                for (self.state_machine.pods[0..self.state_machine.pod_count]) |pod| {
                    if (excess == 0) break;
                    if (!pod.active) continue;
                    if (pod.deployment_id != cmd.deployment_id) continue;
                    if (pod.phase == .terminating) continue;
                    if (pod.node_id != 0) {
                        if (self.findWorkerForNode(pod.node_id)) |worker_idx| {
                            self.appendStopDispatch(worker_idx, pod.id, out, &count);
                        }
                    }
                    excess -= 1;
                }
            },
            else => {},
        }
        return count;
    }

    // -----------------------------------------------------------------------
    // Log repair after view change
    // -----------------------------------------------------------------------

    fn tickScheduler(self: *Replica) void {
        std.debug.assert(self.isLeader());
        std.debug.assert(self.status == .normal);

        const current_tick: u64 = @intCast(@max(0, io_mod.nowTick(self.io)));
        const result = self.scheduler.tick(self.state_machine, current_tick);
        if (result.count > 0) {
            var cmd = msg.BindPodsToNodesCmd{};
            cmd.count = @intCast(result.count);
            for (result.actions[0..result.count], 0..) |action, i| {
                cmd.bindings[i] = .{ .pod_id = action.pod_id, .node_id = action.node_id };
            }
            const bind_client_id: u128 = 0xB17D_0000_0000_0000_0000_0000_0000_0000 | @as(u128, result.actions[0].pod_id);
            self.onRequest(self.replica_id, .{
                .client_id = bind_client_id,
                .request_id = result.actions[0].pod_id,
                .command = .{ .bind_pods_to_nodes = cmd },
            });
        }

        // Process scale-to-zero actions
        for (result.scale_downs[0..result.scale_down_count]) |sd| {
            const client_id: u128 = 0xDEAD_5CA1_0000_0000 | @as(u128, sd.deployment_id);
            self.onRequest(self.replica_id, .{
                .client_id = client_id,
                .request_id = @as(u128, sd.deployment_id),
                .command = .{ .scale_deployment = .{
                    .deployment_id = sd.deployment_id,
                    .desired_replicas = sd.desired_replicas,
                } },
            });
        }
    }

    fn repairStatusQuorum(self: *const Replica) u8 {
        std.debug.assert(self.quorum_size > 0);
        return self.quorum_size - 1;
    }

    fn tickRepair(self: *Replica) void {
        std.debug.assert(self.isLeader());
        std.debug.assert(self.status == .normal);

        self.sendToAllOthers(.{ .request_status = .{
            .view_number = self.view_number,
        } });

        if (self.repair_status_count < self.repairStatusQuorum()) return;

        const committed_floor = self.maxReplicaCommitMin();
        if (committed_floor > self.commit_min) {
            self.sendToAllOthers(.{ .request_prepare = .{
                .view_number = self.view_number,
                .op_number = self.commit_min + 1,
            } });
            return;
        }

        var requested: usize = 0;
        var op = self.commit_min + 1;
        while (op <= self.op_number) : (op += 1) {
            if (!self.journalHas(op)) {
                // present_bitset is modulo LOG_SIZE_MAX, so after wrap it cannot
                // prove which replica still has an exact op. Broadcasting repair
                // requests avoids stalling on a false-positive slot match.
                self.sendToAllOthers(.{ .request_prepare = .{
                    .view_number = self.view_number,
                    .op_number = op,
                } });
                requested += 1;
                if (requested >= REPAIR_BATCH_MAX) return;
            }
        }

        if (self.hasLogGaps()) return;

        self.repair_pending = false;

        var ack_op = self.commit_min + 1;
        while (ack_op <= self.op_number) : (ack_op += 1) {
            if (self.journalHas(ack_op)) {
                const s = journalSlot(ack_op);
                if (self.prepare_ok_counts[s] == 0) self.prepare_ok_counts[s] = 1;
            }
        }

        self.advanceCommit();
    }

    fn tickTransfer(self: *Replica) void {
        std.debug.assert(!self.isLeader());
        std.debug.assert(self.status == .normal);
        std.debug.assert(self.transfer_pending);

        var requested: usize = 0;
        var op = self.commit_min + 1;
        while (op <= self.op_number) : (op += 1) {
            if (!self.journalHas(op)) {
                self.sendToAllOthers(.{ .request_prepare = .{
                    .view_number = self.view_number,
                    .op_number = op,
                } });
                requested += 1;
                if (requested >= REPAIR_BATCH_MAX) return;
            }
        }

        if (requested > 0) return;

        if (self.op_number < self.transfer_target_op) {
            self.sendToAllOthers(.{ .request_prepare = .{
                .view_number = self.view_number,
                .op_number = self.op_number + 1,
            } });
            return;
        }

        self.transfer_pending = false;
    }

    fn onRequestStatus(self: *Replica, from: u8, rs: msg.RequestStatusMsg) void {
        if (rs.view_number != self.view_number) return;

        self.sendTo(from, .{ .send_status = .{
            .view_number = self.view_number,
            .op_number = self.op_number,
            .commit_min = self.commit_min,
        } });
    }

    fn onSendStatus(self: *Replica, from: u8, ss: msg.SendStatusMsg) void {
        if (self.status != .normal) return;
        if (ss.view_number != self.view_number) return;

        if (self.isLeader()) {
            self.noteReplicaCommitMin(from, ss.commit_min);

            if (!self.repair_pending) {
                self.maybeResumeRepair();
                return;
            }

            if (!self.repair_status_received[from]) {
                self.repair_status_received[from] = true;
                self.repair_status_count += 1;
            }

            // StartView fixes the new leader's chosen suffix. Followers may report
            // longer local tails, but status messages are not authoritative enough
            // to extend the log beyond what view change already selected.
            return;
        }

        if (from != self.leader()) return;

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.noteReplicaCommitMin(from, ss.commit_min);

        if (ss.commit_min > self.commit_min) {
            self.commitUpTo(ss.commit_min);
        }

        if (ss.op_number > self.op_number) {
            self.transfer_pending = true;
            self.transfer_target_op = @max(self.transfer_target_op, ss.op_number);
        }

        if (self.hasLogGaps()) {
            self.transfer_pending = true;
            self.transfer_target_op = @max(self.transfer_target_op, @max(self.op_number, ss.op_number));
        }
    }

    fn onRequestPrepare(self: *Replica, from: u8, rp: msg.RequestPrepareMsg) void {
        if (rp.view_number != self.view_number) return;

        if (self.journalGet(rp.op_number)) |entry| {
            // Only the leader may source uncommitted suffix entries. Followers
            // can safely help each other recover committed gaps, but serving a
            // locally-held uncommitted op to another follower can resurrect a
            // divergent suffix after view change.
            if (from != self.leader() and rp.op_number > self.commit_min) return;
            self.sendTo(from, .{ .send_prepare = .{
                .view_number = self.view_number,
                .entry = entry.*,
            } });
        }
    }

    fn onSendPrepare(self: *Replica, from: u8, sp: msg.SendPrepareMsg) void {
        if (self.status != .normal) return;
        if (sp.view_number != self.view_number) return;
        if (!sp.entry.valid()) return;

        const entry = sp.entry;
        const sender_committed = entry.op_number <= self.replica_commit_min[from];
        if (!sender_committed and !self.entryFitsLog(entry)) return;

        if (self.isLeader()) {
            if (!self.repair_pending) return;

            if (sender_committed) {
                if (entry.op_number != self.commit_min + 1) return;
                if (entry.op_number > 1) {
                    const prev = self.journalGet(entry.op_number - 1) orelse return;
                    if (prev.checksum != entry.parent_checksum) return;
                } else if (entry.parent_checksum != 0) {
                    return;
                }

                if (self.journalGet(entry.op_number)) |existing| {
                    if (existing.checksum != entry.checksum) {
                        self.journalPut(entry);
                    }
                } else {
                    self.journalPut(entry);
                }

                self.op_number = @max(self.op_number, entry.op_number);
                self.commitUpTo(entry.op_number);
                return;
            }

            if (self.journalHas(entry.op_number)) return;
            if (entry.op_number <= self.commit_min) return;
            if (entry.op_number > self.op_number) return;

            self.journalPut(entry);
            const slot = journalSlot(entry.op_number);
            const self_bit = @as(u16, 1) << @intCast(self.replica_id);
            const from_bit = @as(u16, 1) << @intCast(from);
            self.prepare_ok_from[slot] = self_bit | from_bit;
            self.prepare_ok_counts[slot] = if (from == self.replica_id) 1 else 2;

            self.sendToAllOthers(.{ .prepare = .{
                .view_number = self.view_number,
                .op_number = entry.op_number,
                .commit_min = self.commit_min,
                .retention_floor = self.retention_floor,
                .entry = entry,
            } });
            self.advanceCommit();

            if (!self.hasLogGaps()) {
                self.repair_pending = false;
            }
        } else {
            if (!self.transfer_pending) return;

            if (entry.op_number <= self.op_number) {
                if (self.journalHas(entry.op_number)) return;
                self.journalPut(entry);
                // Send prepare_ok for gap fill to accelerate commit progress
                if (entry.op_number > self.commit_min) {
                    self.sendTo(self.leader(), .{ .prepare_ok = .{
                        .view_number = self.view_number,
                        .op_number = entry.op_number,
                        .replica_id = self.replica_id,
                        .commit_min = self.commit_min,
                    } });
                }
            } else if (entry.op_number == self.op_number + 1) {
                self.op_number = entry.op_number;
                self.journalPut(entry);

                self.sendTo(self.leader(), .{ .prepare_ok = .{
                    .view_number = self.view_number,
                    .op_number = entry.op_number,
                    .replica_id = self.replica_id,
                    .commit_min = self.commit_min,
                } });
            } else {
                return;
            }

            if (self.commit_max > self.commit_min) {
                self.commitUpTo(self.commit_max);
            }

            if (self.op_number >= self.transfer_target_op and !self.hasLogGaps()) {
                self.transfer_pending = false;
            }
        }
    }

    fn dvcHasOp(self: *const Replica, dvc_idx: usize, op: msg.OpNumber) bool {
        const dvc = &self.do_vc_msgs[dvc_idx];
        for (dvc.log_entries[0..dvc.log_entry_count]) |entry| {
            if (entry.op_number == op) return true;
        }
        return false;
    }

    fn onStartView(self: *Replica, from: u8, sv: msg.StartViewMsg) void {
        if (from != self.leaderForView(sv.view_number)) return;
        if (sv.view_number < self.view_number) return;

        self.view_number = sv.view_number;
        self.retention_floor = sv.retention_floor;

        // StartView is the new leader's selected log suffix. Local uncommitted
        // entries above commit_min may be from an abandoned view and must not be
        // preserved or acknowledged, otherwise a follower can help commit a
        // value the new leader did not choose. Gaps from the bounded StartView
        // tail are repaired through the explicit transfer path below.
        self.truncateAbove(self.commit_min);
        self.op_number = @max(self.logHighOp(), self.commit_min);

        for (sv.log_entries[0..sv.log_entry_count]) |entry| {
            if (!entry.valid()) continue;
            self.journalPut(entry);
        }

        self.op_number = @max(@max(sv.op_number, self.logHighOp()), self.commit_min);

        self.status = .normal;
        self.last_normal_view = self.view_number;
        self.last_leader_activity = io_mod.nowTick(self.io);

        if (sv.commit_min > self.commit_min) {
            self.commitUpTo(sv.commit_min);
        }
        self.commit_max = self.commit_min;

        const new_leader = self.leader();

        // Seed per-replica tracking from leader's retention_floor
        {
            var i: usize = 0;
            while (i < self.replica_count) : (i += 1) {
                self.replica_commit_min[i] = self.retention_floor;
            }
            self.replica_commit_min[new_leader] = sv.commit_min;
            self.replica_commit_min[self.replica_id] = self.commit_min;
        }

        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);
        var ack_op = self.commit_min + 1;
        while (ack_op <= self.op_number) : (ack_op += 1) {
            const e = self.journalGet(ack_op) orelse break;
            if (!e.valid()) break;
            self.sendTo(new_leader, .{ .prepare_ok = .{
                .view_number = self.view_number,
                .op_number = ack_op,
                .replica_id = self.replica_id,
                .commit_min = self.commit_min,
            } });
        }

        if (self.hasLogGaps()) {
            self.transfer_pending = true;
            self.transfer_target_op = self.op_number;
        } else {
            self.transfer_pending = false;
            self.transfer_target_op = 0;
        }

        self.recovered_from_disk = false;
    }

    // -----------------------------------------------------------------------
    // Log forwarding helpers
    // -----------------------------------------------------------------------

    fn buildDvc(self: *const Replica) msg.DoViewChangeMsg {
        var dvc = msg.DoViewChangeMsg{
            .view_number = self.view_number,
            .replica_id = self.replica_id,
            .last_normal_view = self.last_normal_view,
            .op_number = self.op_number,
            .commit_min = self.commit_min,
            .retention_floor = self.effectiveRetentionFloor(),
        };

        for (&dvc.log_entries) |*e| {
            e.* = .{ .command = .{ .noop = {} } };
        }

        var count: u8 = 0;
        if (self.op_number > 0) {
            var scan_op = self.op_number;
            while (count < msg.DVC_LOG_MAX) : (scan_op -= 1) {
                if (self.journalHas(scan_op)) {
                    dvc.log_entries[count] = self.journalGet(scan_op).?.*;
                    count += 1;
                }
                if (scan_op <= 1) break;
            }
        }
        dvc.log_entry_count = count;

        var op: msg.OpNumber = 1;
        while (op <= self.op_number) : (op += 1) {
            if (self.journalHas(op)) {
                msg.bitsetSet(&dvc.present_bitset, @intCast(op % LOG_SIZE_MAX));
            } else {
                msg.bitsetSet(&dvc.nack_bitset, @intCast(op % LOG_SIZE_MAX));
            }
        }

        return dvc;
    }

    fn buildStartView(self: *const Replica) msg.StartViewMsg {
        var sv = msg.StartViewMsg{
            .view_number = self.view_number,
            .op_number = self.op_number,
            .commit_min = self.commit_min,
            .retention_floor = self.retention_floor,
        };

        for (&sv.log_entries) |*e| {
            e.* = .{ .command = .{ .noop = {} } };
        }

        var count: u8 = 0;
        if (self.op_number > 0) {
            var scan_op = self.op_number;
            while (count < msg.SV_LOG_MAX) : (scan_op -= 1) {
                if (self.journalHas(scan_op)) {
                    sv.log_entries[count] = self.journalGet(scan_op).?.*;
                    count += 1;
                }
                if (scan_op <= 1) break;
            }
        }
        sv.log_entry_count = count;
        return sv;
    }

    // -----------------------------------------------------------------------
    // Commit logic
    // -----------------------------------------------------------------------

    fn advanceCommit(self: *Replica) void {
        while (self.commit_max < self.op_number) {
            const next = self.commit_max + 1;
            if (!self.journalHas(next)) break;
            if (self.prepare_ok_counts[journalSlot(next)] < self.quorum_size) break;
            self.commit_max = next;
        }
        self.advanceCommitMin();
    }

    fn advanceCommitMin(self: *Replica) void {
        while (self.commit_min < self.commit_max) {
            const next = self.commit_min + 1;
            if (!self.journalHas(next)) break;
            self.commitEntry(next);
        }
    }

    fn commitUpTo(self: *Replica, target: msg.OpNumber) void {
        const limit = @min(target, self.op_number);
        self.commit_max = @max(self.commit_max, limit);
        while (self.commit_min < limit) {
            const next = self.commit_min + 1;
            if (!self.journalHas(next)) break;
            self.commitEntry(next);
        }
    }

    fn commitEntry(self: *Replica, op: msg.OpNumber) void {
        std.debug.assert(op == self.commit_min + 1);

        const entry = self.journalGet(op) orelse unreachable;
        var stop_dispatches: [sm_mod.MAX_PODS]StopDispatch = undefined;
        const stop_dispatch_count = self.collectStopDispatches(entry.command, &stop_dispatches);
        const apply_start = io_mod.nowTick(self.io);
        const result = self.state_machine.apply(entry.command);
        const apply_end = io_mod.nowTick(self.io);
        const applied_deployment_id = if (entry.command == .create_deployment and result == .ok) result.ok.entity_id else latency.deploymentId(entry.command);
        latency.record(.{ .phase = "commit_apply", .op = latency.commandName(entry.command), .deployment_id = applied_deployment_id, .pod_id = latency.podId(entry.command), .name = latency.commandNameField(entry.command), .start_ms = apply_start, .end_ms = apply_end, .source = "core/src/replica.zig" });
        self.updateClientTable(entry.client_id, entry.request_id, result);
        self.commit_min = op;
        self.replica_commit_min[self.replica_id] = self.commit_min;
        if (self.isLeader()) self.recomputeRetentionFloor();
        self.metadata_dirty = true;

        const slot = journalSlot(op);
        self.pending_reply[slot] = true;
        self.pending_reply_client_id[slot] = entry.client_id;
        self.pending_reply_request_id[slot] = entry.request_id;
        self.pending_reply_result[slot] = result;
        self.pending_effect[slot] = true;

        if (result == .ok and stop_dispatch_count > 0) {
            std.debug.assert(self.pending_stop_count + stop_dispatch_count <= MAX_PENDING_STOPS);
            for (stop_dispatches[0..stop_dispatch_count]) |dispatch| {
                self.pending_stops[self.pending_stop_count] = dispatch;
                self.pending_stop_ops[self.pending_stop_count] = op;
                self.pending_stop_count += 1;
            }
        }
    }

    fn publishCommittedEffect(self: *Replica, op: msg.OpNumber) void {
        const slot = journalSlot(op);
        std.debug.assert(self.pending_effect[slot] or self.pending_reply[slot]);
        const entry = self.journalGet(op) orelse unreachable;
        const result = self.pending_reply_result[slot];

        if (self.pending_effect[slot] and result == .ok) {
            var i: usize = 0;
            while (i < self.pending_stop_count) {
                if (self.pending_stop_ops[i] == op) {
                    const dispatch = self.pending_stops[i];
                    self.dispatchStopPodToWorker(dispatch.worker_idx, dispatch.pod_id, dispatch.grace_period_ms);
                    self.pending_stop_count -= 1;
                    self.pending_stops[i] = self.pending_stops[self.pending_stop_count];
                    self.pending_stop_ops[i] = self.pending_stop_ops[self.pending_stop_count];
                    continue;
                }
                i += 1;
            }

            if (entry.command == .register_node) {
                const node_id = result.ok.entity_id;
                const agent_marker: u128 = 0xA6E0_0000_0000_0000;
                if (entry.client_id & agent_marker == agent_marker) {
                    const worker_idx: usize = @intCast(entry.client_id & 0xFFFF);
                    if (worker_idx < self.worker_count) {
                        self.workers[worker_idx].node_id = node_id;
                        self.workers[worker_idx].pending_register = false;
                        debugLog(
                            "hivemind replica: worker_idx={d} hostname={s} assigned node_id={d}\n",
                            .{ worker_idx, msg.fixedToSlice(&self.workers[worker_idx].hostname), node_id },
                        );
                        self.dispatchPodsForWorker(worker_idx);
                    }
                }
            }

            if (entry.command == .bind_pod_to_node) {
                const cmd = entry.command.bind_pod_to_node;
                self.dispatchCommittedBind(cmd.pod_id, cmd.node_id, "bind_pod_to_node");
            }
            if (entry.command == .bind_pods_to_nodes) {
                const cmd = entry.command.bind_pods_to_nodes;
                const batch_ms = io_mod.nowTick(self.io);
                latency.record(.{ .phase = "bind_batch_commit", .op = "bind_pods_to_nodes", .deployment_id = 0, .pod_id = if (cmd.count > 0) cmd.bindings[0].pod_id else 0, .name = "", .start_ms = batch_ms, .end_ms = batch_ms, .count = cmd.count, .source = "core/src/replica.zig" });
                for (cmd.bindings[0..cmd.count]) |binding| {
                    self.dispatchCommittedBind(binding.pod_id, binding.node_id, "bind_pods_to_nodes");
                }
            }

            if (entry.command == .update_pod_status) {
                const status_cmd = entry.command.update_pod_status;
                const status_ms = io_mod.nowTick(self.io);
                const status_pod = self.state_machine.findPod(status_cmd.pod_id);
                latency.record(.{ .phase = "core_status_committed", .op = "update_pod_status", .deployment_id = if (status_pod) |p| p.deployment_id else 0, .pod_id = status_cmd.pod_id, .name = if (status_pod) |p| msg.fixedToSlice(&p.name) else "", .start_ms = status_ms, .end_ms = status_ms, .source = "core/src/replica.zig" });
                if (status_cmd.new_phase == .running) {
                    latency.record(.{ .phase = "readiness_observation", .op = "update_pod_status", .deployment_id = if (status_pod) |p| p.deployment_id else 0, .pod_id = status_cmd.pod_id, .name = if (status_pod) |p| msg.fixedToSlice(&p.name) else "", .start_ms = status_ms, .end_ms = status_ms, .source = "core/src/replica.zig" });
                }
            }
            self.pending_effect[slot] = false;
        }

        if (self.pending_reply[slot]) {
            if (self.client_reply_fn) |cb| {
                cb(
                    self.client_reply_ctx.?,
                    self.pending_reply_client_id[slot],
                    self.pending_reply_request_id[slot],
                    self.pending_reply_result[slot],
                );
            }
            self.pending_reply[slot] = false;
        }
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------

    fn markStorageFailed(self: *Replica) void {
        if (self.storage_failed) return;
        self.storage_failed = true;
        self.storage_failures += 1;
    }

    /// Group-commit flush: stage all dirty journal/metadata, one durability
    /// barrier, then publish pending Prepare/PrepareOk/client/worker traffic.
    fn flushDurableState(self: *Replica) void {
        if (self.storage_failed) return;
        var disk = self.disk orelse {
            // No disk backend: treat memory as durable and publish immediately.
            for (0..LOG_SIZE_MAX) |i| self.journal_dirty[i] = false;
            const before = self.durable_prepare_through;
            self.metadata_dirty = false;
            self.publishPendingAfterBarrier(before, self.op_number);
            self.metadata_dirty = false;
            self.publishCommitEffects();
            return;
        };

        var barriers: u8 = 0;
        while (barriers < FLUSH_BARRIER_MAX) : (barriers += 1) {
            var any_journal_dirty = false;
            const prepare_through_before = self.durable_prepare_through;

            for (0..LOG_SIZE_MAX) |i| {
                if (!self.journal_dirty[i]) continue;
                any_journal_dirty = true;
                if (self.journal_occupied[i]) {
                    disk.writeSlot(i, &self.journal[i]) catch {
                        self.markStorageFailed();
                        return;
                    };
                } else {
                    disk.clearSlot(i) catch {
                        self.markStorageFailed();
                        return;
                    };
                }
            }

            const meta = disk_mod.Metadata{
                .view_number = self.view_number,
                .last_normal_view = self.last_normal_view,
                .op_number = self.op_number,
                .commit_min = self.commit_min,
                .commit_max = self.commit_max,
            };
            const need_meta = self.metadata_dirty or any_journal_dirty or !disk.metadataEquals(meta);
            if (need_meta) {
                disk.writeMetadata(meta) catch {
                    self.markStorageFailed();
                    return;
                };
                self.metadata_dirty = true;
            }

            if (!any_journal_dirty and !self.metadata_dirty) {
                self.publishPendingAfterBarrier(prepare_through_before, self.durable_prepare_through);
                return;
            }

            disk.sync() catch {
                self.markStorageFailed();
                return;
            };

            for (0..LOG_SIZE_MAX) |i| {
                self.journal_dirty[i] = false;
            }
            self.metadata_dirty = false;

            self.publishPendingAfterBarrier(prepare_through_before, self.op_number);

            if (!self.metadata_dirty and !anyJournalDirty(self)) break;
        }
        std.debug.assert(barriers < FLUSH_BARRIER_MAX or (!self.metadata_dirty and !anyJournalDirty(self)));
    }

    fn anyJournalDirty(self: *const Replica) bool {
        for (self.journal_dirty) |d| {
            if (d) return true;
        }
        return false;
    }

    fn publishCommitEffects(self: *Replica) void {
        var op: msg.OpNumber = 1;
        while (op <= self.commit_min) : (op += 1) {
            const slot = journalSlot(op);
            if (self.pending_reply[slot] or self.pending_effect[slot]) {
                if (self.journalHas(op)) {
                    self.publishCommittedEffect(op);
                }
            }
        }
    }

    fn publishPendingAfterBarrier(self: *Replica, prepare_through_before: msg.OpNumber, prepare_through_after: msg.OpNumber) void {
        _ = prepare_through_before;

        var op: msg.OpNumber = 1;
        while (op <= prepare_through_after) : (op += 1) {
            const slot = journalSlot(op);
            if (!self.journalHas(op)) continue;

            if (self.pending_prepare_broadcast[slot] and self.journal[slot].op_number == op) {
                const entry = self.journal[slot];
                self.sendToAllOthers(.{ .prepare = .{
                    .view_number = self.view_number,
                    .op_number = op,
                    .commit_min = self.commit_min,
                    .retention_floor = self.retention_floor,
                    .entry = entry,
                } });
                self.prepare_ok_counts[slot] = 1;
                self.prepare_ok_from[slot] = @as(u16, 1) << @intCast(self.replica_id);
                self.pending_prepare_broadcast[slot] = false;
            }

            if (self.pending_prepare_ok[slot] and self.journal[slot].op_number == op) {
                const to = self.pending_prepare_ok_to[slot];
                self.sendTo(to, .{ .prepare_ok = .{
                    .view_number = self.view_number,
                    .op_number = op,
                    .replica_id = self.replica_id,
                    .commit_min = self.commit_min,
                } });
                self.pending_prepare_ok[slot] = false;
            }
        }
        self.durable_prepare_through = @max(self.durable_prepare_through, prepare_through_after);

        if (self.isLeader() and self.status == .normal) {
            self.advanceCommit();
        }

        // Client/worker publication waits until commit metadata is not dirty
        // (covered by the barrier that just succeeded, or a subsequent one).
        if (self.metadata_dirty) return;
        self.publishCommitEffects();
    }

    // -----------------------------------------------------------------------
    // Journal access (slot-indexed: slot = op % LOG_SIZE_MAX)
    // -----------------------------------------------------------------------

    pub fn journalHas(self: *const Replica, op: msg.OpNumber) bool {
        if (op == 0) return false;
        const slot = journalSlot(op);
        return self.journal_occupied[slot] and self.journal[slot].op_number == op;
    }

    pub fn journalGet(self: *const Replica, op: msg.OpNumber) ?*const msg.LogEntry {
        if (op == 0) return null;
        const slot = journalSlot(op);
        if (self.journal_occupied[slot] and self.journal[slot].op_number == op) {
            return &self.journal[slot];
        }
        return null;
    }

    fn journalGetMut(self: *Replica, op: msg.OpNumber) ?*msg.LogEntry {
        if (op == 0) return null;
        const slot = journalSlot(op);
        if (self.journal_occupied[slot] and self.journal[slot].op_number == op) {
            return &self.journal[slot];
        }
        return null;
    }

    pub fn journalPut(self: *Replica, entry: msg.LogEntry) void {
        std.debug.assert(entry.op_number > 0);
        // Without a snapshot floor, never replace an occupied slot with a different op.
        std.debug.assert(entry.op_number <= LOG_SIZE_MAX);
        const slot = journalSlot(entry.op_number);
        if (self.journal_occupied[slot] and
            (self.journal[slot].op_number != entry.op_number or
                self.journal[slot].checksum != entry.checksum))
        {
            // Reject stale overwrites (older op landing on a slot already
            // holding a newer one). Different-op replacement is forbidden
            // until snapshots exist.
            if (entry.op_number != self.journal[slot].op_number) {
                std.debug.assert(false);
                return;
            }
            if (entry.op_number < self.journal[slot].op_number) return;
            self.prepare_ok_counts[slot] = 0;
            self.prepare_ok_from[slot] = 0;
        }
        self.journal[slot] = entry;
        self.journal_occupied[slot] = true;
        self.journal_dirty[slot] = true;
    }

    fn truncateAbove(self: *Replica, limit: msg.OpNumber) void {
        for (0..LOG_SIZE_MAX) |i| {
            if (!self.journal_occupied[i]) continue;
            if (self.journal[i].op_number > limit and self.journal[i].op_number > self.commit_min) {
                self.journal_occupied[i] = false;
                self.prepare_ok_counts[i] = 0;
                self.prepare_ok_from[i] = 0;
                self.journal_dirty[i] = true;
            }
        }
    }

    pub fn logHighOp(self: *const Replica) msg.OpNumber {
        var highest: msg.OpNumber = 0;
        for (0..LOG_SIZE_MAX) |i| {
            if (self.journal_occupied[i] and self.journal[i].op_number > highest) {
                highest = self.journal[i].op_number;
            }
        }
        return highest;
    }

    fn lastChecksum(self: *const Replica) u64 {
        if (self.op_number <= 1) return 0;
        if (self.journalGet(self.op_number - 1)) |entry| return entry.checksum;
        return 0;
    }

    fn hasLogGaps(self: *const Replica) bool {
        var op = self.commit_min + 1;
        while (op <= self.op_number) : (op += 1) {
            if (!self.journalHas(op)) return true;
        }
        return false;
    }

    fn entryFitsLog(self: *const Replica, entry: msg.LogEntry) bool {
        if (entry.op_number == 0) return false;

        if (self.journalGet(entry.op_number)) |existing| {
            if (existing.checksum != entry.checksum) return false;
        }

        if (entry.op_number == 1) {
            if (entry.parent_checksum != 0) return false;
        } else if (self.journalGet(entry.op_number - 1)) |prev| {
            if (prev.checksum != entry.parent_checksum) return false;
        }

        if (self.journalGet(entry.op_number + 1)) |next| {
            if (next.parent_checksum != entry.checksum) return false;
        }

        return true;
    }

    fn rebuildCommittedState(self: *Replica, target_commit: msg.OpNumber) !void {
        self.state_machine.initInPlace(self.state_machine.seed);
        self.client_count = 0;

        var op: msg.OpNumber = 1;
        var parent: u64 = 0;
        while (op <= target_commit) : (op += 1) {
            const entry = self.journalGet(op) orelse return error.CorruptJournal;
            if (!entry.valid()) return error.CorruptJournal;
            if (op == 1) {
                if (entry.parent_checksum != 0) return error.CorruptJournal;
            } else if (entry.parent_checksum != parent) {
                return error.CorruptJournal;
            }
            const result = self.state_machine.apply(entry.command);
            self.updateClientTable(entry.client_id, entry.request_id, result);
            parent = entry.checksum;
        }
    }

    fn findClient(self: *const Replica, client_id: u128) ?*const ClientEntry {
        for (self.client_table[0..self.client_count]) |*entry| {
            if (entry.client_id == client_id and entry.active) return entry;
        }
        return null;
    }

    fn hasPendingRequest(self: *const Replica, client_id: u128, request_id: msg.RequestId) bool {
        var op = self.commit_max + 1;
        while (op <= self.op_number) : (op += 1) {
            const slot = journalSlot(op);
            if (!self.journal_occupied[slot]) continue;
            const entry = self.journal[slot];
            if (entry.op_number != op) continue;
            if (entry.client_id == client_id and entry.request_id == request_id) return true;
        }
        return false;
    }

    fn updateClientTable(self: *Replica, client_id: u128, request_id: msg.RequestId, result: msg.Result) void {
        for (self.client_table[0..self.client_count]) |*entry| {
            if (entry.client_id == client_id) {
                entry.request_id = request_id;
                entry.result = result;
                return;
            }
        }
        if (self.client_count < CLIENT_TABLE_MAX) {
            self.client_table[self.client_count] = .{
                .client_id = client_id,
                .request_id = request_id,
                .result = result,
                .active = true,
            };
            self.client_count += 1;
        }
    }

    // -----------------------------------------------------------------------
    // Network helpers
    // -----------------------------------------------------------------------

    fn resendUncommittedPrepares(self: *Replica) void {
        var resend_op = self.commit_min + 1;
        while (resend_op <= self.op_number) : (resend_op += 1) {
            if (self.journalGet(resend_op)) |entry| {
                const slot = journalSlot(resend_op);
                if (self.prepare_ok_counts[slot] < self.quorum_size) {
                    self.sendToAllOthers(.{ .prepare = .{
                        .view_number = self.view_number,
                        .op_number = resend_op,
                        .commit_min = self.commit_min,
                        .retention_floor = self.retention_floor,
                        .entry = entry.*,
                    } });
                }
            }
        }
    }

    fn sendCommitHeartbeat(self: *Replica) void {
        const target = @max(self.commit_min, self.commit_max);
        const commit_checksum = if (target > 0) blk: {
            const entry = self.journalGet(target) orelse break :blk 0;
            break :blk entry.checksum;
        } else 0;
        self.sendToAllOthers(.{ .commit = .{
            .view_number = self.view_number,
            .commit_min = self.commit_min,
            .commit_max = self.commit_max,
            .op_number = self.op_number,
            .retention_floor = self.retention_floor,
            .commit_checksum = commit_checksum,
        } });
    }

    fn sendToAll(self: *Replica, message: msg.Message) void {
        var i: u8 = 0;
        while (i < self.replica_count) : (i += 1) {
            self.sendTo(i, message);
        }
    }

    fn sendToAllOthers(self: *Replica, message: msg.Message) void {
        var i: u8 = 0;
        while (i < self.replica_count) : (i += 1) {
            if (i != self.replica_id) self.sendTo(i, message);
        }
    }

    fn sendTo(self: *Replica, to: u8, message: msg.Message) void {
        if (self.storage_failed) return;
        // Frame format: [4-byte LE len][1-byte from_id][VRR message bytes]
        const vrr_len = msg.serialize(message, self.send_buf[5..]);
        const frame_len: u32 = @intCast(1 + vrr_len);
        @memcpy(self.send_buf[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, frame_len)));
        self.send_buf[4] = self.replica_id;
        const total = 5 + vrr_len;

        // Production: send via callback
        if (self.peer_send_fn) |cb| {
            cb(self.peer_send_ctx.?, to, self.send_buf[0..total]);
            return;
        }

        // Simulation: send via Io vtable
        const handle = self.peer_handles[to];
        _ = self.io.vtable.netWrite(self.io.userdata, handle, self.send_buf[0..total], &.{}, 0) catch {};
    }

    fn defaultPeerHandles() [msg.REPLICA_COUNT_MAX]std.Io.net.Socket.Handle {
        var handles: [msg.REPLICA_COUNT_MAX]std.Io.net.Socket.Handle = undefined;
        for (0..msg.REPLICA_COUNT_MAX) |i| {
            handles[i] = @intCast(i);
        }
        return handles;
    }

    pub fn setDisconnectedPeerHandles(self: *Replica) void {
        for (&self.peer_handles) |*h| {
            h.* = -1;
        }
    }
};

const DispatchRecord = struct {
    worker_idx: usize,
    tag: u8,
    pod_id: u64,
    grace_period_ms: u64,
};

const ReplicaDispatchCapture = struct {
    count: usize = 0,
    records: [64]DispatchRecord = undefined,

    fn send(ctx: ?*anyopaque, worker_idx: usize, data: []const u8) void {
        const capture: *ReplicaDispatchCapture = @ptrCast(@alignCast(ctx.?));
        if (capture.count >= capture.records.len or data.len < 15) return;
        const tag = data[6];
        const pod_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[7..15]));
        const grace_period_ms = if (tag == @intFromEnum(msg.WorkerTag.stop_pod) and data.len >= 23)
            std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[15..23]))
        else
            0;
        capture.records[capture.count] = .{
            .worker_idx = worker_idx,
            .tag = tag,
            .pod_id = pod_id,
            .grace_period_ms = grace_period_ms,
        };
        capture.count += 1;
    }
};

test "duplicate in-flight scheduler request is ignored before commit" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1234);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    const req: msg.RequestMsg = .{
        .client_id = 42,
        .request_id = 42,
        .command = .{ .bind_pod_to_node = .{ .pod_id = 7, .node_id = 9 } },
    };

    replica.onRequest(0, req);
    try std.testing.expectEqual(@as(u64, 1), replica.op_number);
    try std.testing.expect(replica.hasPendingRequest(42, 42));

    replica.onRequest(0, req);
    try std.testing.expectEqual(@as(u64, 1), replica.op_number);
}

test "worker re-registration bypasses prior agent client-table entry" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(2345);
    var current_tick: i64 = 10;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(2345, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(2345);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const worker_idx: usize = 0;
    const client_id: u128 = 0xA6E0_0000_0000_0000 | @as(u128, worker_idx);
    replica.client_table[0] = .{
        .client_id = client_id,
        .request_id = 1,
        .result = .{ .ok = .{ .entity_id = 9 } },
        .active = true,
    };
    replica.client_count = 1;

    replica.onWorkerRegister(worker_idx, .{
        .hostname = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    });
    replica.tick();

    try std.testing.expectEqual(@as(u64, 1), replica.op_number);
    try std.testing.expect(replica.workers[worker_idx].node_id != 0);
    try std.testing.expect(!replica.workers[worker_idx].pending_register);
    try std.testing.expect(replica.client_table[0].request_id > 1);
}

test "dispatchPodToWorker emits start_pod frame for bound node" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1234);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } }).ok.entity_id;

    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "docker.io/mendhak/http-https-echo:31"),
        .port = 8080,
        .replicas = 1,
        .cpu_millicores = 250,
        .memory_megabytes = 128,
    } });

    const pod_id = sm.pods[0].id;
    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
    };

    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.dispatchPodToWorker(pod_id, node_id);

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), capture.records[0].worker_idx);
    try std.testing.expectEqual(@as(u8, 0x02), capture.records[0].tag);
    try std.testing.expectEqual(pod_id, capture.records[0].pod_id);
}

fn makeCommittedEntry(op_number: u64, command: msg.Command) msg.LogEntry {
    var entry = msg.LogEntry{
        .view_number = 0,
        .op_number = op_number,
        .command = command,
        .client_id = op_number,
        .request_id = op_number,
    };
    entry.checksum = entry.computeChecksum();
    return entry;
}

test "worker re-registration redispatches bound active pods" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(3456);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(3456, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(3456);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } }).ok.entity_id;
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .cpu_millicores = 250,
        .memory_megabytes = 128,
    } });
    const pod_id = sm.pods[0].id;
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });
    _ = sm.apply(.{ .update_pod_status = .{ .pod_id = pod_id, .new_phase = .running } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
    };
    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.dispatchPodsForWorker(0);

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@intFromEnum(msg.WorkerTag.start_pod), capture.records[0].tag);
    try std.testing.expectEqual(pod_id, capture.records[0].pod_id);
}

test "worker heartbeat retries scheduled pod dispatch" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4567);
    var current_tick: i64 = 10_000;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4567, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4567);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } }).ok.entity_id;
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .cpu_millicores = 250,
        .memory_megabytes = 128,
    } });
    const pod_id = sm.pods[0].id;
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
        .last_dispatch_retry_tick = 0,
    };
    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.onWorkerHeartbeat(0, .{});

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@intFromEnum(msg.WorkerTag.start_pod), capture.records[0].tag);
    try std.testing.expectEqual(pod_id, capture.records[0].pod_id);
}

test "worker heartbeat dispatch retry is bounded" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(5678);
    var current_tick: i64 = 10_000;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(5678, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(5678);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 1000,
        .memory_megabytes = 1024,
    } }).ok.entity_id;
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .cpu_millicores = 250,
        .memory_megabytes = 128,
    } });
    const pod_id = sm.pods[0].id;
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
        .last_dispatch_retry_tick = 0,
    };
    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.onWorkerHeartbeat(0, .{});
    current_tick += WORKER_DISPATCH_RETRY_INTERVAL - 1;
    replica.onWorkerHeartbeat(0, .{});
    current_tick += 1;
    replica.onWorkerHeartbeat(0, .{});

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(pod_id, capture.records[0].pod_id);
    try std.testing.expectEqual(pod_id, capture.records[1].pod_id);
}

test "commitEntry delete_deployment emits stop_pod for bound worker" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1234);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .gpu_type = .t4,
        .gpu_count = 1,
    } }).ok.entity_id;
    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "echo:v1"),
        .replicas = 1,
        .gpu_type = .t4,
        .gpu_count = 1,
    } }).ok.entity_id;
    const pod_id = sm.pods[0].id;
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
    };

    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.journalPut(makeCommittedEntry(1, .{ .delete_deployment = .{ .deployment_id = dep_id } }));
    replica.commitEntry(1);
    replica.tick();

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@intFromEnum(msg.WorkerTag.stop_pod), capture.records[0].tag);
    try std.testing.expectEqual(pod_id, capture.records[0].pod_id);
    try std.testing.expectEqual(DEFAULT_STOP_GRACE_MS, capture.records[0].grace_period_ms);
}

test "commitEntry scale down emits stop_pod for removed bound pod" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1234);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } }).ok.entity_id;
    const dep_id = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "api"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "api:v1"),
        .replicas = 2,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } }).ok.entity_id;

    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = sm.pods[0].id, .node_id = node_id } });
    _ = sm.apply(.{ .bind_pod_to_node = .{ .pod_id = sm.pods[1].id, .node_id = node_id } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
        .connected = true,
    };

    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    replica.journalPut(makeCommittedEntry(1, .{ .scale_deployment = .{
        .deployment_id = dep_id,
        .desired_replicas = 1,
    } }));
    replica.commitEntry(1);
    replica.tick();

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@intFromEnum(msg.WorkerTag.stop_pod), capture.records[0].tag);
    try std.testing.expectEqual(sm.pods[0].id, capture.records[0].pod_id);
}

test "tickScheduler submits one batch bind command for 50 actions" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(6001);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(6001, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(6001);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    _ = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } });
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "nginx"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 50,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } });

    replica.tickScheduler();
    try std.testing.expectEqual(@as(u64, 1), replica.op_number);
    const entry = replica.journalGet(1).?;
    try std.testing.expect(entry.command == .bind_pods_to_nodes);
    try std.testing.expectEqual(@as(u8, 50), entry.command.bind_pods_to_nodes.count);
}

test "committed batch bind dispatches all bound pods to worker" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(6002);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(6002, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(6002);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    const node_id = sm.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "worker-01"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } }).ok.entity_id;
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "nginx"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "nginx"),
        .replicas = 3,
        .cpu_millicores = 10,
        .memory_megabytes = 16,
    } });

    replica.worker_count = 1;
    replica.workers[0] = .{
        .connected = true,
        .node_id = node_id,
        .hostname = msg.strToFixed(64, "worker-01"),
    };
    var capture = ReplicaDispatchCapture{};
    replica.worker_send_ctx = &capture;
    replica.worker_send_fn = ReplicaDispatchCapture.send;

    var cmd = msg.BindPodsToNodesCmd{ .count = 3 };
    for (sm.pods[0..3], 0..) |pod, i| cmd.bindings[i] = .{ .pod_id = pod.id, .node_id = node_id };
    replica.onRequest(0, .{ .client_id = 0xB17D, .request_id = 1, .command = .{ .bind_pods_to_nodes = cmd } });
    replica.tick();

    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqual(@intFromEnum(msg.WorkerTag.start_pod), capture.records[0].tag);
    try std.testing.expectEqual(sm.pods[0].id, capture.records[0].pod_id);
    try std.testing.expectEqual(sm.pods[1].id, capture.records[1].pod_id);
    try std.testing.expectEqual(sm.pods[2].id, capture.records[2].pod_id);
}
