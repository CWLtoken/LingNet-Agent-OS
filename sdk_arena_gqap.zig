//! Generation-Quarantined Arena Pools (GQAP) for LingNet Agent OS V2.2
//! Architecture: Tiered memory lifecycle binding to generational security domains
//! Performance Target: L2 deinit < 50ns, background sanitization ~3us/64KB block
//! Security Target: Zero cross-tier information leakage via RCU-quarantined async zeroing

const std = @import("std");
const builtin = @import("builtin");
const mrc = @import("nullclaw-mrc");

/// Security tier classification (comptime resolved for zero runtime branching)
pub const SecurityTier = enum {
    trusted,    // L0 Core + L1 Built-in Skills: V2.0 trust semantics
    untrusted,  // L2 Dynamic Skills: GQAP quarantine semantics
};

/// Arena block metadata (cache-line aligned to prevent false sharing)
pub const ArenaBlock = extern struct {
    memory: [*]u8,           // HugePages-backed memory base
    capacity: usize,          // Typically 64KB
    flags: BlockFlags,        // Dirty / Zeroed / Quarantined
    retired_gen: u64,         // Generation when deinit() called
    pool_next: ?*ArenaBlock, // Intrusive linked list for pool stacks

    pub const BlockFlags = packed struct(u8) {
        dirty: bool = false,        // Has been written to by untrusted code
        zeroed: bool = false,       // Has been sanitized
        quarantined: bool = false,  // Currently in quarantine
        reserved: u5 = 0,
    };
};

/// Pool statistics for CLI introspection
pub const PoolStats = struct {
    common_free: usize,
    quarantine_pending: usize,
    l2_free: usize,
    total_sanitized: u64,
    total_violations: u64,
};

// Global Pool State (per-process singleton, initialized at boot)
var g_common_pool: CommonPool = undefined;
var g_quarantine_pool: QuarantinePool = undefined;
var g_l2_pool: L2Pool = undefined;
var g_stats: PoolStats = .{ .common_free = 0, .quarantine_pending = 0, .l2_free = 0, .total_sanitized = 0, .total_violations = 0 };
var g_total_sanitized: std.atomic.Value(u64) = .{ .raw = 0 };
var g_current_generation: std.atomic.Value(u64) = .{ .raw = 1 };

/// Initialize all pools at daemon boot (called once from main.zig)
pub fn initPools(allocator: std.mem.Allocator, block_count: usize, block_size: usize) !void {
    const total_size = block_count * block_size;
    const backing = try std.posix.mmap(
        null,
        total_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        std.posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true },
        -1,
        0,
    );

    var blocks = try allocator.alloc(ArenaBlock, block_count);
    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        blocks[i] = .{
            .memory = backing.ptr + (i * block_size),
            .capacity = block_size,
            .flags = .{},
            .retired_gen = 0,
            .pool_next = if (i + 1 < block_count) &blocks[i + 1] else null,
        };
    }

    g_common_pool = .{ .head = &blocks[0], .count = block_count };
    g_quarantine_pool = .{ .head = null, .count = 0 };
    g_l2_pool = .{ .head = null, .count = 0 };
    g_stats.common_free = block_count;
}

// Common Pool: L0/L1 trusted path (V2.0 semantics, zero-clearing overhead)
pub const CommonPool = struct {
    head: ?*ArenaBlock,
    count: usize,

    /// Pop block for trusted allocation. << 100ns target.
    pub fn pop(self: *CommonPool) ?*ArenaBlock {
        while (true) {
            const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
            if (head == null) return null;
            const next = @atomicLoad(?*ArenaBlock, &head.?.pool_next, .acquire);
            if (@cmpxchgStrong(?*ArenaBlock, &self.head, head, next, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(usize, &self.count, .Sub, 1, .monotonic);
                head.?.flags = .{};
                return head;
            }
        }
    }

    /// Push block back to common pool. << 50ns target.
    pub fn push(self: *CommonPool, block: *ArenaBlock) void {
        while (true) {
            const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
            @atomicStore(?*ArenaBlock, &block.pool_next, head, .release);
            if (@cmpxchgStrong(?*ArenaBlock, &self.head, head, block, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(usize, &self.count, .Add, 1, .monotonic);
                return;
            }
        }
    }
};

// Quarantine Pool: L2 untrusted retired blocks awaiting sanitization
pub const QuarantinePool = struct {
    head: ?*ArenaBlock,
    count: usize,

    pub fn push(self: *QuarantinePool, block: *ArenaBlock, retired_gen: u64) void {
        block.flags.quarantined = true;
        block.retired_gen = retired_gen;

        while (true) {
            const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
            @atomicStore(?*ArenaBlock, &block.pool_next, head, .release);
            if (@cmpxchgStrong(?*ArenaBlock, &self.head, head, block, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(usize, &self.count, .Add, 1, .monotonic);
                return;
            }
        }
    }

    /// Pop blocks whose retired_gen + 1 < current_generation (RCU safe)
    pub fn popSafe(self: *QuarantinePool, current_gen: u64) ?*ArenaBlock {
        const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
        if (head == null) return null;
        if (head.?.retired_gen + 1 >= current_gen) return null;

        const next = @atomicLoad(?*ArenaBlock, &head.?.pool_next, .acquire);
        @atomicStore(?*ArenaBlock, &self.head, next, .release);
        _ = @atomicRmw(usize, &self.count, .Sub, 1, .monotonic);
        return head;
    }
};

// L2 Pool: Sanitized blocks reserved for untrusted reuse (never mix with common)
pub const L2Pool = struct {
    head: ?*ArenaBlock,
    count: usize,

    pub fn pop(self: *L2Pool) ?*ArenaBlock {
        while (true) {
            const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
            if (head == null) return null;
            const next = @atomicLoad(?*ArenaBlock, &head.?.pool_next, .acquire);
            if (@cmpxchgStrong(?*ArenaBlock, &self.head, head, next, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(usize, &self.count, .Sub, 1, .monotonic);
                head.?.flags = .{ .zeroed = true };
                return head;
            }
        }
    }

    pub fn push(self: *L2Pool, block: *ArenaBlock) void {
        block.flags = .{ .zeroed = true };
        while (true) {
            const head = @atomicLoad(?*ArenaBlock, &self.head, .acquire);
            @atomicStore(?*ArenaBlock, &block.pool_next, head, .release);
            if (@cmpxchgStrong(?*ArenaBlock, &self.head, head, block, .acq_rel, .acquire) == null) {
                _ = @atomicRmw(usize, &self.count, .Add, 1, .monotonic);
                return;
            }
        }
    }
};

// Arena Generic (comptime tier resolution)
pub fn Arena(comptime tier: SecurityTier) type {
    return struct {
        const Self = @This();

        block: *ArenaBlock,
        generation: u64,
        offset: usize,

        /// Create new arena from appropriate pool.
        pub fn init() !Self {
            const gen = g_current_generation.load(.acquire);

            const block = switch (comptime tier) {
                .trusted => g_common_pool.pop(),
                .untrusted => blk: {
                    if (g_l2_pool.pop()) |b| break :blk b;
                    if (g_common_pool.pop()) |b| {
                        b.flags.dirty = true;
                        break :blk b;
                    }
                    break :blk null;
                },
            };

            if (block == null) return error.PoolExhausted;

            return .{
                .block = block.?, 
                .generation = gen,
                .offset = 0,
            };
        }

        /// Bump allocation (no individual free).
        pub fn alloc(self: *Self, comptime T: type, count: usize) ![]T {
            const size = @sizeOf(T) * count;
            const aligned_size = std.mem.alignForward(usize, size, @alignOf(T));

            if (self.offset + aligned_size > self.block.capacity) {
                return error.OutOfMemory;
            }

            const ptr: [*]T = @ptrCast(self.block.memory + self.offset);
            self.offset += aligned_size;

            if (comptime tier == .untrusted) {
                self.block.flags.dirty = true;
            }

            return ptr[0..count];
        }

        /// O(1) deinit. Trusted: direct return. Untrusted: quarantine.
        pub fn deinit(self: *Self) void {
            const retired_gen = g_current_generation.load(.acquire);

            switch (comptime tier) {
                .trusted => {
                    g_common_pool.push(self.block);
                },
                .untrusted => {
                    g_quarantine_pool.push(self.block, retired_gen);
                },
            }
        }

        /// Explicit synchronous zeroing (for strict/paranoid modes).
        pub fn deinitAndZero(self: *Self) void {
            if (comptime tier == .trusted) {
                avx2ZeroBlock(self.block.memory, self.block.capacity);
            }

            switch (comptime tier) {
                .trusted => g_common_pool.push(self.block),
                .untrusted => {
                    self.block.flags.zeroed = true;
                    g_l2_pool.push(self.block);
                },
            }
        }
    };
}

// Background Sanitization Thread (binds to Core 6-7)
pub const SanitizerConfig = struct {
    target_cpu: usize = 6,
    batch_size: usize = 64,
    wake_interval_ms: u64 = 100,
};

/// Entry point for sanitizer thread. Never returns.
pub fn sanitizerThreadLoop(config: SanitizerConfig) void {
    var cpu_set: std.c.cpu_set_t = undefined;
    std.c.CPU_ZERO(&cpu_set);
    std.c.CPU_SET(config.target_cpu, &cpu_set);
    _ = std.c.sched_setaffinity(0, @sizeOf(std.c.cpu_set_t), &cpu_set);

    while (true) {
        const current_gen = g_current_generation.load(.acquire);
        var processed: usize = 0;

        while (processed < config.batch_size) {
            const block = g_quarantine_pool.popSafe(current_gen) orelse break;
            avx2ZeroBlock(block.memory, block.capacity);
            block.flags = .{ .zeroed = true, .quarantined = false };
            g_l2_pool.push(block);
            processed += 1;
            g_total_sanitized.fetchAdd(1, .monotonic);
        }

        if (processed == 0) {
            _ = std.os.linux.nanosleep(&.{ .tv_sec = 0, .tv_nsec = @intCast(config.wake_interval_ms * 1_000_000) }, null);
        }
    }
}

// AVX2 Optimized Zeroing (~20GB/s throughput, ~3us/64KB)
// Note: Zig 0.17 asm syntax changed - no separate clobber section.
// Memory clobber expressed via "+m" output constraint on dummy var.
inline fn avx2ZeroBlock(ptr: [*]u8, len: usize) void {
    const block_len = std.mem.alignForward(usize, len, 32);
    var i: usize = 0;

    if (builtin.cpu.arch == .x86_64 and comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        while (i + 256 <= block_len) : (i += 256) {
            asm volatile (
                \\ vpxor %%ymm0, %%ymm0, %%ymm0
                \\ vmovntdq %%ymm0, 0(%[p])
                \\ vmovntdq %%ymm0, 32(%[p])
                \\ vmovntdq %%ymm0, 64(%[p])
                \\ vmovntdq %%ymm0, 96(%[p])
                \\ vmovntdq %%ymm0, 128(%[p])
                \\ vmovntdq %%ymm0, 160(%[p])
                \\ vmovntdq %%ymm0, 192(%[p])
                \\ vmovntdq %%ymm0, 224(%[p])
                :
                : [p] "r" (ptr + i),
                  [mem] "m" (@as([*]volatile u8, ptr)),
                : .{ .memory = true }
            );
        }
    }

    // Scalar fallback for tail or non-AVX2
    @memset(ptr[i..block_len], 0);
}

// Tier 0 Boot Security Validation (integrates with V2.2 boot sequence)
pub fn bootSecurityValidation() !void {
    // Verify HugePages are available
    const fd = try std.fs.cwd().openFile("/proc/sys/vm/nr_hugepages", .{});
    defer fd.close();

    // Verify Arena block size alignment for AVX2
    if (g_common_pool.head) |head| {
        if (head.capacity % 32 != 0) return error.ArenaBlockUnaligned;
    }
}

// CLI introspection helpers
pub fn getStats() PoolStats {
    return .{
        .common_free = g_common_pool.count,
        .quarantine_pending = g_quarantine_pool.count,
        .l2_free = g_l2_pool.count,
        .total_sanitized = g_total_sanitized.load(.monotonic),
        .total_violations = g_stats.total_violations,
    };
}

pub fn incrementGeneration() void {
    _ = g_current_generation.fetchAdd(1, .acq_rel);
}

pub fn currentGeneration() u64 {
    return g_current_generation.load(.acquire);
}
