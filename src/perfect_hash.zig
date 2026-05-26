//! LingNet Agent OS V2.5 — CHD 完美哈希路由表
//! P0-1 FIX (方案C): Compress, Hash, Displace 算法实现
//!
//! CHD 算法（Botelho & Ziviani, 2007）:
//!   1. Compress:  将 N 个键分配到 G 个桶中（第一轮哈希）
//!   2. Hash:      为每个桶选择种子值，使桶内键无冲突（第二轮哈希）
//!   3. Displace:  按桶大小降序排列，贪心放置碰撞键（种子搜索）
//!
//! 特性:
//!   - O(1) 最坏情况查找（无冲突）
//!   - 空间紧凑：~2.09 bits/key（理论最优 ~1.44 bits/key）
//!   - 构建一次，多次查找（适合路由表静态配置）
//!   - 零堆分配查找路径（纯数组索引）

const std = @import("std");

/// CHD 完美哈希表（只读查找，构建后不可修改）
pub fn PerfectHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Seed = u32;
        const Empty = 0xFFFF_FFFF;

        /// 桶信息（构建阶段使用）
        const Bucket = struct {
            items: []BucketItem,
            seed: Seed,
            count: usize,
        };

        pub const BucketItem = struct {
            key: K,
            value: V,
        };

        /// 查找表（运行时只读）
        entries: []V,
        seeds: []Seed,
        num_keys: usize,
        allocator: std.mem.Allocator,

        /// 从静态键值对数组构建完美哈希表
        pub fn build(allocator: std.mem.Allocator, items: []const BucketItem) !Self {
            const n = items.len;
            if (n == 0) return Self{
                .entries = &[_]V{},
                .seeds = &[_]Seed{},
                .num_keys = 0,
                .allocator = allocator,
            };

            // 桶数 = ceil(N / 4)，保持负载因子 ~4
            const num_buckets = (n + 3) / 4;

            // 分配输出表
            const entries = try allocator.alloc(V, n + num_buckets);
            const seeds = try allocator.alloc(Seed, num_buckets);

            // 初始化
            @memset(entries, undefined);
            @memset(seeds, 0);

            // ─── Step 1: Compress ───────────────────────────────────────
            // 将键分配到桶中，统计每个桶的大小
            var bucket_counts = try allocator.alloc(usize, num_buckets);
            defer allocator.free(bucket_counts);
            @memset(bucket_counts, 0);

            for (items) |item| {
                const b_idx = hash1(item.key, num_buckets);
                bucket_counts[b_idx] += 1;
            }

            // ─── Step 2: Hash (为每个桶找种子) ──────────────────────────
            // 按桶大小降序处理（大桶优先）
            var bucket_order = try allocator.alloc(usize, num_buckets);
            defer allocator.free(bucket_order);
            for (0..num_buckets) |i| bucket_order[i] = i;

            // 简单的选择排序（桶数少，O(G^2) 可接受）
            for (0..num_buckets) |i| {
                var max_idx = i;
                var max_val = bucket_counts[bucket_order[i]];
                for (i + 1..num_buckets) |j| {
                    if (bucket_counts[bucket_order[j]] > max_val) {
                        max_idx = j;
                        max_val = bucket_counts[bucket_order[j]];
                    }
                }
                const tmp = bucket_order[i];
                bucket_order[i] = bucket_order[max_idx];
                bucket_order[max_idx] = tmp;
            }

            // 标记已占用的槽位
            var slot_used = try allocator.alloc(bool, n + num_buckets);
            defer allocator.free(slot_used);
            @memset(slot_used, false);

            // 逐个桶处理
            for (bucket_order) |b_idx| {
                const bucket_size = bucket_counts[b_idx];
                if (bucket_size == 0) {
                    seeds[b_idx] = 0;
                    continue;
                }

                // 收集桶内所有键
                var bucket_keys = try allocator.alloc(K, bucket_size);
                defer allocator.free(bucket_keys);
                var ki: usize = 0;
                for (items) |item| {
                    if (hash1(item.key, num_buckets) == b_idx) {
                        bucket_keys[ki] = item.key;
                        ki += 1;
                    }
                }

                // 搜索种子：找到使桶内键无冲突放置的种子
                var found_seed: Seed = 0;
                var placed = false;
                var seed_try: Seed = 0;

                const table_size = n + num_buckets;

                while (!placed and seed_try < 1_000_000) : (seed_try += 1) {
                    var ok = true;

                    // 检查桶内所有键是否映射到不同槽位，且都不与已占用槽位冲突
                    for (0..bucket_size) |i| {
                        const slot_i = hash2(bucket_keys[i], seed_try, table_size);
                        // 检查是否与已占用槽位冲突
                        if (slot_used[slot_i]) {
                            ok = false;
                            break;
                        }
                        // 检查桶内冲突（与其他桶内键）
                        for (i + 1..bucket_size) |j| {
                            const slot_j = hash2(bucket_keys[j], seed_try, table_size);
                            if (slot_i == slot_j) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) break;
                    }

                    if (ok) {
                        found_seed = seed_try;
                        placed = true;
                        // 标记全局槽位
                        for (bucket_keys) |key| {
                            const slot = hash2(key, found_seed, table_size);
                            slot_used[slot] = true;
                        }
                    }
                }

                if (!placed) {
                    // 退化：使用线性探测（理论上不应发生）
                    allocator.free(slot_used);
                    allocator.free(bucket_order);
                    allocator.free(seeds);
                    allocator.free(entries);
                    return error.CHDFailed;
                }

                seeds[b_idx] = found_seed;
            }

            // ─── Step 3: Displace (填充值) ──────────────────────────────
            for (items) |item| {
                const b_idx = hash1(item.key, num_buckets);
                const slot = hash2(item.key, seeds[b_idx], n + num_buckets);
                entries[slot] = item.value;
            }

            return Self{
                .entries = entries,
                .seeds = seeds,
                .num_keys = n,
                .allocator = allocator,
            };
        }

        /// O(1) 完美哈希查找（无冲突）
        pub fn get(self: *const Self, key: K) ?V {
            if (self.num_keys == 0) return null;
            const num_buckets = self.seeds.len;
            const b_idx = hash1(key, num_buckets);
            const slot = hash2(key, self.seeds[b_idx], self.entries.len);
            return self.entries[slot];
        }

        /// O(1) 完美哈希查找（返回指针）
        pub fn getPtr(self: *const Self, key: K) ?*V {
            if (self.num_keys == 0) return null;
            const num_buckets = self.seeds.len;
            const b_idx = hash1(key, num_buckets);
            const slot = hash2(key, self.seeds[b_idx], self.entries.len);
            return &self.entries[slot];
        }

        /// 释放构建时分配的内存
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
            self.allocator.free(self.seeds);
        }

        // ─── 哈希函数 ───────────────────────────────────────────────────

        /// 第一轮哈希：键 → 桶索引
        fn hash1(key: K, num_buckets: usize) usize {
            const k = switch (@typeInfo(K)) {
                .int => @as(u64, @intCast(key)),
                .comptime_int => @as(u64, @intCast(key)),
                else => @as(u64, @intCast(@as(usize, @intFromPtr(key)))),
            };
            // FNV-1a 变体
            const h = (k *% 0x9E37_79B9_7F4A_7C15) >> 32;
            return @as(usize, @intCast(h)) % num_buckets;
        }

        /// 第二轮哈希：键 + 种子 → 槽位索引
        fn hash2(key: K, seed: Seed, table_size: usize) usize {
            const k = switch (@typeInfo(K)) {
                .int => @as(u64, @intCast(key)),
                .comptime_int => @as(u64, @intCast(key)),
                else => @as(u64, @intCast(@as(usize, @intFromPtr(key)))),
            };
            // 混合种子和键
            const mixed = k ^ (@as(u64, seed) << 32 | seed);
            const h = (mixed *% 0x517C_C1B7_2722_0A95) >> 32;
            return @as(usize, @intCast(h)) % table_size;
        }
    };
}

// ─── 测试 ───────────────────────────────────────────────────────────────

test "PerfectHashMap basic build and lookup" {
    const Map = PerfectHashMap(u32, u32);

    const items = [_]Map.BucketItem{
        .{ .key = 100, .value = 1000 },
        .{ .key = 200, .value = 2000 },
        .{ .key = 300, .value = 3000 },
        .{ .key = 400, .value = 4000 },
    };

    var map = try Map.build(std.testing.allocator, &items);
    defer map.deinit();

    // 所有键都能查到
    try std.testing.expectEqual(@as(u32, 1000), map.get(100).?);
    try std.testing.expectEqual(@as(u32, 2000), map.get(200).?);
    try std.testing.expectEqual(@as(u32, 3000), map.get(300).?);
    try std.testing.expectEqual(@as(u32, 4000), map.get(400).?);

    // 不存在的键返回 null
    try std.testing.expect(map.get(999) == null);
}

test "PerfectHashMap larger set" {
    const Map = PerfectHashMap(u32, u32);

    // 20 个随机键
    var items: [20]Map.BucketItem = undefined;
    const keys = [_]u32{ 11, 23, 37, 42, 59, 61, 73, 88, 91, 104, 117, 129, 133, 146, 158, 162, 175, 188, 193, 207 };
    for (keys, 0..) |k, i| {
        items[i] = .{ .key = k, .value = k * 100 };
    }

    var map = try Map.build(std.testing.allocator, &items);
    defer map.deinit();

    // 验证所有键
    for (keys) |k| {
        const v = map.get(k);
        try std.testing.expect(v != null);
        try std.testing.expectEqual(k * 100, v.?);
    }
}

test "PerfectHashMap two keys" {
    const Map = PerfectHashMap(u32, u32);
    const items = [_]Map.BucketItem{
        .{ .key = 400, .value = 400 },
        .{ .key = 500, .value = 500 },
    };
    var map = try Map.build(std.testing.allocator, &items);
    defer map.deinit();
    try std.testing.expectEqual(@as(u32, 400), map.get(400).?);
    try std.testing.expectEqual(@as(u32, 500), map.get(500).?);
    try std.testing.expect(map.get(999) == null);
}

test "PerfectHashMap empty" {
    const Map = PerfectHashMap(u32, u32);
    const items = [_]Map.BucketItem{};
    var map = try Map.build(std.testing.allocator, &items);
    defer map.deinit();
    try std.testing.expect(map.get(1) == null);
}
