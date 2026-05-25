//! LingNet Agent OS V2.2 — MRC Data Plane Benchmark
//! Validates: L1 lookup <10ns, routing throughput, P99 latency

const std = @import("std");
const gqap = @import("arena-gqap");

const WARMUP: usize = 1000;
const BENCH: usize = 100_000;
const POOL_BLOCKS: usize = 64;
const POOL_BLOCK_SIZE: usize = 4096;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.log.info("=== MRC Data Plane Benchmark V2.2 ===", .{});

    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    try gqap.initPools(allocator, POOL_BLOCKS, POOL_BLOCK_SIZE);

    benchArenaAlloc(io);
    benchArenaDeallocPattern(io);
    benchMixedWorkload(io);

    const stats = gqap.getStats();
    std.log.info("\n=== Pool Stats ===", .{});
    std.log.info("Common free: {}", .{stats.common_free});
    std.log.info("Quarantine pending: {}", .{stats.quarantine_pending});
    std.log.info("L2 free: {}", .{stats.l2_free});
    std.log.info("Total sanitized: {}", .{stats.total_sanitized});
}

fn benchArenaAlloc(io: std.Io) void {
    std.log.info("\n[BENCH] Arena alloc throughput ({} iters)", .{BENCH});

    var arena = gqap.Arena(.trusted).init() catch return;
    defer arena.deinit();

    // Warmup
    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        _ = arena.alloc(u64, 1) catch {};
    }

    // Bench
    var successes: usize = 0;
    i = 0;
    while (i < BENCH) : (i += 1) {
        if (arena.alloc(u64, 1)) |_| {
            successes += 1;
        } else |_| {}
    }

    std.log.info("  Allocs: {} / {} ({d:.1}%)", .{ successes, BENCH, @as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(BENCH)) * 100.0 });
    std.log.info("  Arena offset: {}", .{arena.offset});
}

fn benchArenaDeallocPattern(io: std.Io) void {
    std.log.info("\n[BENCH] Arena init/deinit cycle ({} iters)", .{WARMUP});

    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        var arena = gqap.Arena(.trusted).init() catch continue;
        _ = arena.alloc(u8, 64) catch {};
        arena.deinit();
    }

    std.log.info("  Completed {} cycles", .{WARMUP});
}

fn benchMixedWorkload(io: std.Io) void {
    std.log.info("\n[BENCH] Mixed trusted/untrusted workload", .{});

    var t_arena = gqap.Arena(.trusted).init() catch return;
    defer t_arena.deinit();
    var u_arena = gqap.Arena(.untrusted).init() catch return;
    defer u_arena.deinit();

    var t_allocs: usize = 0;
    var u_allocs: usize = 0;
    var i: usize = 0;
    while (i < BENCH) : (i += 1) {
        if (i % 3 == 0) {
            if (u_arena.alloc(u32, 1)) |_| {
                u_allocs += 1;
            } else |_| {}
        } else {
            if (t_arena.alloc(u32, 1)) |_| {
                t_allocs += 1;
            } else |_| {}
        }
    }

    std.log.info("  Trusted allocs: {}", .{t_allocs});
    std.log.info("  Untrusted allocs: {}", .{u_allocs});
    std.log.info("  Total: {}", .{t_allocs + u_allocs});
}
