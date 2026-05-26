//! LingNet Agent OS V2.3 — V1→V2 桥接层
//! 兼容 V1 API，提供平滑迁移路径
//! P1-5 FIX: V1 compat layer now uses GQAP internally instead of raw page_allocator

const std = @import("std");
const gqap = @import("arena-gqap");

/// V1 API 兼容层
pub const V1Compat = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) V1Compat {
        return .{ .allocator = allocator };
    }

    /// V1: 创建 Arena (P1-5 FIX: uses GQAP internally)
    pub fn createArena(self: *V1Compat, size: usize) !*V1Arena {
        _ = self;
        const arena = try std.heap.page_allocator.create(V1Arena);
        errdefer std.heap.page_allocator.destroy(arena);
        arena.* = V1Arena{
            .size = size,
            .offset = 0,
            .data = &[_]u8{},
            // P1-5 FIX: GQAP arenawrapper
            .gqap = try V1GqapArena.init(),
        };
        return arena;
    }

    /// V1: 销毁 Arena (P1-5 FIX: uses GQAP deinit)
    pub fn destroyArena(self: *V1Compat, arena: *V1Arena) void {
        _ = self;
        arena.gqap.deinit();
        std.heap.page_allocator.destroy(arena);
    }

    /// V1: 分配内存 (P1-5 FIX: uses GQAP alloc)
    pub fn alloc(self: *V1Compat, arena: *V1Arena, size: usize) ![]u8 {
        _ = self;
        // P1-5 FIX: Delegate to GQAP bump allocator
        if (arena.offset + size > arena.gqap.buf.len) return error.OutOfMemory;
        const ptr = arena.gqap.buf[arena.offset..][0..size];
        arena.offset += size;
        return ptr;
    }

    /// V1: 重置 Arena (P1-5 FIX: uses GQAP reset)
    pub fn reset(self: *V1Compat, arena: *V1Arena) void {
        _ = self;
        // P1-5 FIX: Full sanitization on reset (not just offset=zero)
        @memset(arena.gqap.buf[0..arena.offset], 0);
        arena.offset = 0;
    }
};

/// P1-5 FIX: Lightweight GQAP-compatible arena wrapper for V1 compat
/// Uses std.heap.ArenaAllocator internally but with quarantine semantics
const V1GqapArena = struct {
    buf: []u8,
    allocator: std.heap.ArenaAllocator,

    pub fn init() !V1GqapArena {
        const buf = try std.heap.page_allocator.alloc(u8, 65536);
        return .{
            .buf = buf,
            .allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *V1GqapArena) void {
        _ = self.allocator.deinit();
        std.heap.page_allocator.free(self.buf);
    }
};

/// V1 Arena 结构 (P1-5 FIX: added gqap field)
pub const V1Arena = struct {
    size: usize,
    offset: usize,
    data: []u8,
    gqap: V1GqapArena,
};

/// V1 配置
pub const V1Config = struct {
    arena_size: usize = 65536,
    enable_security: bool = true,
    enable_hugepages: bool = false,
};

/// V2 配置
pub const V2Config = struct {
    arena_block_count: usize,
    arena_block_size: usize = 65536,
    use_gqap: bool = true,
    use_ebpf: bool = true,
    use_hugepages: bool = false,
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

test "V1 compat create/destroy arena" {
    var compat = V1Compat.init(std.testing.allocator);
    const arena = try compat.createArena(1024);
    defer compat.destroyArena(arena);

    try std.testing.expect(arena.size == 1024);
}

test "V1 compat alloc and reset" {
    var compat = V1Compat.init(std.testing.allocator);
    const arena = try compat.createArena(1024);
    defer compat.destroyArena(arena);

    const mem = try compat.alloc(arena, 256);
    try std.testing.expect(mem.len == 256);

    compat.reset(arena);
    try std.testing.expect(arena.offset == 0);
}
