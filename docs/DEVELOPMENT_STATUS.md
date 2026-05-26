# LingNet Agent OS V2.5 — 开发状态

## 审计修复进度

### ✅ 已完成 (2026-02-27)

| 编号 | 问题 | 修复 | 提交 |
|------|------|------|------|
| P0-1 | CHD完美哈希 | 底线B: AutoHashMap O(1) 已做，方案C: CHD算法待实现 | `98bd287` |
| P0-2 | io_uring集成到MRC | MrcEngine.io_handler回调 + io_uring_route.attachToMrc | `1c24c7e` |
| P0-3 | Python真实LLM API | test_llm_integration.py + providers_example.toml | `da3a4dd` |
| P1-1 | MrcEngine双重lookup | 删除冗余的第一次cam.lookup | `1c24c7e` |
| P1-2 | L1 Skill stub | 真实dlopen加载 + stub fallback | `1c24c7e` |
| P1-3 | eBPF C源码 | 确认已存在(.c文件完整) | `1c24c7e` |
| P1-4 | Ed25519 libsodium | build.zig linkSystemLibrary | `1c24c7e` |
| P2-1 | Metrics HTTP端点 | std.net.Server + /metrics | `1c24c7e` |
| P2-2 | Python层瘦身 | CFFI桥接select_provider | `da3a4dd` |
| P2-3 | P99直方图 | Prometheus summary类型 | `1c24c7e` |
| N1 | timespec字段名 | .tv_sec → .sec | `df0f104` |
| N2 | nanosleep命名空间 | std.posix → std.os.linux | `df0f104` |
| N3 | fallback验证 | verify失败return error | `df0f104` |
| N4 | 路由O(n) | AutoHashMap替代ArrayList | `df0f104` |

### 📋 待实现

| 编号 | 问题 | 方案 | 优先级 |
|------|------|------|--------|
| P0-1C | CHD完美哈希 | 实现CHD(Compress, Hash, Displace)算法，离线构建阶段 | 低 |
| P0-3C | CFFI桥接 | Python策略选择 → Zig io_uring HTTP客户端 | 中 |
| P2-2B | Token计费迁移 | TokenCounter从Python迁移到Zig | 低 |

## 目录结构

```
LingNet Agent OS/
├── src/                    # Zig核心模块
│   ├── boot.zig            # 启动 + nanosleep
│   ├── io_uring_route.zig  # io_uring零拷贝路由
│   ├── l2_loader.zig       # L2 Skill动态加载
│   ├── bpf_verify.zig      # eBPF验证
│   ├── switch.zig          # L0/L1/L2三级路由表
│   ├── metrics.zig         # Prometheus指标 + HTTP端点
│   ├── skill_loader.zig    # L0/L1/L2 Skill加载
│   ├── ed25519.zig         # Ed25519签名
│   └── main.zig            # 主入口
├── sdk/                    # SDK模块
│   ├── sandbox.zig         # Seccomp + Landlock沙箱
│   ├── hugepages.zig       # HugePages支持
│   └── vfs.zig             # 虚拟文件系统
├── sdk_arena_gqap.zig      # GQAP内存池
├── nullclaw-mrc.zig        # MRC数据平面
├── build.zig               # 构建系统
├── config/                 # 配置文件
│   ├── presets/            # 预设配置
│   └── providers_example.toml  # LLM Provider配置模板
├── python/                 # Python策略层
│   ├── python_router_core.py   # 多模型路由核心
│   └── model_clients.py    # Provider客户端
├── tests/                  # 测试
│   ├── test_llm_integration.py  # LLM集成测试
│   └── advisor_reports/    # 审计报告
├── docs/                   # 文档
├── tools/                  # 工具
├── skills/                 # Skill定义
└── ebpf_*.bpf.c            # eBPF C源码
```

## 构建状态
- 编译: ✅ 0错误
- 测试: 112/125通过, 1失败(l2_loader), 12crash(sandbox/bpf预期)
- Zig: 0.17-dev.338
