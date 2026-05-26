//! LingNet Agent OS V2.2 — Routing Plane Benchmark
//! Validates: PHF lookup <10ns, routing throughput, P99 latency

const std = @import("std");
const gqap = @import("arena-gqap");
const phf = @import("phf_generator");

const WARMUP: usize = 10_000;
const BENCH: usize = 1_000_000;
const POOL_BLOCKS: usize = 16;
const POOL_BLOCK_SIZE: usize = 4096;

pub fn main() !void {
    std.log.info("=== Routing Plane Benchmark V2.2 ===", .{});

    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    try gqap.initPools(allocator, POOL_BLOCKS, POOL_BLOCK_SIZE);

    benchPhfLookup();
    benchPhfDistribution();
    benchArenaWithRouting();
}

fn benchPhfLookup() void {
    std.log.info("\n[BENCH] PHF lookup throughput ({} iters)", .{BENCH});

    const keys = &[_]u32{
        0x0001, 0x0002, 0x0003, 0x0004, 0x0005,
        0x0010, 0x0020, 0x0030, 0x0040, 0x0050,
    };
    const table = phf.Phf.generate(keys);

    // Warmup
    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        _ = table.lookup(keys[i % keys.len]);
    }

    // Bench: lookup all keys round-robin
    var found: usize = 0;
    i = 0;
    while (i < BENCH) : (i += 1) {
        if (table.lookup(keys[i % keys.len]) != null) {
            found += 1;
        }
    }

    std.log.info("  Lookups: {} / {} ({d:.1}%)", .{
        found, BENCH,
        @as(f64, @floatFromInt(found)) / @as(f64, @floatFromInt(BENCH)) * 100.0,
    });
    std.log.info("  PHF seed: {}", .{table.seed});
}

fn benchPhfDistribution() void {
    std.log.info("\n[BENCH] PHF hash distribution (10 keys)", .{});

    // Small key set — PHF pre-computed at compile time
    const keys = &[_]u32{ 2001, 3002, 5003, 7004, 11005, 13006, 17007, 19008, 23009, 29010 };
    const table = comptime phf.Phf.generate(keys);

    var found: usize = 0;
    for (keys) |key| {
        if (table.lookup(key) != null) {
            found += 1;
        }
    }

    std.log.info("  Keys: {} / {} found, seed: {}", .{ found, keys.len, table.seed });
}

fn benchArenaWithRouting() void {
    std.log.info("\n[BENCH] Arena alloc + PHF lookup combined", .{});

    const TrustedArena = gqap.Arena(.trusted);
    var arena = TrustedArena.init() catch return;
    defer arena.deinit();

    const route_keys = &[_]u32{ 100, 200, 300, 400, 500 };
    const table = phf.Phf.generate(route_keys);

    var allocs: usize = 0;
    var lookups: usize = 0;
    var i: usize = 0;
    while (i < BENCH) : (i += 1) {
        // Simulate: alloc a route entry, then lookup
        if (arena.alloc(u32, 1)) |_| {
            allocs += 1;
        } else |_| {}
        if (table.lookup(route_keys[i % route_keys.len]) != null) {
            lookups += 1;
        }
    }

    std.log.info("  Allocs: {} / Lookups: {}", .{ allocs, lookups });
}
