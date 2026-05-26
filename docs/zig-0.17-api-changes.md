# Zig 0.17.0-dev.338 API 变动记录

> 记录时间: 2026-05-24
> 对照版本: Zig 0.16.0 -> Zig 0.17.0-dev.338+0d4f3cc67
> 影响文件: build.zig / build.zig.zon

## 1. build.zig API 变动

### 1.1 ObjectOptions / ExecutableOptions / LibraryOptions

| Zig 0.16 | Zig 0.17 |
|----------|----------|
| `root_source_file: LazyPath` | `root_module: *Module` |

**修复方式**: 用 `b.createModule(.{ .root_source_file = b.path("...") })` 创建 Module，然后传给 options。

### 1.2 addObject / addExecutable / addSharedLibrary / addStaticLibrary / addTest

结构体字段从 `root_source_file` 改为 `root_module`:

```zig
// Zig 0.16 (旧)
const obj = b.addObject(.{
    .name = "foo",
    .root_source_file = b.path("foo.zig"),
});

// Zig 0.17 (新)
const obj = b.addObject(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("foo.zig"),
    }),
});
```

### 1.3 addIncludePath

| Zig 0.16 | Zig 0.17 |
|----------|----------|
| `obj.addIncludePath(b.path("include/"))` | `obj.root_module.addIncludePath(b.path("include/"))` |

调用对象从 Compile Step 改为 Module。

### 1.4 setLinkerScript

**未变动**，仍然可用：
```zig
exe.setLinkerScript(b.path("linker.ld"));
```

### 1.5 addAnonymousImport

**未变动**：
```zig
exe.root_module.addAnonymousImport("routing_table", .{
    .root_source_file = routing_table,
});
```

### 1.6 addImport

**未变动**：
```zig
exe.root_module.addImport("arena-gqap", gqap_mod);
```

### 1.7 resolveTargetQuery

**未变动**：
```zig
const bpf_target = b.resolveTargetQuery(.{
    .cpu_arch = .bpfel,
    .os_tag = .linux,
    .abi = .none,
});
```

## 2. 内联汇编语法变动

### 2.1 asm volatile -> asm

| Zig 0.16 | Zig 0.17 |
|----------|----------|
| `asm volatile ("..." : ... : ... : ...)` | `asm ("..." : ... : ... : ...)` |

`volatile` 关键字被移除。Zig 0.17 的内联汇编默认就是 volatile 的。

## 3. 原子操作胖指针

### 3.1 @atomicLoad 对切片

Zig 0.16 可以直接 `@atomicLoad([]const T, &slice, .acquire)`
Zig 0.17 需要先转为指针数组：

```zig
// Zig 0.16 (旧)
const ptr = @atomicLoad(*const []const RouteEntry, &self.l1_table, .acquire);

// Zig 0.17 (新)
const slice = @as(*const []const RouteEntry, &self.l1_table);
const ptr = @atomicLoad(@typeOf(slice.*), slice, .acquire);
```

## 4. bpf_attr 结构体

**未变动**，仍然可用：
```zig
const attr = std.os.linux.bpf_attr{ ... };
```

## 5. CreateModule API

新增 `b.createModule()` 用于创建 Module：

```zig
pub fn createModule(b: *Build, options: CreateModuleOptions) *Module
```

其中 `CreateModuleOptions` 包含 `root_source_file: LazyPath` 字段。

## 6. 其他注意事项

- `std.Build.path()` 未变动
- `std.Build.installArtifact()` 未变动
- `std.Build.addRunArtifact()` 未变动
- `std.Build.step()` 未变动

## 7. 完整 build.zig 迁移示例

见 `build_v2.2.zig` -> `build.zig` 的迁移（M0 任务之一）。

## 8. 版本锁定

`build.zig.zon` 中锁定：
```zig
.zig = .{
    .version = "0.17.0-dev.338+0d4f3cc67",
}
```
