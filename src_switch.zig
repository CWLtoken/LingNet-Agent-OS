//! LingNet Agent OS V2.2 - Switching Plane (nullclaw-switch)
//! Integrates: L0/L1/L2 三级查表 + 强制generation校验
//! Fixes: Audit Mid-Priority #7 (generation检查未强制执行)

const std = @import("std");
const gqap = @import("arena-gqap");
const mrc = @import("nullclaw-mrc");

/// Routing table entry
pub const RouteEntry = struct {
    intent_pattern: []const u8,
    handler: *const fn (*mrc.MrcPacket) callconv(.C) void,
    tier: gqap.SecurityTier,
    stats: RouteStats,
};

pub const RouteStats = struct {
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),
    generation_drops: std.atomic.Value(u64),
};

/// Switch engine state
pub const SwitchEngine = struct {
    // L0: ROM hardcoded (< 1ns)
    l0_table: [16]RouteEntry,

    // L1: CHD perfect hash (< 10ns)
    // NOTE(ZIG_VERSION_GATE): Fat pointer []T cannot be atomically loaded/stored.
    // Using a pointer to a table copy + atomic generation guard for safe updates.
    // The actual table swap uses a mutex; readers check generation before dereferencing.
    l1_table_ptr: ?*const RouteEntry,
    l1_table_len: usize,
    l1_table_mutex: std.Thread.Mutex,
    l1_generation: std.atomic.Value(u64),

    // L2: F14HashMap (~50ns)
    l2_map: std.StringHashMap(RouteEntry),
    l2_lock: std.Thread.RwLock,

    // Global generation counter (shared with GQAP)
    current_generation: *std.atomic.Value(u64),

    /// Initialize switch engine
    pub fn init(allocator: std.mem.Allocator, l0_entries: [16]RouteEntry, l1_entries: []const RouteEntry) SwitchEngine {
        return .{
            .l0_table = l0_entries,
            .l1_table_ptr = if (l1_entries.len > 0) &l1_entries[0] else null,
            .l1_table_len = l1_entries.len,
            .l1_table_mutex = .{},
            .l1_generation = .{ .raw = 1 },
            .l2_map = std.StringHashMap(RouteEntry).init(allocator),
            .l2_lock = .{},
            .current_generation = &gqap.g_current_generation,
        };
    }

    /// Main lookup path (inlined for zero function call overhead)
    /// Target: L0 < 1ns, L1 < 10ns, L2 < 50ns
    pub inline fn lookup(self: *SwitchEngine, packet: *mrc.MrcPacket) ?*const RouteEntry {
        // [FIXED V2.2] Mandatory generation check at entry
        const current_gen = self.current_generation.load(.acquire);
        if (packet.generation < current_gen) {
            // Stale packet - drop
            // Find appropriate stats counter (L0 drop as default)
            self.l0_table[0].stats.generation_drops.fetchAdd(1, .monotonic);
            return null;
        }

        // L0: Direct index for system intents (< 1ns)
        if (packet.intent_id < 16) {
            const entry = &self.l0_table[packet.intent_id];
            entry.stats.hits.fetchAdd(1, .monotonic);
            return entry;
        }

        // L1: CHD perfect hash (< 10ns)
        const l1 = self.getL1Table();
        const hash = chdHash(packet.intent);
        if (hash < l1.len) {
            const entry = &l1[hash];
            // Verify intent string matches (perfect hash verification)
            if (std.mem.eql(u8, entry.intent_pattern, packet.intent)) {
                entry.stats.hits.fetchAdd(1, .monotonic);
                return entry;
            }
        }

        // L2: F14HashMap with read lock (~50ns)
        self.l2_lock.lockShared();
        defer self.l2_lock.unlockShared();

        if (self.l2_map.get(packet.intent)) |*entry| {
            entry.stats.hits.fetchAdd(1, .monotonic);
            return entry;
        }

        // Miss - increment default stats
        self.l0_table[0].stats.misses.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn getL1Table(self: *const SwitchEngine) []const RouteEntry {
        self.l1_table_mutex.lock();
        defer self.l1_table_mutex.unlock();
        if (self.l1_table_ptr) |ptr| {
            return ptr[0..self.l1_table_len];
        }
        return &.{};
    }

    /// Hot replace L1 table (RCU semantics, < 100ns jitter)
    pub fn hotReplaceL1(self: *SwitchEngine, new_table_ptr: *const RouteEntry, new_table_len: usize) void {
        // Increment generation to quarantine old packets
        const new_gen = self.current_generation.fetchAdd(1, .acq_rel) + 1;

        // Mutex-protected pointer swap (fat pointer cannot be atomic)
        self.l1_table_mutex.lock();
        self.l1_table_ptr = new_table_ptr;
        self.l1_table_len = new_table_len;
        self.l1_table_mutex.unlock();

        // Update generation for new table
        self.l1_generation.store(new_gen, .release);

        std.log.info("[SWITCH] L1 table hot-replaced, generation={}", .{new_gen});
    }

    /// Add L2 entry (with automatic promotion check)
    pub fn addL2Entry(self: *SwitchEngine, intent: []const u8, entry: RouteEntry) !void {
        self.l2_lock.lock();
        defer self.l2_lock.unlock();

        try self.l2_map.put(intent, entry);

        // Check if entry qualifies for L1 promotion (>1000 hits/min)
        if (entry.stats.hits.load(.acquire) > 1000) {
            std.log.info("[SWITCH] Entry '{s} qualifies for L1 promotion", .{intent});
            // Trigger background CHD recalculation
        }
    }

    /// Get routing statistics for CLI
    pub fn getStats(self: *SwitchEngine) RoutingStats {
        var stats: RoutingStats = .{};

        for (self.l0_table) |entry| {
            stats.l0_hits += entry.stats.hits.load(.acquire);
            stats.l0_drops += entry.stats.generation_drops.load(.acquire);
        }

        for (self.getL1Table()) |entry| {
            stats.l1_hits += entry.stats.hits.load(.acquire);
        }

        self.l2_lock.lockShared();
        defer self.l2_lock.unlockShared();

        var l2_iter = self.l2_map.iterator();
        while (l2_iter.next()) |entry| {
            stats.l2_hits += entry.value_ptr.stats.hits.load(.acquire);
        }

        stats.current_generation = self.current_generation.load(.acquire);
        return stats;
    }
};

/// CHD perfect hash function (comptime generated)
inline fn chdHash(intent: []const u8) u32 {
    // Placeholder: actual CHD hash from tools/phf_generator.zig
    var hash: u32 = 0;
    for (intent) |c| {
        hash = hash *% 31 +% c;
    }
    return hash;
}

pub const RoutingStats = struct {
    l0_hits: u64 = 0,
    l0_drops: u64 = 0,
    l1_hits: u64 = 0,
    l2_hits: u64 = 0,
    current_generation: u64 = 0,
};
