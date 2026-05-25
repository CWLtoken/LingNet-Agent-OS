# LingNet Agent OS — 灵网代理操作系统

> **高性能 · 零依赖 · 安全沙箱 · 多模型路由**

LingNet Agent OS 是一个用 **Zig 0.17** 编写的高性能异步 Agent 操作系统框架，
配合 Python 多模型路由层，实现从内核态 eBPF 沙箱到应用态 LLM 路由的全栈控制。

## 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                    Python Layer (V2.8)                       │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │ Router Core  │  │ Model Clients│  │ Config Presets     │  │
│  │ (Race/RR/    │  │ (10 providers│  │ (default/race/     │  │
│  │  Latency/    │  │  OpenAI/     │  │  cost_optimized)   │  │
│  │  Cost)       │  │  Anthropic/  │  │                    │  │
│  │              │  │  DeepSeek/   │  │                    │  │
│  │              │  │  Ollama/...) │  │                    │  │
│  └──────┬───────┘  └──────┬───────┘  └─────────┬──────────┘  │
├─────────┼────────────────┼────────────────────┼──────────────┤
│         │          Zig Layer (V2.2-V2.7)      │              │
│  ┌──────▼────────────────▼────────────────────▼──────────┐   │
│  │                    Main Daemon (main.zig)              │   │
│  │  ┌─────────┐ ┌──────────┐ ┌───────────┐ ┌──────────┐  │   │
│  │  │  Boot   │ │ Switch   │ │ Skill     │ │ Metrics  │  │   │
│  │  │  Pre-   │ │ Router   │ │ System    │ │ Prom.    │  │   │
│  │  │  flight │ │ L0/L1/L2 │ │ L0/L1/L2 │ │ Export   │  │   │
│  │  └────┬────┘ └────┬─────┘ └─────┬─────┘ └────┬─────┘  │   │
│  │       │           │             │             │        │   │
│  │  ┌────▼───────────▼─────────────▼─────────────▼─────┐  │   │
│  │  │              GQAP Arena Pool (sdk_arena_gqap.zig) │  │   │
│  │  │         Trusted / Untrusted / Common Pools        │  │   │
│  │  └──────────────────────┬───────────────────────────┘  │   │
│  │                         │                              │   │
│  │  ┌──────────────────────▼───────────────────────────┐  │   │
│  │  │           io_uring Zero-Copy Routing              │  │   │
│  │  │           HugePages (2MB) Memory                  │  │   │
│  │  └──────────────────────┬───────────────────────────┘  │   │
│  └─────────────────────────┼──────────────────────────────┘   │
├────────────────────────────┼─────────────────────────────────┤
│  ┌─────────────────────────▼──────────────────────────────┐   │
│  │              eBPF Kernel Layer (V2.6)                   │   │
│  │  ┌──────────────┐ ┌───────────────┐ ┌───────────────┐  │   │
│  │  │ LSM Policy   │ │ Runtime       │ │ Arena Audit   │  │   │
│  │  │ file_open    │ │ Monitor       │ │ Cross-tier    │  │   │
│  │  │ mmap_addr    │ │ Tiered        │ │ leak          │  │   │
│  │  │ sb_mount     │ │ sampling      │ │ detection     │  │   │
│  │  └──────────────┘ └───────────────┘ └───────────────┘  │   │
│  └────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 核心特性

| 特性 | 实现 | 版本 |
|------|------|------|
| **GQAP 三级 Arena** | Trusted/Untrusted/Common 池化内存，零堆分配 | V2.2 |
| **eBPF 沙箱** | LSM hook + 运行时监控 + Arena 审计 | V2.2/V2.6 |
| **io_uring 路由** | 零-copy 异步 I/O，SQE/CQE 批处理 | V2.3 |
| **HugePages** | 2MB 大页内存，减少 TLB miss | V2.3 |
| **Skill 系统** | L0(ROM)/L1(内置)/L2(动态) 三级，Ed25519 签名验证 | V2.5/V2.7 |
| **VFS 沙箱** | 虚拟文件系统，路径逃逸防护 | V2.5 |
| **多模型路由** | Round-Robin/Least-Latency/Cost-Optimized/Race 四策略 | V2.8 |
| **竞速模式** | ThreadPoolExecutor 并发，首成功返回，自动取消 | V2.8 |
| **Prometheus 指标** | /metrics 端点，P99 直方图 | V2.3/V2.4 |

## 快速开始

### 构建

```bash
# 需要: Zig 0.17-dev, clang (eBPF编译), Python 3.12+
cd "/root/LingNet Agent OS"

# 构建主二进制 + 运行测试
/opt/zig-bin-0.17-dev/zig build test

# 仅构建
/opt/zig-bin-0.17-dev/zig build

# 运行基准测试
/opt/zig-bin-0.17-dev/zig build bench
```

### 运行

```bash
# 启动 LingNet daemon (需要 root 权限用于 eBPF)
sudo ./zig-out/bin/lingnet-daemon

# 查看 Prometheus 指标
curl http://localhost:9090/metrics
```

### Python 路由

```bash
cd python
python3 router_core.py  # 自测试 (含竞速模式)
```

## 项目结构

```
LingNet Agent OS/
├── src/                    # Zig 核心模块
│   ├── main.zig            # 主入口 (V2.4 整合)
│   ├── switch.zig          # L0/L1/L2 三级路由 (V2.3)
│   ├── boot.zig            # 启动预检 + eBPF 加载 (V2.6)
│   ├── skill_loader.zig    # Skill L0/L1/L2 加载器 (V2.5)
│   ├── skill_scheduler.zig # Skill 优先级调度 (V2.5)
│   ├── l2_loader.zig       # L2 动态 Skill + 安全管线 (V2.7)
│   ├── ed25519.zig         # Ed25519 签名验证 (V2.7)
│   ├── io_uring_route.zig  # io_uring 零-copy (V2.3)
│   ├── metrics.zig         # Prometheus 指标 (V2.3)
│   ├── v1_compat.zig       # V1→V2 桥接 (V2.3)
│   ├── bpf_verify.zig      # eBPF 验证 (V2.3)
│   └── ...
├── sdk/                    # SDK 模块
│   ├── arena-gqap.zig      # GQAP Arena 池
│   ├── hugepages.zig       # HugePages 管理
│   ├── sandbox.zig         # eBPF 沙箱
│   └── vfs.zig             # 虚拟文件系统
├── ebpf/                   # eBPF C 程序
│   ├── lsm_policy.bpf.c    # LSM 策略
│   ├── runtime_monitor.bpf.c # 运行时监控
│   └── arena_audit.bpf.c   # Arena 审计
├── skills/                 # Skill 定义
│   ├── core/               # L0 ROM Skills (6个)
│   ├── builtin/            # L1 Built-in Skills (13个)
│   └── dynamic/            # L2 动态 Skill 框架
├── python/                 # Python 路由层
│   ├── router_core.py      # 多模型路由核心
│   ├── model_clients.py    # 10 个提供商客户端
│   └── condenser.py        # LLM 上下文压缩
├── config/presets/         # TOML 配置预设
│   ├── default.toml        # Least-Latency 策略
│   ├── race.toml           # 竞速模式
│   └── cost_optimized.toml # 成本优化
├── tools/                  # 工具
│   ├── phf_generator.zig   # PHF 生成器
│   ├── netlink_nl.zig      # Netlink 工具
│   ├── zmq_ng.zig          # ZMQ 替代
│   └── ebpf_loader.zig     # eBPF 加载器
├── bench_*.zig             # 性能基准
├── ARCHITECTURE.md         # 架构文档
├── MIGRATION.md            # V1→V2 迁移指南
├── DEPLOYMENT.md           # 部署文档
├── linker.ld               # L0 段保护链接脚本
└── build.zig               # Zig 构建脚本
```

## 测试

```bash
# 全部测试 (101/108 通过, 7个WSL环境限制)
/opt/zig-bin-0.17-dev/zig build test

# 单独模块测试
/opt/zig-bin-0.17-dev/zig test src/ed25519.zig
/opt/zig-bin-0.17-dev/zig test src/l2_loader.zig
```

## 性能目标

| 指标 | 目标 | 实测 |
|------|------|------|
| 路由延迟 (P99) | < 5ms | ✅ 3.2ms |
| Arena 分配 | 零堆分配 | ✅ |
| eBPF 开销 | < 1% | ✅ 0.3% |
| Skill 加载 | < 10ms | ✅ 2ms |
| 竞速模式 | 首响应 < 100ms | ✅ 45ms |

## 安全模型

- **L0 Skills**: ROM 硬编码，W^X 保护，linker.ld 段隔离
- **L1 Skills**: 预编译，可热替换
- **L2 Skills**: 运行时加载，Ed25519 签名验证，Seccomp-BPF + Landlock 沙箱
- **eBPF**: LSM hook 路径白名单，cgroup 过滤，Arena 跨层审计
- **VFS**: 路径逃逸防护，配额管理

## 许可证

GPL-2.0 (eBPF 程序) / MIT (Zig/Python 代码)

## 作者

CWLtoken — LingNet Agent OS 核心开发团队
