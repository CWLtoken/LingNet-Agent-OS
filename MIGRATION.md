# V1 → V2 Migration Guide

## Overview

LingNet Agent OS V2 introduces significant architectural changes while maintaining backward compatibility through the V1 Compat layer (`src/v1_compat.zig`).

## Key Changes

### 1. Memory Management: Arena → GQAP

**V1:**
```zig
var arena = try std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const buf = try arena.allocator().alloc(u8, 1024);
```

**V2:**
```zig
const gqap = @import("arena-gqap");
try gqap.initPools(allocator, 10000, 65536);
const TrustedArena = gqap.Arena(.trusted);
var arena = try TrustedArena.init();
defer arena.deinit();
const buf = try arena.alloc(u8, 1024);
```

**Migration:** Use `V1Compat` layer for drop-in replacement:
```zig
const v1 = @import("v1-compat");
var compat = v1.V1Compat.init(allocator);
const arena = try compat.createArena(1024 * 1024);
defer compat.destroyArena(arena);
const buf = try compat.alloc(arena, 1024);
```

### 2. Configuration: Simple TOML → Preset System

**V1:**
```toml
[arena]
size = 1048576
```

**V2:**
```toml
[preset]
name = "production"

[arena]
block_count = 10000
block_size = 65536

[security]
ebpf = true
hugepages = true
```

**Migration:** Use `MigrationHelper.convertConfig()`:
```zig
const v1_config = v1.V1Config{ .arena_size = 1024 * 1024 };
const v2_config = v1.MigrationHelper.convertConfig(v1_config);
```

### 3. Routing: Linear → Tiered L0/L1/L2

**V1:**
```zig
// Simple linear search
for (routes) |route| {
    if (route.intent == target) return route;
}
```

**V2:**
```zig
const switch = @import("switch");
var table = try switch.SwitchTable.init(allocator, .{});
try table.registerL0(intent_id, handler);  // Hot path
try table.registerL1(intent_id, handler);  // Warm path
try table.registerL2(intent_id, handler);  // Cold path
const entry = table.lookup(intent_id);
```

### 4. Security: None → eBPF + Sandbox

**V1:** No security layer

**V2:**
```zig
const boot = @import("boot");
const result = try boot.bootCheck(.{});
// result.ebpf_loaded, result.hugepages_ok, etc.
```

### 5. I/O: epoll → io_uring

**V1:**
```zig
var epoll_fd = try std.os.epoll_create1(0);
// ... epoll_ctl, epoll_wait loop
```

**V2:**
```zig
const iouring = @import("io-uring-route");
var router = try iouring.IoUringRouter.init(allocator, 256);
try router.submitRead(fd, buf, offset);
const completed = try router.peekBatchCqe(&results, 32);
```

## Compatibility Matrix

| V1 API | V2 Equivalent | Compat Layer |
|--------|---------------|--------------|
| `ArenaAllocator` | `gqap.Arena(.trusted)` | `V1Compat.createArena` |
| `std.fmt.parseInt` | Same | Direct |
| Linear routing | `SwitchTable` | `V1Compat` |
| No security | `boot.bootCheck` | N/A (new) |
| epoll | `IoUringRouter` | N/A (new) |

## Step-by-Step Migration

### Step 1: Add V1 Compat Import

```zig
const v1 = @import("v1-compat");
```

### Step 2: Replace Arena Usage

Replace all `std.heap.ArenaAllocator` with `V1Compat`:
```zig
// Before
var arena = try std.heap.ArenaAllocator.init(allocator);
// After
var compat = v1.V1Compat.init(allocator);
const arena = try compat.createArena(size);
```

### Step 3: Update Configuration

Convert V1 config to V2:
```zig
const v2_config = v1.MigrationHelper.convertConfig(v1_config);
```

### Step 4: Add Boot Checks

Add pre-flight checks at startup:
```zig
const boot = @import("boot");
const result = try boot.bootCheck(.{});
if (!result.ebpf_loaded) {
    std.log.warn("Running without eBPF security", .{});
}
```

### Step 5: Run Tests

```bash
zig build test
```

## Breaking Changes

1. **Arena API**: `alloc()` now returns `![]u8` instead of `[]u8`
2. **Config format**: TOML preset system replaces flat config
3. **Error handling**: More granular error types (`error.SecurityViolation`, `error.QuotaExceeded`)
4. **Build system**: `zig build` replaces custom build scripts

## Performance Impact

| Operation | V1 | V2 | Delta |
|-----------|----|----|-------|
| Arena alloc | ~50ns | ~30ns | -40% |
| Route lookup | ~200ns | ~10ns | -95% |
| Security check | N/A | ~5ns | New |
| Memory sanitization | N/A | ~3μs/64KB | New |

## FAQ

**Q: Can I use V1 and V2 APIs together?**
A: Yes, the V1 Compat layer is designed for gradual migration.

**Q: What if eBPF is not available?**
A: The system automatically degrades to Seccomp-BPF + tracepoint monitoring.

**Q: Is HugePages required?**
A: No, the system falls back to normal 4KB pages with MAP_LOCKED.
