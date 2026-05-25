//! LingNet Agent OS V2.2 — Orchestrator
//! VRF/Arena lifecycle management, sanitizer thread, skill orchestration

const std = @import("std");
const gqap = @import("arena-gqap");
const mrc = @import("nullclaw-mrc");

pub const OrchestratorError = error{
    VrfLimitReached,
    ArenaPoolExhausted,
    SkillSpawnFailed,
    SanitizerThreadDead,
    InvalidVrfId,
};

/// VRF (Virtual Routing and Forwarding) instance
pub const VrfInstance = struct {
    id: u32,
    arena: gqap.Arena(.trusted),
    engine: mrc.MrcEngine,
    skill_count: std.atomic.Value(u64),
    is_active: std.atomic.Value(bool),
    gen_sequence: std.atomic.Value(u64),

    pub fn deinit(self: *VrfInstance, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        self.is_active.store(false, .release);
        _ = allocator;
    }
};

/// Orchestrator — top-level lifecycle manager
pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    vrfs: std.ArrayList(*VrfInstance),
    vrf_lock: std.atomic.Mutex,
    next_vrf_id: std.atomic.Value(u32),
    sanitizer_config: SanitizerConfig,
    sanitizer_alive: std.atomic.Value(bool),

    // Skill tracking
    active_skills: std.ArrayList([]const u8),
    skill_lock: std.atomic.Mutex,

    pub const SanitizerConfig = struct {
        target_cpu: u32 = 6,
        batch_size: u32 = 64,
        wake_interval_ms: u64 = 100,
        enable_avx2_zero: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, config: SanitizerConfig) Orchestrator {
        const vrfs = std.ArrayList(*VrfInstance).initCapacity(allocator, 16) catch unreachable;
        const active_skills = std.ArrayList([]const u8).initCapacity(allocator, 64) catch unreachable;

        return .{
            .allocator = allocator,
            .vrfs = vrfs,
            .vrf_lock = .unlocked,
            .next_vrf_id = .{ .raw = 1 },
            .sanitizer_config = config,
            .sanitizer_alive = .{ .raw = false },
            .active_skills = active_skills,
            .skill_lock = .unlocked,
        };
    }

    pub fn deinit(self: *Orchestrator) void {
        // Destroy all VRFs in reverse order
        var i = self.vrfs.items.len;
        while (i > 0) {
            i -= 1;
            const vrf = self.vrfs.orderedRemove(i);
            vrf.deinit(self.allocator);
            self.allocator.destroy(vrf);
        }
        self.vrfs.deinit(self.allocator);
        self.active_skills.deinit(self.allocator);
    }

    /// Create a new VRF instance
    pub fn createVrf(self: *Orchestrator) !*VrfInstance {
        while (!self.vrf_lock.tryLock()) {}
        defer self.vrf_lock.unlock();

        if (self.vrfs.items.len >= 256) return OrchestratorError.VrfLimitReached;

        const vrf = try self.allocator.create(VrfInstance);
        errdefer self.allocator.destroy(vrf);

        const id = self.next_vrf_id.fetchAdd(1, .monotonic);

        var cam_buf: [256]mrc.MrcCamEntry = undefined;
        var flow_buckets: [4096]mrc.MrcFlowTable.FlowBucket = undefined;

        vrf.* = .{
            .id = id,
            .arena = try gqap.Arena(.trusted).init(),
            .engine = .{
                .cam = mrc.MrcCamTable.init(&cam_buf),
                .flows = mrc.MrcFlowTable.init(&flow_buckets),
                .default_action = .forward,
                .stats = .{},
            },
            .skill_count = .{ .raw = 0 },
            .is_active = .{ .raw = true },
            .gen_sequence = .{ .raw = 1 },
        };

        try self.vrfs.append(self.allocator, vrf);
        std.log.info("[ORCH] Created VRF-{} (total: {})", .{ id, self.vrfs.items.len });
        return vrf;
    }

    /// Destroy a VRF instance (RCU semantics)
    pub fn destroyVrf(self: *Orchestrator, vrf_id: u32) void {
        while (!self.vrf_lock.tryLock()) {}
        defer self.vrf_lock.unlock();

        for (self.vrfs.items, 0..) |vrf, i| {
            if (vrf.id == vrf_id) {
                const removed = self.vrfs.orderedRemove(i);
                removed.deinit(self.allocator);
                self.allocator.destroy(removed);
                std.log.info("[ORCH] Destroyed VRF-{}", .{vrf_id});
                return;
            }
        }
    }

    /// Start the background sanitizer thread
    pub fn startSanitizer(self: *Orchestrator) !void {
        if (self.sanitizer_alive.load(.acquire)) {
            std.log.warn("[ORCH] Sanitizer already running", .{});
            return;
        }

        const config = self.sanitizer_config;
        const thread = try std.Thread.spawn(.{}, sanitizerLoop, .{ self, config });
        thread.detach();
        self.sanitizer_alive.store(true, .release);
        std.log.info("[ORCH] Sanitizer thread started (CPU={}, batch={}, interval={}ms)", .{
            config.target_cpu, config.batch_size, config.wake_interval_ms,
        });
    }

    /// Register a skill with the orchestrator
    pub fn registerSkill(self: *Orchestrator, skill_id: []const u8) !void {
        while (!self.skill_lock.tryLock()) {}
        defer self.skill_lock.unlock();

        try self.active_skills.append(self.allocator, skill_id);
        std.log.info("[ORCH] Skill registered: {s} (total: {})", .{ skill_id, self.active_skills.items.len });
    }

    /// Unregister a skill
    pub fn unregisterSkill(self: *Orchestrator, skill_id: []const u8) void {
        while (!self.skill_lock.tryLock()) {}
        defer self.skill_lock.unlock();

        for (self.active_skills.items, 0..) |sid, i| {
            if (std.mem.eql(u8, sid, skill_id)) {
                _ = self.active_skills.orderedRemove(i);
                std.log.info("[ORCH] Skill unregistered: {s}", .{skill_id});
                return;
            }
        }
    }

    /// Get orchestrator statistics
    pub fn getStats(self: *Orchestrator) OrchestratorStats {
        var stats = OrchestratorStats{};
        stats.vrf_count = self.vrfs.items.len;
        stats.skill_count = self.active_skills.items.len;
        stats.sanitizer_alive = self.sanitizer_alive.load(.acquire);

        for (self.vrfs.items) |vrf| {
            if (vrf.is_active.load(.acquire)) {
                stats.active_vrfs += 1;
            }
        }
        return stats;
    }
};

pub const OrchestratorStats = struct {
    vrf_count: usize = 0,
    active_vrfs: u32 = 0,
    skill_count: usize = 0,
    sanitizer_alive: bool = false,
};

/// Background sanitizer thread loop
fn sanitizerLoop(orch: *Orchestrator, config: Orchestrator.SanitizerConfig) callconv(.C) void {
    // TODO(M3): Implement actual AVX2 vmovntdq zero loop
    // For now: periodic wake + alive signal check
    while (orch.sanitizer_alive.load(.acquire)) {
        std.time.sleep(config.wake_interval_ms * std.time.ns_per_ms);
    }

    std.log.warn("[ORCH] Sanitizer thread exiting", .{});
    orch.sanitizer_alive.store(false, .release);
}

// ─── Tests ───────────────────────────────────────────────────────────

var g_test_pools_init: bool = false;

fn ensurePoolsInit() void {
    if (!g_test_pools_init) {
        gqap.initPools(std.heap.page_allocator, 4, 4096) catch {};
        g_test_pools_init = true;
    }
}

test "Orchestrator init/deinit" {
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();
    try std.testing.expectEqual(@as(usize, 0), orch.vrfs.items.len);
}

test "Orchestrator createVrf" {
    ensurePoolsInit();
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();

    const vrf = try orch.createVrf();
    try std.testing.expectEqual(@as(u32, 1), vrf.id);
    try std.testing.expectEqual(@as(usize, 1), orch.vrfs.items.len);
}

test "Orchestrator createMultipleVrfs" {
    ensurePoolsInit();
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();

    const v1 = try orch.createVrf();
    const v2 = try orch.createVrf();
    try std.testing.expectEqual(@as(u32, 1), v1.id);
    try std.testing.expectEqual(@as(u32, 2), v2.id);
    try std.testing.expectEqual(@as(usize, 2), orch.vrfs.items.len);
}

test "Orchestrator destroyVrf" {
    ensurePoolsInit();
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();

    const vrf = try orch.createVrf();
    orch.destroyVrf(vrf.id);
    try std.testing.expectEqual(@as(usize, 0), orch.vrfs.items.len);
}

test "Orchestrator registerSkill" {
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();

    try orch.registerSkill("test.skill");
    try std.testing.expectEqual(@as(usize, 1), orch.active_skills.items.len);
    orch.unregisterSkill("test.skill");
    try std.testing.expectEqual(@as(usize, 0), orch.active_skills.items.len);
}

test "Orchestrator getStats" {
    ensurePoolsInit();
    var orch = Orchestrator.init(std.testing.allocator, .{});
    defer orch.deinit();

    _ = try orch.createVrf();
    try orch.registerSkill("ping");
    const stats = orch.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.vrf_count);
    try std.testing.expectEqual(@as(u32, 1), stats.active_vrfs);
    try std.testing.expectEqual(@as(usize, 1), stats.skill_count);
}
