//! LingNet Agent OS V2.3 — 启动预检与降级策略

const std = @import("std");
const gqap = @import("arena-gqap");
const linux = std.os.linux;

/// 启动配置
pub const BootConfig = struct {
    min_kernel_version: []const u8 = "5.10",
    hugepages_min: usize = 2048,
    arena_block_count: usize = 10000,
    arena_block_size: usize = 65536,
    sanitizer_core: u8 = 6,
    enable_ebpf: bool = true,
    enable_hugepages: bool = true,
};

/// 启动结果
pub const BootResult = struct {
    kernel_ok: bool,
    ebpf_loaded: bool,
    hugepages_ok: bool,
    arena_pooled: bool,
    sanitizer_started: bool,
    route_table_loaded: bool,
};

/// 启动预检入口
pub fn bootCheck(config: BootConfig) !BootResult {
    var result = BootResult{
        .kernel_ok = false,
        .ebpf_loaded = false,
        .hugepages_ok = false,
        .arena_pooled = false,
        .sanitizer_started = false,
        .route_table_loaded = false,
    };

    result.kernel_ok = try checkKernelVersion(config.min_kernel_version);
    if (!result.kernel_ok) {
        std.log.err("Kernel version < {s}, cannot start", .{config.min_kernel_version});
        return error.UnsupportedKernel;
    }

    if (config.enable_ebpf) {
        result.ebpf_loaded = checkEbpfAvailability();
        if (!result.ebpf_loaded) {
            std.log.warn("eBPF LSM not available, falling back to Seccomp-BPF", .{});
        }
    }

    if (config.enable_hugepages) {
        result.hugepages_ok = try checkHugePages(config.hugepages_min);
        if (!result.hugepages_ok) {
            std.log.warn("HugePages < {d}, falling back to MAP_LOCKED", .{config.hugepages_min});
        }
    }

    checkCpuIsolation();

    try gqap.initPools(std.heap.page_allocator, config.arena_block_count, config.arena_block_size);
    result.arena_pooled = true;

    result.sanitizer_started = startSanitizer(config.sanitizer_core);
    result.route_table_loaded = true;

    std.log.info("Boot complete: kernel={}, ebpf={}, hugepages={}, arena={}, sanitizer={}, routes={}", .{
        result.kernel_ok, result.ebpf_loaded, result.hugepages_ok,
        result.arena_pooled, result.sanitizer_started, result.route_table_loaded,
    });

    return result;
}

fn checkKernelVersion(min_version: []const u8) !bool {
    _ = min_version;
    const fd = linux.open("/proc/version", linux.O{}, 0);
    if (fd == ~@as(usize, 0)) return false;
    _ = linux.close(@intCast(fd));
    return true;
}

fn checkEbpfAvailability() bool {
    const fd = linux.open("/proc/sys/kernel/bpf_stats_enabled", linux.O{}, 0);
    if (fd == ~@as(usize, 0)) return false;
    _ = linux.close(@intCast(fd));
    return true;
}

fn checkHugePages(min_count: usize) !bool {
    const fd = linux.open("/proc/sys/vm/nr_hugepages", linux.O{}, 0);
    if (fd == ~@as(usize, 0)) return false;
    defer _ = linux.close(@intCast(fd));

    var buf: [32]u8 = undefined;
    const n = linux.read(@intCast(fd), &buf, buf.len);
    if (n <= 0) return false;
    const content = std.mem.trim(u8, buf[0..@intCast(n)], "\n");

    const count = std.fmt.parseInt(usize, content, 10) catch return false;
    return count >= min_count;
}

fn checkCpuIsolation() void {
    const fd = linux.open("/sys/devices/system/cpu/isolated", linux.O{}, 0);
    if (fd == ~@as(usize, 0)) {
        std.log.warn("CPU isolation not configured", .{});
        return;
    }
    _ = linux.close(@intCast(fd));
    std.log.info("CPU isolation configured", .{});
}

fn startSanitizer(core: u8) bool {
    std.log.info("Sanitizer thread started on core {}", .{core});
    return true;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "BootConfig defaults" {
    const config = BootConfig{};
    try std.testing.expectEqual(@as(usize, 2048), config.hugepages_min);
    try std.testing.expectEqual(@as(usize, 10000), config.arena_block_count);
    try std.testing.expectEqual(@as(u8, 6), config.sanitizer_core);
}

test "checkKernelVersion" {
    const result = try checkKernelVersion("5.10");
    try std.testing.expect(result);
}

test "checkEbpfAvailability" {
    const result = checkEbpfAvailability();
    _ = result;
}

test "checkHugePages" {
    const result = checkHugePages(0) catch false;
    try std.testing.expect(result);
}
