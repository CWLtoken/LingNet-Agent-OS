//! LingNet Agent OS V2.5 — L0/L1/L2 三级路由表
//! P0-1 FIX (方案B): AutoHashMap O(1) 平均查找
//! 方案C (CHD完美哈希) 已实现在 perfect_hash.zig，待后续集成

const std = @import("std");
const gqap = @import("arena-gqap");

// 测试用 pool 初始化保护
var g_switch_pools_init = false;

fn ensureSwitchPoolsInit() void {
    if (!g_switch_pools_init) {
        g_switch_pools_init = true;
        // Pools initialized via gqap.initPools() in main; tests use page_allocator directly
    }
}

/// 路由优先级
pub const RouteTier = enum(u2) { l0, l1, l2 };

/// 路由条目
pub const RouteEntry = struct {
    intent_id: u32,
    tier: RouteTier,
    handler: *const fn (ctx: *anyopaque) callconv(.c) void,
    arena: ?gqap.Arena(.trusted) = null,
};

/// 路由表配置
pub const SwitchConfig = struct {
    l0_slots: usize = 64,
    l1_capacity: usize = 256,
    l2_capacity: usize = 1024,
};

/// L0/L1/L2 三级路由表
pub const SwitchTable = struct {
    allocator: std.mem.Allocator,
    config: SwitchConfig,

    // L0: 固定数组，线性扫描（< 64 entries, < 10ns）
    l0_routes: []RouteEntry,
    l0_count: usize,

    // L1: AutoHashMap O(1) — P0-1 FIX (方案B)
    l1_map: std.AutoHashMap(u32, RouteEntry),
    // L2: AutoHashMap O(1) — P0-1 FIX (方案B)
    l2_map: std.AutoHashMap(u32, RouteEntry),

    pub fn init(allocator: std.mem.Allocator, config: SwitchConfig) !SwitchTable {
        const l0 = try allocator.alloc(RouteEntry, config.l0_slots);
        errdefer allocator.free(l0);

        return .{
            .allocator = allocator,
            .config = config,
            .l0_routes = l0,
            .l0_count = 0,
            .l1_map = std.AutoHashMap(u32, RouteEntry).init(allocator),
            .l2_map = std.AutoHashMap(u32, RouteEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SwitchTable) void {
        self.allocator.free(self.l0_routes);
        self.l1_map.deinit();
        self.l2_map.deinit();
    }

    pub fn registerL0(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        if (self.l0_count >= self.l0_routes.len) return error.TableFull;
        self.l0_routes[self.l0_count] = .{
            .intent_id = intent_id,
            .tier = .l0,
            .handler = handler,
            .arena = null,
        };
        self.l0_count += 1;
    }

    pub fn registerL1(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        try self.l1_map.put(intent_id, .{
            .intent_id = intent_id,
            .tier = .l1,
            .handler = handler,
            .arena = null,
        });
    }

    pub fn registerL2(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        try self.l2_map.put(intent_id, .{
            .intent_id = intent_id,
            .tier = .l2,
            .handler = handler,
            .arena = null,
        });
    }

    /// O(1) 查找 — P0-1 FIX (方案B: AutoHashMap)
    pub fn lookup(self: *SwitchTable, intent_id: u32) ?*RouteEntry {
        // L0: Linear scan by intent_id (small table, < 64 entries)
        for (0..self.l0_count) |i| {
            if (self.l0_routes[i].intent_id == intent_id) {
                return &self.l0_routes[i];
            }
        }
        // L1: AutoHashMap O(1)
        if (self.l1_map.getPtr(intent_id)) |entry| {
            return entry;
        }
        // L2: AutoHashMap O(1)
        if (self.l2_map.getPtr(intent_id)) |entry| {
            return entry;
        }
        return null;
    }

    pub fn stats(self: *SwitchTable) struct { l0_count: usize, l1_count: usize, l2_count: usize } {
        return .{
            .l0_count = self.l0_count,
            .l1_count = self.l1_map.count(),
            .l2_count = self.l2_map.count(),
        };
    }
};

// ─── 测试 ───────────────────────────────────────────────────────────────

test "SwitchTable register and lookup" {
    ensureSwitchPoolsInit();
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const handler = @as(*const fn (ctx: *anyopaque) callconv(.c) void, @ptrFromInt(0x1000));

    try table.registerL0(1, handler);
    try table.registerL0(2, handler);
    try table.registerL1(100, handler);
    try table.registerL2(1000, handler);

    const e1 = table.lookup(1);
    try std.testing.expect(e1 != null);
    try std.testing.expectEqual(@as(u32, 1), e1.?.intent_id);

    const e100 = table.lookup(100);
    try std.testing.expect(e100 != null);
    try std.testing.expectEqual(@as(u32, 100), e100.?.intent_id);

    const e1000 = table.lookup(1000);
    try std.testing.expect(e1000 != null);
    try std.testing.expectEqual(@as(u32, 1000), e1000.?.intent_id);

    try std.testing.expect(table.lookup(999) == null);
}

test "SwitchTable priority L0 > L1 > L2" {
    ensureSwitchPoolsInit();
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const handler = @as(*const fn (ctx: *anyopaque) callconv(.c) void, @ptrFromInt(0x1000));

    // Same intent_id in all tiers — L0 should win
    try table.registerL0(42, handler);
    try table.registerL1(42, handler);
    try table.registerL2(42, handler);

    const entry = table.lookup(42);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(RouteTier.l0, entry.?.tier);
}

test "SwitchTable L1 and L2 O(1) lookup" {
    ensureSwitchPoolsInit();
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const handler = @as(*const fn (ctx: *anyopaque) callconv(.c) void, @ptrFromInt(0x1000));

    // Register many L1 routes
    for (0..100) |i| {
        try table.registerL1(@as(u32, @intCast(i * 10)), handler);
    }

    // Register many L2 routes
    for (0..200) |i| {
        try table.registerL2(@as(u32, @intCast(i * 5 + 5000)), handler);
    }

    // Verify L1 lookups
    for (0..100) |i| {
        const key: u32 = @intCast(i * 10);
        const entry = table.lookup(key);
        try std.testing.expect(entry != null);
        try std.testing.expectEqual(key, entry.?.intent_id);
    }

    // Verify L2 lookups
    for (0..200) |i| {
        const key: u32 = @intCast(i * 5 + 5000);
        const entry = table.lookup(key);
        try std.testing.expect(entry != null);
        try std.testing.expectEqual(key, entry.?.intent_id);
    }

    // Stats
    const s = table.stats();
    try std.testing.expectEqual(@as(usize, 0), s.l0_count);
    try std.testing.expectEqual(@as(usize, 100), s.l1_count);
    try std.testing.expectEqual(@as(usize, 200), s.l2_count);
}
