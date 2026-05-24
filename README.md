# LingNet Agent OS V2.2

灵网代理操作系统 / Linux-based Agent Operating System

基于 Linux 原生原语协调 AI Agent 的操作系统。五层架构设计，支持 100K 并发 Sub-agent，目标 99.99% 可用性。

## 架构概览

- **Layer 0**: Linux 内核基座 (io_uring, HugePages, cgroups v2, eBPF)
- **Layer 1**: 数据传输面 (MRC 多路径引擎, SPSC Ring Buffer)
- **Layer 2**: 交换路由面 (三级查表: L0 ROM / L1 CHD / L2 F14HashMap)
- **Layer 3**: 编排控制面 (VRF/Arena 生命周期, GQAP 代际隔离)
- **Layer 4**: 认知计算面 (凝蜕引擎, 多模型路由, Zig-Python CFFI)

## 技术栈

| 组件 | 版本 | 说明 |
|:---|:---|:---|
| Zig | 0.17 (首选) / 0.16 (备案) | 系统核心 |
| Python | 3.12+ (nogil) | 多模型路由、凝蜕引擎 |
| Linux | 6.1+ (推荐) / 5.10+ (最低) | 内核基座 |
| eBPF | LSM + Tracepoint | 安全沙箱 |

## 快速开始

```bash
# 安装依赖 (Gentoo)
emerge --ask dev-lang/zig:0.17 dev-lang/python:3.12

# 编译
cd /root/LingNet Agent OS
zig build

# 运行
./zig-out/bin/lingnet-daemon
```

## 开发分支

- `main` — 稳定分支
- `agent` — AI Agent 协作开发分支

## 许可证

MIT
