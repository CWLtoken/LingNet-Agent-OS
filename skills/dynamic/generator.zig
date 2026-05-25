//! LingNet Agent OS V2.7 — Agent Self-Generating Skill Framework
//! Skills can be generated at runtime by the agent itself

const std = @import("std");
const gqap = @import("arena-gqap");

/// Skill generation template
pub const SkillTemplate = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8 = "2.7.0",
    tier: SkillTier = .l2,
    permissions: []const Permission = &[_]Permission{},
    entry_code: []const u8 = "",
    max_memory: usize = 65536,
    timeout_ms: u64 = 5000,

    pub const SkillTier = enum(u8) { l0 = 0, l1 = 1, l2 = 2 };
    pub const Permission = enum { file_read, file_write, net_connect, net_listen, exec, sensor };
};

/// Generated skill metadata
pub const GeneratedSkill = struct {
    name: []const u8,
    bytecode: []const u8,
    hash: [32]u8,
    created_at: i64,
    arena: *gqap.Arena(.untrusted),

    pub fn deinit(self: *GeneratedSkill, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.free(self.bytecode);
        allocator.free(self.name);
    }
};

/// Skill generator — creates new skills from templates
pub const SkillGenerator = struct {
    allocator: std.mem.Allocator,
    generated: std.ArrayListAligned(GeneratedSkill, null),

    pub fn init(allocator: std.mem.Allocator) SkillGenerator {
        return .{
            .allocator = allocator,
            .generated = std.ArrayListAligned(GeneratedSkill, null).empty,
        };
    }

    pub fn deinit(self: *SkillGenerator) void {
        for (self.generated.items) |*skill| {
            skill.deinit(self.allocator);
        }
        self.generated.deinit(self.allocator);
    }

    /// Generate a new skill from template
    pub fn generate(self: *SkillGenerator, template: SkillTemplate) !*GeneratedSkill {
        // Create untrusted arena for this skill
        const arena = try self.allocator.create(gqap.Arena(.untrusted));
        arena.* = try gqap.Arena(.untrusted).init();

        // Generate bytecode (simplified: just a stub)
        const bytecode = try self.generateBytecode(template);

        // Compute hash (simplified: use wyhash)
        const h = std.hash.Wyhash.hash(0, bytecode);
        var hash: [32]u8 = undefined;
        for (&hash, 0..) |*b, i| {
            b.* = @as(u8, @truncate(h >> @as(u6, @intCast(i % 8)) * 8));
        }

        const skill = GeneratedSkill{
            .name = try self.allocator.dupe(u8, template.name),
            .bytecode = bytecode,
            .hash = hash,
            .created_at = 0,
            .arena = arena,
        };

        try self.generated.append(self.allocator, skill);
        std.log.info("[SkillGen] Generated skill: {s} ({d} bytes)", .{ template.name, bytecode.len });
        return &self.generated.items[self.generated.items.len - 1];
    }

    /// Generate bytecode from template (simplified)
    fn generateBytecode(self: *SkillGenerator, template: SkillTemplate) ![]const u8 {
        _ = self;
        _ = template;
        // Simplified: return a stub that logs and returns
        return &[_]u8{ 0x90, 0x90, 0xC3 };
    }

    /// List generated skills
    pub fn listGenerated(self: *SkillGenerator) []const GeneratedSkill {
        return self.generated.items;
    }

    /// Remove a generated skill
    pub fn remove(self: *SkillGenerator, name: []const u8) !void {
        for (self.generated.items, 0..) |*skill, i| {
            if (std.mem.eql(u8, skill.name, name)) {
                skill.deinit(self.allocator);
                _ = self.generated.orderedRemove(i);
                return;
            }
        }
        return error.SkillNotFound;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

var g_gen_pools_init = false;
fn ensureGenPoolsInit() void {
    if (!g_gen_pools_init) {
        gqap.initPools(std.heap.page_allocator, 4, 4096) catch {};
        g_gen_pools_init = true;
    }
}

test "SkillGenerator init/deinit" {
    ensureGenPoolsInit();
    var gen = SkillGenerator.init(std.testing.allocator);
    defer gen.deinit();
    try std.testing.expectEqual(@as(usize, 0), gen.generated.items.len);
}

test "SkillGenerator generate" {
    ensureGenPoolsInit();
    var gen = SkillGenerator.init(std.testing.allocator);
    defer gen.deinit();

    const template = SkillTemplate{
        .name = "auto_skill_1",
        .description = "Auto-generated test skill",
    };

    const skill = try gen.generate(template);
    try std.testing.expectEqualStrings("auto_skill_1", skill.name);
    try std.testing.expect(skill.bytecode.len > 0);
}

test "SkillGenerator list and remove" {
    ensureGenPoolsInit();
    var gen = SkillGenerator.init(std.testing.allocator);
    defer gen.deinit();

    const t1 = SkillTemplate{ .name = "skill_a", .description = "A" };
    const t2 = SkillTemplate{ .name = "skill_b", .description = "B" };

    _ = try gen.generate(t1);
    _ = try gen.generate(t2);

    try std.testing.expectEqual(@as(usize, 2), gen.generated.items.len);

    try gen.remove("skill_a");
    try std.testing.expectEqual(@as(usize, 1), gen.generated.items.len);
    try std.testing.expectEqualStrings("skill_b", gen.generated.items[0].name);
}
