//! LingNet Agent OS V2.2 — Sandbox Policy
//! eBPF-seccomp hybrid sandbox with capability-based access control
//!
//! H5 FIX: Real Seccomp-BPF via linux.seccomp (Zig 0.17 API) + Landlock

const std = @import("std");
const gqap = @import("arena-gqap");
const linux = std.os.linux;
const seccomp_ns = std.os.linux.SECCOMP;

// Zig 0.17 std doesn't expose landlock types — define manually from linux/landlock.h
const LandlockRulesetAttr = extern struct {
    handled_access_fs: u64,
    handled_access_net: u64,
    scoped: u64,
};

pub const SandboxError = error{
    SeccompInstallFailed,
    LandlockNotSupported,
    PermissionDenied,
    InvalidPolicy,
};

/// Sandbox policy level
pub const SandboxLevel = enum(u8) {
    none = 0,
    seccomp = 1,
    landlock = 2,
    full = 3,
};

/// Capability request for skill sandboxing
pub const Capability = enum(u8) {
    file_read,
    file_write,
    net_connect,
    net_listen,
    spawn_process,
    load_module,
    system_info,
    signal_send,
};

/// Sandbox policy configuration
pub const SandboxPolicy = struct {
    level: SandboxLevel = .full,
    max_memory_bytes: usize = 64 * 1024 * 1024,
    max_file_handles: u32 = 16,
    max_threads: u32 = 4,
    allowed_paths: []const []const u8 = &.{},
    blocked_syscalls: []const u32 = &.{},

    pub fn validate(self: *const SandboxPolicy) !void {
        if (self.max_memory_bytes == 0) return SandboxError.InvalidPolicy;
        if (self.max_file_handles > 256) return SandboxError.InvalidPolicy;
    }
};

/// Sandbox instance for a running skill
pub const SandboxInstance = struct {
    policy: SandboxPolicy,
    seccomp_fd: i32 = -1,
    landlock_fd: i32 = -1,
    arena: *gqap.Arena(.untrusted),

    pub fn init(policy: SandboxPolicy, arena: *gqap.Arena(.untrusted)) !SandboxInstance {
        try policy.validate();
        var inst = SandboxInstance{ .policy = policy, .arena = arena };

        if (@intFromEnum(policy.level) >= @intFromEnum(SandboxLevel.seccomp)) {
            inst.seccomp_fd = try installSeccompFilter(&policy);
        }
        if (@intFromEnum(policy.level) >= @intFromEnum(SandboxLevel.landlock)) {
            inst.landlock_fd = try installLandlockRules(&policy);
        }
        return inst;
    }

    pub fn deinit(self: *SandboxInstance) void {
        if (self.seccomp_fd >= 0) _ = linux.close(@intCast(self.seccomp_fd));
        if (self.landlock_fd >= 0) _ = linux.close(@intCast(self.landlock_fd));
    }

    pub fn checkCapability(self: *const SandboxInstance, cap: Capability, path: []const u8) !void {
        switch (cap) {
            .file_read => {
                if (self.policy.level == .none) return;
                try self.checkPathAccess(path, false);
            },
            .file_write => {
                if (@intFromEnum(self.policy.level) < @intFromEnum(SandboxLevel.landlock)) return;
                try self.checkPathAccess(path, true);
            },
            .net_connect, .net_listen => {
                if (@intFromEnum(self.policy.level) < @intFromEnum(SandboxLevel.seccomp)) return;
            },
            .spawn_process => {
                if (@intFromEnum(self.policy.level) < @intFromEnum(SandboxLevel.seccomp)) return SandboxError.PermissionDenied;
            },
            .load_module, .signal_send => return SandboxError.PermissionDenied,
            .system_info => {
                if (@intFromEnum(self.policy.level) < @intFromEnum(SandboxLevel.seccomp)) return;
            },
        }
    }

    fn checkPathAccess(self: *const SandboxInstance, path: []const u8, write: bool) !void {
        _ = write;
        for (self.policy.allowed_paths) |allowed| {
            if (std.mem.startsWith(u8, path, allowed)) return;
        }
        std.log.warn("[SANDBOX] Blocked path access: {s}", .{path});
        return SandboxError.PermissionDenied;
    }
};

// ─── Real Seccomp-BPF via Zig 0.17 linux.seccomp API ────────────────

/// BPF instruction encoding for classic BPF (seccomp filter).
/// Zig 0.17 removed sock_filter/sock_fprog — we encode instructions manually.
const BpfInsn = packed struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

fn bpf_insn(code: u16, jt: u8, jf: u8, k: u32) BpfInsn {
    return BpfInsn{ .code = code, .jt = jt, .jf = jf, .k = k };
}

/// Install a real Seccomp-BPF filter using the Zig 0.17 linux.seccomp API.
fn installSeccompFilter(policy: *const SandboxPolicy) !i32 {
    _ = policy;

    // Step 1: PR_SET_NO_NEW_PRIVS via prctl
    // prctl takes (i32, usize, usize, usize, usize)
    const pr_ret = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (pr_ret != 0) {
        std.log.warn("[sandbox] PR_SET_NO_NEW_PRIVS returned {d}", .{@as(isize, @bitCast(pr_ret))});
    }

    // Step 2: Build BPF filter whitelisting safe syscalls
    const filter = buildBpfFilter();

    // Step 3: Install via linux.seccomp(SET_MODE_FILTER, ...)
    // The args parameter is a pointer to sock_fprog { len, *filter }
    const prog = ProgProg{
        .len = @intCast(filter.len),
        .filter = &filter[0],
    };

    const rc = linux.seccomp(@as(u32, seccomp_ns.SET_MODE_FILTER), @as(u32, seccomp_ns.FILTER_FLAG.TSYNC), &prog);
    // Returns 0 on success, ~0 (max usize) with errno on failure
    if (rc != 0) {
        std.log.err("[sandbox] seccomp SET_MODE_FILTER failed: rc={d}", .{@as(isize, @bitCast(rc))});
        return SandboxError.SeccompInstallFailed;
    }

    std.log.info("[sandbox] Seccomp-BPF installed ({d} rules)", .{@as(u32, @intCast(filter.len))});
    return 0; // success marker
}

const ProgProg = extern struct {
    len: c_ushort,
    filter: *const BpfInsn,
};

/// Build a BPF filter that whitelists safe syscalls.
/// BPF instruction opcodes (from linux/filter.h):
///   BPF_LD | BPF_W | BPF_ABS = 0x20  (load word from absolute offset)
///   BPF_JMP | BPF_JEQ | BPF_K = 0x15 (jump if equal to constant)
///   BPF_RET | BPF_K = 0x06            (return constant)
fn buildBpfFilter() []const BpfInsn {
    const ALLOW: u32 = @as(u32, seccomp_ns.RET.ALLOW);
    const KILL: u32 = @as(u32, seccomp_ns.RET.KILL_PROCESS);

    // SECCOMP_DATA_ARCH offset: check AUDIT_ARCH_X86_64
    const filter = [_]BpfInsn{
        bpf_insn(0x20, 0, 0, 4),                   // load arch (offsetof data.arch)
        bpf_insn(0x15, 0, 1, 0xC000003E),           // if arch != AUDIT_ARCH_X86_64 → KILL
        bpf_insn(0x06, 0, 0, KILL),                 // return KILL_PROCESS
        bpf_insn(0x20, 0, 0, 0),                    // load syscall number
        // Whitelist: read(0), write(1), close(3), exit(60), exit_group(231),
        // mmap(9), munmap(11), brk(12), rt_sigreturn(15), futex(202),
        // clock_gettime(228), clock_nanosleep(230)
        bpf_insn(0x15, 11, 0, 0),                   // if 0 → allow
        bpf_insn(0x15, 10, 0, 1),                   // if 1 → allow
        bpf_insn(0x15, 9, 0, 3),                    // if 3 → allow
        bpf_insn(0x15, 8, 0, 60),                   // if 60 → allow
        bpf_insn(0x15, 7, 0, 231),                  // if 231 → allow
        bpf_insn(0x15, 6, 0, 9),                    // if 9 → allow
        bpf_insn(0x15, 5, 0, 11),                   // if 11 → allow
        bpf_insn(0x15, 4, 0, 12),                   // if 12 → allow
        bpf_insn(0x15, 3, 0, 15),                   // if 15 → allow
        bpf_insn(0x15, 2, 0, 202),                  // if 202 → allow
        bpf_insn(0x15, 1, 0, 228),                  // if 228 → allow
        bpf_insn(0x15, 0, 1, 230),                  // if 230 → allow, else KILL
        bpf_insn(0x06, 0, 0, KILL),                 // return KILL_PROCESS
        bpf_insn(0x06, 0, 0, ALLOW),                // return ALLOW
    };
    return &filter;
}

// ─── Landlock via Zig 0.17 ──────────────────────────────────────────

/// Install Landlock filesystem sandbox via raw LANDLOCK syscalls.
fn installLandlockRules(policy: *const SandboxPolicy) !i32 {
    _ = policy;

    var ruleset_attr = LandlockRulesetAttr{ .handled_access_fs = 0x1FFF, .handled_access_net = 0, .scoped = 0 };
    const ruleset_fd = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&ruleset_attr), @sizeOf(LandlockRulesetAttr), 0);
    if (ruleset_fd == ~@as(usize, 0) or @as(isize, @bitCast(ruleset_fd)) == -38) {
        std.log.warn("[sandbox] Landlock not available on this kernel", .{});
        return SandboxError.LandlockNotSupported;
    }
    if (@as(isize, @bitCast(ruleset_fd)) < 0) {
        std.log.warn("[sandbox] landlock_create_ruleset failed: {d}", .{@as(isize, @bitCast(ruleset_fd))});
        return SandboxError.LandlockNotSupported;
    }

    const fd: linux.fd_t = @intCast(ruleset_fd);
    const restrict_ret = linux.syscall2(.landlock_restrict_self, @as(u32, @bitCast(fd)), 0);
    _ = linux.close(fd);

    if (restrict_ret != 0) {
        std.log.warn("[sandbox] landlock_restrict_self failed: {d}", .{@as(isize, @bitCast(restrict_ret))});
        return SandboxError.LandlockNotSupported;
    }

    std.log.info("[sandbox] Landlock sandbox installed", .{});
    return 0;
}

/// Detect available sandbox capabilities at runtime
pub fn detectCapabilities() CapabilitySet {
    var caps = CapabilitySet{};

    const seccomp_ret = linux.seccomp(@as(u32, seccomp_ns.SET_MODE_STRICT), 0, null);
    caps.seccomp_available = seccomp_ret == 0;

    // Use module-level LandlockRulesetAttr
    var ll_attr = LandlockRulesetAttr{ .handled_access_fs = 0x1FFF, .handled_access_net = 0, .scoped = 0 };
    const ll_ret = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&ll_attr), @sizeOf(LandlockRulesetAttr), 0);
    caps.landlock_available = @as(isize, @bitCast(ll_ret)) != -38;

    const lsm_fd = linux.open("/sys/kernel/security/lsm", linux.O{ .ACCMODE = .RDONLY }, 0);
    if (lsm_fd != ~@as(usize, 0)) {
        var buf: [256]u8 = undefined;
        const n = linux.read(@intCast(lsm_fd), &buf, buf.len);
        if (n > 0) caps.ebpf_lsm_available = std.mem.indexOf(u8, buf[0..@intCast(n)], "bpf") != null;
        _ = linux.close(@intCast(lsm_fd));
    }

    return caps;
}

pub const CapabilitySet = struct {
    seccomp_available: bool = false,
    landlock_available: bool = false,
    ebpf_lsm_available: bool = false,

    pub fn recommendLevel(self: CapabilitySet) SandboxLevel {
        if (self.ebpf_lsm_available and self.landlock_available and self.seccomp_available) return .full;
        if (self.landlock_available and self.seccomp_available) return .landlock;
        if (self.seccomp_available) return .seccomp;
        return .none;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "SandboxPolicy validate" {
    var policy = SandboxPolicy{};
    policy.max_memory_bytes = 1024 * 1024;
    try policy.validate();

    policy.max_memory_bytes = 0;
    try std.testing.expectError(SandboxError.InvalidPolicy, policy.validate());
}

test "SandboxPolicy validate too many handles" {
    var policy = SandboxPolicy{};
    policy.max_memory_bytes = 1024;
    policy.max_file_handles = 512;
    try std.testing.expectError(SandboxError.InvalidPolicy, policy.validate());
}

test "CapabilitySet recommendLevel" {
    var caps = CapabilitySet{};
    try std.testing.expectEqual(SandboxLevel.none, caps.recommendLevel());

    caps.seccomp_available = true;
    try std.testing.expectEqual(SandboxLevel.seccomp, caps.recommendLevel());

    caps.landlock_available = true;
    try std.testing.expectEqual(SandboxLevel.landlock, caps.recommendLevel());

    caps.ebpf_lsm_available = true;
    try std.testing.expectEqual(SandboxLevel.full, caps.recommendLevel());
}

var g_pools_initialized = false;

test "SandboxInstance init/deinit (none level)" {
    if (!g_pools_initialized) {
        try gqap.initPools(std.heap.page_allocator, 4, 4096);
        g_pools_initialized = true;
    }
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    var inst = try SandboxInstance.init(.{ .level = .none, .max_memory_bytes = 1024 }, &arena);
    inst.deinit();
}

test "checkCapability signal_send always blocked" {
    if (!g_pools_initialized) {
        try gqap.initPools(std.heap.page_allocator, 4, 4096);
        g_pools_initialized = true;
    }
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    var inst = try SandboxInstance.init(.{ .level = .full, .max_memory_bytes = 1024 }, &arena);
    defer inst.deinit();

    try std.testing.expectError(SandboxError.PermissionDenied, inst.checkCapability(.signal_send, ""));
}

test "checkCapability load_module always blocked" {
    if (!g_pools_initialized) {
        try gqap.initPools(std.heap.page_allocator, 4, 4096);
        g_pools_initialized = true;
    }
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    var inst = try SandboxInstance.init(.{ .level = .full, .max_memory_bytes = 1024 }, &arena);
    defer inst.deinit();

    try std.testing.expectError(SandboxError.PermissionDenied, inst.checkCapability(.load_module, ""));
}

test "checkCapability file_read with allowed path" {
    if (!g_pools_initialized) {
        try gqap.initPools(std.heap.page_allocator, 4, 4096);
        g_pools_initialized = true;
    }
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    var inst = try SandboxInstance.init(.{
        .level = .full,
        .max_memory_bytes = 1024,
        .allowed_paths = &.{"skills/", "/tmp/lingnet/"},
    }, &arena);
    defer inst.deinit();

    try inst.checkCapability(.file_read, "skills/test/handler.zig");
}

test "checkCapability file_read blocked path" {
    if (!g_pools_initialized) {
        try gqap.initPools(std.heap.page_allocator, 4, 4096);
        g_pools_initialized = true;
    }
    var arena = try gqap.Arena(.untrusted).init();
    defer arena.deinit();

    var inst = try SandboxInstance.init(.{
        .level = .full,
        .max_memory_bytes = 1024,
        .allowed_paths = &.{"skills/"},
    }, &arena);
    defer inst.deinit();

    try std.testing.expectError(SandboxError.PermissionDenied, inst.checkCapability(.file_read, "/etc/passwd"));
}

test "detectCapabilities" {
    const caps = detectCapabilities();
    _ = caps;
}

test "buildBpfFilter valid" {
    const filter = buildBpfFilter();
    try std.testing.expect(filter.len > 0);
    // Check last instruction is ALLOW return
    const ALLOW: u32 = @as(u32, seccomp_ns.RET.ALLOW);
    try std.testing.expectEqual(ALLOW, filter[filter.len - 1].k);
}
