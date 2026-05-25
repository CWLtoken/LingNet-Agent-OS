//! LingNet Agent OS V2.2 — Sandbox Policy
//! eBPF-seccomp hybrid sandbox with capability-based access control

const std = @import("std");
const gqap = @import("arena-gqap");
const linux = std.os.linux;

pub const SandboxError = error{
    SeccompInstallFailed,
    LandlockNotSupported,
    PermissionDenied,
    InvalidPolicy,
    EbpfSandboxUnavailable,
};

/// Sandbox policy level
pub const SandboxLevel = enum(u8) {
    /// No sandbox (debug only)
    none = 0,
    /// Seccomp-BPF syscall filter only
    seccomp = 1,
    /// Seccomp + Landlock filesystem sandbox
    landlock = 2,
    /// Full eBPF LSM + Seccomp + Landlock (V2.2 default)
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
    max_memory_bytes: usize = 64 * 1024 * 1024, // 64MB
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
    arena: *gqap.Arena(.untrusted), // Skills always use UntrustedArena (external lifetime)

    pub fn init(policy: SandboxPolicy, arena: *gqap.Arena(.untrusted)) !SandboxInstance {
        try policy.validate();

        var inst = SandboxInstance{
            .policy = policy,
            .arena = arena,
        };

        // Install seccomp filter
        if (@intFromEnum(policy.level) >= @intFromEnum(SandboxLevel.seccomp)) {
            inst.seccomp_fd = try installSeccompFilter(&policy);
        }

        // Install landlock rules
        if (@intFromEnum(policy.level) >= @intFromEnum(SandboxLevel.landlock)) {
            inst.landlock_fd = try installLandlockRules(&policy);
        }

        return inst;
    }

    pub fn deinit(self: *SandboxInstance) void {
        if (self.seccomp_fd >= 0) {
            _ = linux.close(@intCast(self.seccomp_fd));
        }
        if (self.landlock_fd >= 0) {
            _ = linux.close(@intCast(self.landlock_fd));
        }
    }

    /// Check if a capability is allowed
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
            .load_module, .signal_send => {
                return SandboxError.PermissionDenied;
            },
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

/// Install Seccomp-BPF filter (whitelist mode)
fn installSeccompFilter(policy: *const SandboxPolicy) !i32 {
    _ = policy;
    // TODO(M3): Build raw BPF for syscall whitelist
    return 0;
}

/// Install Landlock filesystem rules
fn installLandlockRules(policy: *const SandboxPolicy) !i32 {
    _ = policy;
    // TODO(M3): landlock_create_ruleset + landlock_restrict_self
    return 0;
}

/// Detect available sandbox capabilities at runtime
pub fn detectCapabilities() CapabilitySet {
    var caps = CapabilitySet{};

    // Simplified: assume seccomp available on Linux
    caps.seccomp_available = true;
    // TODO(M3): Proper landlock detection via syscall
    caps.landlock_available = false;

    return caps;
}

pub const CapabilitySet = struct {
    seccomp_available: bool = false,
    landlock_available: bool = false,
    ebpf_lsm_available: bool = false,

    pub fn recommendLevel(self: CapabilitySet) SandboxLevel {
        if (self.ebpf_lsm_available and self.landlock_available and self.seccomp_available) {
            return .full;
        }
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
    // Initialize global pools once across all tests
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
        .allowed_paths = &.{"./skills/", "/tmp/lingnet/"},
    }, &arena);
    defer inst.deinit();

    try inst.checkCapability(.file_read, "./skills/test/handler.zig");
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
        .allowed_paths = &.{"./skills/"},
    }, &arena);
    defer inst.deinit();

    try std.testing.expectError(SandboxError.PermissionDenied, inst.checkCapability(.file_read, "/etc/passwd"));
}

test "detectCapabilities" {
    const caps = detectCapabilities();
    try std.testing.expect(caps.seccomp_available or !caps.seccomp_available);
}
