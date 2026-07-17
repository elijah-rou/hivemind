const std = @import("std");

// ---------------------------------------------------------------------------
// VRR identifiers
// ---------------------------------------------------------------------------

pub const ViewNumber = u64;
pub const OpNumber = u64;
pub const RequestId = u128;
pub const NodeId = u64;
pub const DeploymentId = u64;
pub const PodId = u64;

pub const REPLICA_COUNT_MAX: u8 = 11;

pub const Status = enum(u8) {
    normal,
    view_change,
    recovering,
};

// ---------------------------------------------------------------------------
// Hardware types
// ---------------------------------------------------------------------------

pub const GpuType = enum(u8) {
    none,
    a100_40,
    a100_80,
    h100_sxm,
    h100_pcie,
    h200,
    l40s,
    a10g,
    t4,
};

pub const NodeStatus = enum(u8) {
    provisioning,
    starting,
    ready,
    unhealthy,
    draining,
    terminating,
    terminated,
};

pub const PodPhase = enum(u8) {
    pending,
    scheduled,
    running,
    succeeded,
    failed,
    terminating,
};

// ---------------------------------------------------------------------------
// Shared sub-types for deployment specs
// ---------------------------------------------------------------------------

pub const EnvEntry = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    value: [256]u8 = std.mem.zeroes([256]u8),
    is_secret_ref: bool = false,
};

pub const TrafficRule = struct {
    version: u32 = 0,
    weight: u8 = 0,
};

pub const ProbeConfig = struct {
    path: [64]u8 = std.mem.zeroes([64]u8),
    interval_ms: u32 = 10000,
    timeout_ms: u32 = 5000,
    enabled: bool = false,
};

// ---------------------------------------------------------------------------
// State machine commands -- replicated through VRR consensus
// ---------------------------------------------------------------------------

pub const Command = union(enum(u8)) {
    register_node: RegisterNodeCmd,
    deregister_node: DeregisterNodeCmd,
    update_node_status: UpdateNodeStatusCmd,
    create_deployment: CreateDeploymentCmd,
    bind_pod_to_node: BindPodToNodeCmd,
    update_pod_status: UpdatePodStatusCmd,
    scale_deployment: ScaleDeploymentCmd,
    unbind_pod: UnbindPodCmd,
    set_killswitch: SetKillswitchCmd,
    noop: void,
    update_deployment: UpdateDeploymentCmd,
    set_traffic_split: SetTrafficSplitCmd,
    rollback_deployment: RollbackDeploymentCmd,
    delete_deployment: DeleteDeploymentCmd,
    pause_deployment: PauseDeploymentCmd,
    resume_deployment: ResumeDeploymentCmd,
    bind_pods_to_nodes: BindPodsToNodesCmd,
};

pub const RegisterNodeCmd = struct {
    node_name: [64]u8 = std.mem.zeroes([64]u8),
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
};

pub const DeregisterNodeCmd = struct {
    node_id: NodeId = 0,
};

pub const UpdateNodeStatusCmd = struct {
    node_id: NodeId = 0,
    new_status: NodeStatus = .provisioning,
};

pub const CreateDeploymentCmd = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    namespace: [64]u8 = std.mem.zeroes([64]u8),
    image: [256]u8 = std.mem.zeroes([256]u8),
    entrypoint: [256]u8 = std.mem.zeroes([256]u8),
    port: u16 = 8080,
    replicas: u32 = 1,
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    min_replicas: u32 = 0,
    max_replicas: u32 = 10,
    scale_to_zero_after_ms: u64 = 0,
    target_queue_depth: u32 = 1,
    liveness: ProbeConfig = .{},
    readiness: ProbeConfig = .{},
    startup_timeout_ms: u32 = 30000,
    juicefs_path: [128]u8 = std.mem.zeroes([128]u8),
    env_vars: [16]EnvEntry = [_]EnvEntry{.{}} ** 16,
    env_count: u8 = 0,
    /// Optional registry host hint (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com). Image should still be fully qualified for pulls.
    image_pull_registry: [128]u8 = std.mem.zeroes([128]u8),
    image_pull_username: [64]u8 = std.mem.zeroes([64]u8),
    image_pull_password: [256]u8 = std.mem.zeroes([256]u8),
    /// When set, `image_pull_password` holds a Doppler secret name (resolved on the agent).
    image_pull_password_is_secret: u8 = 0,
};

pub const BindPodToNodeCmd = struct {
    pod_id: PodId = 0,
    node_id: NodeId = 0,
};

pub const BIND_BATCH_MAX: usize = 64;

pub const PodBinding = struct {
    pod_id: PodId = 0,
    node_id: NodeId = 0,
};

pub const BindPodsToNodesCmd = struct {
    bindings: [BIND_BATCH_MAX]PodBinding = [_]PodBinding{.{}} ** BIND_BATCH_MAX,
    count: u8 = 0,
};

pub const UpdatePodStatusCmd = struct {
    pod_id: PodId = 0,
    new_phase: PodPhase = .pending,
};

pub const ScaleDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
    desired_replicas: u32 = 0,
};

pub const UnbindPodCmd = struct {
    pod_id: PodId = 0,
};

pub const SetKillswitchCmd = struct {
    node_id: NodeId = 0,
    deployment_id: DeploymentId = 0,
    active: bool = false,
};

pub const UpdateDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
    image: [256]u8 = std.mem.zeroes([256]u8),
    entrypoint: [256]u8 = std.mem.zeroes([256]u8),
    port: u16 = 0,
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    env_vars: [16]EnvEntry = [_]EnvEntry{.{}} ** 16,
    env_count: u8 = 0,
};

pub const SetTrafficSplitCmd = struct {
    deployment_id: DeploymentId = 0,
    rules: [4]TrafficRule = [_]TrafficRule{.{}} ** 4,
    rule_count: u8 = 0,
};

pub const RollbackDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const DeleteDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const PauseDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const ResumeDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub const ErrorCode = enum(u8) {
    ok,
    not_found,
    already_exists,
    capacity_exceeded,
    invalid_transition,
    not_leader,
    /// Retained log is full; no snapshot floor exists to truncate committed ops.
    log_full,
};

pub const ResultData = struct {
    entity_id: u64 = 0,
};

pub const Result = union(enum(u8)) {
    ok: ResultData,
    err: ErrorCode,
};

// ---------------------------------------------------------------------------
// VRR protocol messages
// ---------------------------------------------------------------------------

pub const LogEntry = struct {
    checksum: u64 = 0,
    parent_checksum: u64 = 0,
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    command: Command = .{ .noop = {} },
    client_id: u128 = 0,
    request_id: RequestId = 0,

    pub fn computeChecksum(self: *const LogEntry) u64 {
        var hasher = std.hash.Wyhash.init(0);
        var u64_wire: [8]u8 = undefined;
        var u128_wire: [16]u8 = undefined;
        std.mem.writeInt(u64, &u64_wire, self.parent_checksum, .little);
        hasher.update(&u64_wire);
        std.mem.writeInt(u64, &u64_wire, self.view_number, .little);
        hasher.update(&u64_wire);
        std.mem.writeInt(u64, &u64_wire, self.op_number, .little);
        hasher.update(&u64_wire);
        var cmd_wire: [COMMAND_CANONICAL_SIZE]u8 = undefined;
        writeCanonicalCommand(&cmd_wire, self.command);
        hasher.update(&cmd_wire);
        std.mem.writeInt(u128, &u128_wire, self.client_id, .little);
        hasher.update(&u128_wire);
        std.mem.writeInt(u128, &u128_wire, self.request_id, .little);
        hasher.update(&u128_wire);
        return hasher.final();
    }

    pub fn valid(self: *const LogEntry) bool {
        return self.checksum == self.computeChecksum();
    }
};

pub const RequestMsg = struct {
    client_id: u128 = 0,
    request_id: RequestId = 0,
    command: Command = .{ .noop = {} },
};

pub const PrepareMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    entry: LogEntry = .{},
};

pub const PrepareOkMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    replica_id: u8 = 0,
    commit_min: OpNumber = 0,
    entry_checksum: u64 = 0,
    commit_checksum: u64 = 0,
};

pub const CommitMsg = struct {
    view_number: ViewNumber = 0,
    commit_min: OpNumber = 0,
    commit_max: OpNumber = 0,
    op_number: OpNumber = 0,
    retention_floor: OpNumber = 0,
    commit_checksum: u64 = 0,
};

pub const ReplyMsg = struct {
    view_number: ViewNumber = 0,
    request_id: RequestId = 0,
    result: Result = .{ .ok = .{} },
};

pub const StartViewChangeMsg = struct {
    view_number: ViewNumber = 0,
    replica_id: u8 = 0,
};

pub const DVC_LOG_MAX: usize = 8;
pub const LOG_BITSET_WORDS: usize = 16;
pub const LOG_BITSET_BITS: usize = LOG_BITSET_WORDS * 64;

pub const DoViewChangeMsg = struct {
    view_number: ViewNumber = 0,
    replica_id: u8 = 0,
    last_normal_view: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    log_entries: [DVC_LOG_MAX]LogEntry = [_]LogEntry{.{}} ** DVC_LOG_MAX,
    log_entry_count: u8 = 0,
    present_bitset: [LOG_BITSET_WORDS]u64 = std.mem.zeroes([LOG_BITSET_WORDS]u64),
    nack_bitset: [LOG_BITSET_WORDS]u64 = std.mem.zeroes([LOG_BITSET_WORDS]u64),
};

pub const SV_LOG_MAX: usize = 8;

pub const StartViewMsg = struct {
    view_number: ViewNumber = 0,
    selected_last_normal_view: ViewNumber = 0,
    op_number: OpNumber = 0,
    tip_checksum: u64 = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    log_entries: [SV_LOG_MAX]LogEntry = [_]LogEntry{.{}} ** SV_LOG_MAX,
    log_entry_count: u8 = 0,
};

pub const RequestPrepareMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    selected_source: u8 = 0,
    selected_last_normal_view: ViewNumber = 0,
    selected_tip_op: OpNumber = 0,
    selected_tip_checksum: u64 = 0,
    selected_commit_bound: OpNumber = 0,
    expected_entry_checksum: u64 = 0,
};

pub const SendPrepareMsg = struct {
    view_number: ViewNumber = 0,
    entry: LogEntry = .{},
    selected_source: u8 = 0,
    selected_last_normal_view: ViewNumber = 0,
    selected_tip_op: OpNumber = 0,
    selected_tip_checksum: u64 = 0,
    selected_commit_bound: OpNumber = 0,
    expected_entry_checksum: u64 = 0,
};

pub const RequestStatusMsg = struct {
    view_number: ViewNumber = 0,
};

pub const RequestStartViewMsg = struct {
    view_number: ViewNumber = 0,
};

pub const SendStatusMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    tip_checksum: u64 = 0,
    commit_checksum: u64 = 0,
};

pub const Tag = enum(u8) {
    request,
    prepare,
    prepare_ok,
    commit,
    reply,
    start_view_change,
    do_view_change,
    start_view,
    request_prepare,
    send_prepare,
    request_status,
    send_status,
    request_start_view,
};

pub const Message = union(Tag) {
    request: RequestMsg,
    prepare: PrepareMsg,
    prepare_ok: PrepareOkMsg,
    commit: CommitMsg,
    reply: ReplyMsg,
    start_view_change: StartViewChangeMsg,
    do_view_change: DoViewChangeMsg,
    start_view: StartViewMsg,
    request_prepare: RequestPrepareMsg,
    send_prepare: SendPrepareMsg,
    request_status: RequestStatusMsg,
    send_status: SendStatusMsg,
    request_start_view: RequestStartViewMsg,
};

// ---------------------------------------------------------------------------
// Client protocol tags
// ---------------------------------------------------------------------------

pub const ClientTag = enum(u8) {
    request = 0x20, // client → hivemind: consensus command
    reply = 0x21, // hivemind → client: consensus reply
    run_request = 0x22, // client → hivemind: run (no consensus)
    run_response = 0x23, // hivemind → client: run response
    cluster_state_request = 0x24, // client → hivemind: read-only state query
    cluster_state_response = 0x25, // hivemind → client: state snapshot
    leader_probe_request = 0x26, // client → hivemind: fixed-size leader query
    leader_probe_response = 0x27, // hivemind → client: fixed-size leader identity
};

pub const LEADER_PROBE_REQUEST_BYTES: usize = 0;
pub const LEADER_PROBE_RESPONSE_BYTES: usize = 12;

pub const LeaderProbeResponse = struct {
    status: Status,
    is_leader: bool,
    replica_id: u8,
    leader_id: u8,
    view_number: ViewNumber,

    pub fn encode(self: LeaderProbeResponse) [LEADER_PROBE_RESPONSE_BYTES]u8 {
        var out: [LEADER_PROBE_RESPONSE_BYTES]u8 = undefined;
        out[0] = @intFromEnum(self.status);
        out[1] = @intFromBool(self.is_leader);
        out[2] = self.replica_id;
        out[3] = self.leader_id;
        @memcpy(out[4..12], &std.mem.toBytes(std.mem.nativeToLittle(ViewNumber, self.view_number)));
        return out;
    }

    pub fn decode(bytes: []const u8) !LeaderProbeResponse {
        if (bytes.len != LEADER_PROBE_RESPONSE_BYTES) return error.InvalidLength;
        const status = enumFromIntChecked(Status, bytes[0]) catch return error.InvalidStatus;
        if (bytes[1] > 1) return error.InvalidBoolean;
        if (bytes[2] >= REPLICA_COUNT_MAX) return error.InvalidReplica;
        if (bytes[3] >= REPLICA_COUNT_MAX) return error.InvalidLeader;
        return .{
            .status = status,
            .is_leader = bytes[1] == 1,
            .replica_id = bytes[2],
            .leader_id = bytes[3],
            .view_number = std.mem.littleToNative(ViewNumber, std.mem.bytesToValue(ViewNumber, bytes[4..12])),
        };
    }
};

comptime {
    std.debug.assert(LEADER_PROBE_RESPONSE_BYTES == 12);
}

test "leader probe response golden and malformed contract" {
    const golden = [_]u8{ 0, 1, 2, 2, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 };
    const response = LeaderProbeResponse{ .status = .normal, .is_leader = true, .replica_id = 2, .leader_id = 2, .view_number = 0x0102030405060708 };
    try std.testing.expectEqualSlices(u8, &golden, &response.encode());
    try std.testing.expectEqual(response, try LeaderProbeResponse.decode(&golden));
    try std.testing.expectError(error.InvalidLength, LeaderProbeResponse.decode(golden[0..11]));
    var malformed = golden;
    malformed[1] = 2;
    try std.testing.expectError(error.InvalidBoolean, LeaderProbeResponse.decode(&malformed));
}

// ---------------------------------------------------------------------------
// Worker protocol messages (bidirectional over worker-initiated TCP)
// ---------------------------------------------------------------------------

pub const WorkerTag = enum(u8) {
    // Hivemind -> Worker
    register_ack = 0x01,
    start_pod = 0x02,
    stop_pod = 0x03,
    run_request = 0x04,

    // Worker -> Hivemind
    register = 0x10,
    heartbeat = 0x11,
    pod_status = 0x12,
    run_response = 0x13,
};

pub const WorkerRegisterMsg = struct {
    hostname: [64]u8 = std.mem.zeroes([64]u8),
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
};

pub const WorkerHeartbeatMsg = struct {
    timestamp: u64 = 0,
    cpu_usage_pct: u8 = 0,
    memory_used_mb: u32 = 0,
    gpu_utilization: [8]u8 = std.mem.zeroes([8]u8),
    pods_running: u16 = 0,
};

pub const WorkerPodStatusMsg = struct {
    pod_id: u64 = 0,
    old_phase: PodPhase = .pending,
    new_phase: PodPhase = .pending,
    timestamp: u64 = 0,
    exit_code: i32 = 0,
    message: [128]u8 = std.mem.zeroes([128]u8),
};

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Largest Command variant payload (bytes). Wire Command is tag + this payload,
/// zero-padded to @sizeOf(Command) so outer message field offsets stay stable.
pub const COMMAND_PAYLOAD_MAX: usize = blk: {
    var max: usize = 0;
    for (@typeInfo(Command).@"union".fields) |field| {
        max = @max(max, @sizeOf(field.type));
    }
    break :blk max;
};

fn canonicalSize(comptime T: type) usize {
    if (T == void) return 0;
    if (T == bool) return 1;
    return switch (@typeInfo(T)) {
        .int, .float, .@"enum" => @sizeOf(T),
        .array => |array| array.len * canonicalSize(array.child),
        .@"struct" => blk: {
            var size: usize = 0;
            inline for (std.meta.fields(T)) |field| size += canonicalSize(field.type);
            break :blk size;
        },
        else => @compileError("unsupported canonical command field type"),
    };
}

/// Stable tag-first little-endian Command size, independent of struct padding/ABI.
pub const COMMAND_CANONICAL_SIZE: usize = blk: {
    var max: usize = 0;
    for (@typeInfo(Command).@"union".fields) |field| {
        max = @max(max, canonicalSize(field.type));
    }
    break :blk 1 + max;
};

comptime {
    // Tag + max payload must fit in the in-memory Command storage we reserve on the wire.
    if (1 + COMMAND_PAYLOAD_MAX > @sizeOf(Command)) @compileError("Command wire payload exceeds @sizeOf(Command)");
    if (1 + @sizeOf(ResultData) > @sizeOf(Result)) @compileError("Result wire payload exceeds @sizeOf(Result)");
}

pub fn serialize(msg: Message, buf: []u8) usize {
    const tag_byte: u8 = @intFromEnum(std.meta.activeTag(msg));
    buf[0] = tag_byte;
    const payload_len = serializePayload(msg, buf[1..]);
    return 1 + payload_len;
}

pub fn enumFromIntChecked(comptime E: type, value: @typeInfo(E).@"enum".tag_type) !E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return error.InvalidEnumTag;
}

fn validateBoolByte(raw: u8) !bool {
    return switch (raw) {
        0 => false,
        1 => true,
        else => error.InvalidBool,
    };
}

fn writeBool(dst: []u8, value: bool) void {
    std.debug.assert(dst.len >= 1);
    dst[0] = if (value) 1 else 0;
}

fn writeStructFields(comptime T: type, dst: []u8, value: T) void {
    std.debug.assert(dst.len >= @sizeOf(T));
    @memset(dst[0..@sizeOf(T)], 0);
    inline for (std.meta.fields(T)) |field| {
        const offset = @offsetOf(T, field.name);
        const field_size = @sizeOf(field.type);
        const field_val = @field(value, field.name);
        writeValue(field.type, dst[offset..][0..field_size], field_val);
    }
}

fn writeValue(comptime T: type, dst: []u8, value: T) void {
    if (T == void) return;
    if (T == bool) {
        writeBool(dst, value);
        return;
    }
    if (T == Command) {
        writeCommand(dst, value);
        return;
    }
    if (T == Result) {
        writeResult(dst, value);
        return;
    }
    if (T == LogEntry) {
        writeLogEntry(dst, value);
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => writeStructFields(T, dst, value),
        .@"enum" => {
            const raw: @typeInfo(T).@"enum".tag_type = @intFromEnum(value);
            @memcpy(dst[0..@sizeOf(T)], std.mem.asBytes(&raw));
        },
        .array => |a| {
            if (a.child == u8) {
                @memcpy(dst[0..@sizeOf(T)], std.mem.asBytes(&value));
                return;
            }
            var i: usize = 0;
            while (i < a.len) : (i += 1) {
                const elem_size = @sizeOf(a.child);
                writeValue(a.child, dst[i * elem_size ..][0..elem_size], value[i]);
            }
        },
        .int, .float => @memcpy(dst[0..@sizeOf(T)], std.mem.asBytes(&value)),
        else => @memcpy(dst[0..@sizeOf(T)], std.mem.asBytes(&value)),
    }
}

fn readStructFields(comptime T: type, src: []const u8) !T {
    if (src.len < @sizeOf(T)) return error.MessageTooShort;
    var out: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const offset = @offsetOf(T, field.name);
        const field_size = @sizeOf(field.type);
        @field(out, field.name) = try readValue(field.type, src[offset..][0..field_size]);
    }
    return out;
}

fn readValue(comptime T: type, src: []const u8) !T {
    if (T == void) return {};
    if (T == bool) {
        if (src.len < 1) return error.MessageTooShort;
        return try validateBoolByte(src[0]);
    }
    if (T == Command) return try readCommand(src);
    if (T == Result) return try readResult(src);
    if (T == LogEntry) return try readLogEntry(src);
    switch (@typeInfo(T)) {
        .@"struct" => return try readStructFields(T, src),
        .@"enum" => {
            if (src.len < @sizeOf(T)) return error.MessageTooShort;
            const raw = std.mem.bytesToValue(@typeInfo(T).@"enum".tag_type, src[0..@sizeOf(@typeInfo(T).@"enum".tag_type)]);
            return try enumFromIntChecked(T, raw);
        },
        .array => |a| {
            if (src.len < @sizeOf(T)) return error.MessageTooShort;
            if (a.child == u8) {
                return std.mem.bytesToValue(T, src[0..@sizeOf(T)]);
            }
            var out: T = undefined;
            var i: usize = 0;
            while (i < a.len) : (i += 1) {
                const elem_size = @sizeOf(a.child);
                out[i] = try readValue(a.child, src[i * elem_size ..][0..elem_size]);
            }
            return out;
        },
        .int, .float => {
            if (src.len < @sizeOf(T)) return error.MessageTooShort;
            return std.mem.bytesToValue(T, src[0..@sizeOf(T)]);
        },
        else => {
            if (src.len < @sizeOf(T)) return error.MessageTooShort;
            return std.mem.bytesToValue(T, src[0..@sizeOf(T)]);
        },
    }
}

/// Fixed Command wire layout: [tag:u8][payload...][pad to @sizeOf(Command)].
/// Tag is validated before any union is constructed.
pub fn writeCommand(dst: []u8, command: Command) void {
    std.debug.assert(dst.len >= @sizeOf(Command));
    @memset(dst[0..@sizeOf(Command)], 0);
    dst[0] = @intFromEnum(std.meta.activeTag(command));
    switch (command) {
        .noop => {},
        inline else => |payload| {
            writeStructFields(@TypeOf(payload), dst[1..][0..@sizeOf(@TypeOf(payload))], payload);
        },
    }
}

pub fn readCommand(src: []const u8) !Command {
    if (src.len < @sizeOf(Command)) return error.MessageTooShort;
    const tag = enumFromIntChecked(std.meta.Tag(Command), src[0]) catch return error.InvalidCommandTag;
    switch (tag) {
        inline else => |t| {
            const name = @tagName(t);
            inline for (std.meta.fields(Command)) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    if (field.type == void) return @unionInit(Command, field.name, {});
                    const payload = try readStructFields(field.type, src[1..][0..@sizeOf(field.type)]);
                    return @unionInit(Command, field.name, payload);
                }
            }
            return error.InvalidCommandTag;
        },
    }
}

fn writeCanonicalValue(comptime T: type, dst: []u8, value: T) usize {
    const size = canonicalSize(T);
    std.debug.assert(dst.len >= size);
    if (T == void) return 0;
    if (T == bool) {
        dst[0] = if (value) 1 else 0;
        return 1;
    }
    switch (@typeInfo(T)) {
        .int => std.mem.writeInt(T, dst[0..@sizeOf(T)], value, .little),
        .float => {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(Int, dst[0..@sizeOf(T)], @bitCast(value), .little);
        },
        .@"enum" => {
            const TagInt = @typeInfo(T).@"enum".tag_type;
            std.mem.writeInt(TagInt, dst[0..@sizeOf(TagInt)], @intFromEnum(value), .little);
        },
        .array => |array| {
            var pos: usize = 0;
            for (value) |element| pos += writeCanonicalValue(array.child, dst[pos..], element);
            std.debug.assert(pos == size);
        },
        .@"struct" => {
            var pos: usize = 0;
            inline for (std.meta.fields(T)) |field| {
                pos += writeCanonicalValue(field.type, dst[pos..], @field(value, field.name));
            }
            std.debug.assert(pos == size);
        },
        else => unreachable,
    }
    return size;
}

fn readCanonicalValue(comptime T: type, src: []const u8) !T {
    const size = canonicalSize(T);
    if (src.len < size) return error.MessageTooShort;
    if (T == void) return {};
    if (T == bool) return try validateBoolByte(src[0]);
    return switch (@typeInfo(T)) {
        .int => std.mem.readInt(T, src[0..@sizeOf(T)], .little),
        .float => blk: {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(std.mem.readInt(Int, src[0..@sizeOf(T)], .little));
        },
        .@"enum" => blk: {
            const TagInt = @typeInfo(T).@"enum".tag_type;
            const raw = std.mem.readInt(TagInt, src[0..@sizeOf(TagInt)], .little);
            break :blk try enumFromIntChecked(T, raw);
        },
        .array => |array| blk: {
            var out: T = undefined;
            var pos: usize = 0;
            for (&out) |*element| {
                element.* = try readCanonicalValue(array.child, src[pos..]);
                pos += canonicalSize(array.child);
            }
            break :blk out;
        },
        .@"struct" => blk: {
            var out: T = undefined;
            var pos: usize = 0;
            inline for (std.meta.fields(T)) |field| {
                @field(out, field.name) = try readCanonicalValue(field.type, src[pos..]);
                pos += canonicalSize(field.type);
            }
            break :blk out;
        },
        else => unreachable,
    };
}

pub fn writeCanonicalCommand(dst: []u8, command: Command) void {
    std.debug.assert(dst.len >= COMMAND_CANONICAL_SIZE);
    @memset(dst[0..COMMAND_CANONICAL_SIZE], 0);
    dst[0] = @intFromEnum(std.meta.activeTag(command));
    switch (command) {
        .noop => {},
        inline else => |payload| {
            const written = writeCanonicalValue(@TypeOf(payload), dst[1..], payload);
            std.debug.assert(written <= COMMAND_CANONICAL_SIZE - 1);
        },
    }
}

pub fn readCanonicalCommand(src: []const u8) !Command {
    if (src.len < COMMAND_CANONICAL_SIZE) return error.MessageTooShort;
    const tag = enumFromIntChecked(std.meta.Tag(Command), src[0]) catch return error.InvalidCommandTag;
    switch (tag) {
        inline else => |active_tag| {
            const name = @tagName(active_tag);
            inline for (std.meta.fields(Command)) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    const payload = try readCanonicalValue(field.type, src[1..]);
                    return @unionInit(Command, field.name, payload);
                }
            }
            return error.InvalidCommandTag;
        },
    }
}

/// Fixed Result wire layout: [tag:u8][payload...][pad to @sizeOf(Result)].
pub fn writeResult(dst: []u8, result: Result) void {
    std.debug.assert(dst.len >= @sizeOf(Result));
    @memset(dst[0..@sizeOf(Result)], 0);
    dst[0] = @intFromEnum(std.meta.activeTag(result));
    switch (result) {
        .ok => |data| writeStructFields(ResultData, dst[1..][0..@sizeOf(ResultData)], data),
        .err => |code| {
            dst[1] = @intFromEnum(code);
        },
    }
}

pub fn readResult(src: []const u8) !Result {
    if (src.len < @sizeOf(Result)) return error.MessageTooShort;
    const tag = enumFromIntChecked(std.meta.Tag(Result), src[0]) catch return error.InvalidResultTag;
    return switch (tag) {
        .ok => .{ .ok = try readStructFields(ResultData, src[1..][0..@sizeOf(ResultData)]) },
        .err => .{ .err = try enumFromIntChecked(ErrorCode, src[1]) },
    };
}

fn writeLogEntry(dst: []u8, entry: LogEntry) void {
    writeStructFields(LogEntry, dst, entry);
}

fn readLogEntry(src: []const u8) !LogEntry {
    return try readStructFields(LogEntry, src);
}

pub fn validateCommand(command: Command) !void {
    switch (command) {
        .register_node => |c| try validateEnumValue(GpuType, c.gpu_type),
        .update_node_status => |c| try validateEnumValue(NodeStatus, c.new_status),
        .create_deployment => |c| {
            try validateEnumValue(GpuType, c.gpu_type);
            if (c.env_count > c.env_vars.len) return error.InvalidEnvCount;
            if (c.image_pull_password_is_secret > 1) return error.InvalidSecretFlag;
            try validateProbe(c.liveness);
            try validateProbe(c.readiness);
            for (c.env_vars[0..c.env_count]) |_| {}
        },
        .update_pod_status => |c| try validateEnumValue(PodPhase, c.new_phase),
        .update_deployment => |c| {
            try validateEnumValue(GpuType, c.gpu_type);
            if (c.env_count > c.env_vars.len) return error.InvalidEnvCount;
        },
        .set_traffic_split => |c| {
            if (c.rule_count > c.rules.len) return error.InvalidRuleCount;
        },
        .bind_pods_to_nodes => |c| {
            if (c.count > c.bindings.len) return error.InvalidBindingCount;
        },
        .set_killswitch => {},
        .deregister_node,
        .bind_pod_to_node,
        .scale_deployment,
        .unbind_pod,
        .noop,
        .rollback_deployment,
        .delete_deployment,
        .pause_deployment,
        .resume_deployment,
        => {},
    }
}

fn validateProbe(probe: ProbeConfig) !void {
    // enabled already validated as bool during readStructFields
    _ = probe;
}

fn validateEnumValue(comptime E: type, value: E) !void {
    // Value was constructed via enumFromIntChecked on the wire path; re-check raw.
    const raw: @typeInfo(E).@"enum".tag_type = @intFromEnum(value);
    _ = enumFromIntChecked(E, raw) catch return error.InvalidEnumTag;
}

fn validateResult(result: Result) !void {
    switch (result) {
        .ok => {},
        .err => |code| try validateEnumValue(ErrorCode, code),
    }
}

fn validateLogEntry(entry: LogEntry) !void {
    try validateCommand(entry.command);
}

pub fn deserialize(buf: []const u8) !Message {
    if (buf.len < 1) return error.MessageTooShort;
    const tag = enumFromIntChecked(Tag, buf[0]) catch return error.InvalidMessageTag;
    const data = buf[1..];
    const decoded: Message = switch (tag) {
        .request => .{ .request = try decodeExact(RequestMsg, data) },
        .prepare => .{ .prepare = try decodeExact(PrepareMsg, data) },
        .prepare_ok => .{ .prepare_ok = try decodeExact(PrepareOkMsg, data) },
        .commit => .{ .commit = try decodeExact(CommitMsg, data) },
        .reply => .{ .reply = try decodeExact(ReplyMsg, data) },
        .start_view_change => .{ .start_view_change = try decodeExact(StartViewChangeMsg, data) },
        .do_view_change => .{ .do_view_change = try decodeExact(DoViewChangeMsg, data) },
        .start_view => .{ .start_view = try decodeExact(StartViewMsg, data) },
        .request_prepare => .{ .request_prepare = try decodeExact(RequestPrepareMsg, data) },
        .send_prepare => .{ .send_prepare = try decodeExact(SendPrepareMsg, data) },
        .request_status => .{ .request_status = try decodeExact(RequestStatusMsg, data) },
        .send_status => .{ .send_status = try decodeExact(SendStatusMsg, data) },
        .request_start_view => .{ .request_start_view = try decodeExact(RequestStartViewMsg, data) },
    };
    try validateDecodedMessage(decoded);
    return decoded;
}

fn decodeExact(comptime T: type, data: []const u8) !T {
    if (data.len != @sizeOf(T)) return error.InvalidMessageSize;
    // Types that embed Command/Result must use the fixed nested codec — never bytesToValue.
    const has_nested = comptime blk: {
        break :blk typeContainsCommandOrResult(T);
    };
    if (has_nested) {
        return try readStructFields(T, data);
    }
    return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
}

fn typeContainsCommandOrResult(comptime T: type) bool {
    if (T == Command or T == Result or T == LogEntry) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (typeContainsCommandOrResult(field.type)) return true;
            }
            return false;
        },
        .array => |a| typeContainsCommandOrResult(a.child),
        else => false,
    };
}

fn validateDecodedMessage(decoded: Message) !void {
    switch (decoded) {
        .request => |m| try validateCommand(m.command),
        .prepare => |m| try validateLogEntry(m.entry),
        .reply => |m| try validateResult(m.result),
        .do_view_change => |m| {
            if (m.log_entry_count > DVC_LOG_MAX) return error.InvalidLogEntryCount;
            for (m.log_entries[0..m.log_entry_count]) |entry| {
                try validateLogEntry(entry);
            }
        },
        .start_view => |m| {
            if (m.log_entry_count > SV_LOG_MAX) return error.InvalidLogEntryCount;
            for (m.log_entries[0..m.log_entry_count]) |entry| {
                try validateLogEntry(entry);
            }
        },
        .send_prepare => |m| try validateLogEntry(m.entry),
        .prepare_ok,
        .commit,
        .start_view_change,
        .request_prepare,
        .request_status,
        .send_status,
        .request_start_view,
        => {},
    }
}

/// Serialize with zeroed padding and fixed nested Command/Result codecs.
fn serializePayload(msg: Message, dst: []u8) usize {
    switch (msg) {
        inline else => |payload| {
            const T = @TypeOf(payload);
            const size = @sizeOf(T);
            writeStructFields(T, dst[0..size], payload);
            return size;
        },
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn strToFixed(comptime N: usize, s: []const u8) [N]u8 {
    var buf: [N]u8 = std.mem.zeroes([N]u8);
    const len = @min(s.len, N);
    @memcpy(buf[0..len], s[0..len]);
    return buf;
}

pub fn fixedToSlice(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

pub fn bitsetSet(bs: *[LOG_BITSET_WORDS]u64, bit: usize) void {
    std.debug.assert(bit < LOG_BITSET_BITS);
    bs[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
}

pub fn bitsetGet(bs: *const [LOG_BITSET_WORDS]u64, bit: usize) bool {
    std.debug.assert(bit < LOG_BITSET_BITS);
    return (bs[bit / 64] >> @intCast(bit % 64)) & 1 == 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serialize/deserialize round-trip" {
    var buf: [4096]u8 = undefined;
    const msg = Message{ .prepare_ok = .{
        .view_number = 7,
        .op_number = 42,
        .replica_id = 2,
        .commit_min = 11,
        .entry_checksum = 0xCAFE,
    } };
    const len = serialize(msg, &buf);
    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(decoded.prepare_ok.view_number, 7);
    try std.testing.expectEqual(decoded.prepare_ok.op_number, 42);
    try std.testing.expectEqual(decoded.prepare_ok.replica_id, 2);
    try std.testing.expectEqual(decoded.prepare_ok.commit_min, 11);
    try std.testing.expectEqual(decoded.prepare_ok.entry_checksum, 0xCAFE);
}

test "source-bound repair round-trip" {
    var buf: [4096]u8 = undefined;
    const message = Message{ .request_prepare = .{
        .view_number = 9,
        .op_number = 17,
        .selected_source = 2,
        .selected_last_normal_view = 8,
        .selected_tip_op = 24,
        .selected_tip_checksum = 0xCAFE,
        .selected_commit_bound = 12,
    } };
    const len = serialize(message, &buf);
    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(@as(ViewNumber, 9), decoded.request_prepare.view_number);
    try std.testing.expectEqual(@as(OpNumber, 17), decoded.request_prepare.op_number);
    try std.testing.expectEqual(@as(u8, 2), decoded.request_prepare.selected_source);
    try std.testing.expectEqual(@as(ViewNumber, 8), decoded.request_prepare.selected_last_normal_view);
    try std.testing.expectEqual(@as(OpNumber, 24), decoded.request_prepare.selected_tip_op);
    try std.testing.expectEqual(@as(u64, 0xCAFE), decoded.request_prepare.selected_tip_checksum);
    try std.testing.expectEqual(@as(OpNumber, 12), decoded.request_prepare.selected_commit_bound);
}

test "RequestStartView round-trip" {
    var buf: [1 + @sizeOf(RequestStartViewMsg)]u8 = undefined;
    const message = Message{ .request_start_view = .{ .view_number = 17 } };
    const len = serialize(message, &buf);
    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(@as(ViewNumber, 17), decoded.request_start_view.view_number);
}

test "StartView certificate round-trip" {
    var buf: [1 + @sizeOf(StartViewMsg)]u8 = undefined;
    const message = Message{ .start_view = .{
        .view_number = 9,
        .selected_last_normal_view = 7,
        .op_number = 24,
        .tip_checksum = 0xBEEF,
        .commit_min = 12,
        .retention_floor = 4,
    } };
    const len = serialize(message, &buf);
    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(@as(ViewNumber, 9), decoded.start_view.view_number);
    try std.testing.expectEqual(@as(ViewNumber, 7), decoded.start_view.selected_last_normal_view);
    try std.testing.expectEqual(@as(OpNumber, 24), decoded.start_view.op_number);
    try std.testing.expectEqual(@as(u64, 0xBEEF), decoded.start_view.tip_checksum);
    try std.testing.expectEqual(@as(OpNumber, 12), decoded.start_view.commit_min);
    try std.testing.expectEqual(@as(OpNumber, 4), decoded.start_view.retention_floor);
}

test "deserialize rejects unknown tag" {
    const buf = [_]u8{0xFF};
    try std.testing.expectError(error.InvalidMessageTag, deserialize(&buf));
}

test "deserialize rejects invalid command tag in request before union switch" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    // Fixed wire layout: Command tag is byte 0 of the command region.
    const off = 1 + @offsetOf(RequestMsg, "command");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidCommandTag, deserialize(&buf));
}

test "deserialize rejects invalid command tag in prepare" {
    var buf: [1 + @sizeOf(PrepareMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.prepare);
    const off = 1 + @offsetOf(PrepareMsg, "entry") + @offsetOf(LogEntry, "command");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidCommandTag, deserialize(&buf));
}

test "deserialize rejects invalid command tag in send_prepare" {
    var buf: [1 + @sizeOf(SendPrepareMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.send_prepare);
    const off = 1 + @offsetOf(SendPrepareMsg, "entry") + @offsetOf(LogEntry, "command");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidCommandTag, deserialize(&buf));
}

test "deserialize rejects invalid command tag in do_view_change entry" {
    var buf: [1 + @sizeOf(DoViewChangeMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.do_view_change);
    const count_off = 1 + @offsetOf(DoViewChangeMsg, "log_entry_count");
    buf[count_off] = 1;
    const off = 1 + @offsetOf(DoViewChangeMsg, "log_entries") + @offsetOf(LogEntry, "command");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidCommandTag, deserialize(&buf));
}

test "deserialize rejects invalid command tag in start_view entry" {
    var buf: [1 + @sizeOf(StartViewMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.start_view);
    const count_off = 1 + @offsetOf(StartViewMsg, "log_entry_count");
    buf[count_off] = 1;
    const off = 1 + @offsetOf(StartViewMsg, "log_entries") + @offsetOf(LogEntry, "command");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidCommandTag, deserialize(&buf));
}

test "deserialize rejects invalid result tag in reply" {
    var buf: [1 + @sizeOf(ReplyMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.reply);
    const off = 1 + @offsetOf(ReplyMsg, "result");
    buf[off] = 0xFF;
    try std.testing.expectError(error.InvalidResultTag, deserialize(&buf));
}

test "deserialize rejects invalid ErrorCode in reply err" {
    var buf: [1 + @sizeOf(ReplyMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.reply);
    const result_base = 1 + @offsetOf(ReplyMsg, "result");
    buf[result_base] = @intFromEnum(std.meta.Tag(Result).err);
    buf[result_base + 1] = 0xFF;
    try std.testing.expectError(error.InvalidEnumTag, deserialize(&buf));
}

test "deserialize rejects invalid GpuType in request command" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).register_node);
    const gpu_off = cmd_base + 1 + @offsetOf(RegisterNodeCmd, "gpu_type");
    buf[gpu_off] = 0xFF;
    try std.testing.expectError(error.InvalidEnumTag, deserialize(&buf));
}

test "deserialize rejects invalid NodeStatus in request command" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).update_node_status);
    const status_off = cmd_base + 1 + @offsetOf(UpdateNodeStatusCmd, "new_status");
    buf[status_off] = 0xFF;
    try std.testing.expectError(error.InvalidEnumTag, deserialize(&buf));
}

test "deserialize rejects invalid PodPhase in request command" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).update_pod_status);
    const phase_off = cmd_base + 1 + @offsetOf(UpdatePodStatusCmd, "new_phase");
    buf[phase_off] = 0xFF;
    try std.testing.expectError(error.InvalidEnumTag, deserialize(&buf));
}

test "deserialize rejects env_count above env_vars capacity" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).create_deployment);
    const env_count_off = cmd_base + 1 + @offsetOf(CreateDeploymentCmd, "env_count");
    buf[env_count_off] = 255;
    try std.testing.expectError(error.InvalidEnvCount, deserialize(&buf));
}

test "deserialize rejects binding count above BIND_BATCH_MAX" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).bind_pods_to_nodes);
    const count_off = cmd_base + 1 + @offsetOf(BindPodsToNodesCmd, "count");
    buf[count_off] = 255;
    try std.testing.expectError(error.InvalidBindingCount, deserialize(&buf));
}

test "deserialize rejects rule_count above rules capacity" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).set_traffic_split);
    const count_off = cmd_base + 1 + @offsetOf(SetTrafficSplitCmd, "rule_count");
    buf[count_off] = 9;
    try std.testing.expectError(error.InvalidRuleCount, deserialize(&buf));
}

test "deserialize rejects invalid bool in killswitch" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).set_killswitch);
    const active_off = cmd_base + 1 + @offsetOf(SetKillswitchCmd, "active");
    buf[active_off] = 2;
    try std.testing.expectError(error.InvalidBool, deserialize(&buf));
}

test "deserialize rejects invalid secret flag" {
    var buf: [1 + @sizeOf(RequestMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.request);
    const cmd_base = 1 + @offsetOf(RequestMsg, "command");
    buf[cmd_base] = @intFromEnum(std.meta.Tag(Command).create_deployment);
    const flag_off = cmd_base + 1 + @offsetOf(CreateDeploymentCmd, "image_pull_password_is_secret");
    buf[flag_off] = 2;
    try std.testing.expectError(error.InvalidSecretFlag, deserialize(&buf));
}

test "deserialize rejects trailing payload bytes" {
    var buf: [1 + @sizeOf(PrepareOkMsg) + 1]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.prepare_ok);
    try std.testing.expectError(error.InvalidMessageSize, deserialize(&buf));
}

test "deserialize rejects truncated prepare_ok" {
    var buf: [1 + @sizeOf(PrepareOkMsg) - 1]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.prepare_ok);
    try std.testing.expectError(error.InvalidMessageSize, deserialize(&buf));
}

test "deserialize rejects protocol-v1 PrepareOk without checksum" {
    const protocol_v1_size = @sizeOf(PrepareOkMsg) - @sizeOf(u64);
    var buf: [1 + protocol_v1_size]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.prepare_ok);
    try std.testing.expectError(error.InvalidMessageSize, deserialize(&buf));
}

test "deserialize rejects oversized DVC log_entry_count" {
    var buf: [1 + @sizeOf(DoViewChangeMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.do_view_change);
    const count_off = 1 + @offsetOf(DoViewChangeMsg, "log_entry_count");
    buf[count_off] = @as(u8, @intCast(DVC_LOG_MAX + 1));
    try std.testing.expectError(error.InvalidLogEntryCount, deserialize(&buf));
}

test "deserialize round-trip preserves prepare entry validity" {
    var buf: [16384]u8 = undefined;
    var entry = LogEntry{
        .view_number = 1,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 9,
        .request_id = 3,
    };
    entry.checksum = entry.computeChecksum();
    try std.testing.expect(entry.valid());

    const prep = Message{ .prepare = .{
        .view_number = 1,
        .op_number = 1,
        .entry = entry,
    } };
    const plen = serialize(prep, &buf);
    const pd = try deserialize(buf[0..plen]);
    try std.testing.expect(pd.prepare.entry.valid());
}

test "command fixed wire tag is at offset zero" {
    var wire: [@sizeOf(Command)]u8 = undefined;
    writeCommand(&wire, .{ .noop = {} });
    try std.testing.expectEqual(@as(u8, @intFromEnum(std.meta.Tag(Command).noop)), wire[0]);
    writeCommand(&wire, .{ .deregister_node = .{ .node_id = 7 } });
    try std.testing.expectEqual(@as(u8, @intFromEnum(std.meta.Tag(Command).deregister_node)), wire[0]);
    const decoded = try readCommand(&wire);
    try std.testing.expectEqual(@as(u64, 7), decoded.deregister_node.node_id);
}

test "strToFixed" {
    const fixed = strToFixed(64, "worker-01");
    try std.testing.expectEqualStrings("worker-01", fixedToSlice(&fixed));
}

test "worker tags stay wire compatible with rust agent" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(WorkerTag.register_ack));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(WorkerTag.start_pod));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(WorkerTag.stop_pod));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(WorkerTag.run_request));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(WorkerTag.register));
    try std.testing.expectEqual(@as(u8, 0x11), @intFromEnum(WorkerTag.heartbeat));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(WorkerTag.pod_status));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(WorkerTag.run_response));
}
