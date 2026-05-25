//! LingNet Agent OS V2.2 — Perfect Hash Function Generator
//! Simple compile-time perfect hash for L0/L1 routing tables

const std = @import("std");

/// PHF using FNV-1a hash with seed search
pub const Phf = struct {
    seed: u32,
    buckets: []const i32,
    bucket_count: usize,

    pub fn generate(comptime keys: []const u32) Phf {
        const n = keys.len;
        const m = if (n == 0) 1 else n * 2;

        // Try seeds until we find one with no collisions
        var seed: u32 = 1;
        while (seed < 65536) : (seed += 1) {
            var buckets: [128]i32 = undefined;
            for (&buckets) |*b| b.* = -1;
            var ok = true;
            for (keys) |key| {
                const h = hashU32(key, seed) % @as(u32, @intCast(m));
                if (buckets[h] != -1) {
                    ok = false;
                    break;
                }
                buckets[h] = @intCast(key);
            }
            if (ok) {
                return .{ .seed = seed, .buckets = &buckets, .bucket_count = m };
            }
        }

        // Fallback: identity mapping (seed = 0)
        var buckets: [128]i32 = undefined;
        for (&buckets, 0..) |*b, i| {
            b.* = if (i < n) @intCast(keys[i]) else -1;
        }
        return .{ .seed = 0, .buckets = &buckets, .bucket_count = n };
    }

    pub fn lookup(self: Phf, key: u32) ?usize {
        if (self.seed == 0 or self.bucket_count == 0) {
            // Linear search fallback
            for (self.buckets, 0..) |b, i| {
                if (b == @as(i32, @intCast(key))) return i;
            }
            return null;
        }
        const h = hashU32(key, self.seed) % @as(u32, @intCast(self.bucket_count));
        if (self.buckets[h] == @as(i32, @intCast(key))) return h;
        return null;
    }

    fn hashU32(key: u32, seed: u32) u32 {
        var h: u32 = seed;
        var k = key;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            h ^= k & 0xFF;
            h *%= 16777619;
            k >>= 8;
        }
        return h;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "Phf lookup" {
    const keys = &[_]u32{ 100, 200, 300, 400, 500 };
    const phf = Phf.generate(keys);

    for (keys) |key| {
        const idx = phf.lookup(key);
        try std.testing.expect(idx != null);
    }

    try std.testing.expect(phf.lookup(999) == null);
}

test "Phf empty keys" {
    const keys = &[_]u32{};
    const phf = Phf.generate(keys);
    try std.testing.expect(phf.lookup(1) == null);
}

test "Phf single key" {
    const keys = &[_]u32{ 42 };
    const phf = Phf.generate(keys);
    try std.testing.expect(phf.lookup(42) != null);
    try std.testing.expect(phf.lookup(43) == null);
}
