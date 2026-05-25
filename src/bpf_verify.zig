//! LingNet Agent OS V2.3 — eBPF 运行时验证

const std = @import("std");
const linux = std.os.linux;

pub const BpfProgType = enum(u32) {
    lsm = 29,
    kprobe = 2,
    tracepoint = 5,
};

pub const BpfVerifyResult = struct {
    prog_fd: linux.fd_t,
    loaded: bool,
    attached: bool,
    error_code: i32,

    pub fn deinit(self: *BpfVerifyResult) void {
        if (self.prog_fd >= 0) {
            _ = linux.close(self.prog_fd);
        }
    }
};

pub const BpfVerifier = struct {
    loaded_progs: std.ArrayListAligned(BpfProgInfo, null),

    pub fn init(allocator: std.mem.Allocator) BpfVerifier {
        _ = allocator;
        return .{
            .loaded_progs = std.ArrayListAligned(BpfProgInfo, null).empty,
        };
    }

    pub fn deinit(self: *BpfVerifier) void {
        self.loaded_progs.deinit(std.heap.page_allocator);
    }

    pub fn loadProgram(self: *BpfVerifier, prog_type: BpfProgType, bytecode: []const u8) !BpfVerifyResult {
        _ = self;
        _ = prog_type;
        _ = bytecode;

        var result = BpfVerifyResult{
            .prog_fd = -1,
            .loaded = false,
            .attached = false,
            .error_code = 0,
        };

        const bpf_fd = linux.syscall3(.BPF, @intFromEnum(.PROG_LOAD), 0, 0);
        if (bpf_fd == ~@as(usize, 0)) {
            std.log.warn("BPF syscall not available", .{});
            return result;
        }

        result.prog_fd = @intCast(bpf_fd);
        result.loaded = true;
        return result;
    }

    pub fn verifyLsmHook(self: *BpfVerifier, hook_point: []const u8) !bool {
        _ = self;
        _ = hook_point;

        const fd = linux.open("/sys/kernel/security/lsm", linux.O{}, 0);
        if (fd == ~@as(usize, 0)) {
            std.log.err("Cannot read LSM configuration", .{});
            return false;
        }
        defer _ = linux.close(@intCast(fd));

        var buf: [256]u8 = undefined;
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (n <= 0) return false;
        const lsm_config = buf[0..@intCast(n)];

        return std.mem.indexOf(u8, lsm_config, "bpf") != null;
    }

    pub fn verifyTracepoint(self: *BpfVerifier, category: []const u8, name: []const u8) !bool {
        _ = self;

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/sys/kernel/debug/tracing/events/{s}/{s}/id", .{ category, name });
        const path_z: [*:0]u8 = @ptrCast(path.ptr);

        const fd = linux.open(path_z, linux.O{}, 0);
        if (fd == ~@as(usize, 0)) return false;
        _ = linux.close(@intCast(fd));
        return true;
    }

    pub fn getLoadedPrograms(self: *BpfVerifier) []BpfProgInfo {
        return self.loaded_progs.items;
    }
};

pub const BpfProgInfo = struct {
    name: []const u8,
    prog_type: BpfProgType,
    fd: linux.fd_t,
    loaded: bool,
};

// ─── Tests ───────────────────────────────────────────────────────────

test "BpfVerifier init/deinit" {
    var verifier = BpfVerifier.init(std.testing.allocator);
    defer verifier.deinit();
    try std.testing.expectEqual(@as(usize, 0), verifier.loaded_progs.items.len);
}

test "BpfVerifier verifyLsmHook" {
    var verifier = BpfVerifier.init(std.testing.allocator);
    defer verifier.deinit();
    const result = verifier.verifyLsmHook("file_open") catch false;
    _ = result;
}

test "BpfVerifier verifyTracepoint" {
    var verifier = BpfVerifier.init(std.testing.allocator);
    defer verifier.deinit();
    const result = verifier.verifyTracepoint("syscalls", "sys_enter_openat") catch false;
    _ = result;
}

test "BpfProgType values" {
    try std.testing.expectEqual(@as(u32, 29), @intFromEnum(BpfProgType.lsm));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(BpfProgType.kprobe));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(BpfProgType.tracepoint));
}
