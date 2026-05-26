//! LingNet Agent OS V2.4 — Performance Benchmarks
//! rdtsc timer + P99 histogram for all critical paths

const std = @import("std");
const gqap = @import("arena-gqap");

/// rdtsc timestamp counter
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Histogram for latency distribution
pub const Histogram = struct {
    buckets: [256]u64,
    min: u64,
    max: u64,
    count: u64,
    sum: u64,

    pub fn init() Histogram {
        var h: Histogram = .{
            .buckets = undefined,
            .min = std.math.maxInt(u64),
            .max = 0,
            .count = 0,
            .sum = 0,
        };
        for (&h.buckets) |*b| {
            b.* = 0;
        }
        return h;
    }

    pub fn record(self: *Histogram, value: u64) void {
        const bucket: usize = if (value >= 255) 255 else @intCast(value);
        self.buckets[bucket] += 1;
        self.count += 1;
        self.sum += value;
        if (value < self.min) self.min = value;
        if (value > self.max) self.max = value;
    }

    pub fn percentile(self: *Histogram, p: f64) u64 {
        const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.count)) * p / 100.0));
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) return i;
        }
        return 255;
    }

    pub fn report(self: *Histogram, name: []const u8) void {
        std.log.info("[PERF] {}: count={} min={} max={} avg={} P50={} P99={} P999={}", .{
            name, self.count, self.min, self.max,
            if (self.count > 0) self.sum / self.count else 0,
            self.percentile(50),
            self.percentile(99),
            self.percentile(99.9),
        });
    }
};

/// Benchmark: Trusted Arena init/deinit
fn benchTrustedArena(iterations: usize) void {
    var hist = Histogram.init();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = rdtsc();
        var arena = gqap.Arena(.trusted).init() catch unreachable;
        const elapsed = rdtsc() - start;
        hist.record(elapsed);
        arena.deinit();
    }
    hist.report("TrustedArena.init+deinit");
}

/// Benchmark: Untrusted Arena init/deinit
fn benchUntrustedArena(iterations: usize) void {
    var hist = Histogram.init();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = rdtsc();
        var arena = gqap.Arena(.untrusted).init() catch unreachable;
        const elapsed = rdtsc() - start;
        hist.record(elapsed);
        arena.deinit();
    }
    hist.report("UntrustedArena.init+deinit");
}

/// Benchmark: Arena alloc
fn benchArenaAlloc(iterations: usize) void {
    var arena = gqap.Arena(.trusted).init() catch unreachable;
    defer arena.deinit();

    var hist = Histogram.init();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = rdtsc();
        const buf = arena.alloc(u8, 256) catch unreachable;
        const elapsed = rdtsc() - start;
        hist.record(elapsed);
        _ = buf;
    }
    hist.report("Arena.alloc(256)");
}

/// Benchmark: Pool stats read
fn benchPoolStats(iterations: usize) void {
    var hist = Histogram.init();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = rdtsc();
        const stats = gqap.getStats();
        const elapsed = rdtsc() - start;
        hist.record(elapsed);
        _ = stats;
    }
    hist.report("getStats");
}

/// Run all benchmarks
pub fn runAllBenchmarks() void {
    const iterations = 100_000;

    std.log.info("\n[LingNet V2.4] Performance Benchmarks ({d} iterations each)\n", .{iterations});

    benchTrustedArena(iterations);
    benchUntrustedArena(iterations);
    benchArenaAlloc(iterations);
    benchPoolStats(iterations);

    std.log.info("\n[LingNet V2.4] Benchmarks complete ✅\n", .{});
}

// ─── Tests ───────────────────────────────────────────────────────────

var g_bench_pools_init = false;
fn ensureBenchPoolsInit() void {
    if (!g_bench_pools_init) {
        gqap.initPools(std.heap.page_allocator, 4, 4096) catch {};
        g_bench_pools_init = true;
    }
}

test "Histogram basic" {
    var h = Histogram.init();
    h.record(10);
    h.record(20);
    h.record(30);
    try std.testing.expectEqual(@as(u64, 3), h.count);
    try std.testing.expectEqual(@as(u64, 10), h.min);
    try std.testing.expectEqual(@as(u64, 30), h.max);
}

test "Histogram percentile" {
    var h = Histogram.init();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        h.record(@intCast(i));
    }
    try std.testing.expectEqual(@as(u64, 49), h.percentile(50));
    try std.testing.expectEqual(@as(u64, 98), h.percentile(99));
}

test "rdtsc monotonic" {
    const t1 = rdtsc();
    const t2 = rdtsc();
    try std.testing.expect(t2 >= t1);
}

test "benchTrustedArena smoke" {
    ensureBenchPoolsInit();
    var hist = Histogram.init();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const start = rdtsc();
        var arena = gqap.Arena(.trusted).init() catch unreachable;
        const elapsed = rdtsc() - start;
        hist.record(elapsed);
        arena.deinit();
    }
    try std.testing.expect(hist.count == 10);
}
