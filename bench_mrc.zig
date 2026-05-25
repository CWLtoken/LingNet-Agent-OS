//! LingNet Agent OS V2.2 — MRC Data Plane Benchmark
//! Validates: Arena alloc throughput, mixed workload, deinit cycles

const std = @import("std");
const gqap = @import("arena-gqap");

const WARMUP: usize = 1000;
const BENCH: usize = 100_000;
const POOL_BLOCKS: usize = 64;
const POOL_BLOCK_SIZE: usize = 4096;

pub fn main() !void {
    std.log.info("=== MRC Data Plane Benchmark V2.2 ===", .{});

    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    try gqap.initPools(allocator, POOL_BLOCKS, POOL_BLOCK_SIZE);

    benchArenaAlloc();
    benchDeallocCycle();
    benchMixedWorkload();

    const stats = gqap.getStats();
    std.log.info("\n=== Pool Stats ===", .{});
    std.log.info("  Common free: {}", .{stats.common_free});
    std.log.info("  Quarantine pending: {}", .{stats.quarantine_pending});
    std.log.info("  L2 free: {}", .{stats.l2_free});
    std.log.info("  Total sanitized: {}", .{stats.total_sanitized});
}

fn benchArenaAlloc() void {
    std.log.info("\n[BENCH] Arena alloc throughput ({} iters)", .{BENCH});

    const TrustedArena = gqap.Arena(.trusted);
    var arena = TrustedArena.init() catch return;
    defer arena.deinit();

    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        _ = arena.alloc(u64, 1) catch {};
    }

    var successes: usize = 0;
    i = 0;
    while (i < BENCH) : (i += 1) {
        if (arena.alloc(u64, 1)) |_| {
            successes += 1;
        } else |_| {}
    }

    std.log.info("  Allocs: {} / {} ({d:.1}%)", .{
        successes, BENCH,
        @as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(BENCH)) * 100.0,
    });
    std.log.info("  Arena offset: {}", .{arena.offset});
}

fn benchDeallocCycle() void {
    std.log.info("\n[BENCH] Arena init/deinit cycle ({} iters)", .{WARMUP});

    const TrustedArena = gqap.Arena(.trusted);
    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        var arena = TrustedArena.init() catch continue;
        _ = arena.alloc(u8, 64) catch {};
        arena.deinit();
    }

    std.log.info("  Completed {} cycles", .{WARMUP});
}

fn benchMixedWorkload() void {
    std.log.info("\n[BENCH] Mixed trusted/untrusted workload", .{});

    const TrustedArena = gqap.Arena(.trusted);
    const UntrustedArena = gqap.Arena(.untrusted);
    var t_arena = TrustedArena.init() catch return;
    defer t_arena.deinit();
    var u_arena = UntrustedArena.init() catch return;
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

    std.log.info("  Trusted: {} / Untrusted: {} / Total: {}", .{ t_allocs, u_allocs, t_allocs + u_allocs });
}
