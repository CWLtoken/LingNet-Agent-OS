//! LingNet Agent OS V2.3 — HugePages 支持
//! mmap(2MB) 大页内存，减少 TLB miss

const std = @import("std");
const linux = std.os.linux;

/// HugePages 配置
pub const HugePagesConfig = struct {
    page_size: usize = 2 * 1024 * 1024, // 2MB
    page_count: usize = 16,              // 32MB total
    mount_point: []const u8 = "/dev/hugepages",
};

/// HugePages 内存区域
pub const HugePagesRegion = struct {
    ptr: [*]u8,
    size: usize,
    page_size: usize,
    page_count: usize,

    /// 分配 HugePages 内存
    pub fn init(config: HugePagesConfig) !HugePagesRegion {
        const total_size = config.page_size * config.page_count;

        // 使用 mmap + MAP_HUGETLB 分配大页
        const prot = linux.PROT{ .READ = true, .WRITE = true };
        const flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true };
        const ptr = linux.mmap(
            null,
            total_size,
            prot,
            flags,
            -1,
            0,
        );

        if (ptr == ~@as(usize, 0)) {
            const fallback = linux.mmap(
                null,
                total_size,
                prot,
                linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );
            if (fallback == ~@as(usize, 0)) return error.MmapFailed;
            return .{
                .ptr = @ptrFromInt(fallback),
                .size = total_size,
                .page_size = 4096, // 普通页
                .page_count = total_size / 4096,
            };
        }

        return .{
            .ptr = @ptrFromInt(ptr),
            .size = total_size,
            .page_size = config.page_size,
            .page_count = config.page_count,
        };
    }

    /// 释放 HugePages 内存
    pub fn deinit(self: *HugePagesRegion) void {
        _ = linux.munmap(self.ptr, self.size);
    }

    /// 获取指定页的指针
    pub fn getPage(self: *HugePagesRegion, index: usize) ?[*]u8 {
        if (index >= self.page_count) return null;
        return self.ptr + index * self.page_size;
    }

    /// 清零所有页
    pub fn zeroAll(self: *HugePagesRegion) void {
        @memset(self.ptr[0..self.size], 0);
    }

    /// 统计信息
    pub fn stats(self: *HugePagesRegion) Stats {
        return .{
            .total_size = self.size,
            .page_size = self.page_size,
            .page_count = self.page_count,
            .is_hugepage = self.page_size > 4096,
        };
    }

    pub const Stats = struct {
        total_size: usize,
        page_size: usize,
        page_count: usize,
        is_hugepage: bool,
    };
};

// ─── Tests ───────────────────────────────────────────────────────────

test "HugePagesRegion init/deinit" {
    const config = HugePagesConfig{ .page_count = 1 };
    var region = HugePagesRegion.init(config) catch |err| {
        std.log.warn("HugePages not available: {}", .{err});
        return;
    };
    defer region.deinit();

    const s = region.stats();
    try std.testing.expect(s.total_size > 0);
    try std.testing.expect(s.page_count >= 1);
}

test "HugePagesRegion getPage" {
    const config = HugePagesConfig{ .page_count = 4 };
    var region = HugePagesRegion.init(config) catch |err| {
        std.log.warn("HugePages not available: {}", .{err});
        return;
    };
    defer region.deinit();

    const page0 = region.getPage(0);
    try std.testing.expect(page0 != null);

    const page_last = region.getPage(3);
    try std.testing.expect(page_last != null);

    try std.testing.expect(region.getPage(4) == null);
}
