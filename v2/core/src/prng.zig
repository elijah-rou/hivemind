/// Ratio: numerator/denominator probability. Allows very low probabilities
/// like 1-in-10-million that u8 percentages can't express.
pub const Ratio = struct {
    numerator: u32,
    denominator: u32,

    pub fn init(numerator: u32, denominator: u32) Ratio {
        return .{ .numerator = numerator, .denominator = denominator };
    }

    /// Zero probability (never triggers).
    pub fn zero() Ratio {
        return .{ .numerator = 0, .denominator = 1 };
    }

    /// Convenience: from percentage (e.g., 3 → 3/100).
    pub fn fromPercent(pct: u8) Ratio {
        return .{ .numerator = pct, .denominator = 100 };
    }

    pub fn isZero(self: Ratio) bool {
        return self.numerator == 0;
    }
};

/// Xorshift64 PRNG. Deterministic: same seed = identical sequence.
pub const Prng = struct {
    state: u64,

    pub fn init(seed: u64) Prng {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    pub fn next(self: *Prng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    pub fn bounded(self: *Prng, bound: u64) u64 {
        return self.next() % bound;
    }

    pub fn intBounded(self: *Prng, comptime T: type, bound: T) T {
        return @intCast(self.bounded(@intCast(bound)));
    }

    /// Returns true with probability ratio.numerator / ratio.denominator.
    pub fn chance(self: *Prng, ratio: Ratio) bool {
        if (ratio.numerator == 0) return false;
        if (ratio.numerator >= ratio.denominator) return true;
        return self.bounded(ratio.denominator) < ratio.numerator;
    }
};

test "deterministic output" {
    var a = Prng.init(42);
    var b = Prng.init(42);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const std = @import("std");
        try std.testing.expectEqual(a.next(), b.next());
    }
}

test "ratio chance" {
    const std = @import("std");
    var p = Prng.init(999);

    // Zero ratio never fires
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(!p.chance(Ratio.zero()));
    }

    // 100% ratio always fires
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(p.chance(Ratio.init(1, 1)));
    }

    // 50% ratio fires roughly half the time
    var hits: u32 = 0;
    i = 0;
    while (i < 10000) : (i += 1) {
        if (p.chance(Ratio.init(1, 2))) hits += 1;
    }
    try std.testing.expect(hits > 4000 and hits < 6000);
}

test "bounded stays in range" {
    var p = Prng.init(123);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const std = @import("std");
        try std.testing.expect(p.bounded(10) < 10);
    }
}
