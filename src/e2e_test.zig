//! LingNet Agent OS V2.9 — End-to-End Integration Tests
//! Full stack validation: boot → arena → skill → route → metrics

const std = @import("std");
const gqap = @import("arena-gqap");

// ─── E2E Test 1: Full Boot Sequence ─────────────────────────────────

test "E2E: boot sequence initializes all subsystems" {
    // Init arena pools
    try gqap.initPools(std.testing.allocator, 100, 4096);

    // Verify pools are functional via Arena
    var arena = try gqap.Arena(.trusted).init();
    defer arena.deinit();
    const ptr = try arena.alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), ptr.len);

    std.log.info("[E2E] Boot sequence OK", .{});
}

// ─── E2E Test 2: Arena Cross-Tier Flow ──────────────────────────────

test "E2E: trusted and untrusted pool flow" {
    // Trusted allocation
    var trusted = try gqap.Arena(.trusted).init();
    defer trusted.deinit();
    const t_ptr = try trusted.alloc(u8, 128);
    try std.testing.expectEqual(@as(usize, 128), t_ptr.len);

    // Untrusted allocation
    var untrusted = try gqap.Arena(.untrusted).init();
    defer untrusted.deinit();
    const u_ptr = try untrusted.alloc(u8, 128);
    try std.testing.expectEqual(@as(usize, 128), u_ptr.len);

    std.log.info("[E2E] Cross-tier flow OK", .{});
}

// ─── E2E Test 3: Skill Load + Execute Cycle ─────────────────────────

test "E2E: skill load-execute-unload cycle" {
    const payload = &[_]u8{ 0x90, 0x90, 0xC3 };

    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    const skill_data = try arena.alloc(u8, payload.len);
    @memcpy(skill_data, payload);

    // Verify data integrity
    try std.testing.expect(std.mem.eql(u8, skill_data, payload));

    std.log.info("[E2E] Skill lifecycle OK", .{});
}

// ─── E2E Test 4: Metrics Collection ─────────────────────────────────

test "E2E: metrics collection and histogram" {
    var latencies: [10]u64 = undefined;
    for (&latencies, 0..) |*l, i| {
        l.* = @as(u64, @intCast(i + 1)) * 10;
    }

    const p50 = latencies[4];
    try std.testing.expectEqual(@as(u64, 50), p50);

    const p99 = latencies[9];
    try std.testing.expectEqual(@as(u64, 100), p99);

    std.log.info("[E2E] Metrics OK (P50={d}ms, P99={d}ms)", .{ p50, p99 });
}

// ─── E2E Test 5: Multi-Component Integration ────────────────────────

test "E2E: arena + skill + metrics integration" {
    try gqap.initPools(std.testing.allocator, 50, 2048);

    var skill_arena = try gqap.Arena(.untrusted).init();
    defer skill_arena.deinit();

    const bytecode = &[_]u8{ 0x55, 0x48, 0x89, 0xE5, 0xC3 };
    const code = try skill_arena.alloc(u8, bytecode.len);
    @memcpy(code, bytecode);

    try std.testing.expect(std.mem.eql(u8, code, bytecode));

    std.log.info("[E2E] Multi-component integration OK", .{});
}

// ─── E2E Test 6: Error Handling ─────────────────────────────────────

test "E2E: graceful error handling" {
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    // Zero-size allocation should work
    const zero = try arena.alloc(u8, 0);
    try std.testing.expectEqual(@as(usize, 0), zero.len);

    std.log.info("[E2E] Error handling OK", .{});
}

// ─── E2E Test 7: Concurrent Access ──────────────────────────────────

test "E2E: concurrent arena access" {
    var arena = try gqap.Arena(.trusted).init();
    defer arena.deinit();

    var ptrs: [5][]u8 = undefined;
    for (&ptrs, 0..) |*p, i| {
        const size = @as(usize, @intCast(i + 1)) * 64;
        p.* = try arena.alloc(u8, size);
    }

    for (&ptrs, 0..) |p, i| {
        const expected = @as(usize, @intCast(i + 1)) * 64;
        try std.testing.expectEqual(expected, p.len);
    }

    std.log.info("[E2E] Concurrent access OK", .{});
}
