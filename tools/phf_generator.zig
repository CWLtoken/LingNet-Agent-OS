//! LingNet Agent OS V2.2 — Perfect Hash Function Generator
//! Simple compile-time perfect hash for L0/L1 routing tables

const std = @import("std");

/// PHF using FNV-1a hash with seed search
pub const Phf = struct {
    seed: u32,
    bucket_count: usize,
    buckets: [256]i32,

    pub fn generate(comptime keys: []const u32) Phf {
        @setEvalBranchQuota(100000);
        const n = keys.len;
        const m = if (n == 0) 1 else if (n <= 5) n * 4 else if (n <= 10) n * 3 else n * 2;
        const max_seed = if (n <= 10) 10000 else 1000;

        var result: Phf = undefined;
        result.bucket_count = m;
        result.seed = 0;

        var seed: u32 = 1;
        while (seed < max_seed) : (seed += 1) {
            var buckets: [256]i32 = undefined;
            for (&buckets) |*b| b.* = -1;
            var ok = true;
            for (keys) |key| {
                const h = hashU32(key, seed) % @as(u32, @intCast(m));
                if (buckets[h] != -1) {
                    ok = false;
                    break;
                }
                buckets[h] = @bitCast(key);
            }
            if (ok) {
                result.seed = seed;
                result.buckets = buckets;
                return result;
            }
        }

        // Fallback: identity mapping (seed = 0)
        for (&result.buckets, 0..) |*b, i| {
            b.* = if (i < n) @bitCast(keys[i]) else -1;
        }
        return result;
    }

    pub fn lookup(self: Phf, key: u32) ?usize {
        if (self.seed == 0 or self.bucket_count == 0) {
            for (&self.buckets, 0..) |b, i| {
                if (@as(u32, @bitCast(b)) == key) return i;
            }
            return null;
        }
        const h = hashU32(key, self.seed) % @as(u32, @intCast(self.bucket_count));
        if (h < self.buckets.len and @as(u32, @bitCast(self.buckets[h])) == key) return h;
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
    const keys = &[_]u32{ 2001, 3002, 5003, 7004, 11005 };
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
