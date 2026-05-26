# Zig 0.17.0-dev.338 API 审计报告

**生成时间**: 2026-05-26
**项目**: LingNet Agent OS
**扫描文件数**: 60+ .zig 源文件

---

## 版本信息

| 项目 | 值 |
|------|-----|
| Zig 版本 | 0.17.0-dev.338+0d4f3cc67 |
| 标准库路径 | /opt/zig-bin-0.17-dev/lib/std/ |

---

## 风险 API 使用（需要修复）

### 🔴 高风险 — 编译失败

| API | 文件 | 行 | 问题 | 修复方案 |
|-----|------|----|------|----------|
| `std.Thread.Mutex` | `src_switch.zig` | 34 | 0.17 中不存在 | → `std.atomic.Mutex` 或 `std.Thread.Mutex` 替代方案 |
| `std.Thread.RwLock` | `src_switch.zig` | 39 | 0.17 中不存在 | → `std.Io.RwLock` 或自旋锁 |
| `std.posix.nanosleep` | `src/boot.zig` | 63 | 0.17 中不存在 | → `std.os.linux.nanosleep` |
| `std.os.linux.nanosleep` + `.tv_sec/.tv_nsec` | `sdk_arena_gqap.zig` | 292 | timespec 字段名错误 | → `.sec/.nsec` |

### 🟡 中风险 — 行为变更

| API | 文件 | 行 | 问题 | 修复方案 |
|-----|------|----|------|----------|
| `std.crypto.random.bytes` | `src/ed25519.zig` | 27 | `std.crypto` 在 0.17 部分缺失 | 当前用 fallback 路径，生产构建需 libsodium |
| `std.math.order` | `src/skill_scheduler.zig` | 54 | ✅ 0.17 中存在 | 无需修复 |
| `std.math.maxInt` | `bench_perf.zig` | 29 | ✅ 0.17 中存在（`comptime_int`） | 无需修复 |
| `std.posix.mmap` | `sdk_arena_gqap.zig` | 53 | ✅ 0.17 中存在 | 无需修复 |
| `std.posix.PROT` / `std.posix.MAP` | `sdk_arena_gqap.zig` | 56-57 | ✅ 0.17 中存在 | 无需修复 |

### 🟢 V2.3 已修复（从旧代码移除的 risky API）

| API | 状态 |
|-----|------|
| `sock_filter` / `sock_fprog` | ✅ 已替换为 `packed struct BpfInsn` |
| `STATX_INO` bitmask | ✅ 已替换为 `STATX{ .INO = true }` |
| `CLOCK_MONOTONIC` | ✅ 已替换为 `clockid_t.MONOTONIC` |
| `.tv_sec` / `.tv_nsec` | ⚠️ `src/boot.zig` 和 `sdk_arena_gqap.zig` 仍在使用 |
| `landlock_ruleset_attr` | ✅ 已替换为手动 `extern struct` |
| `LANDLOCK_*` 大写 syscall | ✅ 已替换为数字 syscall |
| `linux.bpf_insn` | ✅ 已替换为 `bpf_ns.BpfInsn` |
| `linux.bpf_attr` | ✅ 已替换为 `bpf_ns.Attr` |
| `std.time.Timer` | ✅ 已替换为 `clock_gettime` |
| `std.math.min` | ✅ 已替换为 `if` 表达式 |
| `@cImport` | ✅ 完全移除 |

---

## V2.2 遗留代码风险（src_switch 等旧模块）

### src_switch.zig

| API | 状态 | 风险 |
|-----|------|------|
| `std.Thread.Mutex` | ❌ 0.17 不存在 | 编译失败 |
| `std.Thread.RwLock` | ❌ 0.17 不存在 | 编译失败 |
| `std.atomic.Value` | ✅ 0.17 存在 | 安全 |
| `std.StringHashMap` | ✅ 0.17 存在 | 安全 |
| `.fetchAdd/.load/.store` | ✅ 0.17 存在 | 安全 |
| `.acquire/.release/.monotonic/.acq_rel` | ✅ 0.17 存在 | 安全 |

### nullclaw-mrc.zig

| API | 状态 | 风险 |
|-----|------|------|
| `std.atomic.Value` | ✅ 0.17 存在 | 安全 |
| `std.atomic.Mutex` | ✅ 0.17 存在 | 安全 |
| `packed struct` | ✅ 0.17 存在 | 安全 |
| `extern struct` | ✅ 0.17 存在 | 安全 |

### sdk_arena_gqap.zig

| API | 状态 | 风险 |
|-----|------|------|
| `std.posix.mmap` | ✅ 0.17 存在 | 安全 |
| `std.os.linux.nanosleep` | ⚠️ 函数存在但 timespec 字段名错误 | 运行时正确但需修复字段名 |
| `.tv_sec` / `.tv_nsec` | ❌ 0.17 中改为 `.sec`/`.nsec` | 编译错误 |
| `std.Thread.Mutex` | ❌ 未使用 | 安全 |
| `std.ArrayList` | ✅ 0.17 存在 | 安全 |

---

## 安全 API 使用（V2.3 修复后的代码）

### src/boot.zig
- `std.os.linux.statx` + `STATX{ .INO = true }` ✅
- `std.os.linux.nanosleep` → ⚠️ `std.posix.nanosleep` 需要改
- `std.Thread.spawn` / `std.Thread.join` ✅
- `std.fmt.parseInt` ✅
- `@embedFile` ✅
- `@intFromEnum` ✅

### src/skill_scheduler.zig
- `linux.clock_gettime(clockid_t.MONOTONIC, &ts)` ✅
- `ts.sec` / `ts.nsec` ✅
- `std.math.order` ✅
- `@intFromEnum` ✅

### src/bpf_verify.zig + tools_ebpf_loader.zig
- `bpf_ns = std.os.linux.BPF` ✅
- `bpf_ns.ProgLoadAttr` ✅
- `bpf_ns.Attr{ .prog_load = ... }` ✅
- `bpf_ns.Cmd.prog_load` ✅
- `linux.bpf(bpf_ns.Cmd.prog_load, &attr, size)` ✅
- `@sizeOf(bpf_ns.ProgLoadAttr)` ✅
- `@intCast` / `@intFromPtr` ✅

### src/l2_loader.zig
- `linux.prctl(@intFromEnum(PR.SET_NO_NEW_PRIVS), ...)` ✅
- `linux.seccomp(@as(u32, SECCOMP.SET_MODE_FILTER), ...)` ✅
- `packed struct BpfInsn` ✅
- `linux.syscall3(.landlock_create_ruleset, ...)` ✅
- `linux.syscall2(.landlock_restrict_self, ...)` ✅
- 手动 `LL_RulesetAttr` ✅

### sdk/sandbox.zig
- `seccomp_ns = std.os.linux.SECCOMP` ✅
- `linux.seccomp(@as(u32, seccomp_ns.SET_MODE_FILTER), ...)` ✅
- `LandlockRulesetAttr` 手动定义 ✅
- `linux.syscall3(.landlock_create_ruleset, ...)` ✅
- `linux.syscall2(.landlock_restrict_self, ...)` ✅

### src/ed25519.zig
- `std.crypto.random.bytes` ⚠️ 0.17 中 `std.crypto` 部分缺失
- 纯 Zig fallback（Wyhash）✅ — test 模式不依赖 libsodium

---

## timespec 字段名对照

| Zig 0.16 | Zig 0.17 | 状态 |
|----------|----------|------|
| `.tv_sec` | `.sec` | ⚠️ `src/boot.zig`、`sdk_arena_gqap.zig` 仍用旧名 |
| `.tv_nsec` | `.nsec` | ⚠️ 同上 |

---

## 命名空间冲突对照

| 用途 | 函数（小写） | 模块（大写） |
|------|-------------|-------------|
| seccomp | `linux.seccomp()` | `std.os.linux.SECCOMP` |
| bpf | `linux.bpf()` | `std.os.linux.BPF` |

**规则**: 调用函数用 `linux.xxx()`，引用常量/类型用 `std.os.linux.XXX`（大写模块）。

---

## 优先级建议

### P0 — 编译阻断（必须修复）
1. `src_switch.zig`: `std.Thread.Mutex` → 需找到 0.17 替代
2. `src_switch.zig`: `std.Thread.RwLock` → 需找到 0.17 替代
3. `sdk_arena_gqap.zig:292`: `.tv_sec/.tv_nsec` → `.sec/.nsec`
4. `src/boot.zig:63`: `std.posix.nanosleep` → `std.os.linux.nanosleep`

### P1 — 功能风险（建议修复）
1. `src/ed25519.zig`: `std.crypto.random.bytes` — test 模式 fallback OK，生产需 libsodium
2. 确认 `std.Thread.{Mutex,RwLock}` 在 0.17 中的实际位置

### P2 — 低风险（可延后）
1. `bench_perf.zig`: `std.math.maxInt(u64)` — ✅ 存在，无需改

---

## 总结

- **已修复**: 11 个关键 API 兼容性问题（sock_filter, STATX, CLOCK_MONOTONIC, landlock, bpf_attr, std.time.Timer, std.math.min, @cImport 等）
- **剩余风险**: 4 个（src_switch 2 + timespec 2）
- **V2.3 新增代码**: 全部使用正确的 Zig 0.17 API
- **V2.2 遗留代码**: src_switch 需要 Mutex/RwLock 修复
