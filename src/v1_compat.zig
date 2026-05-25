//! LingNet Agent OS V2.3 — V1→V2 桥接层
//! 兼容 V1 API，提供平滑迁移路径

const std = @import("std");
const gqap = @import("arena-gqap");

/// V1 API 兼容层
pub const V1Compat = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) V1Compat {
        return .{ .allocator = allocator };
    }

    /// V1: 创建 Arena (映射到 V2 GQAP)
    pub fn createArena(self: *V1Compat, size: usize) !*V1Arena {
        _ = self;
        const arena = try std.heap.page_allocator.create(V1Arena);
        arena.* = V1Arena{
            .size = size,
            .offset = 0,
            .data = try std.heap.page_allocator.alloc(u8, size),
        };
        return arena;
    }

    /// V1: 销毁 Arena
    pub fn destroyArena(self: *V1Compat, arena: *V1Arena) void {
        _ = self;
        std.heap.page_allocator.free(arena.data);
        std.heap.page_allocator.destroy(arena);
    }

    /// V1: 分配内存
    pub fn alloc(self: *V1Compat, arena: *V1Arena, size: usize) ![]u8 {
        _ = self;
        if (arena.offset + size > arena.size) return error.OutOfMemory;
        const ptr = arena.data[arena.offset..][0..size];
        arena.offset += size;
        return ptr;
    }

    /// V1: 重置 Arena
    pub fn reset(self: *V1Compat, arena: *V1Arena) void {
        _ = self;
        arena.offset = 0;
    }
};

/// V1 Arena 结构
pub const V1Arena = struct {
    size: usize,
    offset: usize,
    data: []u8,
};

/// V1→V2 迁移辅助
pub const MigrationHelper = struct {
    /// 将 V1 配置转换为 V2 配置
    pub fn convertConfig(v1_config: V1Config) V2Config {
        return .{
            .arena_block_count = v1_config.arena_size / 65536,
            .arena_block_size = 65536,
            .use_gqap = true,
            .use_ebpf = v1_config.enable_security,
            .use_hugepages = v1_config.enable_hugepages,
        };
    }
};

/// V1 配置
pub const V1Config = struct {
    arena_size: usize = 1024 * 1024,
    enable_security: bool = true,
    enable_hugepages: bool = false,
    max_routes: usize = 256,
};

/// V2 配置
pub const V2Config = struct {
    arena_block_count: usize = 16,
    arena_block_size: usize = 65536,
    use_gqap: bool = true,
    use_ebpf: bool = true,
    use_hugepages: bool = false,
};

// ─── Tests ───────────────────────────────────────────────────────────

test "V1Compat createArena/destroyArena" {
    var compat = V1Compat.init(std.testing.allocator);
    const arena = try compat.createArena(4096);
    defer compat.destroyArena(arena);

    try std.testing.expectEqual(@as(usize, 4096), arena.size);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "V1Compat alloc/reset" {
    var compat = V1Compat.init(std.testing.allocator);
    const arena = try compat.createArena(4096);
    defer compat.destroyArena(arena);

    const buf = try compat.alloc(arena, 256);
    try std.testing.expectEqual(@as(usize, 256), buf.len);
    try std.testing.expectEqual(@as(usize, 256), arena.offset);

    compat.reset(arena);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "MigrationHelper convertConfig" {
    const v1 = V1Config{
        .arena_size = 1024 * 1024,
        .enable_security = true,
        .enable_hugepages = true,
    };

    const v2 = MigrationHelper.convertConfig(v1);

    try std.testing.expectEqual(@as(usize, 16), v2.arena_block_count);
    try std.testing.expectEqual(@as(usize, 65536), v2.arena_block_size);
    try std.testing.expect(v2.use_gqap);
    try std.testing.expect(v2.use_ebpf);
    try std.testing.expect(v2.use_hugepages);
}
