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
const view_candidate = @import("view_change_candidate.zig");
pub const DiskInterface = disk_mod.DiskInterface;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const LOG_SIZE_MAX: usize = msg.LOG_BITSET_BITS;
/// One committed operation can introduce one unique client. Retain dedup for
/// the entire unsnapshotted journal lifetime.
pub const CLIENT_TABLE_MAX: usize = LOG_SIZE_MAX;
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

/// Prepare wire/semantics gate used before onPrepare mutates view/status/log.
fn prepareSemanticsValid(prepare: msg.PrepareMsg) bool {
    if (prepare.op_number == 0 or prepare.op_number > LOG_SIZE_MAX) return false;
    if (prepare.commit_min > prepare.op_number) return false;
    if (prepare.retention_floor != 0) return false;
    if (prepare.entry.op_number != prepare.op_number) return false;
    if (!prepare.entry.valid()) return false;
    return true;
}

/// Commit wire/semantics gate used before onCommit mutates view/status/log.
fn commitSemanticsValid(commit: msg.CommitMsg) bool {
    if (commit.op_number > LOG_SIZE_MAX) return false;
    if (commit.commit_min > LOG_SIZE_MAX) return false;
    if (commit.commit_max > LOG_SIZE_MAX) return false;
    if (commit.retention_floor != 0) return false;
    if (commit.commit_min > commit.op_number) return false;
    if (commit.commit_max > commit.op_number) return false;
    return true;
}

/// StartView entry-set gate: bounds, no op above sv.op_number, no duplicate/conflict identities.
fn startViewEntriesValid(sv: msg.StartViewMsg) bool {
    if (sv.commit_min > sv.op_number or sv.op_number > LOG_SIZE_MAX) return false;
    if (sv.retention_floor != 0) return false;
    if (sv.selected_last_normal_view > sv.view_number) return false;
    if ((sv.op_number == 0) != (sv.tip_checksum == 0)) return false;
    if (sv.log_entry_count > msg.SV_LOG_MAX) return false;
    var i: usize = 0;
    while (i < sv.log_entry_count) : (i += 1) {
        const entry = sv.log_entries[i];
        if (entry.op_number < 1 or entry.op_number > LOG_SIZE_MAX) return false;
        if (!entry.valid()) return false;
        if (entry.op_number > sv.op_number) return false;
        var j: usize = i + 1;
        while (j < sv.log_entry_count) : (j += 1) {
            if (sv.log_entries[j].op_number == entry.op_number) return false;
        }
    }
    return true;
}

fn selectionBindingValid(source: u8, tip_op: msg.OpNumber, tip_checksum: u64) bool {
    if (tip_checksum == 0) return source == 0 and tip_op == 0;
    return source < msg.REPLICA_COUNT_MAX and tip_op > 0 and tip_op <= LOG_SIZE_MAX;
}

/// Stateless peer-message semantics checked before a socket may claim identity.
pub fn peerMessageSemanticsValid(message: msg.Message) bool {
    return switch (message) {
        .prepare => |m| prepareSemanticsValid(m),
        // A late ack may report a commit watermark above the acked op.
        .prepare_ok => |m| m.op_number > 0 and m.op_number <= LOG_SIZE_MAX and m.commit_min <= LOG_SIZE_MAX and m.entry_checksum != 0 and ((m.commit_min == 0) == (m.commit_checksum == 0)),
        .commit => |m| commitSemanticsValid(m),
        .do_view_change => |m| blk: {
            if (m.commit_min > m.op_number or m.op_number > LOG_SIZE_MAX) break :blk false;
            if (m.retention_floor != 0) break :blk false;
            if (m.log_entry_count > msg.DVC_LOG_MAX) break :blk false;
            for (m.log_entries[0..m.log_entry_count]) |entry| {
                if (entry.op_number == 0 or entry.op_number > m.op_number or !entry.valid()) break :blk false;
            }
            break :blk true;
        },
        .start_view => |m| startViewEntriesValid(m),
        .request_prepare => |m| m.op_number > 0 and m.op_number <= LOG_SIZE_MAX and m.selected_commit_bound <= m.selected_tip_op and selectionBindingValid(m.selected_source, m.selected_tip_op, m.selected_tip_checksum) and ((m.selected_tip_checksum == 0) == (m.expected_entry_checksum == 0)),
        .send_prepare => |m| m.entry.op_number > 0 and m.entry.op_number <= LOG_SIZE_MAX and m.entry.valid() and m.selected_commit_bound <= m.selected_tip_op and selectionBindingValid(m.selected_source, m.selected_tip_op, m.selected_tip_checksum) and ((m.selected_tip_checksum == 0) == (m.expected_entry_checksum == 0)),
        .send_status => |m| m.commit_min <= m.op_number and m.op_number <= LOG_SIZE_MAX and ((m.op_number == 0) == (m.tip_checksum == 0)) and ((m.commit_min == 0) == (m.commit_checksum == 0)),
        .request,
        .reply,
        .start_view_change,
        .request_status,
        .request_start_view,
        => true,
    };
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

pub const CLIENT_TABLE_MEMORY_BYTES: usize = CLIENT_TABLE_MAX * @sizeOf(ClientEntry);
comptime {
    std.debug.assert(CLIENT_TABLE_MAX >= LOG_SIZE_MAX);
    std.debug.assert(CLIENT_TABLE_MEMORY_BYTES <= 128 * 1024);
}

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
    // Direct constructors default to a build-valid allocator to bound test churn.
    // Production and TestCluster owners inject their allocator explicitly.
    allocator: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator,
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

pub const BarrierKind = enum { prepare, commit, leader_start_view, follower_start_view };
pub const BarrierCutPoint = enum { before_slot_write, before_metadata_write, before_sync, before_publication };
pub const BarrierCut = struct { id: u64, kind: BarrierKind, point: BarrierCutPoint };

pub const Replica = struct {
    // Configuration
    allocator: std.mem.Allocator,
    view_change_candidate: view_candidate.ViewChangeCandidate,
    pending_start_view: view_candidate.PendingStartView,
    deferred_view_target: msg.ViewNumber,
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
    pending_view_selection: bool,
    selected_source: u8,
    selected_last_normal_view: msg.ViewNumber,
    selected_tip_op: msg.OpNumber,
    selected_tip_checksum: u64,
    selected_commit_bound: msg.OpNumber,
    selected_retention_floor: msg.OpNumber,
    selected_target_view: msg.ViewNumber,
    selected_next_op: msg.OpNumber,
    selected_expected_checksum: u64,
    selected_sources_attempted: u16,
    selected_sources_requested: u16,

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
    /// Protocol causes covered by the next normal group-commit barrier.
    pending_prepare_barrier: bool,
    pending_commit_barrier: bool,
    disk: ?DiskInterface,
    /// Fail-stop: disk write/sync failed; no further consensus/client/worker traffic.
    storage_failed: bool,
    barrier_cut: ?BarrierCut,
    barrier_cut_count: u64,
    last_barrier_cut_id: u64,

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
    /// Not sufficient alone: same-op replacements require identity checks.
    durable_prepare_through: msg.OpNumber,
    /// Per-slot durable prepare identity after a successful barrier.
    durable_prepare_op: [LOG_SIZE_MAX]msg.OpNumber,
    durable_prepare_checksum: [LOG_SIZE_MAX]u64,

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
            .allocator = config.allocator,
            .view_change_candidate = .{ .allocator = config.allocator },
            .pending_start_view = .{},
            .deferred_view_target = 0,
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
            .pending_view_selection = false,
            .selected_source = 0,
            .selected_last_normal_view = 0,
            .selected_tip_op = 0,
            .selected_tip_checksum = 0,
            .selected_commit_bound = 0,
            .selected_retention_floor = 0,
            .selected_target_view = 0,
            .selected_next_op = 0,
            .selected_expected_checksum = 0,
            .selected_sources_attempted = 0,
            .selected_sources_requested = 0,
            .repair_pending = false,
            .repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64),
            .repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool),
            .repair_status_count = 0,
            .transfer_pending = false,
            .transfer_target_op = 0,
            .journal_dirty = std.mem.zeroes([LOG_SIZE_MAX]bool),
            .metadata_dirty = false,
            .pending_prepare_barrier = false,
            .pending_commit_barrier = false,
            .disk = config.disk,
            .storage_failed = false,
            .barrier_cut = null,
            .barrier_cut_count = 0,
            .last_barrier_cut_id = 0,
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
            .durable_prepare_op = std.mem.zeroes([LOG_SIZE_MAX]msg.OpNumber),
            .durable_prepare_checksum = std.mem.zeroes([LOG_SIZE_MAX]u64),
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
        self.allocator = config.allocator;
        self.view_change_candidate = .{ .allocator = config.allocator };
        self.pending_start_view = .{};
        self.deferred_view_target = 0;
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
        self.pending_view_selection = false;
        self.selected_expected_checksum = 0;
        self.selected_sources_attempted = 0;
        self.selected_sources_requested = 0;
        self.repair_pending = false;
        self.repair_present = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.LOG_BITSET_WORDS]u64);
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
        self.transfer_pending = false;
        self.transfer_target_op = 0;
        self.journal_dirty = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.metadata_dirty = false;
        self.pending_prepare_barrier = false;
        self.pending_commit_barrier = false;
        self.disk = config.disk;
        self.storage_failed = false;
        self.barrier_cut = null;
        self.barrier_cut_count = 0;
        self.last_barrier_cut_id = 0;
        self.pending_prepare_broadcast = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok_to = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.pending_reply = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_reply_client_id = std.mem.zeroes([LOG_SIZE_MAX]u128);
        self.pending_reply_request_id = std.mem.zeroes([LOG_SIZE_MAX]msg.RequestId);
        self.pending_effect = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_stop_count = 0;
        self.durable_prepare_through = 0;
        self.durable_prepare_op = std.mem.zeroes([LOG_SIZE_MAX]msg.OpNumber);
        self.durable_prepare_checksum = std.mem.zeroes([LOG_SIZE_MAX]u64);
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
        self.assertCandidateOwnership();
    }

    fn assertCandidateOwnership(self: *const Replica) void {
        std.debug.assert(self.view_change_candidate.allocator != null);
        if (self.view_change_candidate.phase == .idle) {
            std.debug.assert(self.view_change_candidate.entries.len == 0);
            std.debug.assert(self.view_change_candidate.present.len == 0);
            std.debug.assert(!self.pending_start_view.active);
        }
        if (self.pending_start_view.active) {
            std.debug.assert(self.pending_start_view.role == .leader);
            std.debug.assert(self.view_change_candidate.phase == .persisting_start_view);
        }
    }

    pub fn deinit(self: *Replica) void {
        self.view_change_candidate.deinit();
        std.debug.assert(self.view_change_candidate.allocator == null);
        std.debug.assert(self.view_change_candidate.entries.len == 0);
        std.debug.assert(self.view_change_candidate.present.len == 0);
    }

    pub fn resetInPlace(self: *Replica, config: ReplicaConfig) void {
        self.deinit();
        self.initInPlace(config);
    }

    /// Recover state from disk after a crash. Restores metadata and journal
    /// entries, then sets status to view_change to rejoin the cluster.
    /// Returns false when no durable metadata exists. Returns error on
    /// corrupt/missing committed prefix.
    pub fn recoverFromDisk(self: *Replica) !bool {
        var disk = self.disk orelse return false;

        const meta = disk.readMetadata() orelse return false;
        if (meta.commit_min > meta.commit_max) return error.CorruptMetadata;
        if (meta.commit_max > meta.op_number) return error.CorruptMetadata;
        if (meta.op_number > LOG_SIZE_MAX) return error.CorruptMetadata;
        if (meta.last_normal_view > meta.view_number) return error.CorruptMetadata;

        self.view_number = meta.view_number;
        self.last_normal_view = meta.last_normal_view;
        self.op_number = meta.op_number;
        self.commit_min = meta.commit_min;
        self.commit_max = meta.commit_max;
        self.retention_floor = 0;
        self.replica_commit_min = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber);
        self.replica_commit_min[self.replica_id] = self.commit_min;
        self.durable_prepare_through = self.op_number;
        self.durable_prepare_op = std.mem.zeroes([LOG_SIZE_MAX]msg.OpNumber);
        self.durable_prepare_checksum = std.mem.zeroes([LOG_SIZE_MAX]u64);

        // Restore journal entries from disk
        self.journal_occupied = std.mem.zeroes([LOG_SIZE_MAX]bool);
        for (0..LOG_SIZE_MAX) |i| {
            if (disk.readSlot(i)) |entry| {
                if (entry.op_number > 0 and entry.valid()) {
                    self.journal[i] = entry;
                    self.journal_occupied[i] = true;
                    if (entry.op_number <= self.op_number) {
                        self.durable_prepare_op[i] = entry.op_number;
                        self.durable_prepare_checksum[i] = entry.checksum;
                    }
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
        self.pending_prepare_barrier = false;
        self.pending_commit_barrier = false;
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
        self.pending_view_selection = false;

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

    /// Snapshots are not implemented. Every retained op remains repairable for
    /// the full fail-closed LOG_SIZE_MAX lifetime.
    fn effectiveRetentionFloor(self: *const Replica) msg.OpNumber {
        _ = self;
        return 0;
    }

    fn recomputeRetentionFloor(self: *Replica) void {
        self.retention_floor = 0;
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
                if (self.pending_start_view.active) {
                    std.debug.assert(self.view_change_candidate.phase == .persisting_start_view);
                } else if (self.pending_view_selection) {
                    const deadline_tick = self.view_change_candidate.metadata.deadline_tick;
                    if (deadline_tick > 0 and now_tick >= 0 and @as(u64, @intCast(now_tick)) >= deadline_tick) {
                        self.abortSelectedView();
                    } else {
                        self.advanceSelectedView();
                    }
                } else {
                    const timeout = if (self.recovered_from_disk)
                        RECOVERED_VIEW_CHANGE_TIMEOUT
                    else
                        VIEW_CHANGE_TIMEOUT * 2;
                    if (now_tick - self.last_leader_activity >= timeout) {
                        self.initiateViewChange();
                    }
                }
            },
            .recovering => {},
        }

        self.flushDurableState();
    }

    // -----------------------------------------------------------------------
    // Message dispatch
    // -----------------------------------------------------------------------

    fn deferredHigherViewTarget(self: *const Replica, from: u8, message: msg.Message) ?msg.ViewNumber {
        return switch (message) {
            .start_view_change => |m| if (m.replica_id == from) m.view_number else null,
            .prepare => |m| if (from == self.leaderForView(m.view_number) and prepareSemanticsValid(m)) m.view_number else null,
            .commit => |m| if (from == self.leaderForView(m.view_number) and commitSemanticsValid(m)) m.view_number else null,
            .start_view => |m| if (from == self.leaderForView(m.view_number) and startViewEntriesValid(m)) m.view_number else null,
            else => null,
        };
    }

    pub fn onMessage(self: *Replica, from: u8, message: msg.Message) void {
        if (self.storage_failed) return;
        // Peer-sourced `from` must be a live cluster member. Out-of-range IDs
        // would OOB-index vote/status arrays or forge quorum identity.
        if (from >= self.replica_count) return;
        if (self.pending_start_view.active) {
            if (self.deferredHigherViewTarget(from, message)) |message_view| {
                if (message_view > self.pending_start_view.target_view) {
                    self.deferred_view_target = @max(self.deferred_view_target, message_view);
                }
            }
            // The installed candidate is immutable until its publication point.
            // Selection-bound RequestPrepare is read-only and must remain
            // serviceable while a later StartView waits on its barrier.
            if (message != .request and message != .reply and message != .request_prepare) return;
        }
        if (self.pending_view_selection and self.leaderForView(self.selected_target_view) != self.replica_id) {
            switch (message) {
                .send_prepare, .start_view, .start_view_change, .request_prepare => {},
                else => return,
            }
        }
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
            .request_start_view => |m| self.onRequestStartView(from, m),
            .reply => {},
        }
    }

    fn peerLogBoundsOk(commit_min: msg.OpNumber, op_number: msg.OpNumber) bool {
        return commit_min <= op_number and op_number <= LOG_SIZE_MAX;
    }

    fn peerOpInRetainedLog(op: msg.OpNumber) bool {
        return op >= 1 and op <= LOG_SIZE_MAX;
    }

    fn peerCommitInRetainedLog(commit_min: msg.OpNumber) bool {
        return commit_min <= LOG_SIZE_MAX;
    }

    fn peerLogEntriesOk(entries: []const msg.LogEntry, count: usize, max_count: usize) bool {
        if (count > max_count) return false;
        for (entries[0..count]) |entry| {
            if (!peerOpInRetainedLog(entry.op_number)) return false;
            if (!entry.valid()) return false;
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Normal operation
    // -----------------------------------------------------------------------

    fn onRequest(self: *Replica, _: u8, request: msg.RequestMsg) void {
        if (self.status != .normal) return;
        if (!self.isLeader()) return;
        if (self.repair_pending) return;
        if (self.storage_failed) return;

        // Client table dedup — only replay results that have already passed
        // the commit durability barrier. Unpublished pending replies must not
        // be acknowledged from the in-memory client table.
        if (self.hasPendingClientReply(request.client_id, request.request_id)) return;
        if (self.findClient(request.client_id)) |entry| {
            if (entry.request_id > request.request_id) {
                // A stale request must never receive a newer result relabeled
                // with its older request ID.
                return;
            }
            if (entry.request_id == request.request_id) {
                // Exact replay of the committed request/result pair.
                if (self.client_reply_fn) |cb| {
                    cb(self.client_reply_ctx.?, request.client_id, entry.request_id, entry.result);
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

        // Reject malformed prepares before any view/status/log mutation.
        // Unsigned underflow of (op_number - retention_floor) is possible otherwise.
        if (!prepareSemanticsValid(prepare)) return;

        // One leader cannot propose two identities for the same (view, op).
        // Reject before heartbeat, retention, status, or journal mutation.
        if (prepare.view_number == self.view_number) {
            if (self.journalGet(prepare.op_number)) |existing| {
                if (existing.checksum != prepare.entry.checksum) return;
            }
        }

        // Prepare proves only that a leader is active. StartView is the sole
        // adoption record for a new view and its selected suffix.
        if (prepare.view_number > self.view_number) {
            self.awaitStartView(prepare.view_number);
            self.requestStartView(prepare.view_number);
            return;
        }

        if (prepare.view_number != self.view_number) return;
        if (self.status == .view_change) {
            self.requestStartView(prepare.view_number);
            return;
        }
        if (self.isLeader()) return;

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.noteReplicaCommitMin(from, prepare.commit_min);
        std.debug.assert(prepare.retention_floor == 0);
        self.retention_floor = 0;

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
                    // Re-ack only when the current entry identity is durable.
                    if (self.isDurablePrepare(prepare.op_number)) {
                        self.sendTo(from, .{ .prepare_ok = .{
                            .view_number = self.view_number,
                            .op_number = prepare.op_number,
                            .replica_id = self.replica_id,
                            .commit_min = self.commit_min,
                            .entry_checksum = existing.checksum,
                            .commit_checksum = if (self.commit_min == 0) 0 else self.journalGet(self.commit_min).?.checksum,
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
        if (ok.replica_id != from) return;
        if (!peerOpInRetainedLog(ok.op_number)) return;
        const current_entry = self.journalGet(ok.op_number) orelse return;
        if (ok.entry_checksum != current_entry.checksum) return;
        // commit_min is the sender watermark and may exceed the acked op
        // (late PrepareOk after the follower has already committed further).
        if (!peerCommitInRetainedLog(ok.commit_min)) return;

        if (ok.commit_min > self.replica_commit_min[from]) {
            if (ok.commit_min == 0) return;
            const committed = self.journalGet(ok.commit_min) orelse return;
            if (committed.checksum != ok.commit_checksum) return;
        }
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

        // Reject malformed commits before any view/status/log mutation.
        if (!commitSemanticsValid(commit_msg)) return;

        const target = @max(commit_msg.commit_min, commit_msg.commit_max);
        const advancing = target > self.commit_min;
        if (advancing and commit_msg.commit_checksum == 0) return;

        // Commit cannot substitute for the StartView certificate that selected
        // this view's suffix. A conflicting local speculative target is exactly
        // why the follower must request the leader's adoption record.
        if (commit_msg.view_number > self.view_number) {
            self.awaitStartView(commit_msg.view_number);
            self.requestStartView(commit_msg.view_number);
            return;
        }

        if (commit_msg.view_number != self.view_number) return;
        if (advancing) {
            // Within an adopted view, advancement remains identity-bound.
            if (self.journalGet(target)) |target_entry| {
                if (target_entry.checksum != commit_msg.commit_checksum) return;
            }
        }
        if (self.status == .view_change) {
            self.requestStartView(commit_msg.view_number);
            return;
        }
        if (self.isLeader()) return;

        self.last_leader_activity = io_mod.nowTick(self.io);
        self.noteReplicaCommitMin(from, commit_msg.commit_min);
        std.debug.assert(commit_msg.retention_floor == 0);
        self.retention_floor = 0;

        if (target > self.commit_min) {
            if (self.journalGet(target) != null) {
                std.debug.assert(commit_msg.commit_checksum != 0);
                self.commitUpTo(target);
            } else {
                // Valid advancing Commit for an op we lack locally: repair, do not commit.
                self.transfer_pending = true;
                self.transfer_target_op = @max(self.transfer_target_op, target);
            }
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
        self.initiateViewChangeTo(self.view_number + 1);
    }

    fn awaitStartView(self: *Replica, new_view: msg.ViewNumber) void {
        std.debug.assert(new_view > self.view_number);
        std.debug.assert(!self.pending_start_view.active);

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
        self.resetSelectedView();
    }

    fn initiateViewChangeTo(self: *Replica, new_view: msg.ViewNumber) void {
        std.debug.assert(new_view > self.view_number);
        std.debug.assert(!self.pending_start_view.active);

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
        self.resetSelectedView();

        self.start_vc_count[self.replica_id] = true;
        self.start_vc_total = 1;

        self.sendToAll(.{ .start_view_change = .{
            .view_number = new_view,
            .replica_id = self.replica_id,
        } });

        self.maybeDoViewChange();
    }

    fn onStartViewChange(self: *Replica, from: u8, svc: msg.StartViewChangeMsg) void {
        if (svc.replica_id != from) return;
        if (svc.view_number < self.view_number) return;
        if (svc.view_number > self.view_number) {
            self.status = .view_change;
            self.view_number = svc.view_number;
            self.last_leader_activity = io_mod.nowTick(self.io);
            self.start_vc_count = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
            self.start_vc_total = 0;
            self.do_vc_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
            self.do_vc_total = 0;
            self.resetSelectedView();
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

    fn dvcTipSemanticsValid(dvc: msg.DoViewChangeMsg) bool {
        if (dvc.op_number == 0) return dvc.log_entry_count == 0;
        var matching_tip_count: usize = 0;
        for (dvc.log_entries[0..dvc.log_entry_count]) |entry| {
            if (entry.op_number != dvc.op_number) continue;
            if (!entry.valid()) return false;
            matching_tip_count += 1;
        }
        return matching_tip_count == 1;
    }

    fn onDoViewChange(self: *Replica, from: u8, dvc: msg.DoViewChangeMsg) void {
        if (self.status != .view_change) return;
        if (dvc.view_number != self.view_number) return;
        if (dvc.replica_id != from) return;
        if (!peerLogBoundsOk(dvc.commit_min, dvc.op_number)) return;
        if (dvc.retention_floor != 0) return;
        if (!peerLogEntriesOk(&dvc.log_entries, dvc.log_entry_count, msg.DVC_LOG_MAX)) return;
        if (!dvcTipSemanticsValid(dvc)) return;

        const new_leader: u8 = @intCast(self.view_number % self.replica_count);
        if (new_leader != self.replica_id) return;

        if (self.pending_view_selection and dvc.replica_id == self.selected_source) {
            const tip_checksum = dvcEntryChecksum(&dvc, dvc.op_number) orelse {
                self.abortSelectedView();
                return;
            };
            if (dvc.last_normal_view != self.selected_last_normal_view or
                dvc.op_number != self.selected_tip_op or
                tip_checksum != self.selected_tip_checksum or
                !dvcOverlapEqual(&dvc, &self.do_vc_msgs[dvc.replica_id]))
            {
                self.abortSelectedView();
                return;
            }
        }

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
        if (self.pending_view_selection) {
            self.advanceSelectedView();
            return;
        }

        var max_commit: msg.OpNumber = 0;
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            max_commit = @max(max_commit, self.do_vc_msgs[i].commit_min);
        }

        var selected_index: ?usize = null;
        var selected_tip_checksum: u64 = 0;
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            const candidate = &self.do_vc_msgs[i];
            const candidate_tip_checksum = dvcEntryChecksum(candidate, candidate.op_number) orelse return;

            if (selected_index) |current_index| {
                const current = &self.do_vc_msgs[current_index];
                if (candidate.last_normal_view < current.last_normal_view) continue;
                if (candidate.last_normal_view == current.last_normal_view and candidate.op_number < current.op_number) continue;
                if (candidate.last_normal_view == current.last_normal_view and candidate.op_number == current.op_number) {
                    if (candidate_tip_checksum != selected_tip_checksum) return;
                    if (!dvcOverlapEqual(candidate, current)) return;
                    if (candidate.replica_id > current.replica_id) continue;
                }
            }
            selected_index = i;
            selected_tip_checksum = candidate_tip_checksum;
        }

        const source_index = selected_index orelse return;
        const selected = &self.do_vc_msgs[source_index];
        if (max_commit > selected.op_number) return;
        if (!dvcTailChainValid(selected)) return;
        // Any committed identity exposed by the quorum must agree with the one
        // selected source. This is a fail-closed guard for implementations that
        // learned a commit after preparing a different suffix.
        for (0..self.replica_count) |i| {
            if (!self.do_vc_received[i]) continue;
            const evidence = &self.do_vc_msgs[i];
            for (evidence.log_entries[0..evidence.log_entry_count]) |committed_entry| {
                if (committed_entry.op_number > evidence.commit_min) continue;
                for (selected.log_entries[0..selected.log_entry_count]) |selected_entry| {
                    if (selected_entry.op_number == committed_entry.op_number and selected_entry.checksum != committed_entry.checksum) return;
                }
            }
        }

        self.pending_view_selection = true;
        self.selected_source = selected.replica_id;
        self.selected_last_normal_view = selected.last_normal_view;
        self.selected_tip_op = selected.op_number;
        self.selected_tip_checksum = selected_tip_checksum;
        self.selected_commit_bound = max_commit;
        self.selected_retention_floor = self.effectiveRetentionFloor();
        self.selected_target_view = self.view_number;
        self.selected_next_op = self.commit_min + 1;

        if (self.selected_tip_op > self.commit_min) {
            const now_tick = io_mod.nowTick(self.io);
            const now: u64 = @intCast(@max(0, now_tick));
            const timeout: u64 = @intCast(VIEW_CHANGE_TIMEOUT * 2);
            self.view_change_candidate = view_candidate.ViewChangeCandidate.allocate(self.allocator, .{
                .source_replica = self.selected_source,
                .target_view = self.selected_target_view,
                .source_last_normal_view = self.selected_last_normal_view,
                .base_op = self.commit_min + 1,
                .tip_op = self.selected_tip_op,
                .tip_checksum = self.selected_tip_checksum,
                .commit_bound = self.selected_commit_bound,
                .deadline_tick = now + timeout,
            }) catch {
                self.abortSelectedView();
                return;
            };

            for (selected.log_entries[0..selected.log_entry_count]) |entry| {
                if (entry.op_number < self.view_change_candidate.metadata.base_op) continue;
                self.view_change_candidate.add(entry) catch {
                    self.abortSelectedView();
                    return;
                };
            }
        }
        self.advanceSelectedView();
    }

    fn dvcEntryChecksum(dvc: *const msg.DoViewChangeMsg, op: msg.OpNumber) ?u64 {
        if (op == 0) return 0;
        for (dvc.log_entries[0..dvc.log_entry_count]) |entry| {
            if (entry.op_number == op and entry.valid()) return entry.checksum;
        }
        return null;
    }

    fn dvcOverlapEqual(a: *const msg.DoViewChangeMsg, b: *const msg.DoViewChangeMsg) bool {
        for (a.log_entries[0..a.log_entry_count]) |a_entry| {
            for (b.log_entries[0..b.log_entry_count]) |b_entry| {
                if (a_entry.op_number == b_entry.op_number and a_entry.checksum != b_entry.checksum) return false;
            }
        }
        return true;
    }

    fn dvcTailChainValid(dvc: *const msg.DoViewChangeMsg) bool {
        for (dvc.log_entries[0..dvc.log_entry_count]) |child| {
            if (!child.valid()) return false;
            for (dvc.log_entries[0..dvc.log_entry_count]) |parent| {
                if (parent.op_number + 1 == child.op_number and child.parent_checksum != parent.checksum) return false;
            }
        }
        return true;
    }

    fn resetSelectedView(self: *Replica) void {
        self.view_change_candidate.reset();
        self.pending_view_selection = false;
        self.selected_next_op = 0;
        self.selected_expected_checksum = 0;
        self.selected_sources_attempted = 0;
        self.selected_sources_requested = 0;
    }

    fn abortSelectedView(self: *Replica) void {
        self.resetSelectedView();
        if (self.status == .view_change) self.initiateViewChange();
    }

    fn addSelectedEntry(self: *Replica, entry: msg.LogEntry) bool {
        if (!self.pending_view_selection) return false;
        if (self.view_change_candidate.phase == .idle) return false;
        self.view_change_candidate.add(entry) catch {
            self.abortSelectedView();
            return false;
        };
        return true;
    }

    fn selectedEntryExpectedChecksum(self: *const Replica, op: msg.OpNumber) ?u64 {
        if (op == self.selected_tip_op) return self.selected_tip_checksum;
        if (op >= self.selected_tip_op) return null;
        const child_op = op + 1;
        if (child_op < self.view_change_candidate.metadata.base_op) return null;
        const child_index: usize = @intCast(child_op - self.view_change_candidate.metadata.base_op);
        if (child_index >= self.view_change_candidate.entries.len) return null;
        if (!self.view_change_candidate.present[child_index]) return null;
        return self.view_change_candidate.entries[child_index].parent_checksum;
    }

    fn requestSelectedEntry(self: *Replica, op: msg.OpNumber, expected_checksum: u64) void {
        std.debug.assert(expected_checksum != 0);
        if (self.leaderForView(self.selected_target_view) != self.replica_id) {
            self.sendTo(self.selected_source, .{ .request_prepare = .{
                .view_number = self.selected_target_view,
                .op_number = op,
                .selected_source = self.selected_source,
                .selected_last_normal_view = self.selected_last_normal_view,
                .selected_tip_op = self.selected_tip_op,
                .selected_tip_checksum = self.selected_tip_checksum,
                .selected_commit_bound = self.selected_commit_bound,
                .expected_entry_checksum = expected_checksum,
            } });
            return;
        }
        // DVC retention hints are advisory ordering only. If every hinted
        // source fails exact identity, boundedly try all configured peers.
        for (0..2) |pass| {
            for (0..self.replica_count) |source_index| {
                if (source_index == self.replica_id) continue;
                const source_bit = @as(u16, 1) << @intCast(source_index);
                if (self.selected_sources_attempted & source_bit != 0) continue;
                const hinted = self.do_vc_received[source_index] and
                    msg.bitsetGet(&self.do_vc_msgs[source_index].present_bitset, @intCast(op % LOG_SIZE_MAX));
                if ((pass == 0) != hinted) continue;

                self.selected_sources_attempted |= source_bit;
                self.selected_sources_requested |= source_bit;
                self.sendTo(@intCast(source_index), .{ .request_prepare = .{
                    .view_number = self.selected_target_view,
                    .op_number = op,
                    .selected_source = self.selected_source,
                    .selected_last_normal_view = self.selected_last_normal_view,
                    .selected_tip_op = self.selected_tip_op,
                    .selected_tip_checksum = self.selected_tip_checksum,
                    .selected_commit_bound = self.selected_commit_bound,
                    .expected_entry_checksum = expected_checksum,
                } });
                return;
            }
        }
    }

    fn advanceSelectedView(self: *Replica) void {
        if (!self.pending_view_selection) return;
        if (self.status != .view_change) return;
        if (self.view_number != self.selected_target_view) {
            self.resetSelectedView();
            return;
        }

        if (self.selected_tip_op == self.commit_min) {
            self.startViewCandidateReady();
            return;
        }
        if (self.view_change_candidate.phase == .idle) {
            self.abortSelectedView();
            return;
        }

        if (self.selected_source == self.replica_id) {
            var op = self.view_change_candidate.metadata.base_op;
            while (op <= self.selected_tip_op) : (op += 1) {
                const index: usize = @intCast(op - self.view_change_candidate.metadata.base_op);
                if (self.view_change_candidate.present[index]) continue;
                const entry = self.journalGet(op) orelse break;
                if (!self.addSelectedEntry(entry.*)) return;
            }
        }

        if (self.view_change_candidate.complete()) {
            self.installCompletedCandidate();
            return;
        }

        var op = self.selected_tip_op;
        while (op >= self.view_change_candidate.metadata.base_op) : (op -= 1) {
            const index: usize = @intCast(op - self.view_change_candidate.metadata.base_op);
            if (self.view_change_candidate.present[index]) {
                if (op == self.view_change_candidate.metadata.base_op) break;
                continue;
            }
            const expected_checksum = self.selectedEntryExpectedChecksum(op) orelse {
                if (op == self.view_change_candidate.metadata.base_op) break;
                continue;
            };
            if (self.selected_next_op != op or self.selected_expected_checksum != expected_checksum) {
                self.selected_next_op = op;
                self.selected_expected_checksum = expected_checksum;
                self.selected_sources_attempted = 0;
                self.selected_sources_requested = 0;
            }
            if (self.journalGet(op)) |local_entry| {
                if (local_entry.checksum == expected_checksum) {
                    if (!self.addSelectedEntry(local_entry.*)) return;
                    self.selected_sources_attempted = 0;
                    self.selected_sources_requested = 0;
                    if (self.view_change_candidate.complete()) {
                        self.installCompletedCandidate();
                        return;
                    }
                    if (op == self.view_change_candidate.metadata.base_op) break;
                    continue;
                }
            }
            self.requestSelectedEntry(op, expected_checksum);
            return;
        }
    }

    fn installCompletedCandidate(self: *Replica) void {
        if (!self.pending_view_selection) return;
        if (!self.view_change_candidate.complete()) return;

        const committed_checksum: u64 = if (self.commit_min == 0) 0 else blk: {
            const committed = self.journalGet(self.commit_min) orelse {
                self.abortSelectedView();
                return;
            };
            break :blk committed.checksum;
        };
        self.view_change_candidate.validate(self.commit_min, committed_checksum) catch {
            self.abortSelectedView();
            return;
        };

        self.truncateAboveFromValidatedStartView(self.commit_min);
        for (self.view_change_candidate.entries) |entry| {
            self.journalPutFromValidatedStartView(entry);
        }
        self.selected_next_op = self.selected_tip_op + 1;
        self.startViewCandidateReady();
    }

    fn startViewCandidateReady(self: *Replica) void {
        if (!self.pending_view_selection or self.pending_start_view.active) return;
        if (self.selected_tip_op > 0) {
            const tip = self.journalGet(self.selected_tip_op) orelse return;
            if (tip.checksum != self.selected_tip_checksum) return;
        }
        if (self.leaderForView(self.selected_target_view) == self.replica_id and self.selected_commit_bound < self.commit_min) return;
        if (self.selected_commit_bound > self.selected_tip_op) return;
        if (self.hasSelectedChainGap()) return;

        // A non-empty candidate was installed in one validated truncate+replace
        // pass. The empty suffix still needs its one tombstone pass here.
        if (self.view_change_candidate.phase == .idle) {
            self.truncateAboveFromValidatedStartView(self.selected_tip_op);
        } else {
            std.debug.assert(self.view_change_candidate.phase == .candidate_complete);
        }
        if (self.logHighOp() != self.selected_tip_op) return;
        std.debug.assert(!self.hasSelectedChainGap());

        const carried_retention_floor: msg.OpNumber = 0;
        if (self.leaderForView(self.selected_target_view) == self.replica_id) {
            for (0..self.replica_count) |i| self.replica_commit_min[i] = 0;
            for (0..self.replica_count) |i| {
                if (!self.do_vc_received[i]) continue;
                self.replica_commit_min[i] = self.do_vc_msgs[i].commit_min;
            }
        }

        // Volatile journal and metadata must name the same selected tip even if
        // a subsequent slot, metadata, or sync operation fails.
        self.op_number = self.selected_tip_op;

        self.pending_prepare_broadcast = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool);
        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);
        const final_commit = @max(self.commit_min, self.selected_commit_bound);
        self.pending_start_view = .{
            .active = true,
            .role = if (self.leaderForView(self.selected_target_view) == self.replica_id) .leader else .follower,
            .source_replica = self.selected_source,
            .target_view = self.selected_target_view,
            .source_last_normal_view = self.selected_last_normal_view,
            .tip_checksum = self.selected_tip_checksum,
            .op_number = self.selected_tip_op,
            .commit_min = final_commit,
            .retention_floor = carried_retention_floor,
            .last_normal_view = self.selected_target_view,
        };
        self.view_change_candidate.phase = .persisting_start_view;
        self.metadata_dirty = true;
        self.assertPendingStartViewChain();
    }

    fn assertPendingStartViewChain(self: *const Replica) void {
        if (!self.pending_start_view.active) return;
        const pending = self.pending_start_view;
        std.debug.assert(pending.role != .none);
        std.debug.assert(self.status == .view_change);
        std.debug.assert(self.logHighOp() == pending.op_number);
        std.debug.assert(self.op_number == pending.op_number);
        std.debug.assert(pending.commit_min >= self.commit_min);
        std.debug.assert(pending.commit_min <= pending.op_number);
        if (pending.op_number > 0) {
            const tip = self.journalGet(pending.op_number) orelse unreachable;
            std.debug.assert(tip.checksum == pending.tip_checksum);
        }
        std.debug.assert(!self.hasSelectedChainGap());
    }

    fn hasSelectedChainGap(self: *const Replica) bool {
        var parent_checksum: u64 = if (self.commit_min == 0) 0 else blk: {
            const committed = self.journalGet(self.commit_min) orelse return true;
            break :blk committed.checksum;
        };
        var op = self.commit_min + 1;
        while (op <= self.selected_tip_op) : (op += 1) {
            const entry = self.journalGet(op) orelse return true;
            if (!entry.valid() or entry.parent_checksum != parent_checksum) return true;
            parent_checksum = entry.checksum;
        }
        return false;
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

    fn requestStartView(self: *Replica, view_number: msg.ViewNumber) void {
        std.debug.assert(self.status == .view_change);
        std.debug.assert(self.view_number == view_number);
        self.sendTo(self.leaderForView(view_number), .{ .request_start_view = .{
            .view_number = view_number,
        } });
    }

    fn onRequestStartView(self: *Replica, from: u8, request: msg.RequestStartViewMsg) void {
        if (self.status != .normal) return;
        if (!self.isLeader()) return;
        if (request.view_number != self.view_number) return;
        self.sendTo(from, .{ .start_view = self.buildStartView() });
    }

    fn onRequestStatus(self: *Replica, from: u8, rs: msg.RequestStatusMsg) void {
        if (rs.view_number != self.view_number) return;

        self.sendTo(from, .{ .send_status = .{
            .view_number = self.view_number,
            .op_number = self.op_number,
            .commit_min = self.commit_min,
            .tip_checksum = if (self.op_number == 0) 0 else self.journalGet(self.op_number).?.checksum,
            .commit_checksum = if (self.commit_min == 0) 0 else self.journalGet(self.commit_min).?.checksum,
        } });
    }

    fn onSendStatus(self: *Replica, from: u8, ss: msg.SendStatusMsg) void {
        if (self.status != .normal) return;
        if (ss.view_number != self.view_number) return;
        if (!peerLogBoundsOk(ss.commit_min, ss.op_number)) return;

        if (self.isLeader()) {
            if (ss.op_number > 0) {
                const tip = self.journalGet(ss.op_number) orelse return;
                if (tip.checksum != ss.tip_checksum) return;
            }
            if (ss.commit_min > 0) {
                const committed = self.journalGet(ss.commit_min) orelse return;
                if (committed.checksum != ss.commit_checksum) return;
            }
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
            if (self.journalGet(ss.commit_min)) |committed| {
                if (committed.checksum != ss.commit_checksum) return;
                self.commitUpTo(ss.commit_min);
            } else {
                self.transfer_pending = true;
                self.transfer_target_op = @max(self.transfer_target_op, ss.commit_min);
            }
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
        if (rp.op_number == 0 or rp.op_number > LOG_SIZE_MAX) return;

        const selection_bound = rp.selected_tip_checksum != 0;
        if (selection_bound) {
            if (rp.selected_commit_bound > rp.selected_tip_op) return;
            if (rp.expected_entry_checksum == 0) return;
            if (rp.selected_tip_op == 0 or rp.op_number > rp.selected_tip_op) return;
            if (self.isLeader() and self.status == .normal and rp.view_number == self.view_number) {
                if (rp.selected_source != self.selected_source) return;
                if (rp.selected_last_normal_view != self.selected_last_normal_view) return;
                if (rp.selected_tip_op != self.selected_tip_op) return;
                if (rp.selected_tip_checksum != self.selected_tip_checksum) return;
                if (rp.selected_commit_bound != self.selected_commit_bound) return;
            } else {
                if (rp.view_number > self.view_number) return;
                if (from != self.leaderForView(rp.view_number)) return;
                if (self.replica_id == rp.selected_source) {
                    if (rp.selected_last_normal_view != self.last_normal_view) return;
                    if (rp.selected_tip_op > self.op_number) return;
                    const selected_tip = self.journalGet(rp.selected_tip_op) orelse return;
                    if (selected_tip.checksum != rp.selected_tip_checksum) return;
                }
            }
        } else {
            if (rp.view_number != self.view_number) return;
        }

        if (self.journalGet(rp.op_number)) |entry| {
            if (!selection_bound and from != self.leader() and rp.op_number > self.commit_min) return;
            if (selection_bound and entry.checksum != rp.expected_entry_checksum) return;
            self.sendTo(from, .{ .send_prepare = .{
                .view_number = rp.view_number,
                .entry = entry.*,
                .selected_source = rp.selected_source,
                .selected_last_normal_view = rp.selected_last_normal_view,
                .selected_tip_op = rp.selected_tip_op,
                .selected_tip_checksum = rp.selected_tip_checksum,
                .selected_commit_bound = rp.selected_commit_bound,
                .expected_entry_checksum = rp.expected_entry_checksum,
            } });
        }
    }

    fn onSendPrepare(self: *Replica, from: u8, sp: msg.SendPrepareMsg) void {
        if (sp.view_number != self.view_number) return;
        if (!sp.entry.valid()) return;
        if (sp.entry.op_number == 0 or sp.entry.op_number > LOG_SIZE_MAX) return;

        if (self.status == .view_change and self.pending_view_selection) {
            if (sp.selected_source != self.selected_source) return;
            if (sp.selected_last_normal_view != self.selected_last_normal_view) return;
            if (sp.selected_tip_op != self.selected_tip_op) return;
            if (sp.selected_tip_checksum != self.selected_tip_checksum) return;
            if (sp.selected_commit_bound != self.selected_commit_bound) return;
            if (sp.entry.op_number != self.selected_next_op) return;
            if (sp.expected_entry_checksum != self.selected_expected_checksum) return;
            if (self.leaderForView(self.selected_target_view) == self.replica_id) {
                const source_bit = @as(u16, 1) << @intCast(from);
                if (self.selected_sources_requested & source_bit == 0) return;
            } else if (from != self.selected_source) return;
            if (sp.entry.checksum != self.selected_expected_checksum) {
                self.advanceSelectedView();
                return;
            }
            if (!self.addSelectedEntry(sp.entry)) return;
            self.selected_sources_attempted = 0;
            self.selected_sources_requested = 0;
            self.advanceSelectedView();
            return;
        }

        if (self.status != .normal) return;
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
            const from_bit = @as(u16, 1) << @intCast(from);
            // Remote repair source already holds the entry; self-vote and Prepare
            // broadcast wait for the local durability barrier.
            self.prepare_ok_from[slot] = if (from == self.replica_id) 0 else from_bit;
            self.prepare_ok_counts[slot] = if (from == self.replica_id) 0 else 1;
            self.pending_prepare_broadcast[slot] = true;
            self.metadata_dirty = true;

            if (!self.hasLogGaps()) {
                self.repair_pending = false;
            }
        } else {
            if (!self.transfer_pending) return;

            if (entry.op_number <= self.op_number) {
                if (self.journalHas(entry.op_number)) return;
                self.journalPut(entry);
                // PrepareOk for gap fill waits for the durability barrier.
                if (entry.op_number > self.commit_min) {
                    const slot = journalSlot(entry.op_number);
                    self.pending_prepare_ok[slot] = true;
                    self.pending_prepare_ok_to[slot] = self.leader();
                }
            } else if (entry.op_number == self.op_number + 1) {
                self.op_number = entry.op_number;
                self.journalPut(entry);

                const slot = journalSlot(entry.op_number);
                self.pending_prepare_ok[slot] = true;
                self.pending_prepare_ok_to[slot] = self.leader();
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
        if (!startViewEntriesValid(sv)) return;
        if (self.commit_min > sv.op_number) return;
        const anchor_checksum: u64 = if (self.commit_min == 0) 0 else blk: {
            const anchor = self.journalGet(self.commit_min) orelse return;
            if (!self.isDurablePrepare(self.commit_min)) return;
            break :blk anchor.checksum;
        };
        if (self.commit_min == sv.op_number and anchor_checksum != sv.tip_checksum) return;

        if (sv.view_number > self.view_number) self.awaitStartView(sv.view_number);
        if (self.status != .view_change or sv.view_number != self.view_number) return;
        if (self.pending_view_selection) {
            if (from != self.selected_source or
                sv.selected_last_normal_view != self.selected_last_normal_view or
                sv.op_number != self.selected_tip_op or
                sv.tip_checksum != self.selected_tip_checksum or
                sv.commit_min != self.selected_commit_bound)
            {
                self.abortSelectedView();
            }
            return;
        }

        self.resetSelectedView();
        self.pending_view_selection = true;
        self.selected_source = from;
        self.selected_last_normal_view = sv.selected_last_normal_view;
        self.selected_tip_op = sv.op_number;
        self.selected_tip_checksum = sv.tip_checksum;
        self.selected_commit_bound = sv.commit_min;
        std.debug.assert(sv.retention_floor == 0);
        self.selected_retention_floor = 0;
        self.selected_target_view = sv.view_number;
        self.selected_next_op = self.commit_min + 1;
        self.last_leader_activity = io_mod.nowTick(self.io);

        if (self.selected_tip_op > self.commit_min) {
            const now: u64 = @intCast(@max(0, io_mod.nowTick(self.io)));
            self.view_change_candidate = view_candidate.ViewChangeCandidate.allocate(self.allocator, .{
                .source_replica = from,
                .target_view = sv.view_number,
                .source_last_normal_view = sv.selected_last_normal_view,
                .base_op = self.commit_min + 1,
                .tip_op = sv.op_number,
                .tip_checksum = sv.tip_checksum,
                .commit_bound = sv.commit_min,
                .deadline_tick = now + @as(u64, @intCast(VIEW_CHANGE_TIMEOUT * 2)),
            }) catch {
                self.abortSelectedView();
                return;
            };
            for (sv.log_entries[0..sv.log_entry_count]) |entry| {
                if (entry.op_number < self.view_change_candidate.metadata.base_op) continue;
                self.view_change_candidate.add(entry) catch {
                    self.abortSelectedView();
                    return;
                };
            }
        }
        self.advanceSelectedView();
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
            .retention_floor = 0,
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

        std.debug.assert(dvcTipSemanticsValid(dvc));
        return dvc;
    }

    fn buildStartView(self: *const Replica) msg.StartViewMsg {
        var sv = msg.StartViewMsg{
            .view_number = self.view_number,
            .selected_last_normal_view = self.selected_last_normal_view,
            .op_number = self.selected_tip_op,
            .tip_checksum = self.selected_tip_checksum,
            .commit_min = self.selected_commit_bound,
            .retention_floor = 0,
        };

        for (&sv.log_entries) |*e| {
            e.* = .{ .command = .{ .noop = {} } };
        }

        var count: u8 = 0;
        if (sv.op_number > 0) {
            var scan_op = sv.op_number;
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
        // Client-table publication waits for the commit durability barrier.
        self.commit_min = op;
        self.replica_commit_min[self.replica_id] = self.commit_min;
        if (self.isLeader()) self.recomputeRetentionFloor();
        self.metadata_dirty = true;
        self.pending_commit_barrier = true;

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
            self.updateClientTable(
                self.pending_reply_client_id[slot],
                self.pending_reply_request_id[slot],
                self.pending_reply_result[slot],
            );
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

    pub fn armBarrierCut(self: *Replica, cut: BarrierCut) void {
        std.debug.assert(cut.id > 0);
        std.debug.assert(self.barrier_cut == null);
        self.barrier_cut = cut;
    }

    fn triggerBarrierCut(self: *Replica, kind: BarrierKind, point: BarrierCutPoint) bool {
        const cut = self.barrier_cut orelse return false;
        if (cut.kind != kind or cut.point != point) return false;
        self.barrier_cut = null;
        self.barrier_cut_count += 1;
        self.last_barrier_cut_id = cut.id;
        self.markStorageFailed();
        return true;
    }

    fn triggerNormalBarrierCut(self: *Replica, prepare: bool, commit: bool, point: BarrierCutPoint) bool {
        std.debug.assert(prepare or commit);
        const cut = self.barrier_cut orelse return false;
        const cause_matches = switch (cut.kind) {
            .prepare => prepare,
            .commit => commit,
            .leader_start_view, .follower_start_view => false,
        };
        if (!cause_matches or cut.point != point) return false;
        self.barrier_cut = null;
        self.barrier_cut_count += 1;
        self.last_barrier_cut_id = cut.id;
        self.markStorageFailed();
        return true;
    }

    fn metadataForPersistence(self: *const Replica) disk_mod.Metadata {
        if (self.pending_start_view.active) {
            const pending = self.pending_start_view;
            self.assertPendingStartViewChain();
            return .{
                .view_number = pending.target_view,
                .last_normal_view = pending.last_normal_view,
                .op_number = pending.op_number,
                .commit_min = pending.commit_min,
                .commit_max = pending.commit_min,
            };
        }
        return .{
            .view_number = self.view_number,
            .last_normal_view = self.last_normal_view,
            .op_number = self.op_number,
            .commit_min = self.commit_min,
            .commit_max = self.commit_max,
        };
    }

    fn syncPendingStartView(self: *Replica, disk: *DiskInterface, kind: BarrierKind) bool {
        std.debug.assert(kind == .leader_start_view or kind == .follower_start_view);
        self.assertPendingStartViewChain();
        const meta = self.metadataForPersistence();
        std.debug.assert(meta.op_number == self.logHighOp());
        std.debug.assert(meta.commit_min == self.pending_start_view.commit_min);
        std.debug.assert(meta.commit_max == meta.commit_min);

        if (self.triggerBarrierCut(kind, .before_slot_write)) return false;
        for (0..LOG_SIZE_MAX) |i| {
            if (!self.journal_dirty[i]) continue;
            if (self.journal_occupied[i]) {
                disk.writeSlot(i, &self.journal[i]) catch {
                    self.markStorageFailed();
                    return false;
                };
            } else {
                disk.clearSlot(i) catch {
                    self.markStorageFailed();
                    return false;
                };
            }
        }
        if (self.triggerBarrierCut(kind, .before_metadata_write)) return false;
        disk.writeMetadata(meta) catch {
            self.markStorageFailed();
            return false;
        };
        self.metadata_dirty = true;
        if (self.triggerBarrierCut(kind, .before_sync)) return false;
        disk.sync() catch {
            self.markStorageFailed();
            return false;
        };
        std.debug.assert(disk.metadataEquals(meta));
        for (0..LOG_SIZE_MAX) |i| self.journal_dirty[i] = false;
        self.metadata_dirty = false;
        self.pending_prepare_barrier = false;
        self.pending_commit_barrier = false;
        return true;
    }

    /// Group-commit flush: stage all dirty journal/metadata, one durability
    /// barrier, then publish pending Prepare/PrepareOk/client/worker traffic.
    fn flushDurableState(self: *Replica) void {
        if (self.storage_failed) return;
        var disk = self.disk orelse {
            // Volatile mode explicitly uses the same publication transition,
            // synchronously, with memory as the durability boundary.
            for (0..LOG_SIZE_MAX) |i| self.journal_dirty[i] = false;
            const before = self.durable_prepare_through;
            const through = if (self.pending_start_view.active) self.pending_start_view.op_number else self.op_number;
            self.metadata_dirty = false;
            self.pending_prepare_barrier = false;
            self.pending_commit_barrier = false;
            self.publishPendingAfterBarrier(before, through);
            self.metadata_dirty = false;
            self.publishCommitEffects();
            return;
        };

        if (self.pending_start_view.active) {
            const before = self.durable_prepare_through;
            const through = self.pending_start_view.op_number;
            const kind: BarrierKind = switch (self.pending_start_view.role) {
                .leader => .leader_start_view,
                .follower => .follower_start_view,
                .none => unreachable,
            };
            if (!self.syncPendingStartView(&disk, kind)) return;
            if (self.triggerBarrierCut(kind, .before_publication)) return;
            self.publishPendingAfterBarrier(before, through);
            return;
        }

        var barriers: u8 = 0;
        while (barriers < FLUSH_BARRIER_MAX) : (barriers += 1) {
            const any_journal_dirty = anyJournalDirty(self);
            const prepare_cause = self.pending_prepare_barrier;
            const commit_cause = self.pending_commit_barrier;
            const prepare_through_before = self.durable_prepare_through;

            if ((prepare_cause or commit_cause) and self.triggerNormalBarrierCut(prepare_cause, commit_cause, .before_slot_write)) return;
            for (0..LOG_SIZE_MAX) |i| {
                if (!self.journal_dirty[i]) continue;
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

            const meta = self.metadataForPersistence();
            const need_meta = self.metadata_dirty or any_journal_dirty or !disk.metadataEquals(meta);
            if (need_meta) {
                if ((prepare_cause or commit_cause) and self.triggerNormalBarrierCut(prepare_cause, commit_cause, .before_metadata_write)) return;
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

            if ((prepare_cause or commit_cause) and self.triggerNormalBarrierCut(prepare_cause, commit_cause, .before_sync)) return;
            disk.sync() catch {
                self.markStorageFailed();
                return;
            };
            std.debug.assert(disk.metadataEquals(meta));

            for (0..LOG_SIZE_MAX) |i| {
                self.journal_dirty[i] = false;
            }
            self.metadata_dirty = false;
            if (prepare_cause) self.pending_prepare_barrier = false;
            if (commit_cause) self.pending_commit_barrier = false;

            if ((prepare_cause or commit_cause) and self.triggerNormalBarrierCut(prepare_cause, commit_cause, .before_publication)) return;
            self.publishPendingAfterBarrier(prepare_through_before, meta.op_number);

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

    fn publishPendingStartViewAfterBarrier(self: *Replica) void {
        if (!self.pending_start_view.active) return;
        const pending = self.pending_start_view;
        const deferred_view = self.deferred_view_target;
        self.assertPendingStartViewChain();

        self.view_number = pending.target_view;
        self.last_normal_view = pending.last_normal_view;
        self.op_number = pending.op_number;
        std.debug.assert(pending.retention_floor == 0);
        self.retention_floor = 0;
        self.commit_max = @max(self.commit_max, pending.commit_min);
        if (pending.commit_min > self.commit_min) self.commitUpTo(pending.commit_min);
        std.debug.assert(self.commit_min == pending.commit_min);
        self.commit_max = self.commit_min;
        self.replica_commit_min[self.replica_id] = self.commit_min;

        self.prepare_ok_counts = std.mem.zeroes([LOG_SIZE_MAX]u8);
        self.prepare_ok_from = std.mem.zeroes([LOG_SIZE_MAX]u16);
        self.pending_prepare_ok = std.mem.zeroes([LOG_SIZE_MAX]bool);
        if (pending.role == .leader) {
            self.recomputeRetentionFloor();
            var self_op = self.commit_min + 1;
            while (self_op <= self.op_number) : (self_op += 1) {
                std.debug.assert(self.isDurablePrepare(self_op));
                const slot = journalSlot(self_op);
                self.prepare_ok_counts[slot] = 1;
                self.prepare_ok_from[slot] = @as(u16, 1) << @intCast(self.replica_id);
            }
        } else {
            for (0..self.replica_count) |i| self.replica_commit_min[i] = self.retention_floor;
            self.replica_commit_min[self.leader()] = self.selected_commit_bound;
            var ack_op = self.commit_min + 1;
            while (ack_op <= self.op_number) : (ack_op += 1) {
                std.debug.assert(self.isDurablePrepare(ack_op));
                const slot = journalSlot(ack_op);
                self.pending_prepare_ok[slot] = true;
                self.pending_prepare_ok_to[slot] = self.leader();
            }
        }

        self.status = .normal;
        const now_tick = io_mod.nowTick(self.io);
        self.last_heartbeat = now_tick;
        self.last_leader_activity = now_tick;
        self.repair_pending = pending.role == .leader;
        self.repair_status_received = std.mem.zeroes([msg.REPLICA_COUNT_MAX]bool);
        self.repair_status_count = 0;
        self.transfer_pending = false;
        self.transfer_target_op = 0;
        self.recovered_from_disk = false;
        self.metadata_dirty = false;

        if (pending.role == .leader) {
            const start_view = self.buildStartView();
            self.sendToAllOthers(.{ .start_view = start_view });
        } else {
            self.sendTo(self.leader(), .{ .send_status = .{
                .view_number = self.view_number,
                .op_number = self.op_number,
                .commit_min = self.commit_min,
                .tip_checksum = if (self.op_number == 0) 0 else self.journalGet(self.op_number).?.checksum,
                .commit_checksum = if (self.commit_min == 0) 0 else self.journalGet(self.commit_min).?.checksum,
            } });
        }

        self.view_change_candidate.reset();
        self.pending_view_selection = false;
        self.selected_next_op = 0;
        self.pending_start_view = .{};
        self.deferred_view_target = 0;
        if (self.disk) |disk| std.debug.assert(disk.metadataEquals(self.metadataForPersistence()));

        if (deferred_view > self.view_number) self.initiateViewChangeTo(deferred_view);
    }

    fn publishPendingAfterBarrier(self: *Replica, prepare_through_before: msg.OpNumber, prepare_through_after: msg.OpNumber) void {
        _ = prepare_through_before;

        var durable_op: msg.OpNumber = 1;
        while (durable_op <= prepare_through_after) : (durable_op += 1) {
            if (!self.journalHas(durable_op)) continue;
            const slot = journalSlot(durable_op);
            self.durable_prepare_op[slot] = durable_op;
            self.durable_prepare_checksum[slot] = self.journal[slot].checksum;
        }
        self.durable_prepare_through = @max(self.durable_prepare_through, prepare_through_after);
        self.publishPendingStartViewAfterBarrier();

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
                    .retention_floor = 0,
                    .entry = entry,
                } });
                const self_bit = @as(u16, 1) << @intCast(self.replica_id);
                if (self.prepare_ok_from[slot] & self_bit == 0) {
                    self.prepare_ok_from[slot] |= self_bit;
                    self.prepare_ok_counts[slot] += 1;
                }
                self.pending_prepare_broadcast[slot] = false;
            }

            if (self.pending_prepare_ok[slot] and self.journal[slot].op_number == op) {
                const to = self.pending_prepare_ok_to[slot];
                self.sendTo(to, .{ .prepare_ok = .{
                    .view_number = self.view_number,
                    .op_number = op,
                    .replica_id = self.replica_id,
                    .commit_min = self.commit_min,
                    .entry_checksum = self.journal[slot].checksum,
                    .commit_checksum = if (self.commit_min == 0) 0 else self.journalGet(self.commit_min).?.checksum,
                } });
                self.pending_prepare_ok[slot] = false;
            }

            if (self.journalHas(op)) {
                self.durable_prepare_op[slot] = op;
                self.durable_prepare_checksum[slot] = self.journal[slot].checksum;
            }
        }
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
        self.journalPutInternal(entry, false);
    }

    fn journalPutFromValidatedStartView(self: *Replica, entry: msg.LogEntry) void {
        self.journalPutInternal(entry, true);
    }

    fn journalPutInternal(self: *Replica, entry: msg.LogEntry, validated_start_view: bool) void {
        if (entry.op_number == 0 or entry.op_number > LOG_SIZE_MAX) return;
        const slot = journalSlot(entry.op_number);
        if (self.journal_occupied[slot] and
            (self.journal[slot].op_number != entry.op_number or
                self.journal[slot].checksum != entry.checksum))
        {
            if (entry.op_number != self.journal[slot].op_number) return;
            if (entry.op_number <= self.commit_min) return;
            // Durable prepared evidence is immutable during normal traffic and
            // repair. Only the separately preflighted StartView install path may
            // replace it in a later view.
            if (self.isDurablePrepare(entry.op_number) and !validated_start_view) return;
            self.prepare_ok_counts[slot] = 0;
            self.prepare_ok_from[slot] = 0;
            self.durable_prepare_op[slot] = 0;
            self.durable_prepare_checksum[slot] = 0;
        }
        self.journal[slot] = entry;
        self.journal_occupied[slot] = true;
        self.journal_dirty[slot] = true;
        self.pending_prepare_barrier = true;
    }

    fn truncateAbove(self: *Replica, limit: msg.OpNumber) void {
        self.truncateAboveInternal(limit, false);
    }

    fn truncateAboveFromValidatedStartView(self: *Replica, limit: msg.OpNumber) void {
        self.truncateAboveInternal(limit, true);
    }

    fn truncateAboveInternal(self: *Replica, limit: msg.OpNumber, validated_start_view: bool) void {
        for (0..LOG_SIZE_MAX) |i| {
            if (!self.journal_occupied[i]) continue;
            if (self.journal[i].op_number <= limit or self.journal[i].op_number <= self.commit_min) continue;
            if (self.isDurablePrepare(self.journal[i].op_number) and !validated_start_view) continue;
            self.journal_occupied[i] = false;
            self.prepare_ok_counts[i] = 0;
            self.prepare_ok_from[i] = 0;
            self.durable_prepare_op[i] = 0;
            self.durable_prepare_checksum[i] = 0;
            self.journal_dirty[i] = true;
            self.pending_prepare_barrier = true;
        }
    }

    /// True when op is present and its current checksum was covered by a barrier.
    pub fn isDurablePrepare(self: *const Replica, op: msg.OpNumber) bool {
        if (op == 0) return false;
        const slot = journalSlot(op);
        if (!self.journal_occupied[slot]) return false;
        if (self.journal[slot].op_number != op) return false;
        return self.durable_prepare_op[slot] == op and
            self.durable_prepare_checksum[slot] == self.journal[slot].checksum;
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

    fn hasPendingClientReply(self: *const Replica, client_id: u128, request_id: msg.RequestId) bool {
        for (0..LOG_SIZE_MAX) |i| {
            if (!self.pending_reply[i]) continue;
            if (self.pending_reply_client_id[i] == client_id and
                self.pending_reply_request_id[i] == request_id)
            {
                return true;
            }
        }
        return false;
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
        std.debug.assert(self.client_count < CLIENT_TABLE_MAX);
        self.client_table[self.client_count] = .{
            .client_id = client_id,
            .request_id = request_id,
            .result = result,
            .active = true,
        };
        self.client_count += 1;
    }

    // -----------------------------------------------------------------------
    // Network helpers
    // -----------------------------------------------------------------------

    fn resendUncommittedPrepares(self: *Replica) void {
        var resend_op = self.commit_min + 1;
        while (resend_op <= self.op_number) : (resend_op += 1) {
            // Never re-broadcast until the current entry identity is durable.
            if (!self.isDurablePrepare(resend_op)) continue;
            if (self.journalGet(resend_op)) |entry| {
                const slot = journalSlot(resend_op);
                if (self.prepare_ok_counts[slot] < self.quorum_size) {
                    self.sendToAllOthers(.{ .prepare = .{
                        .view_number = self.view_number,
                        .op_number = resend_op,
                        .commit_min = self.commit_min,
                        .retention_floor = 0,
                        .entry = entry.*,
                    } });
                }
            }
        }
    }

    fn sendCommitHeartbeat(self: *Replica) void {
        const target = @max(self.commit_min, self.commit_max);
        // Never emit checksum 0 for a nonzero advancing/current commit target.
        const commit_checksum: u64 = if (target > 0) blk: {
            const entry = self.journalGet(target) orelse return;
            if (entry.checksum == 0) return;
            break :blk entry.checksum;
        } else 0;
        std.debug.assert(target == 0 or commit_checksum != 0);
        self.sendToAllOthers(.{ .commit = .{
            .view_number = self.view_number,
            .commit_min = self.commit_min,
            .commit_max = self.commit_max,
            .op_number = self.op_number,
            .retention_floor = 0,
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

const ClientReplyCapture = struct {
    count: usize = 0,
    client_id: u128 = 0,
    request_id: msg.RequestId = 0,
    result: msg.Result = .{ .ok = .{ .entity_id = 0 } },

    fn reply(ctx: *anyopaque, client_id: u128, request_id: msg.RequestId, result: msg.Result) void {
        const capture: *ClientReplyCapture = @ptrCast(@alignCast(ctx));
        capture.count += 1;
        capture.client_id = client_id;
        capture.request_id = request_id;
        capture.result = result;
    }
};

comptime {
    std.debug.assert(@sizeOf(Replica) <= 8 * 1024 * 1024);
    std.debug.assert(@sizeOf(view_candidate.ViewChangeCandidate) <= 256);
}

test "stale client request is ignored instead of relabeling newer result" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1201);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1201, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1201);
    var capture = ClientReplyCapture{};
    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
        .client_reply_ctx = &capture,
        .client_reply_fn = ClientReplyCapture.reply,
    });
    replica.updateClientTable(77, 9, .{ .ok = .{ .entity_id = 900 } });

    replica.onRequest(0, .{ .client_id = 77, .request_id = 8, .command = .{ .noop = {} } });
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(@as(u64, 0), replica.op_number);

    replica.onRequest(0, .{ .client_id = 77, .request_id = 9, .command = .{ .noop = {} } });
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(u128, 9), capture.request_id);
    try std.testing.expectEqual(@as(u64, 900), capture.result.ok.entity_id);
    try std.testing.expectEqual(@as(u64, 0), replica.op_number);
}

test "restart rebuild preserves dedup beyond 64 unique clients" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1202);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1202, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);
    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1202);
    var capture = ClientReplyCapture{};
    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
        .client_reply_ctx = &capture,
        .client_reply_fn = ClientReplyCapture.reply,
    });

    var parent_checksum: u64 = 0;
    for (1..97) |op| {
        var entry = msg.LogEntry{
            .view_number = 0,
            .op_number = @intCast(op),
            .command = .{ .noop = {} },
            .client_id = @intCast(10_000 + op),
            .request_id = 1,
            .parent_checksum = parent_checksum,
        };
        entry.checksum = entry.computeChecksum();
        replica.journalPut(entry);
        parent_checksum = entry.checksum;
    }
    replica.op_number = 96;
    replica.commit_min = 96;
    replica.commit_max = 96;
    try replica.rebuildCommittedState(96);
    try std.testing.expectEqual(@as(usize, 96), replica.client_count);

    replica.onRequest(0, .{ .client_id = 10_001, .request_id = 1, .command = .{ .noop = {} } });
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(u128, 1), capture.request_id);
    try std.testing.expectEqual(@as(u64, 96), replica.op_number);
}

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

test "onMessage drops out-of-range from" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7001);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7001, 3, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7001);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;

    replica.onMessage(99, .{ .start_view_change = .{
        .view_number = 1,
        .replica_id = 99,
    } });
    try std.testing.expectEqual(@as(u8, 0), replica.start_vc_total);
}

test "onStartViewChange rejects spoofed replica_id" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7002);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7002, 3, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7002);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;
    replica.start_vc_count[0] = true;
    replica.start_vc_total = 1;

    replica.onMessage(1, .{ .start_view_change = .{
        .view_number = 1,
        .replica_id = 2,
    } });
    try std.testing.expectEqual(@as(u8, 1), replica.start_vc_total);
    try std.testing.expect(!replica.start_vc_count[2]);
}

test "onDoViewChange rejects unbounded op_number" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7003);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7003, 3, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7003);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;

    replica.onMessage(0, .{ .do_view_change = .{
        .view_number = 1,
        .replica_id = 0,
        .op_number = LOG_SIZE_MAX + 1,
        .commit_min = 0,
    } });
    try std.testing.expectEqual(@as(u8, 0), replica.do_vc_total);
}

test "DVC tip preflight rejects missing duplicate conflicting and zero-op tips before quorum" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xD7C71F);
    defer tc.deinit();
    const leader = tc.replicas[1];
    leader.status = .view_change;
    leader.view_number = 1;

    var tip = msg.LogEntry{ .view_number = 0, .op_number = 1, .client_id = 1, .request_id = 1 };
    tip.checksum = tip.computeChecksum();
    var conflicting = tip;
    conflicting.client_id = 2;
    conflicting.checksum = conflicting.computeChecksum();

    const missing = msg.DoViewChangeMsg{ .view_number = 1, .replica_id = 0, .op_number = 1 };
    leader.onMessage(0, .{ .do_view_change = missing });
    try std.testing.expectEqual(@as(u8, 0), leader.do_vc_total);

    var duplicate = missing;
    duplicate.log_entry_count = 2;
    duplicate.log_entries[0] = tip;
    duplicate.log_entries[1] = tip;
    leader.onMessage(0, .{ .do_view_change = duplicate });
    try std.testing.expectEqual(@as(u8, 0), leader.do_vc_total);

    var conflict = duplicate;
    conflict.log_entries[1] = conflicting;
    leader.onMessage(0, .{ .do_view_change = conflict });
    try std.testing.expectEqual(@as(u8, 0), leader.do_vc_total);

    var zero_with_tip = msg.DoViewChangeMsg{ .view_number = 1, .replica_id = 0, .op_number = 0, .log_entry_count = 1 };
    zero_with_tip.log_entries[0] = tip;
    leader.onMessage(0, .{ .do_view_change = zero_with_tip });
    try std.testing.expectEqual(@as(u8, 0), leader.do_vc_total);

    var valid = missing;
    valid.log_entry_count = 1;
    valid.log_entries[0] = tip;
    leader.onMessage(0, .{ .do_view_change = valid });
    try std.testing.expectEqual(@as(u8, 1), leader.do_vc_total);
    try std.testing.expectEqual(tip.checksum, leader.do_vc_msgs[0].log_entries[0].checksum);
}

test "local and recovered DVC always contain exactly one matching tip" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xD7C72F);
    defer tc.deinit();
    const replica = tc.replicas[0];
    var entry = msg.LogEntry{ .view_number = 0, .op_number = 1, .client_id = 1, .request_id = 1 };
    entry.checksum = entry.computeChecksum();
    replica.journalPut(entry);
    replica.op_number = 1;
    var dvc = replica.buildDvc();
    try std.testing.expect(Replica.dvcTipSemanticsValid(dvc));

    replica.recovered_from_disk = true;
    dvc = replica.buildDvc();
    try std.testing.expect(Replica.dvcTipSemanticsValid(dvc));
    try std.testing.expectEqual(@as(msg.OpNumber, 1), dvc.op_number);
    try std.testing.expectEqual(entry.checksum, Replica.dvcEntryChecksum(&dvc, 1).?);
}

test "journalPut soft-drops zero and oversize op" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7004);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7004, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7004);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    var zero = msg.LogEntry{ .op_number = 0, .command = .{ .noop = {} } };
    zero.checksum = zero.computeChecksum();
    replica.journalPut(zero);
    try std.testing.expect(!replica.journalHas(0));

    var huge = msg.LogEntry{ .op_number = LOG_SIZE_MAX + 1, .command = .{ .noop = {} } };
    huge.checksum = huge.computeChecksum();
    replica.journalPut(huge);
    for (replica.journal_occupied) |occ| {
        try std.testing.expect(!occ);
    }
}

test "onPrepare rejects bad retention before mutating view_change status" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7011);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7011, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7011);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;
    replica.commit_min = 0;
    replica.op_number = 0;

    var entry = msg.LogEntry{
        .view_number = 2,
        .op_number = 1,
        .command = .{ .noop = {} },
    };
    entry.checksum = entry.computeChecksum();

    // Leader for view 2 with replica_count=3 is replica 2.
    // retention_floor > commit_min must not promote out of view_change.
    replica.onMessage(2, .{ .prepare = .{
        .view_number = 2,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 5,
        .entry = entry,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);

    // Mismatched entry.op_number must also be ignored pre-mutation.
    entry.op_number = 9;
    entry.checksum = entry.computeChecksum();
    replica.onMessage(2, .{ .prepare = .{
        .view_number = 2,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .entry = entry,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);
}

test "onCommit rejects bad semantics before mutating view_change status" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7012);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7012, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7012);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;
    replica.commit_min = 0;
    replica.commit_max = 0;
    replica.op_number = 0;
    replica.retention_floor = 0;

    var committed = msg.LogEntry{
        .view_number = 1,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 7,
        .request_id = 7,
        .parent_checksum = 0,
    };
    committed.checksum = committed.computeChecksum();
    replica.journalPut(committed);
    replica.op_number = 1;
    replica.commit_min = 1;
    replica.commit_max = 1;
    const journal_checksum_before = replica.journalGet(1).?.checksum;
    const sm_seed_before = sm.seed;

    // Leader for view 2 with replica_count=3 is replica 2.
    // retention_floor > commit_min must not promote or truncate.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 1,
        .commit_max = 1,
        .op_number = 1,
        .retention_floor = 5,
        .commit_checksum = 0,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.commit_max);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.retention_floor);
    try std.testing.expectEqual(journal_checksum_before, replica.journalGet(1).?.checksum);
    try std.testing.expectEqual(sm_seed_before, sm.seed);

    // commit_min > op_number must also be ignored pre-mutation.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 5,
        .commit_max = 5,
        .op_number = 1,
        .retention_floor = 0,
        .commit_checksum = 0,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);

    // op_number beyond retained log must be ignored pre-mutation.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 1,
        .commit_max = 1,
        .op_number = LOG_SIZE_MAX + 1,
        .retention_floor = 0,
        .commit_checksum = 0,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.commit_min);
    try std.testing.expectEqual(journal_checksum_before, replica.journalGet(1).?.checksum);
}

test "onStartView rejects out-of-range duplicate and conflicting entries before mutation" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7013);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7013, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7013);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 0;
    replica.commit_min = 0;
    replica.commit_max = 0;
    replica.op_number = 0;
    replica.retention_floor = 0;

    var entry1 = msg.LogEntry{
        .view_number = 3,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry1.checksum = entry1.computeChecksum();

    var entry2 = msg.LogEntry{
        .view_number = 3,
        .op_number = 2,
        .command = .{ .noop = {} },
        .client_id = 2,
        .request_id = 2,
        .parent_checksum = entry1.checksum,
    };
    entry2.checksum = entry2.computeChecksum();

    // Leader for view 3 with replica_count=3 is replica 0.
    // Entry above sv.op_number must not mutate view/status/log.
    var sv_oor = msg.StartViewMsg{
        .view_number = 3,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv_oor.log_entries[0] = entry2;
    replica.onMessage(0, .{ .start_view = sv_oor });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.op_number);
    try std.testing.expect(!replica.journalHas(2));

    // Exact duplicate same-op identity must be rejected pre-mutation.
    var sv_dup = msg.StartViewMsg{
        .view_number = 3,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 2,
    };
    sv_dup.log_entries[0] = entry1;
    sv_dup.log_entries[1] = entry1;
    replica.onMessage(0, .{ .start_view = sv_dup });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), replica.view_number);
    try std.testing.expect(!replica.journalHas(1));

    // Conflicting same-op identities must be rejected pre-mutation.
    var conflict = entry1;
    conflict.client_id = 99;
    conflict.request_id = 99;
    conflict.checksum = conflict.computeChecksum();
    try std.testing.expect(conflict.checksum != entry1.checksum);
    var sv_conflict = msg.StartViewMsg{
        .view_number = 3,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 2,
    };
    sv_conflict.log_entries[0] = entry1;
    sv_conflict.log_entries[1] = conflict;
    replica.onMessage(0, .{ .start_view = sv_conflict });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), replica.view_number);
    try std.testing.expect(!replica.journalHas(1));
}

test "higher valid StartView adoption emits no StartViewChange" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xAD0A7);
    defer tc.deinit();
    const follower = tc.replicas[1];
    follower.status = .normal;
    follower.view_number = 0;
    const svc_tag = @intFromEnum(msg.Tag.start_view_change);
    const before = tc.network.stats.sent[svc_tag];

    follower.onMessage(0, .{ .start_view = .{ .view_number = 3 } });

    try std.testing.expectEqual(before, tc.network.stats.sent[svc_tag]);
    try std.testing.expectEqual(msg.Status.view_change, follower.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 3), follower.view_number);
    try std.testing.expect(follower.pending_start_view.active);
}

test "onStartView accepts valid bounded message" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7014);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7014, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7014);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 0;
    replica.commit_min = 0;
    replica.commit_max = 0;
    replica.op_number = 0;

    var entry1 = msg.LogEntry{
        .view_number = 3,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry1.checksum = entry1.computeChecksum();

    var sv = msg.StartViewMsg{
        .view_number = 3,
        .selected_last_normal_view = 0,
        .op_number = 1,
        .tip_checksum = entry1.checksum,
        .commit_min = 0,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = entry1;
    replica.onMessage(0, .{ .start_view = sv });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    replica.tick();
    try std.testing.expectEqual(msg.Status.normal, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 3), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expectEqual(entry1.checksum, replica.journalGet(1).?.checksum);
}

test "onStartView rejects broken prospective parent chain before mutation" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7020);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7020, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7020);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 0;
    replica.commit_min = 0;
    replica.commit_max = 0;
    replica.op_number = 0;

    var committed = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    committed.checksum = committed.computeChecksum();
    replica.journalPut(committed);
    replica.op_number = 1;
    replica.commit_min = 1;
    replica.commit_max = 1;

    var bad_child = msg.LogEntry{
        .view_number = 3,
        .op_number = 2,
        .command = .{ .noop = {} },
        .client_id = 2,
        .request_id = 2,
        .parent_checksum = 0xDEADBEEF, // does not match local committed predecessor
    };
    bad_child.checksum = bad_child.computeChecksum();

    // Leader for view 3 with replica_count=3 is replica 0.
    var sv = msg.StartViewMsg{
        .view_number = 3,
        .op_number = 2,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 1,
    };
    sv.log_entries[0] = bad_child;
    replica.onMessage(0, .{ .start_view = sv });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expect(!replica.journalHas(2));
    try std.testing.expectEqual(committed.checksum, replica.journalGet(1).?.checksum);

    // Incoming adjacent entries with a broken parent link must also be rejected.
    var e1 = msg.LogEntry{
        .view_number = 3,
        .op_number = 2,
        .command = .{ .noop = {} },
        .client_id = 3,
        .request_id = 3,
        .parent_checksum = committed.checksum,
    };
    e1.checksum = e1.computeChecksum();
    var e2 = msg.LogEntry{
        .view_number = 3,
        .op_number = 3,
        .command = .{ .noop = {} },
        .client_id = 4,
        .request_id = 4,
        .parent_checksum = 0xBAD0BAD0,
    };
    e2.checksum = e2.computeChecksum();
    var sv_chain = msg.StartViewMsg{
        .view_number = 3,
        .op_number = 3,
        .commit_min = 1,
        .retention_floor = 0,
        .log_entry_count = 2,
    };
    sv_chain.log_entries[0] = e1;
    sv_chain.log_entries[1] = e2;
    replica.onMessage(0, .{ .start_view = sv_chain });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 0), replica.view_number);
    try std.testing.expect(!replica.journalHas(2));
    try std.testing.expect(!replica.journalHas(3));
}

test "onCommit advancing requires nonzero checksum and exact local match" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7021);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7021, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7021);

    const replica = try allocator.create(Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .view_change;
    replica.view_number = 1;
    replica.commit_min = 0;
    replica.commit_max = 0;
    replica.op_number = 0;
    replica.retention_floor = 0;

    var e1 = msg.LogEntry{
        .view_number = 1,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    e1.checksum = e1.computeChecksum();
    replica.journalPut(e1);
    replica.op_number = 1;

    const journal_checksum_before = e1.checksum;
    const sm_seed_before = sm.seed;

    // Advancing with zero commit_checksum must not mutate view/status/log.
    // Leader for view 2 with replica_count=3 is replica 2.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 1,
        .commit_max = 1,
        .op_number = 1,
        .retention_floor = 0,
        .commit_checksum = 0,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 1), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.retention_floor);
    try std.testing.expectEqual(journal_checksum_before, replica.journalGet(1).?.checksum);
    try std.testing.expectEqual(sm_seed_before, sm.seed);

    // A nonzero higher-view checksum that conflicts with speculative local A
    // enters view change so StartView can install the leader's committed B.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 1,
        .commit_max = 1,
        .op_number = 1,
        .retention_floor = 0,
        .commit_checksum = journal_checksum_before ^ 1,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 2), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expect(replica.journalHas(1));
    try std.testing.expectEqual(journal_checksum_before, replica.journalGet(1).?.checksum);
    try std.testing.expectEqual(sm_seed_before, sm.seed);
    try std.testing.expect(!replica.transfer_pending);

    // A valid higher-view Commit is not an adoption record. It can move the
    // follower into view change, but cannot promote or commit its local suffix.
    replica.onMessage(2, .{ .commit = .{
        .view_number = 2,
        .commit_min = 1,
        .commit_max = 1,
        .op_number = 1,
        .retention_floor = 0,
        .commit_checksum = journal_checksum_before,
    } });
    try std.testing.expectEqual(msg.Status.view_change, replica.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 2), replica.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), replica.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), replica.op_number);
    try std.testing.expectEqual(journal_checksum_before, replica.journalGet(1).?.checksum);
}

test "higher-view Prepare retains suffix and requests StartView adoption" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0x57A27);
    defer tc.deinit();
    tc.network.min_delay = 0;

    const leader = tc.replicas[2];
    const follower = tc.replicas[1];
    var committed = msg.LogEntry{ .view_number = 0, .op_number = 1, .client_id = 7, .request_id = 1 };
    committed.checksum = committed.computeChecksum();
    var speculative = msg.LogEntry{ .view_number = 0, .op_number = 2, .client_id = 7, .request_id = 2, .parent_checksum = committed.checksum };
    speculative.checksum = speculative.computeChecksum();
    var proposed = msg.LogEntry{ .view_number = 2, .op_number = 2, .client_id = 8, .request_id = 2, .parent_checksum = committed.checksum };
    proposed.checksum = proposed.computeChecksum();

    follower.journalPut(committed);
    follower.journalPut(speculative);
    follower.op_number = 2;
    follower.commit_min = 1;
    follower.commit_max = 1;
    follower.durable_prepare_op[journalSlot(1)] = 1;
    follower.durable_prepare_checksum[journalSlot(1)] = committed.checksum;

    leader.status = .normal;
    leader.view_number = 2;
    leader.last_normal_view = 2;
    leader.journalPut(committed);
    leader.op_number = 1;
    leader.commit_min = 1;
    leader.commit_max = 1;
    leader.selected_source = 2;
    leader.selected_last_normal_view = 0;
    leader.selected_tip_op = 1;
    leader.selected_tip_checksum = committed.checksum;
    leader.selected_commit_bound = 1;
    leader.durable_prepare_op[journalSlot(1)] = 1;
    leader.durable_prepare_checksum[journalSlot(1)] = committed.checksum;

    const request_tag = @intFromEnum(msg.Tag.request_start_view);
    const before = tc.network.stats.sent[request_tag];
    tc.deliver(1, 2, .{ .prepare = .{
        .view_number = 2,
        .op_number = 2,
        .commit_min = 1,
        .retention_floor = 0,
        .entry = proposed,
    } });

    try std.testing.expectEqual(msg.Status.view_change, follower.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 2), follower.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), follower.commit_min);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), follower.op_number);
    try std.testing.expectEqual(speculative.checksum, follower.journalGet(2).?.checksum);
    try std.testing.expectEqual(before + 1, tc.network.stats.sent[request_tag]);

    const start_view_tag = @intFromEnum(msg.Tag.start_view);
    const start_view_before = tc.network.stats.sent[start_view_tag];
    leader.onMessage(1, .{ .request_start_view = .{ .view_number = 2 } });
    try std.testing.expectEqual(start_view_before + 1, tc.network.stats.sent[start_view_tag]);
    follower.onMessage(2, .{ .start_view = leader.buildStartView() });
    try std.testing.expect(follower.pending_start_view.active);
    try std.testing.expectEqual(msg.Status.view_change, follower.status);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), follower.op_number);
    follower.tick();
    try std.testing.expectEqual(msg.Status.normal, follower.status);
    try std.testing.expectEqual(@as(msg.ViewNumber, 2), follower.view_number);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), follower.op_number);
    try std.testing.expect(!follower.journalHas(2));
}

test "selection-bound RequestPrepare serves retained source across later current view" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 5, 0x50A2CE);
    defer tc.deinit();
    tc.network.min_delay = 0;
    tc.network.max_delay = 0;
    const source = tc.replicas[4];
    source.status = .view_change;
    source.view_number = 9;
    source.last_normal_view = 4;

    var parent: u64 = 0;
    var entries: [3]msg.LogEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{ .view_number = 4, .op_number = index + 1, .client_id = 40, .request_id = index + 1, .parent_checksum = parent };
        entry.checksum = entry.computeChecksum();
        parent = entry.checksum;
        source.journalPut(entry.*);
    }
    source.op_number = 3;
    source.commit_min = 1;
    source.commit_max = 1;

    const request = msg.RequestPrepareMsg{
        .view_number = 7,
        .op_number = 1,
        .selected_source = 4,
        .selected_last_normal_view = 4,
        .selected_tip_op = 3,
        .selected_tip_checksum = entries[2].checksum,
        .selected_commit_bound = 1,
        .expected_entry_checksum = entries[0].checksum,
    };
    const send_tag = @intFromEnum(msg.Tag.send_prepare);
    const before = tc.network.stats.sent[send_tag];
    source.onMessage(2, .{ .request_prepare = request });
    try std.testing.expectEqual(before + 1, tc.network.stats.sent[send_tag]);

    var wire: [16 * 1024]u8 = undefined;
    const received = tc.network.deliverAndMaybeReplay(2, &wire) orelse return error.TestUnexpectedResult;
    const response = try msg.deserialize(wire[0..received.len]);
    try std.testing.expectEqual(@as(msg.ViewNumber, 7), response.send_prepare.view_number);
    try std.testing.expectEqual(entries[0].checksum, response.send_prepare.entry.checksum);

    var changed_lnv = request;
    changed_lnv.selected_last_normal_view += 1;
    source.onMessage(2, .{ .request_prepare = changed_lnv });
    try std.testing.expectEqual(before + 1, tc.network.stats.sent[send_tag]);

    var changed_tip = request;
    changed_tip.selected_tip_checksum ^= 1;
    source.onMessage(2, .{ .request_prepare = changed_tip });
    try std.testing.expectEqual(before + 1, tc.network.stats.sent[send_tag]);

    source.onMessage(2, .{ .request_prepare = .{ .view_number = 7, .op_number = 1 } });
    try std.testing.expectEqual(before + 1, tc.network.stats.sent[send_tag]);

    source.pending_start_view = .{
        .active = true,
        .role = .follower,
        .target_view = 9,
        .op_number = 3,
        .commit_min = 1,
    };
    source.onMessage(2, .{ .request_prepare = request });
    try std.testing.expectEqual(before + 2, tc.network.stats.sent[send_tag]);
}

test "PrepareOk binds votes to exact entry identity and sender" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xACCE55);
    defer tc.deinit();
    const leader = tc.replicas[0];

    var entry_a = msg.LogEntry{ .view_number = 0, .op_number = 1, .command = .{ .noop = {} }, .client_id = 1, .request_id = 1 };
    entry_a.checksum = entry_a.computeChecksum();
    var entry_b = entry_a;
    entry_b.client_id = 2;
    entry_b.request_id = 2;
    entry_b.checksum = entry_b.computeChecksum();
    try std.testing.expect(entry_a.checksum != entry_b.checksum);

    leader.journalPut(entry_b);
    leader.op_number = 1;
    const slot = journalSlot(1);
    leader.prepare_ok_counts[slot] = 1;
    leader.prepare_ok_from[slot] = 1;

    try std.testing.expect(!peerMessageSemanticsValid(.{ .prepare_ok = .{ .view_number = 0, .op_number = 1, .replica_id = 1, .entry_checksum = 0 } }));
    leader.onMessage(1, .{ .prepare_ok = .{ .view_number = 1, .op_number = 1, .replica_id = 1, .entry_checksum = entry_b.checksum } });
    try std.testing.expectEqual(@as(u8, 1), leader.prepare_ok_counts[slot]);

    leader.onMessage(1, .{ .prepare_ok = .{ .view_number = 0, .op_number = 1, .replica_id = 1, .entry_checksum = entry_a.checksum } });
    try std.testing.expectEqual(@as(u8, 1), leader.prepare_ok_counts[slot]);
    try std.testing.expectEqual(@as(msg.OpNumber, 0), leader.commit_min);

    leader.onMessage(1, .{ .prepare_ok = .{ .view_number = 0, .op_number = 1, .replica_id = 1, .entry_checksum = entry_b.checksum } });
    try std.testing.expectEqual(@as(u8, 2), leader.prepare_ok_counts[slot]);
    try std.testing.expectEqual(@as(msg.OpNumber, 1), leader.commit_min);

    leader.onMessage(1, .{ .prepare_ok = .{ .view_number = 0, .op_number = 1, .replica_id = 1, .entry_checksum = entry_b.checksum } });
    try std.testing.expectEqual(@as(u8, 2), leader.prepare_ok_counts[slot]);
    leader.onMessage(2, .{ .prepare_ok = .{ .view_number = 0, .op_number = 1, .replica_id = 1, .entry_checksum = entry_b.checksum } });
    try std.testing.expectEqual(@as(u8, 2), leader.prepare_ok_counts[slot]);
}

test "same-view conflicting Prepare preserves durable prepared identity" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xD0AB1E);
    defer tc.deinit();
    const follower = tc.replicas[1];

    var entry_a = msg.LogEntry{ .view_number = 0, .op_number = 1, .command = .{ .noop = {} }, .client_id = 1, .request_id = 1 };
    entry_a.checksum = entry_a.computeChecksum();
    var entry_b = entry_a;
    entry_b.client_id = 2;
    entry_b.request_id = 2;
    entry_b.checksum = entry_b.computeChecksum();
    follower.journalPut(entry_a);
    follower.op_number = 1;
    const slot = journalSlot(1);
    follower.durable_prepare_op[slot] = 1;
    follower.durable_prepare_checksum[slot] = entry_a.checksum;

    follower.onMessage(0, .{ .prepare = .{ .view_number = 0, .op_number = 1, .entry = entry_b } });
    try std.testing.expectEqual(entry_a.checksum, follower.journalGet(1).?.checksum);
    try std.testing.expectEqual(entry_a.checksum, follower.durable_prepare_checksum[slot]);

    follower.journalPut(entry_b);
    try std.testing.expectEqual(entry_a.checksum, follower.journalGet(1).?.checksum);
    try std.testing.expectEqual(entry_a.checksum, follower.durable_prepare_checksum[slot]);
}

test "leader StartView durable sync survives crash before broadcast" {
    const tc = try @import("vopr/test_harness.zig").TestCluster.init(std.testing.allocator, 3, 0xD07AB1E);
    defer tc.deinit();
    const leader = tc.replicas[0];
    leader.status = .view_change;
    leader.view_number = 3;
    leader.pending_view_selection = true;
    leader.selected_source = 1;
    leader.selected_last_normal_view = 2;
    leader.selected_target_view = 3;
    leader.selected_commit_bound = 0;

    var first = msg.LogEntry{ .view_number = 2, .op_number = 1, .client_id = 1, .request_id = 1 };
    first.checksum = first.computeChecksum();
    var second = msg.LogEntry{ .view_number = 2, .op_number = 2, .client_id = 1, .request_id = 2, .parent_checksum = first.checksum };
    second.checksum = second.computeChecksum();
    leader.journalPutFromValidatedStartView(first);
    leader.journalPutFromValidatedStartView(second);
    leader.selected_tip_op = 2;
    leader.selected_tip_checksum = second.checksum;
    leader.view_change_candidate.phase = .candidate_complete;
    leader.startViewCandidateReady();
    try std.testing.expect(leader.pending_start_view.active);

    const start_view_tag = @intFromEnum(msg.Tag.start_view);
    const before = tc.network.stats.sent[start_view_tag];
    var disk = leader.disk.?;
    try std.testing.expect(leader.syncPendingStartView(&disk, .leader_start_view));
    try std.testing.expectEqual(msg.Status.view_change, leader.status);
    try std.testing.expect(leader.pending_start_view.active);
    try std.testing.expectEqual(before, tc.network.stats.sent[start_view_tag]);

    tc.crashReplica(0);
    try std.testing.expectEqual(@as(msg.OpNumber, 2), tc.replicas[0].op_number);
    try std.testing.expectEqual(second.checksum, tc.replicas[0].journalGet(2).?.checksum);
}

test "sendCommitHeartbeat never emits zero checksum for advancing target" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7022);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7022, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7022);

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

    var e1 = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    e1.checksum = e1.computeChecksum();
    replica.journalPut(e1);
    replica.op_number = 1;
    replica.commit_min = 1;
    replica.commit_max = 1;

    const Capture = struct {
        checksum: u64 = 0,
        seen: bool = false,

        fn send(ctx: *anyopaque, to: u8, data: []const u8) void {
            _ = to;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (data.len < 5) return;
            const message = msg.deserialize(data[5..]) catch return;
            switch (message) {
                .commit => |c| {
                    self.checksum = c.commit_checksum;
                    self.seen = true;
                },
                else => {},
            }
        }
    };
    var capture = Capture{};
    replica.peer_send_ctx = &capture;
    replica.peer_send_fn = Capture.send;

    replica.sendCommitHeartbeat();
    try std.testing.expect(capture.seen);
    try std.testing.expect(capture.checksum != 0);
    try std.testing.expectEqual(e1.checksum, capture.checksum);
}
