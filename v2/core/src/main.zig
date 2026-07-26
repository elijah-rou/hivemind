const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const StateMachine = @import("state_machine.zig").StateMachine;
const ConnectionManager = @import("connection.zig").ConnectionManager;
const disk_mod = @import("disk.zig");
const MetricsServer = @import("metrics.zig").MetricsServer;
const S3Backup = @import("s3_backup.zig").S3Backup;
const gossip_mod = @import("gossip.zig");
const GossipState = gossip_mod.GossipState;
const OriginIdentity = gossip_mod.OriginIdentity;
const io_mod = @import("vopr/simulated_io.zig");
const latency = @import("latency.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip binary name

    var node_id: u8 = 0;
    var replica_count: u8 = 1;
    var worker_port: u16 = 9000;
    var client_port: u16 = 9001;
    var peer_port: u16 = 0;
    var peers_arg: []const u8 = "";
    var data_dir: []const u8 = "";
    var metrics_port: u16 = 0;
    var s3_backup_uri: []const u8 = "";
    var gossip_port: u16 = 0;
    var gossip_peers_arg: []const u8 = "";
    var origin_id: []const u8 = "default";
    var provider_name: []const u8 = "unknown";
    var region_name: []const u8 = "default";
    var locality_name: []const u8 = "default";
    var continent_name: []const u8 = "unknown";
    var encryption_key_arg: []const u8 = "";

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--node-id")) {
            if (args_iter.next()) |v| node_id = std.fmt.parseInt(u8, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--replica-count")) {
            if (args_iter.next()) |v| replica_count = std.fmt.parseInt(u8, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--worker-port")) {
            if (args_iter.next()) |v| worker_port = std.fmt.parseInt(u16, v, 10) catch 9000;
        } else if (std.mem.eql(u8, arg, "--client-port")) {
            if (args_iter.next()) |v| client_port = std.fmt.parseInt(u16, v, 10) catch 9001;
        } else if (std.mem.eql(u8, arg, "--replica-port")) {
            if (args_iter.next()) |v| peer_port = std.fmt.parseInt(u16, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--peers")) {
            if (args_iter.next()) |v| peers_arg = v;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            if (args_iter.next()) |v| data_dir = v;
        } else if (std.mem.eql(u8, arg, "--metrics-port")) {
            if (args_iter.next()) |v| metrics_port = std.fmt.parseInt(u16, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--s3-backup")) {
            if (args_iter.next()) |v| s3_backup_uri = v;
        } else if (std.mem.eql(u8, arg, "--gossip-port")) {
            if (args_iter.next()) |v| gossip_port = std.fmt.parseInt(u16, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--gossip-peers")) {
            if (args_iter.next()) |v| gossip_peers_arg = v;
        } else if (std.mem.eql(u8, arg, "--origin-id")) {
            if (args_iter.next()) |v| origin_id = v;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            if (args_iter.next()) |v| provider_name = v;
        } else if (std.mem.eql(u8, arg, "--region")) {
            if (args_iter.next()) |v| region_name = v;
        } else if (std.mem.eql(u8, arg, "--locality")) {
            if (args_iter.next()) |v| locality_name = v;
        } else if (std.mem.eql(u8, arg, "--continent")) {
            if (args_iter.next()) |v| continent_name = v;
        } else if (std.mem.eql(u8, arg, "--encryption-key")) {
            if (args_iter.next()) |v| encryption_key_arg = v;
        }
    }

    latency.initFromEnv(node_id);

    // Also check env var
    if (encryption_key_arg.len == 0) {
        const env_val = std.c.getenv("HIVEMIND_ENCRYPTION_KEY");
        if (env_val) |v| {
            encryption_key_arg = std.mem.span(v);
        }
    }

    std.debug.print("hivemind core: node={d} replicas={d} worker_port={d} client_port={d} peer_port={d} data_dir={s}\n", .{
        node_id, replica_count, worker_port, client_port, peer_port, data_dir,
    });

    // Storage-mode contract (POC, not production durability):
    // - absent --data-dir: volatile in-memory journal (explicit POC mode)
    // - present --data-dir: experimental single-copy file journal; torn writes /
    //   power loss are not validated as production-safe
    if (data_dir.len == 0) {
        std.debug.print("hivemind core: storage mode: volatile POC (no --data-dir; in-memory only, not durable across restart)\n", .{});
    } else {
        std.debug.print("hivemind core: storage mode: experimental single-copy journal (--data-dir); torn writes and power loss are not validated\n", .{});
    }

    const sm = try allocator.create(StateMachine);
    sm.initInPlace(0);

    // Open file-backed disk if --data-dir is set
    var file_disk: ?*disk_mod.FileDisk = null;
    if (data_dir.len > 0) {
        // Restrict data-dir permissions; journal contents may include secrets.
        const dir_perms: std.Io.Dir.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o700));
        _ = std.Io.Dir.cwd().createDirPathStatus(init.io, data_dir, dir_perms) catch |err| {
            std.debug.print("failed to create data-dir: {}\n", .{err});
            return err;
        };
        var dir_z_buf: [4096]u8 = undefined;
        if (data_dir.len >= dir_z_buf.len) return error.PathTooLong;
        @memcpy(dir_z_buf[0..data_dir.len], data_dir);
        dir_z_buf[data_dir.len] = 0;
        if (std.c.chmod(@ptrCast(&dir_z_buf), @as(std.c.mode_t, 0o700)) != 0) {
            std.debug.print("failed to chmod data-dir 0700\n", .{});
            return error.PermissionDenied;
        }

        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/journal.bin", .{data_dir}) catch @panic("data-dir path too long");
        const fd_ptr = try allocator.create(disk_mod.FileDisk);
        fd_ptr.openInPlace(path) catch |err| {
            switch (err) {
                error.LegacyJournalVersion => std.debug.print(
                    "failed to open journal: legacy layout v1 is unsupported after the command codec change; delete journal.bin or use a fresh --data-dir (no migration)\n",
                    .{},
                ),
                error.UnsupportedJournalVersion => std.debug.print(
                    "failed to open journal: unsupported journal layout version (want v{d})\n",
                    .{disk_mod.FileDisk.VERSION},
                ),
                else => std.debug.print("failed to open journal: {}\n", .{err}),
            }
            return err;
        };
        file_disk = fd_ptr;
    }

    const replica = try allocator.create(replica_mod.Replica);
    replica.initInPlace(.{
        .replica_id = node_id,
        .replica_count = replica_count,
        .io = init.io,
        .state_machine = sm,
        .disk = if (file_disk) |fd| fd.diskInterface() else null,
    });

    // Recover from disk if we have one
    if (file_disk != null) {
        const recovered = replica.recoverFromDisk() catch |err| {
            std.debug.print("hivemind core: fatal storage recovery error: {}\n", .{err});
            std.process.exit(1);
        };
        if (recovered) {
            std.debug.print("hivemind core: recovered from disk (view={d} op={d} commit={d})\n", .{
                replica.view_number, replica.op_number, replica.commit_min,
            });
        }
    }

    // Initialize encryption (optional)
    const enc_mod = @import("encryption.zig");
    var encryption_state: ?enc_mod.EncryptionState = null;
    if (encryption_key_arg.len > 0) {
        encryption_state = enc_mod.EncryptionState.init(encryption_key_arg) catch |err| {
            std.debug.print("hivemind core: encryption key invalid: {}\n", .{err});
            return err;
        };
        std.debug.print("hivemind core: frame encryption enabled (XChaCha20-Poly1305)\n", .{});
    }

    const conn_mgr = try allocator.create(ConnectionManager);
    conn_mgr.initInPlace(replica, worker_port, client_port, peer_port) catch |err| {
        std.debug.print("failed to start: {}\n", .{err});
        return err;
    };
    defer conn_mgr.deinit();

    // Wire encryption to connection manager
    if (encryption_state != null) {
        conn_mgr.encryption = &encryption_state.?;
    }

    // Wire replica callbacks to connection manager
    replica.client_reply_ctx = @ptrCast(conn_mgr);
    replica.client_reply_fn = clientReplyCallback;
    replica.worker_send_ctx = @ptrCast(conn_mgr);
    replica.worker_send_fn = workerSendCallback;

    // Wire peer send callback
    if (peer_port > 0) {
        replica.peer_send_ctx = @ptrCast(conn_mgr);
        replica.peer_send_fn = peerSendCallback;
    }

    // Start metrics server if configured
    var metrics: ?MetricsServer = null;
    if (metrics_port > 0) {
        metrics = MetricsServer.init(metrics_port, replica) catch |err| blk: {
            std.debug.print("hivemind core: metrics server failed: {}\n", .{err});
            break :blk null;
        };
        if (metrics != null) {
            metrics.?.connection_mgr = conn_mgr;
            std.debug.print("hivemind core: metrics on :{d}\n", .{metrics_port});
        }
    }

    // S3 backup (requires --data-dir and --s3-backup)
    var s3_backup: ?S3Backup = null;
    if (s3_backup_uri.len > 0 and data_dir.len > 0) {
        var journal_path_buf: [4096]u8 = undefined;
        const journal_path = std.fmt.bufPrint(&journal_path_buf, "{s}/journal.bin", .{data_dir}) catch "";
        if (journal_path.len > 0) {
            s3_backup = S3Backup.init(journal_path, s3_backup_uri, 60_000); // every 60s
            std.debug.print("hivemind core: s3 backup to {s} every 60s\n", .{s3_backup_uri});
        }
    }

    // Ignore SIGCHLD so forked backup children don't become zombies
    if (s3_backup != null) {
        // Ignore SIGCHLD so forked backup children don't become zombies
        const SIG_IGN: usize = 1;
        var sa: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
        sa.handler = .{ .handler = @ptrFromInt(SIG_IGN) };
        _ = std.c.sigaction(std.c.SIG.CHLD, &sa, null);
    }

    // Cross-origin gossip (optional)
    var gossip: ?GossipState = null;
    if (gossip_port > 0) {
        const identity = OriginIdentity{
            .origin_id = msg.strToFixed(32, origin_id),
            .provider = msg.strToFixed(32, provider_name),
            .region = msg.strToFixed(32, region_name),
            .locality = msg.strToFixed(32, locality_name),
            .continent = msg.strToFixed(32, continent_name),
        };
        gossip = GossipState.init(gossip_port, identity, replica) catch |err| blk: {
            std.debug.print("hivemind core: gossip init failed: {}\n", .{err});
            break :blk null;
        };
        if (gossip != null and gossip_peers_arg.len > 0) {
            parseGossipPeers(&gossip.?, gossip_peers_arg);
            std.debug.print("hivemind core: gossip on :{d} origin={s} provider={s} region={s} locality={s} continent={s}\n", .{ gossip_port, origin_id, provider_name, region_name, locality_name, continent_name });
        }
        // Wire gossip to metrics and encryption
        if (gossip != null) {
            if (metrics != null) metrics.?.gossip = &gossip.?;
            if (encryption_state != null) gossip.?.encryption = &encryption_state.?;
        }
    }

    std.debug.print("hivemind core: listening on worker_port={d} client_port={d} peer_port={d}\n", .{ worker_port, client_port, peer_port });

    // Connect to peers after a 2s delay (allow listeners to start)
    if (peers_arg.len > 0) {
        const ts_delay = std.c.timespec{ .sec = 2, .nsec = 0 };
        _ = std.c.nanosleep(&ts_delay, null);
        parsePeersAndConnect(conn_mgr, peers_arg);
    }

    while (true) {
        conn_mgr.poll();
        replica.tick();
        if (replica.storage_failed) {
            std.debug.print("hivemind core: fatal storage failure; exiting nonzero\n", .{});
            std.process.exit(1);
        }
        conn_mgr.dispatchRun();
        if (metrics) |*m| m.poll();
        if (s3_backup) |*b| b.maybeTrigger(io_mod.nowTick(init.io));
        if (gossip) |*g| {
            const now = io_mod.nowTick(init.io);
            if (replica.isLeader() and replica.status == .normal) {
                g.tick(now);
            } else {
                g.receiveOnly(now);
            }
        }
        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }
}

fn peerSendCallback(ctx: ?*anyopaque, to: u8, data: []const u8) void {
    const cm: *ConnectionManager = @ptrCast(@alignCast(ctx.?));
    cm.sendToPeer(to, data);
}

fn clientReplyCallback(ctx: ?*anyopaque, client_id: u128, request_id: u128, result: @import("message.zig").Result) void {
    const cm: *ConnectionManager = @ptrCast(@alignCast(ctx.?));
    cm.sendReplyToClientId(client_id, request_id, result);
}

fn workerSendCallback(ctx: ?*anyopaque, worker_idx: usize, data: []const u8) void {
    const cm: *ConnectionManager = @ptrCast(@alignCast(ctx.?));
    if (worker_idx >= cm.worker_count or !cm.workers[worker_idx].connected) return;

    // data = [4B len][2B version][1B tag][payload...] (old frame format from replica)
    // Extract inner content (version+tag+payload) and re-frame through sendFrame
    // which handles flags byte and encryption.
    const frame_header = 4; // skip the 4-byte length prefix
    if (data.len <= frame_header) return;
    const inner = data[frame_header..]; // version+tag+payload

    const key = if (cm.encryption != null and cm.encryption.?.enabled) &cm.encryption.?.worker_key else null;
    cm.sendFrame(cm.workers[worker_idx].fd, key, inner) catch {
        cm.workers[worker_idx].connected = false;
    };
}

/// Parse peer list format "1@127.0.0.1:9102,2@127.0.0.1:9202" and connect.
fn parsePeersAndConnect(cm: *ConnectionManager, peers_str: []const u8) void {
    var remaining = peers_str;
    while (remaining.len > 0) {
        // Find next comma or end
        const comma_pos = std.mem.indexOfScalar(u8, remaining, ',') orelse remaining.len;
        const entry = remaining[0..comma_pos];
        remaining = if (comma_pos < remaining.len) remaining[comma_pos + 1 ..] else remaining[remaining.len..];

        if (entry.len == 0) continue;

        // Parse "ID@HOST:PORT"
        const at_pos = std.mem.indexOfScalar(u8, entry, '@') orelse continue;
        const peer_id = std.fmt.parseInt(u8, entry[0..at_pos], 10) catch continue;
        const host_port = entry[at_pos + 1 ..];
        const colon_pos = std.mem.indexOfScalar(u8, host_port, ':') orelse continue;
        const host_str = host_port[0..colon_pos];
        const port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch continue;

        const host_ip = parseIpv4(host_str) orelse continue;

        std.debug.print("hivemind core: connecting to peer {d} at {s}:{d}\n", .{ peer_id, host_str, port });
        cm.connectToPeer(peer_id, host_ip, port);
    }
}

/// Parse gossip peers: "aws-us-east-1@10.0.1.1:9300,crusoe-us-east-1@10.0.2.1:9300"
fn parseGossipPeers(g: *GossipState, peers_str: []const u8) void {
    var remaining = peers_str;
    while (remaining.len > 0) {
        const comma_pos = std.mem.indexOfScalar(u8, remaining, ',') orelse remaining.len;
        const entry = remaining[0..comma_pos];
        remaining = if (comma_pos < remaining.len) remaining[comma_pos + 1 ..] else remaining[remaining.len..];

        if (entry.len == 0) continue;

        // Parse "ORIGIN_ID@HOST:PORT"
        const at_pos = std.mem.indexOfScalar(u8, entry, '@') orelse continue;
        const peer_origin_id = entry[0..at_pos];
        const host_port = entry[at_pos + 1 ..];
        const colon_pos = std.mem.indexOfScalar(u8, host_port, ':') orelse continue;
        const host_str = host_port[0..colon_pos];
        const port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch continue;

        const host_ip = parseIpv4(host_str) orelse continue;

        std.debug.print("hivemind core: gossip peer {s} at {s}:{d}\n", .{ peer_origin_id, host_str, port });
        g.addPeer(peer_origin_id, host_ip, port);
    }
}

fn parseIpv4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var rem = s;

    while (octet_idx < 4) : (octet_idx += 1) {
        if (rem.len == 0) return null;
        const dot_pos = std.mem.indexOfScalar(u8, rem, '.') orelse rem.len;
        octets[octet_idx] = std.fmt.parseInt(u8, rem[0..dot_pos], 10) catch return null;
        rem = if (dot_pos < rem.len) rem[dot_pos + 1 ..] else rem[rem.len..];
    }

    // Network byte order (big-endian)
    return @as(u32, octets[0]) | (@as(u32, octets[1]) << 8) | (@as(u32, octets[2]) << 16) | (@as(u32, octets[3]) << 24);
}
