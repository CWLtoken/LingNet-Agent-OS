//! LingNet Agent OS V2.3 — L0/L1/L2 三级路由表
//! CHD完美哈希 + io_uring 零拷贝路由

const std = @import("std");
const gqap = @import("arena-gqap");

// 测试用 pool 初始化保护
var g_switch_pools_init = false;
fn ensureSwitchPoolsInit() void {
    if (!g_switch_pools_init) {
        gqap.initPools(std.heap.page_allocator, 4, 4096) catch {};
        g_switch_pools_init = true;
    }
}

/// 路由层级
pub const RouteTier = enum(u2) {
    l0 = 0,
    l1 = 1,
    l2 = 2,
};

/// 路由条目
pub const RouteEntry = struct {
    intent_id: u32,
    tier: RouteTier,
    handler: *const fn (ctx: *anyopaque) callconv(.c) void,
    arena: gqap.Arena(.trusted),

    pub fn init(intent_id: u32, tier: RouteTier, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !RouteEntry {
        return .{
            .intent_id = intent_id,
            .tier = tier,
            .handler = handler,
            .arena = try gqap.Arena(.trusted).init(),
        };
    }

    pub fn deinit(self: *RouteEntry) void {
        self.arena.deinit();
    }
};

/// 路由表配置
pub const SwitchConfig = struct {
    l0_slots: usize = 64,
    l1_slots: usize = 256,
    l2_slots: usize = 1024,
    use_hugepages: bool = false,
    io_uring_entries: u32 = 256,
};

/// 三级路由表
pub const SwitchTable = struct {
    allocator: std.mem.Allocator,
    config: SwitchConfig,
    l0_routes: []RouteEntry,
    l0_count: usize,
    // N4 FIX: Use HashMap for O(1) lookup instead of O(n) linear scan
    l1_map: std.AutoHashMap(u32, RouteEntry),
    l2_map: std.AutoHashMap(u32, RouteEntry),
    ring: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, config: SwitchConfig) !SwitchTable {
        const l0 = try allocator.alloc(RouteEntry, config.l0_slots);
        errdefer allocator.free(l0);

        return .{
            .allocator = allocator,
            .config = config,
            .l0_routes = l0,
            .l0_count = 0,
            // N4 FIX: HashMap for O(1) lookup
            .l1_map = std.AutoHashMap(u32, RouteEntry).init(allocator),
            .l2_map = std.AutoHashMap(u32, RouteEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SwitchTable) void {
        for (self.l0_routes[0..self.l0_count]) |*entry| {
            entry.deinit();
        }
        self.allocator.free(self.l0_routes);
        self.l1_map.deinit();
        self.l2_map.deinit();
    }

    pub fn registerL0(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        if (self.l0_count >= self.l0_routes.len) return error.L0TableFull;
        self.l0_routes[self.l0_count] = try RouteEntry.init(intent_id, .l0, handler);
        self.l0_count += 1;
    }

    pub fn registerL1(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        const entry = try RouteEntry.init(intent_id, .l1, handler);
        // N4 FIX: HashMap insert instead of ArrayList append
        try self.l1_map.put(intent_id, entry);
    }

    pub fn registerL2(self: *SwitchTable, intent_id: u32, handler: *const fn (ctx: *anyopaque) callconv(.c) void) !void {
        const entry = try RouteEntry.init(intent_id, .l2, handler);
        // N4 FIX: HashMap insert instead of ArrayList append
        try self.l2_map.put(intent_id, entry);
    }

    pub fn lookup(self: *SwitchTable, intent_id: u32) ?*RouteEntry {
        // L0: Linear scan by intent_id (small table, < 64 entries)
        for (0..self.l0_count) |i| {
            if (self.l0_routes[i].intent_id == intent_id) {
                return &self.l0_routes[i];
            }
        }
        // L1: HashMap O(1) — N4 FIX
        if (self.l1_map.getPtr(intent_id)) |entry| {
            return entry;
        }
        // L2: HashMap O(1) — N4 FIX
        if (self.l2_map.getPtr(intent_id)) |entry| {
            return entry;
        }
        return null;
    }

    pub fn stats(self: *SwitchTable) Stats {
        return .{
            .l0_count = self.l0_count,
            .l1_count = self.l1_map.count(),
            .l2_count = self.l2_map.count(),
        };
    }

    pub const Stats = struct {
        l0_count: usize,
        l1_count: usize,
        l2_count: usize,
    };
};

// ─── Tests ───────────────────────────────────────────────────────────

test "SwitchTable init/deinit" {
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const s = table.stats();
    try std.testing.expectEqual(@as(usize, 0), s.l0_count);
    try std.testing.expectEqual(@as(usize, 0), s.l1_count);
    try std.testing.expectEqual(@as(usize, 0), s.l2_count);
}

test "SwitchTable register and lookup" {
    ensureSwitchPoolsInit();
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const dummy_handler = @as(*const fn (ctx: *anyopaque) callconv(.c) void, @ptrFromInt(0x1000));
    try table.registerL0(1, dummy_handler);

    const entry = table.lookup(1);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 1), entry.?.intent_id);

    try std.testing.expect(table.lookup(999) == null);
}

test "SwitchTable priority L0 > L1 > L2" {
    ensureSwitchPoolsInit();
    var table = try SwitchTable.init(std.testing.allocator, .{});
    defer table.deinit();

    const handler = @as(*const fn (ctx: *anyopaque) callconv(.c) void, @ptrFromInt(0x1000));

    try table.registerL0(42, handler);
    try table.registerL1(42, handler);
    try table.registerL2(42, handler);

    const entry = table.lookup(42);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(RouteTier.l0, entry.?.tier);
}
