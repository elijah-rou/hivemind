const std = @import("std");
const vopr = @import("vopr/vopr.zig");
const prng_mod = @import("prng.zig");
const Prng = prng_mod.Prng;
const Ratio = prng_mod.Ratio;

const VoprConfig = vopr.VoprConfig;
const VoprResult = vopr.VoprResult;

// Config mutation parameter count
pub const hivemind_quiet = true;

const PARAM_COUNT = 16;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip binary name

    var mode: Mode = .sequential;
    var seed_count: u64 = 1000;
    var thread_count: u32 = 0;
    var budget_secs: u64 = 0;
    var mutate = false;
    const corpus_path = "fuzz_failures.jsonl";
    var replay_seed: ?u64 = null;
    var verbose = false;
    var trace_path: ?[*:0]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "sequential")) {
            mode = .sequential;
        } else if (std.mem.eql(u8, arg, "random")) {
            mode = .random;
        } else if (std.mem.eql(u8, arg, "replay")) {
            mode = .replay;
            if (args_iter.next()) |s| {
                replay_seed = std.fmt.parseInt(u64, s, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            if (args_iter.next()) |v| seed_count = std.fmt.parseInt(u64, v, 10) catch 1000;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args_iter.next()) |v| thread_count = std.fmt.parseInt(u32, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--budget")) {
            if (args_iter.next()) |v| budget_secs = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--mutate")) {
            mutate = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            if (args_iter.next()) |v| trace_path = @ptrCast(v.ptr);
        }
    }

    if (mode == .replay) {
        const seed = replay_seed orelse {
            log("usage: fuzz replay <SEED> [--verbose] [--mutate]\n", .{});
            return;
        };
        try runReplay(allocator, seed, mutate, verbose, trace_path);
        return;
    }

    try runFuzzer(allocator, mode, seed_count, thread_count, budget_secs, mutate, corpus_path);
}

const Mode = enum { sequential, random, replay };

fn runFuzzer(
    allocator: std.mem.Allocator,
    mode: Mode,
    seed_count: u64,
    thread_count_arg: u32,
    budget_secs: u64,
    mutate: bool,
    corpus_path: []const u8,
) !void {
    const start = wallClockMs();
    const thread_count = try resolveThreadCount(seed_count, thread_count_arg);

    var random_seeds: []u64 = &[_]u64{};
    if (mode == .random) {
        random_seeds = try allocator.alloc(u64, @intCast(seed_count));
        var random_prng = Prng.init(@intCast(@as(u64, @bitCast(wallClockMs()))));
        for (random_seeds) |*seed| seed.* = random_prng.next();
    }
    defer if (random_seeds.len > 0) allocator.free(random_seeds);

    const corpus_fd = std.c.open("fuzz_failures.jsonl", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o644));
    defer {
        if (corpus_fd >= 0) _ = std.c.close(corpus_fd);
    }

    log("[fuzz] mode={s} seeds={d} threads={d} budget={d}s mutate={}\n", .{
        @tagName(mode), seed_count, thread_count, budget_secs, mutate,
    });

    var log_mutex: std.atomic.Mutex = .unlocked;
    var thread_results = try allocator.alloc(ThreadResult, thread_count);
    defer allocator.free(thread_results);
    @memset(thread_results, .{});

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    for (threads, 0..) |*thread, thread_index| {
        const range = threadRange(seed_count, thread_count, thread_index);
        thread.* = try std.Thread.spawn(.{}, fuzzWorker, .{WorkerArgs{
            .mode = mode,
            .start_index = range.start,
            .end_index = range.end,
            .random_seeds = random_seeds,
            .start_ms = start,
            .budget_secs = budget_secs,
            .mutate = mutate,
            .corpus_fd = corpus_fd,
            .log_mutex = &log_mutex,
            .result = &thread_results[thread_index],
        }});
    }

    for (threads) |thread| thread.join();

    var seeds_tested: u64 = 0;
    var failures_found: u64 = 0;
    var last_failure_seed: u64 = 0;
    for (thread_results) |result| {
        seeds_tested += result.seeds_tested;
        failures_found += result.failures_found;
        if (result.last_failure_seed > last_failure_seed) {
            last_failure_seed = result.last_failure_seed;
        }
    }

    const elapsed_ms = wallClockMs() - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const rate = if (elapsed_s > 0) @as(f64, @floatFromInt(seeds_tested)) / elapsed_s else 0;

    if (last_failure_seed > 0) {
        logProgress(seeds_tested, failures_found, elapsed_s, rate, last_failure_seed);
    }
    log("{{\"elapsed_secs\":{d:.1},\"seeds_tested\":{d},\"failures_found\":{d},\"seeds_per_sec\":{d:.1},\"corpus\":\"{s}\"}}\n", .{
        elapsed_s, seeds_tested, failures_found, rate, corpus_path,
    });

    if (failures_found > 0) {
        std.process.exit(1);
    }
}

const ThreadResult = struct {
    seeds_tested: u64 = 0,
    failures_found: u64 = 0,
    last_failure_seed: u64 = 0,
};

const WorkerArgs = struct {
    mode: Mode,
    start_index: u64,
    end_index: u64,
    random_seeds: []const u64,
    start_ms: i64,
    budget_secs: u64,
    mutate: bool,
    corpus_fd: c_int,
    log_mutex: *std.atomic.Mutex,
    result: *ThreadResult,
};

const SeedRange = struct { start: u64, end: u64 };

fn resolveThreadCount(seed_count: u64, thread_count_arg: u32) !usize {
    if (seed_count == 0) return 1;

    const requested = if (thread_count_arg == 0)
        try std.Thread.getCpuCount()
    else
        @as(usize, thread_count_arg);
    std.debug.assert(requested > 0);

    const bounded_by_seeds = @min(requested, @as(usize, @intCast(seed_count)));
    return @max(@as(usize, 1), bounded_by_seeds);
}

fn threadRange(seed_count: u64, thread_count: usize, thread_index: usize) SeedRange {
    std.debug.assert(thread_count > 0);
    std.debug.assert(thread_index < thread_count);

    const base = seed_count / thread_count;
    const extra = seed_count % thread_count;
    const index: u64 = @intCast(thread_index);
    const start = index * base + @min(index, extra);
    const len = base + if (index < extra) @as(u64, 1) else 0;
    return .{ .start = start, .end = start + len };
}

fn fuzzWorker(args: WorkerArgs) void {
    const allocator = std.heap.smp_allocator;

    var index = args.start_index;
    while (index < args.end_index) : (index += 1) {
        if (budgetExpired(args.start_ms, args.budget_secs)) break;

        const seed: u64 = switch (args.mode) {
            .sequential => index,
            .random => args.random_seeds[@intCast(index)],
            .replay => unreachable,
        };

        var config = baseConfig();
        if (args.mutate) {
            config = mutateConfig(config, seed);
        }
        config.seed = seed;

        const result = vopr.run(allocator, config) catch |err| {
            lockMutex(args.log_mutex);
            defer args.log_mutex.unlock();
            log("[fuzz] seed={d} ERROR: {}\n", .{ seed, err });
            args.result.failures_found += 1;
            continue;
        };

        args.result.seeds_tested += 1;

        if (result.outcome != .passed) {
            args.result.failures_found += 1;
            args.result.last_failure_seed = seed;
            lockMutex(args.log_mutex);
            defer args.log_mutex.unlock();
            recordFailure(args.corpus_fd, seed, config, result);
            log("[fuzz] FAILURE seed={d} outcome={s} violations={d} p1={d} p2={d}\n", .{
                seed,
                @tagName(result.outcome),
                result.checker_summary.safety_violations,
                result.phase1_ticks,
                result.phase2_ticks,
            });
        }
    }
}

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn budgetExpired(start_ms: i64, budget_secs: u64) bool {
    if (budget_secs == 0) return false;
    const elapsed_ms = wallClockMs() - start_ms;
    if (elapsed_ms <= 0) return false;
    return @as(u64, @intCast(elapsed_ms)) >= budget_secs * 1000;
}

fn runReplay(allocator: std.mem.Allocator, seed: u64, mutate: bool, verbose: bool, trace_path: ?[*:0]const u8) !void {
    var config = baseConfig();
    if (mutate) {
        config = mutateConfig(config, seed);
    }
    config.seed = seed;

    log("[fuzz] replay seed={d} config: replicas={d} safety={d} requests={d} partitions={d}/{d} heal={d}/{d} crash={d}/{d}\n", .{
        seed,
        config.replica_count,
        config.safety_ticks,
        config.request_count,
        config.partition_probability.numerator,
        config.partition_probability.denominator,
        config.heal_probability.numerator,
        config.heal_probability.denominator,
        config.crash_probability.numerator,
        config.crash_probability.denominator,
    });

    // TraceCollector is multi-MiB. Replay owns it on the heap so replay does
    // not add the collector's full bounded capacity to the process stack.
    comptime std.debug.assert(@sizeOf(vopr.TraceCollector) <= @import("vopr/trace.zig").MAX_TRACE_COLLECTOR_BYTES);
    const collector_storage = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.of(vopr.TraceCollector),
        @sizeOf(vopr.TraceCollector),
    );
    const collector: *vopr.TraceCollector = @ptrCast(collector_storage.ptr);
    collector.initInPlace(config.replica_count);
    defer {
        collector.deinit();
        allocator.free(collector_storage);
    }

    const result = if (verbose or trace_path != null)
        try vopr.run_traced_collected(allocator, config, collector)
    else
        try vopr.run(allocator, config);

    // Write trace JSONL if path specified
    if (trace_path) |path| {
        if (std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644)) |fd| {
            collector.writeJsonl(fd);
            _ = std.c.close(fd);
            log("[fuzz] trace written ({d} events)\n", .{collector.count});
        } else |err| {
            log("[fuzz] failed to create trace file: {}\n", .{err});
        }
    }

    log("[fuzz] result: outcome={s} p1_ticks={d} p2_ticks={d} requests={d}\n", .{
        @tagName(result.outcome),
        result.phase1_ticks,
        result.phase2_ticks,
        result.requests_submitted,
    });
    log("[fuzz]   commits={d} canonical_ops={d} max_commit={d} violations={d} view_changes={d}\n", .{
        result.checker_summary.commits_checked,
        result.checker_summary.canonical_ops,
        result.checker_summary.max_commit,
        result.checker_summary.safety_violations,
        result.checker_summary.view_changes_observed,
    });
    log("[fuzz]   convergence={d} ticks, messages={d} ({d} bytes)\n", .{
        result.convergence_ticks,
        result.messages_sent,
        result.messages_bytes,
    });

    if (result.outcome != .passed) {
        std.process.exit(1);
    }
}

fn baseConfig() VoprConfig {
    return .{
        .seed = 0,
        .replica_count = 5,
        .safety_ticks = 500,
        .request_count = 20,
        .liveness_ticks = 8000,
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
        .disk_sync_fault_rate = Ratio.init(1, 1000),
        .deployment_count = 3,
        .worker_count = 4,
        .agent_pod_crash_probability = Ratio.init(1, 100),
    };
}

fn randomRatio(prng: *Prng, max_numerator: u32, denominator: u32) Ratio {
    return Ratio.init(@intCast(prng.bounded(max_numerator + 1)), denominator);
}

fn mutateConfig(base: VoprConfig, seed: u64) VoprConfig {
    var prng = Prng.init(seed ^ 0xC00F16);
    var config = base;

    const param = prng.bounded(PARAM_COUNT);
    switch (param) {
        0 => config.replica_count = 3 + @as(u8, @intCast(prng.bounded(3))) * 2,
        1 => config.safety_ticks = 100 + prng.bounded(1900),
        2 => config.request_count = 1 + @as(u32, @intCast(prng.bounded(99))),
        3 => config.partition_probability = randomRatio(&prng, 15, 100),
        4 => config.heal_probability = randomRatio(&prng, 20, 100),
        5 => config.crash_probability = randomRatio(&prng, 5, 100),
        6 => config.pause_probability = randomRatio(&prng, 5, 100),
        7 => config.asymmetric_partition_probability = randomRatio(&prng, 5, 100),
        8 => config.partition_stability = @intCast(prng.bounded(50)),
        9 => config.crash_stability = @intCast(prng.bounded(80)),
        10 => config.drop_rate = randomRatio(&prng, 10, 100),
        11 => config.replay_rate = randomRatio(&prng, 5, 100),
        12 => config.path_max_capacity = @intCast(4 + prng.bounded(28)),
        13 => config.deployment_count = @intCast(prng.bounded(11)),
        14 => config.worker_count = @intCast(prng.bounded(9)),
        15 => config.liveness_ticks = 500 + prng.bounded(3500),
        else => {},
    }

    return config;
}

fn recordFailure(fd: c_int, seed: u64, config: VoprConfig, result: VoprResult) void {
    if (fd < 0) return;
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"engine\":\"zig\",\"seed\":{d},\"outcome\":\"{s}\",\"config\":{{\"replicas\":{d},\"safety\":{d},\"requests\":{d},\"partition\":\"{d}/{d}\",\"heal\":\"{d}/{d}\",\"crash\":\"{d}/{d}\"}},\"result\":{{\"p1\":{d},\"p2\":{d},\"violations\":{d},\"view_changes\":{d},\"messages\":{d}}}}}\n", .{
        seed,
        @tagName(result.outcome),
        config.replica_count,
        config.safety_ticks,
        config.request_count,
        config.partition_probability.numerator,
        config.partition_probability.denominator,
        config.heal_probability.numerator,
        config.heal_probability.denominator,
        config.crash_probability.numerator,
        config.crash_probability.denominator,
        result.phase1_ticks,
        result.phase2_ticks,
        result.checker_summary.safety_violations,
        result.checker_summary.view_changes_observed,
        result.messages_sent,
    }) catch return;
    _ = std.c.write(fd, line.ptr, line.len);
}

fn logProgress(seeds: u64, failures: u64, elapsed: f64, rate: f64, last_fail: u64) void {
    const mins = @as(u64, @intFromFloat(elapsed)) / 60;
    const secs = @as(u64, @intFromFloat(elapsed)) % 60;
    if (last_fail > 0) {
        log("[fuzz] {d:0>2}:{d:0>2} | seeds: {d} | failures: {d} | rate: {d:.1}/s | last_fail: seed={d}\n", .{ mins, secs, seeds, failures, rate, last_fail });
    } else {
        log("[fuzz] {d:0>2}:{d:0>2} | seeds: {d} | failures: {d} | rate: {d:.1}/s\n", .{ mins, secs, seeds, failures, rate });
    }
}

fn wallClockMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

test "replay trace collector has bounded explicit heap lifetime" {
    const trace_mod = @import("vopr/trace.zig");
    const collector = try std.testing.allocator.create(vopr.TraceCollector);
    collector.initInPlace(5);
    defer {
        collector.deinit();
        std.testing.allocator.destroy(collector);
    }

    try std.testing.expect(@sizeOf(vopr.TraceCollector) > 1024 * 1024);
    try std.testing.expect(@sizeOf(vopr.TraceCollector) <= trace_mod.MAX_TRACE_COLLECTOR_BYTES);
    try std.testing.expectEqual(@as(usize, 0), collector.count);
}

test "thread ranges cover each seed once" {
    const testing = std.testing;
    try testing.expectEqual(SeedRange{ .start = 0, .end = 3 }, threadRange(10, 4, 0));
    try testing.expectEqual(SeedRange{ .start = 3, .end = 6 }, threadRange(10, 4, 1));
    try testing.expectEqual(SeedRange{ .start = 6, .end = 8 }, threadRange(10, 4, 2));
    try testing.expectEqual(SeedRange{ .start = 8, .end = 10 }, threadRange(10, 4, 3));
}

test "thread count is bounded by seed count" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 3), try resolveThreadCount(3, 8));
    try testing.expectEqual(@as(usize, 1), try resolveThreadCount(0, 8));
}
