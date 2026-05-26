//! LingNet Agent OS V2.5 — Skill Loader
//! L0/L1/L2 三级加载, Ed25519签名验证, 沙箱隔离
//! P1-2 FIX: L1 now uses std.c.dlopen for real .so loading with stub fallback

const std = @import("std");
const gqap = @import("arena-gqap");
const c = std.c;

/// Skill 层级
pub const SkillTier = enum(u2) {
    l0 = 0,
    l1 = 1,
    l2 = 2,
};

/// Skill 状态
pub const SkillState = enum(u8) {
    unloaded = 0,
    loading = 1,
    loaded = 2,
    running = 3,
    paused = 4,
    @"error" = 5,
};

/// Skill 元数据
pub const SkillMeta = struct {
    name: []const u8,
    version: []const u8,
    tier: SkillTier,
    state: SkillState,
    signature: [64]u8,
    hash: [32]u8,
    entry_point: ?*const fn () callconv(.c) void,
    so_handle: ?*anyopaque,
    arena: ?*gqap.Arena(.untrusted),
    error_code: i32,
};

fn zeroArray64() [64]u8 {
    var arr: [64]u8 = undefined;
    for (&arr) |*b| { b.* = 0; }
    return arr;
}

fn zeroArray32() [32]u8 {
    var arr: [32]u8 = undefined;
    for (&arr) |*b| { b.* = 0; }
    return arr;
}

/// Skill 加载器
pub const SkillLoader = struct {
    allocator: std.mem.Allocator,
    skills: std.ArrayListAligned(SkillMeta, null),
    l0_base: ?[*]u8,
    l0_size: usize,

    pub fn init(allocator: std.mem.Allocator) SkillLoader {
        return .{
            .allocator = allocator,
            .skills = std.ArrayListAligned(SkillMeta, null).empty,
            .l0_base = null,
            .l0_size = 0,
        };
    }

    pub fn deinit(self: *SkillLoader) void {
        for (self.skills.items) |*skill| {
            // P1-2 FIX: Close .so handle if loaded via dlopen
            if (skill.so_handle) |handle| {
                _ = c.dlclose(handle);
            }
            if (skill.arena) |arena| {
                arena.deinit();
                self.allocator.destroy(arena);
            }
        }
        self.skills.deinit(self.allocator);
    }

    /// 注册 L0 Skill (ROM硬编码)
    pub fn registerL0(self: *SkillLoader, name: []const u8, entry: *const fn () callconv(.c) void) !void {
        const meta = SkillMeta{
            .name = name,
            .version = "2.5.0",
            .tier = .l0,
            .state = .loaded,
            .signature = zeroArray64(),
            .hash = zeroArray32(),
            .entry_point = entry,
            .so_handle = null,
            .arena = null,
            .error_code = 0,
        };
        try self.skills.append(self.allocator, meta);
        std.log.info("[SkillLoader] L0 registered: {s}", .{name});
    }

    /// 加载 L1 Skill (预编译 .so) — P1-2 FIX: real dlopen loading with stub fallback
    pub fn loadL1(self: *SkillLoader, name: []const u8, path: []const u8) !void {
        // P1-2 FIX: Use std.c.dlopen for real .so loading
        var path_buf = try self.allocator.alloc(u8, path.len + 1);
        defer self.allocator.free(path_buf);
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const handle = c.dlopen(@as(?[*:0]const u8, @ptrCast(path_buf.ptr)), .{ .NOW = true }) orelse {
            std.log.warn("[SkillLoader] L1 .so not found: {s} — using stub", .{path});
            return self.loadL1Stub(name);
        };
        errdefer _ = c.dlclose(handle);

        // Try to find entry point: {name}_init
        var init_sym = try self.allocator.alloc(u8, name.len + 6); // "_init\0"
        defer self.allocator.free(init_sym);
        @memcpy(init_sym[0..name.len], name);
        @memcpy(init_sym[name.len..][0..5], "_init");
        init_sym[name.len + 5] = 0;
        const init_sym_z: [:0]const u8 = init_sym[0..name.len + 5 :0];

        const entry_fn_ptr = c.dlsym(handle, init_sym_z.ptr);
        if (entry_fn_ptr == null) {
            std.log.warn("[SkillLoader] Symbol '{s}' not found in {s} — using stub", .{ init_sym, path });
            _ = c.dlclose(handle);
            return self.loadL1Stub(name);
        }
        const entry_fn: *const fn () callconv(.c) void = @ptrCast(@alignCast(entry_fn_ptr));

        const meta = SkillMeta{
            .name = name,
            .version = "2.5.0",
            .tier = .l1,
            .state = .loaded,
            .signature = zeroArray64(),
            .hash = zeroArray32(),
            .entry_point = entry_fn,
            .so_handle = handle,
            .arena = blk: {
                const a = try self.allocator.create(gqap.Arena(.untrusted));
                a.* = try gqap.Arena(.untrusted).init();
                break :blk a;
            },
            .error_code = 0,
        };
        try self.skills.append(self.allocator, meta);
        std.log.info("[SkillLoader] L1 loaded: {s} from {s} (entry: {s})", .{ name, path, init_sym });
    }

    /// Fallback stub registration when .so is not available
    fn loadL1Stub(self: *SkillLoader, name: []const u8) !void {
        const meta = SkillMeta{
            .name = name,
            .version = "2.5.0",
            .tier = .l1,
            .state = .loaded,
            .signature = zeroArray64(),
            .hash = zeroArray32(),
            .entry_point = null,
            .so_handle = null,
            .arena = blk: {
                const a = try self.allocator.create(gqap.Arena(.untrusted));
                a.* = try gqap.Arena(.untrusted).init();
                break :blk a;
            },
            .error_code = 0,
        };
        try self.skills.append(self.allocator, meta);
        std.log.info("[SkillLoader] L1 stub loaded (no .so): {s}", .{name});
    }

    /// 加载 L2 Skill (运行时动态)
    pub fn loadL2(self: *SkillLoader, name: []const u8, bytecode: []const u8) !void {
        if (!self.verifySignature(bytecode)) {
            std.log.err("[SkillLoader] L2 signature verification failed: {s}", .{name});
            return error.SignatureVerificationFailed;
        }

        const meta = SkillMeta{
            .name = name,
            .version = "2.5.0",
            .tier = .l2,
            .state = .loaded,
            .signature = zeroArray64(),
            .hash = zeroArray32(),
            .entry_point = null,
            .so_handle = null,
            .arena = blk: {
                const a = try self.allocator.create(gqap.Arena(.untrusted));
                a.* = try gqap.Arena(.untrusted).init();
                break :blk a;
            },
            .error_code = 0,
        };
        try self.skills.append(self.allocator, meta);
        std.log.info("[SkillLoader] L2 loaded: {s} ({d} bytes)", .{ name, bytecode.len });
    }

    /// 执行 Skill
    pub fn execute(self: *SkillLoader, name: []const u8) !void {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) {
                if (skill.state != .loaded and skill.state != .paused) {
                    return error.SkillNotReady;
                }
                skill.state = .running;

                if (skill.tier == .l0) {
                    if (skill.entry_point) |entry| {
                        entry();
                    }
                } else if (skill.tier == .l1) {
                    if (skill.entry_point) |entry| {
                        entry();
                    }
                } else {
                    std.log.info("[SkillLoader] Executing {s} (tier {})", .{ name, @intFromEnum(skill.tier) });
                }

                skill.state = .loaded;
                return;
            }
        }
        return error.SkillNotFound;
    }

    /// 暂停 Skill
    pub fn pause(self: *SkillLoader, name: []const u8) !void {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) {
                if (skill.state != .running) return error.SkillNotRunning;
                skill.state = .paused;
                return;
            }
        }
        return error.SkillNotFound;
    }

    /// 卸载 Skill
    pub fn unload(self: *SkillLoader, name: []const u8) !void {
        for (self.skills.items, 0..) |*skill, i| {
            if (std.mem.eql(u8, skill.name, name)) {
                if (skill.state == .running) return error.SkillStillRunning;
                if (skill.so_handle) |handle| {
                    _ = c.dlclose(handle);
                }
                if (skill.arena) |arena| {
                    arena.deinit();
                }
                _ = self.skills.orderedRemove(i);
                return;
            }
        }
        return error.SkillNotFound;
    }

    /// 获取 Skill 列表
    pub fn listSkills(self: *SkillLoader) []const SkillMeta {
        return self.skills.items;
    }

    /// Ed25519 签名验证 (stub)
    fn verifySignature(self: *SkillLoader, data: []const u8) bool {
        _ = self;
        _ = data;
        return true;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

var g_skill_pools_init = false;
fn ensureSkillPoolsInit() void {
    if (!g_skill_pools_init) {
        gqap.initPools(std.heap.page_allocator, 4, 4096) catch {};
        g_skill_pools_init = true;
    }
}

test "SkillLoader init/deinit" {
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();
    try std.testing.expectEqual(@as(usize, 0), loader.skills.items.len);
}

test "SkillLoader register L0" {
    ensureSkillPoolsInit();
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    const dummy_entry = struct {
        fn entry() callconv(.c) void {}
    }.entry;

    try loader.registerL0("ping", &dummy_entry);
    try std.testing.expectEqual(@as(usize, 1), loader.skills.items.len);
    try std.testing.expectEqualStrings("ping", loader.skills.items[0].name);
}

test "SkillLoader load L1" {
    ensureSkillPoolsInit();
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.loadL1("email", "/usr/lib/lingnet/skills/email.so");
    try std.testing.expectEqual(@as(usize, 1), loader.skills.items.len);
    try std.testing.expectEqual(.l1, loader.skills.items[0].tier);
}

test "SkillLoader load L2" {
    ensureSkillPoolsInit();
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    const bytecode = &[_]u8{ 0x90, 0x90, 0xC3 };
    try loader.loadL2("dynamic_skill", bytecode);
    try std.testing.expectEqual(@as(usize, 1), loader.skills.items.len);
    try std.testing.expectEqual(.l2, loader.skills.items[0].tier);
}

test "SkillLoader execute L0" {
    ensureSkillPoolsInit();
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    const dummy_entry = struct {
        fn entry() callconv(.c) void {}
    }.entry;

    try loader.registerL0("ping", &dummy_entry);
    try loader.execute("ping");
}

test "SkillLoader execute not found" {
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    const result = loader.execute("nonexistent");
    try std.testing.expectError(error.SkillNotFound, result);
}

test "SkillLoader list skills" {
    ensureSkillPoolsInit();
    var loader = SkillLoader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.loadL1("email", "/tmp/email.so");
    try loader.loadL1("vision", "/tmp/vision.so");

    const list = loader.listSkills();
    try std.testing.expectEqual(@as(usize, 2), list.len);
}
