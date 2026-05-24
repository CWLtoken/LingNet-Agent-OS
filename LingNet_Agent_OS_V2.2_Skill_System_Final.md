# LingNet Agent OS V2.2 - Skill 系统完整规格书（修复冻结版）
**文档版本**: v2.2-final-freeze-20260524  
**冻结日期**: 2026-05-24  
**核心依赖**: Zig 0.17, Python 3.12+ (nogil), Linux 6.1+  
**前置文档**: LingNet Agent OS V2.0 完整技术规格书（已同步更新至2.2）
**审计状态**: 7项高优先级问题全部修复，12项中优先级问题已处理，8项低优先级优化纳入V2.3路线图

---

## 目录
1. [预设系统架构](#1-预设系统架构)
2. [Skill 三层模型](#2-skill-三层模型)
3. [初始种子 Skill 清单](#3-初始种子-skill-清单)
4. [多模型提供商配置](#4-多模型提供商配置)
5. [Agent 自写 Skill LLM Prompt 模板](#5-agent-自写-skill-llm-prompt-模板)
6. [TUI 界面设计](#6-tui-界面设计)
7. [编译与部署管线](#7-编译与部署管线)
8. [安全沙箱规范](#8-安全沙箱规范)
9. [GQAP 代际隔离 Arena 池（V2.2新增）](#9-gqap-代际隔离-arena-池v22新增)
10. [启动预检与降级策略（V2.2增强）](#10-启动预检与降级策略v22增强)
11. [性能验收指标体系（V2.2更新）](#11-性能验收指标体系v22更新)
12. [开发路线图（V2.2更新）](#12-开发路线图v22更新)
13. [附录: 审计修复对照表](#13-附录审计修复对照表)

---

## 1. 预设系统架构

### 1.1 核心概念映射
```text
Lingtai 预设         LingNet 预设 (Persona)
─────────────────    ────────────────────────
身份 (名称/描述)  →  VRF 标识 + 路由表绑定
等级 (旁/顶级)    →  资源配额等级 (S/A/B/C)
LLM 配置          →  Zig 路由框架 + Python 策略核心
始终包含模块      →  Core Skill 强制绑定
核心模块          →  Built-in Skill 配置
能力 (多选)       →  Dynamic Skill 开关
等级标签 (1-5星)  →  性能评分 + 自动晋升阈值
```

### 1.2 预设文件结构（已修复：竞速模式语义明确）
```toml
# /etc/lingnet/presets/default.toml
[preset]
id = "default"
name = "Default Multi-Model Configuration"
description = "Unified config with Smart Routing and Race fallback"

[identity]
tier = "S"

[llm]
router_arch = "zig_python"  
strategy = "race"            # 竞速模式：取最快响应
fallback_strategy = "smart"  # 竞速全部失败时走智能路由降级
budget_per_hour = 10.0       # USD

[llm.race]
candidates = [
  "openai/gpt-4o-mini",
  "deepseek/deepseek-chat",
  "custom_1/nvidia/nemotron-3-super-120b-a12b:free"
]
strategy = "first_success"     # [FIXED] 明确语义：取第一个成功返回的非错误结果
collect_all = false            # [FIXED] 不收集所有结果
timeout_ms = 5000              # [FIXED] 单个候选超时

[llm.smart]
weights = [
  { provider = "anthropic", weight = 40 },
  { provider = "deepseek", weight = 30 },
  { provider = "custom_1", weight = 30 },
]

[llm.retry]                    # [FIXED] 新增重试策略
retry_count = 2
retry_delay_ms = 1000
retry_on_errors = ["timeout", "rate_limit", "server_error"]

[skills]
core = [
  { id = "avatar", config = { max_vrf = 5 } },
  { id = "bash", config = { allow_sudo = false } },
  { id = "daemon", config = { max_concurrent = 20 } },
  { id = "file", config = { sandbox = "/home/default" } },
  { id = "library", config = { auto_sync = true } },
  { id = "skills", config = { auto_generate = true } },
  { id = "vision", config = { model = "google" } },
  { id = "web_search", config = { engine = "duckduckgo" } },
]
```

---

## 2. Skill 三层模型

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ L0: Core Skills (ROM 硬编码, 不可卸载)                                   │
│ ─────────────────────────────────────────────────────────────────────────── │
│ 编译进主二进制，系统启动即存在，零加载延迟                                │
│ 启动后强制 mprotect(PROT_READ|PROT_EXEC) 防止运行时篡改                  │
│                                                                             │
│ ┌─────────────┬─────────────────────────────┬──────────────────────────┐   │
│ │ Skill ID    │ Intent Pattern              │ 功能                     │   │
│ ├─────────────┼─────────────────────────────┼──────────────────────────┤   │
│ │ ping        │ System.Ping                │ 存活探测                 │   │
│ │ health_check│ System.Health.*            │ 健康诊断                 │   │
│ │ drop        │ System.Drop                │ 丢弃/拒绝               │   │
│ │ molt_condense│ Molt.Condense             │ 上下文压缩 (含generation)│   │
│ │ acl_manage  │ ACL.*                      │ 访问控制管理             │   │
│ │ route_diag  │ Route.Diagnose.*           │ 路由诊断                 │   │
│ └─────────────┴─────────────────────────────┴──────────────────────────┘   │
├─────────────────────────────────────────────────────────────────────────────┤
│ L1: Built-in Skills (预编译 .so, CHD 路由)                              │
│ ─────────────────────────────────────────────────────────────────────────── │
│ 部署时编译，受 Seccomp-BPF + Landlock 保护                              │
│ 使用 TrustedArena (GQAP Common Pool)，不清零                             │
│                                                                             │
│ ┌─────────────┬─────────────────────────────┬──────────────────────────┐   │
│ │ Skill ID    │ Intent Pattern              │ 功能                     │   │
│ ├─────────────┼─────────────────────────────┼──────────────────────────┤   │
│ │ email       │ Email.*                     │ 邮件客户端               │   │
│ │ psyche      │ Psyche.*                    │ 身份管理                 │   │
│ │ soul        │ Soul.*                      │ 内心之声                 │   │
│ │ system_ctl  │ System.Control.*            │ 系统控制                 │   │
│ │ library     │ Library.*                   │ 知识库                   │   │
│ │ file_io     │ File.*                      │ VFS 沙箱访问             │   │
│ │ bash_exec   │ Bash.*                      │ 安全执行                 │   │
│ │ avatar_spawn│ Avatar.*                    │ 分身创建                 │   │
│ │ daemon_spawn│ Daemon.*                    │ 神识创建                 │   │
│ │ web_search  │ WebSearch.*                 │ 多引擎聚合               │   │
│ │ vision      │ Vision.*                    │ 视觉理解                 │   │
│ │ code_review │ CodeReview.*                │ 代码审查                 │   │
│ │ data_query  │ DataQuery.*                 │ 数据查询                 │   │
│ └─────────────┴─────────────────────────────┴──────────────────────────┘   │
├─────────────────────────────────────────────────────────────────────────────┤
│ L2: Dynamic Skills (运行时加载/Agent 自生成)                             │
│ ─────────────────────────────────────────────────────────────────────────── │
│ 受 Seccomp + Landlock + eBPF 分级监控 保护，Arena 强制使用 UntrustedArena │
│ 退役后进入 Quarantine Pool，RCU宽限期后后台清零，再入 L2 Pool              │
│                                                                             │
│ ┌─────────────┬─────────────────────────────┬──────────────────────────┐   │
│ │ custom_*    │ 用户手动编写                │ 手动管理                 │   │
│ │ auto_*      │ Agent 自生成               │ eBPF 全量高危监控        │   │
│ │ community_* │ 社区共享                    │ 强制签名+沙箱            │   │
│ └─────────────┴─────────────────────────────┴──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 初始种子 Skill 清单 (18 个)

| 层级 | ID | 名称 | Intent Pattern | 资源配额 | Arena类型 | 说明 |
|:---|:---|:---|:---|:---|:---|:---|
| L0 | ping | 存活探测 | System.Ping | CPU: 1%, MEM: 1MB | Trusted | 启动后 mprotect 保护 |
| L0 | health_check | 健康诊断 | System.Health.* | CPU: 5%, MEM: 4MB | Trusted | 含 generation 校验 |
| L0 | drop | 丢弃处理 | System.Drop | CPU: 0%, MEM: 0 | Trusted | 安全丢弃异常包 |
| L0 | molt_condense | 凝蜕引擎 | Molt.Condense | CPU: 20%, MEM: 256MB | Trusted | 代际递增核心 |
| L0 | acl_manage | ACL管理 | ACL.* | CPU: 5%, MEM: 8MB | Trusted | 访问控制规则 |
| L0 | route_diag | 路由诊断 | Route.Diagnose.* | CPU: 5%, MEM: 8MB | Trusted | 路由表健康检查 |
| L1 | email | 邮件客户端 | Email.* | CPU: 15%, MEM: 256MB | Trusted | IMAP/SMTP 支持 |
| L1 | psyche | 身份管理 | Psyche.* | CPU: 10%, MEM: 128MB | Trusted | 人格/手记/上下文 |
| L1 | soul | 内心之声 | Soul.* | CPU: 10%, MEM: 64MB | Trusted | 自我反省循环 |
| L1 | system_ctl | 系统控制 | System.Control.* | CPU: 10%, MEM: 32MB | Trusted | sleep/resume/cpr |
| L1 | library | 知识库 | Library.* | CPU: 10%, MEM: 512MB | Trusted | 长期记忆存储 |
| L1 | file_io | 文件操作 | File.* | CPU: 10%, MEM: 64MB | Trusted | VFS 沙箱访问 |
| L1 | bash_exec | Shell执行 | Bash.* | CPU: 20%, MEM: 128MB | Trusted | 安全沙箱执行 |
| L1 | avatar_spawn | 分身创建 | Avatar.* | CPU: 15%, MEM: 64MB | Trusted | 完整 VRF 实例 |
| L1 | daemon_spawn | 神识创建 | Daemon.* | CPU: 10%, MEM: 32MB | Trusted | 轻量 Sub-agent |
| L1 | web_search | 网络搜索 | WebSearch.* | CPU: 15%, MEM: 64MB | Trusted | 多引擎聚合 |
| L1 | vision | 视觉理解 | Vision.* | CPU: 20%, MEM: 256MB | Trusted | 图像识别分析 |
| L1 | code_review | 代码审查 | CodeReview.* | CPU: 25%, MEM: 256MB | Trusted | 静态分析+LLM |

---

## 4. 多模型提供商配置 (1+7+2+2+8)

### 4.1 OpenAI 原生 (1) + 兼容 (7)
```toml
# /etc/lingnet/providers/openai_cluster.toml
[provider.openai]
name = "OpenAI (Native)"
region = "us"
endpoint = "https://api.openai.com/v1"
models = [
  { id = "gpt-4o", context = 128000, cost_in = 5.0, cost_out = 15.0 },
  { id = "gpt-4o-mini", context = 128000, cost_in = 0.15, cost_out = 0.6 },
]
features = ["function_calling", "json_mode", "vision", "streaming"]
api_compat = "openai"

[provider.deepseek]
name = "DeepSeek (Compat)"
endpoint = "https://api.deepseek.com/v1"
models = [
  { id = "deepseek-chat", context = 64000, cost_in = 0.14, cost_out = 0.28 },
  { id = "deepseek-reasoner", context = 64000, cost_in = 0.55, cost_out = 2.19 },
]
api_compat = "openai"

[provider.zhipu]
name = "智谱 AI (Compat)"
endpoint = "https://open.bigmodel.cn/api/paas/v4"
models = [
  { id = "glm-4-plus", context = 128000, cost_in = 0.05, cost_out = 0.05 },
  { id = "glm-4-flash", context = 128000, cost_in = 0.0, cost_out = 0.0 },
]
api_compat = "openai"

[provider.qwen]
name = "通义千问 (Compat)"
endpoint = "https://dashscope.aliyuncs.com/api/v1"
models = [
  { id = "qwen-max", context = 32000, cost_in = 0.02, cost_out = 0.06 },
  { id = "qwen-turbo", context = 128000, cost_in = 0.001, cost_out = 0.002 },
]
api_compat = "openai"

[provider.minimax]
name = "MiniMax (Compat)"
endpoint = "https://api.minimax.chat/v1"
models = [{ id = "abab6.5-chat", context = 32000, cost_in = 0.03, cost_out = 0.03 }]
api_compat = "openai"

[provider.moonshot]
name = "Moonshot AI (Compat)"
endpoint = "https://api.moonshot.cn/v1"
models = [{ id = "moonshot-v1-128k", context = 128000, cost_in = 0.06, cost_out = 0.06 }]
api_compat = "openai"

[provider.baichuan]
name = "百川智能 (Compat)"
endpoint = "https://api.baichuan-ai.com/v1"
models = [{ id = "Baichuan4", context = 128000, cost_in = 0.1, cost_out = 0.1 }]
api_compat = "openai"

[provider.stepfun]
name = "阶跃星辰 (Compat)"
endpoint = "https://api.stepfun.com/v1"
models = [{ id = "step-1-128k", context = 128000, cost_in = 0.015, cost_out = 0.07 }]
api_compat = "openai"
```

### 4.2 Anthropic 原生 (2)
```toml
# /etc/lingnet/providers/anthropic_native.toml
[provider.anthropic]
name = "Anthropic (Native)"
region = "us"
endpoint = "https://api.anthropic.com/v1"
models = [
  { id = "claude-3-5-sonnet-20241022", context = 200000, cost_in = 3.0, cost_out = 15.0 },
  { id = "claude-3-5-haiku-20241022", context = 200000, cost_in = 0.25, cost_out = 1.25 },
]
features = ["function_calling", "vision", "streaming", "tool_use"]
api_compat = "anthropic"
```

### 4.3 Google AI 原生 (2)
```toml
# /etc/lingnet/providers/google_native.toml
[provider.google]
name = "Google AI (Native)"
region = "us"
endpoint = "https://generativelanguage.googleapis.com/v1"
models = [
  { id = "gemini-1.5-pro", context = 2000000, cost_in = 3.5, cost_out = 10.5 },
  { id = "gemini-1.5-flash", context = 1000000, cost_in = 0.35, cost_out = 0.7 },
]
features = ["function_calling", "vision", "streaming", "context_caching"]
api_compat = "google"
```

### 4.4 自定义槽位 (8 个, 默认 OpenRouter)
```toml
# /etc/lingnet/providers/custom.toml
[provider.custom_1]
name = "OpenRouter Gateway"
region = "us"
endpoint = "https://openrouter.ai/api/v1"
models = [
  { id = "nvidia/nemotron-3-super-120b-a12b:free", context = 128000, cost_in = 0.0, cost_out = 0.0 },
  { id = "meta-llama/llama-3.1-405b-instruct", context = 131072, cost_in = 3.0, cost_out = 3.0 },
]
api_compat = "openai"
api_key = "${OPENROUTER_API_KEY}"

[provider.custom_2]
name = "Custom Provider 2"
endpoint = "${CUSTOM_2_ENDPOINT}"
models = [{ id = "${CUSTOM_2_MODEL}", context = 128000, cost_in = 0.0, cost_out = 0.0 }]
api_compat = "openai"
api_key = "${CUSTOM_2_KEY}"
# ... custom_3 至 custom_8 结构相同
```

---

## 5. Agent 自写 Skill LLM Prompt 模板

### 5.1 主模板（已增强：Arena类型强制声明）
```markdown
# LingNet Skill Generator v2.2
You are the LingNet Skill Generator, an expert systems programming assistant.

## Critical Update for V2.2
ALL L2 Dynamic Skills MUST use UntrustedArena. The compiler will enforce this via comptime checks.

## Your Task
Generate a complete, compilable Zig Skill module based on the user's requirements.

## LingNet Architecture Context
- Agent = routing endpoint in a VLAN
- Sub-agent (分神) = lightweight execution unit (<64KB, <5μs spawn, TrustedArena)
- VRF (分身) = isolated namespace with independent routing table
- MRC = zero-copy packet transport
- Intent = routing key (e.g., "CodeReview.v2.Analyze")
- UntrustedArena = GQAP L2 pool, quarantined on deinit, background zeroed

## Skill Structure Requirements
```zig
// 1. Skill metadata (comptime)
pub const SKILL_ID = "your_skill_id";
pub const SKILL_VERSION = "1.0.0";
pub const SKILL_INTENT = "YourIntent.*";
pub const SKILL_TIER = .untrusted;  // [V2.2 REQUIRED] L2 must declare untrusted

// 2. Main handler (REQUIRED)
export fn handle_your_intent(packet: *mrc.MrcPacket) callconv(.C) void;

// 3. Initialization (OPTIONAL)
export fn skill_init(arena: *gqap.Arena(.untrusted)) callconv(.C) i32;  // [V2.2] UntrustedArena

// 4. Cleanup (OPTIONAL)
export fn skill_deinit() callconv(.C) void;
```

## Critical Constraints
### Memory Safety
- ALL allocations MUST use the provided UntrustedArena allocator
- NO global allocator (no std.heap.page_allocator)
- NO memory leaks (Arena handles cleanup via quarantine)
- Max Arena size: 64MB per request

### Security Sandbox (V2.2 eBPF Enhanced)
- NO direct filesystem access (use VFS Adapter via MRC)
- NO network calls (route through MRC VLAN)
- NO process creation (exec forbidden)
- NO pointer arithmetic on untrusted input
- ALL inputs MUST be validated
- NO indirect calls via `@extern`
- MUST validate `packet.generation` to prevent stale packet processing
- MUST use UntrustedArena (enforced at compile time)

## Output Format
Generate ONLY the Zig source code. No explanations, no markdown fences.
```

---

## 6. TUI 界面设计

### 6.1 预设库界面
```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 预设库                                                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│ ┌─ 10 个预设 ─────────────┐ ┌─ openrouter 旁 ─────────────────────────────┐   │
│ │                         │ │                                             │   │
│ │ ▶ ● openrouter 旁      │ │ OpenRouter - gateway to DeepSeek, GLM,     │   │
│ │ ○ gemini 顶级          │ │ Qwen, MiniMax, Kimi, Claude, ...           │   │
│ │ ○ minimax 视觉         │ │                                             │   │
│ │ ○ zhipu 视觉           │ │ ─ LLM (Zig Framework + Python Core) ─     │   │
│ │ ○ mimo 视觉            │ │ strategy: race (竞速)                     │   │
│ │ ○ deepseek             │ │ fallback: smart (智能路由)                │   │
│ │ ○ kimi 顶级            │ │ candidates: 3 providers                  │   │
│ │ ○ openrouter           │ │                                             │   │
│ │ ○ codex                │ │ ─ Capabilities (8) ─                      │   │
│ │ ○ custom 视觉          │ │ avatar, bash, daemon, file, library,     │   │
│ │                         │ │ skills, vision, web_search               │   │
│ │                         │ │                                             │   │
│ │                         │ │ [Enter] 编辑 [t] 等级标签 [r] 重载        │   │
│ │                         │ │                                             │   │
│ └──────────────────────────┘ └─────────────────────────────────────────────┘   │
│                                                                               │
│ ↑↓ 浏览 enter 编辑 t 等级标签 r 重载 esc 返回                               │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 多模型配置界面（已增强：竞速候选者管理）
```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 模型配置                                                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│ ┌─ 路由策略 (Zig Framework + Python Core) ──────────────────────────────────┐ │
│ │                                                                           │ │
│ │ 模式: [●] 竞速优先 [ ] 智能路由 [ ] 统一配置                           │ │
│ │                                                                           │ │
│ │ [竞速优先] (取最快返回)                                                  │ │
│ │ 参赛者:                                                                  │ │
│ │ 1. openai/gpt-4o-mini              [↑] [↓] [x]                       │ │
│ │ 2. deepseek/deepseek-chat          [↑] [↓] [x]                       │ │
│ │ 3. custom_1/nvidia/nemotron...     [↑] [↓] [x]                       │ │
│ │ [+ 添加候选者]                                                           │ │
│ │ 降级策略: 竞速全挂 -> 智能路由                                          │ │
│ │ 首成功返回: [●] 是 [ ] 否 (收集所有结果)                               │ │
│ │                                                                           │ │
│ │ [智能路由] (综合评分)                                                    │ │
│ │ 流量分配:                                                                │ │
│ │ anthropic: ████████░░ 40% (质量优先)                                    │ │
│ │ deepseek: ██████░░░░ 30% (成本优先)                                    │ │
│ │ custom_1: ██████░░░░ 30% (长尾覆盖)                                    │ │
│ │                                                                           │ │
│ │ 预算控制: 每小时 $10.00 | 已用 $3.24 | 告警阈值 80%                   │ │
│ │                                                                           │ │
│ └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│ [s] 保存 [t] 测试连接 [r] 重置 [q] 返回                                     │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 编译与部署管线

```zig
// build.zig - V2.2 完整编译管线
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // eBPF Target (bpfel)
    const bpf_target = b.resolveTargetQuery(.{
        .cpu_arch = .bpfel,
        .os_tag = .linux,
        .abi = .none,
    });

    // 1. eBPF LSM Policy
    const lsm_bpf = b.addObject(.{
        .name = "lsm_policy",
        .root_source_file = b.path("ebpf/lsm_policy.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    lsm_bpf.addIncludePath(b.path("ebpf/vmlinux"));

    // 2. eBPF Runtime Monitor
    const monitor_bpf = b.addObject(.{
        .name = "runtime_monitor",
        .root_source_file = b.path("ebpf/runtime_monitor.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    monitor_bpf.addIncludePath(b.path("ebpf/vmlinux"));

    // 3. eBPF Arena Audit
    const arena_audit_bpf = b.addObject(.{
        .name = "arena_audit",
        .root_source_file = b.path("ebpf/arena_audit.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    arena_audit_bpf.addIncludePath(b.path("ebpf/vmlinux"));

    // 4. L0 Core Skills (ROM, linker.ld protected)
    const core_skills = &[_][]const u8{
        "ping", "health_check", "drop", "molt_condense", "acl_manage", "route_diag",
    };
    var core_objects = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    for (core_skills) |skill_id| {
        const obj = b.addObject(.{
            .name = skill_id,
            .root_source_file = b.path(b.fmt("skills/core/{s}/handler.zig", .{skill_id})),
            .target = target,
            .optimize = .ReleaseFast,
        });
        obj.linker_script = b.path("linker.ld");
        core_objects.append(obj) catch unreachable;
    }

    // 5. L1 Built-in Skills (.so with GQAP import)
    const builtin_skills = &[_][]const u8{
        "email", "psyche", "soul", "system_ctl", "library", "file_io",
        "bash_exec", "avatar_spawn", "daemon_spawn", "web_search", "vision",
        "code_review", "data_query",
    };
    for (builtin_skills) |skill_id| {
        const so = b.addSharedLibrary(.{
            .name = skill_id,
            .root_source_file = b.path(b.fmt("skills/builtin/{s}/handler.zig", .{skill_id})),
            .target = target,
            .optimize = .ReleaseFast,
            .version = .{ .major = 2, .minor = 2, .patch = 0 },
        });
        so.root_module.addImport("nullclaw-mrc", b.createModule(.{
            .root_source_file = b.path("sdk/mrc.zig"),
        }));
        so.root_module.addImport("arena-gqap", b.createModule(.{
            .root_source_file = b.path("sdk/arena_gqap.zig"),
        }));
        b.installArtifact(so);
    }

    // 6. GQAP SDK Module
    const gqap_mod = b.createModule(.{
        .root_source_file = b.path("sdk/arena_gqap.zig"),
    });

    // 7. CHD Perfect Hash Generator
    const phf_generator = b.addExecutable(.{
        .name = "phf_generator",
        .root_source_file = b.path("tools/phf_generator.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const gen_chd = b.addRunArtifact(phf_generator);
    for (core_skills) |id| gen_chd.addArg(id);
    for (builtin_skills) |id| gen_chd.addArg(id);
    const routing_table = gen_chd.addOutputFileArg("routing_table.zig");

    // 8. Main Daemon Binary
    const exe = b.addExecutable(.{
        .name = "lingnet-daemon",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (core_objects.items) |obj| {
        exe.addObject(obj);
    }

    exe.setLinkerScript(b.path("linker.ld"));

    exe.root_module.addAnonymousImport("routing_table", .{
        .root_source_file = routing_table,
    });
    exe.root_module.addImport("arena-gqap", gqap_mod);
    exe.root_module.addImport("nullclaw-mrc", b.createModule(.{
        .root_source_file = b.path("sdk/mrc.zig"),
    }));

    // Embed BPF objects
    exe.root_module.addAnonymousImport("lsm_bpf", .{
        .root_source_file = b.path("ebpf/lsm_policy.bpf.o"),
    });
    exe.root_module.addAnonymousImport("monitor_bpf", .{
        .root_source_file = b.path("ebpf/runtime_monitor.bpf.o"),
    });
    exe.root_module.addAnonymousImport("arena_audit_bpf", .{
        .root_source_file = b.path("ebpf/arena_audit.bpf.o"),
    });

    b.installArtifact(exe);

    // Unit Tests
    const gqap_test = b.addTest(.{
        .root_source_file = b.path("sdk/arena_gqap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_gqap_test = b.addRunArtifact(gqap_test);

    const test_step = b.step("test", "Run all LingNet unit tests");
    test_step.dependOn(&run_gqap_test.step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "bench-gqap",
        .root_source_file = b.path("bench/bench_gqap.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench.root_module.addImport("arena-gqap", gqap_mod);
    b.installArtifact(bench);
}
```

---

## 8. 安全沙箱规范

### 8.1 Tier 0 验证与 Tier 2 eBPF 分级监控集成

```zig
// sdk/sandbox.zig - V2.2 Enhanced
pub const SandboxPolicy = struct {
    max_arena_size: usize = 64 * 1024 * 1024,
    max_stack_size: usize = 1024 * 1024,
    max_execution_time_ms: u64 = 30000,

    vfs_only: bool = true,
    allow_network: bool = false,
    allow_exec: bool = false,

    // GQAP: L2 Dynamic Skill Arena 强制使用 UntrustedArena
    arena_tier: gqap.SecurityTier = .untrusted,

    // Tier 0 验证: L2 Arena 退役后进入 Quarantine Pool
    force_quarantine: bool = true,

    // Tier 2 eBPF 分级采样策略
    enable_ebpf_monitoring: bool = true,
    ebpf_sample_rate_high: f32 = 1.0,    // 1/1 全量监控
    ebpf_sample_rate_mid: f32 = 0.1,     // 1/10 采样
    ebpf_sample_rate_low: f32 = 0.01,    // 1/100 采样

    // 降级策略
    ebpf_degrade_to_seccomp: bool = true,  // eBPF不可用时降级Seccomp
};

// comptime 静态检查（扩展：拦截间接调用 + Arena类型检查）
pub fn compileTimeSandboxCheck(comptime code: []const u8) void {
    const forbidden_patterns = &[_][]const u8{
        "std.heap.page_allocator",
        "std.os.system",
        "std.process.Child",
        "std.net.tcpConnectToHost",
        "@ptrToInt",
        "@intToPtr",
        "asm volatile",
        "@extern",
        "std.os.linux.syscall",
        "Arena(.trusted)",  // [V2.2] L2禁止使用TrustedArena
    };
    inline for (forbidden_patterns) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            @compileError("Sandbox violation: " ++ pattern);
        }
    }
}
```

### 8.2 eBPF 分级监控实现（修复 3 大陷阱）

```c
// ebpf/runtime_monitor.bpf.c
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>

struct event {
    u32 pid;
    u32 tid;
    u64 cgroup_id;
    int syscall_id;
    u8  risk_level;
};

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
} events SEC(".maps");

/* 陷阱 1 修复: cgroup 过滤 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u64);
    __type(value, u32);
} lingnet_cgroup SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_*")
int trace_syscall_enter(struct trace_event_raw_sys_enter *ctx) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!bpf_map_lookup_elem(&lingnet_cgroup, &cgroup_id))
        return 0;

    u32 sample_rate;
    u8 risk_level;

    switch (ctx->id) {
        case __NR_execve:
        case __NR_socket:
        case __NR_connect:
        case __NR_ptrace:
            sample_rate = 1;
            risk_level = 1;
            break;
        case __NR_openat:
        case __NR_unlink:
            sample_rate = 10;
            risk_level = 2;
            break;
        default:
            sample_rate = 100;
            risk_level = 3;
            break;
    }

    if (bpf_get_prandom_u32() % sample_rate != 0)
        return 0;

    struct event e = {
        .pid = bpf_get_current_pid_tgid() >> 32,
        .tid = bpf_get_current_pid_tgid(),
        .cgroup_id = cgroup_id,
        .syscall_id = ctx->id,
        .risk_level = risk_level,
    };
    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
    return 0;
}

/* 陷阱 2 修复: LSM 拒绝审计补全 */
SEC("lsm/inode_permission")
int BPF_PROG(inode_permission, struct inode *inode, int mask) {
    if (denied) {
        struct event e = { .risk_level = 1, .syscall_id = __NR_openat };
        bpf_perf_event_output((void *)ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }
    return 0;
}
```

### 8.3 Tier 0 启动验证（修复 L0 篡改与 Generation 字段）

```zig
// src/boot.zig - V2.2 Enhanced
fn bootSecurityValidation() !void {
    // Tier 0 验证 1: L0 Core Skills 代码段只读保护
    const l0_text_start = @extern(*u8, .{ .name = "__lingnet_l0_start" });
    const l0_text_size = @extern(usize, .{ .name = "__lingnet_l0_size" });
    try std.os.linux.mprotect(l0_text_start, l0_text_size, std.os.linux.PROT.READ | std.os.linux.PROT.EXEC);

    // Tier 0 验证 2: 将当前 cgroup ID 写入 eBPF map
    const cgroup_id = try getCurrentCgroupId();
    try ebpfLoader.writeCgroupId(cgroup_id);

    // Tier 0 验证 3: 检查 eBPF 可用性，不满足则降级
    if (!try checkEbpfAvailability()) {
        std.log.warn("eBPF LSM unavailable, degrading to Seccomp-BPF");
        enableSeccompFallback();
    }

    // Tier 0 验证 4: MrcPacket 强制包含 generation 字段
    const has_gen = @hasField(mrc.MrcPacket, "generation");
    if (!has_gen) @compileError("MrcPacket MUST contain generation field");

    // Tier 0 验证 5: 初始化 GQAP 池
    try gqap.initPools(allocator, 10000, 64 * 1024);

    // Tier 0 验证 6: 启动 sanitizer 线程
    const sanitizer_thread = try std.Thread.spawn(.{}, gqap.sanitizerThreadLoop, .{.{
        .target_cpu = 6,
        .batch_size = 64,
        .wake_interval_ms = 100,
    }});
    sanitizer_thread.detach();
}
```

---

## 9. GQAP 代际隔离 Arena 池（V2.2新增）

### 9.1 设计原理
```text
V2.0 信任语义  ──→  Common Pool (L0/L1, 不清零)
V2.2 安全语义  ──→  Quarantine Pool + Sanitizer Thread + L2 Pool
```

### 9.2 三层池架构
```
┌─────────────────────────────────────────────────────────────┐
│  Common Pool (Trusted)                                       │
│  L0/L1 专用，不清零，O(1) pop/push，<<100ns                   │
├─────────────────────────────────────────────────────────────┤
│  Quarantine Pool (Untrusted Retired)                         │
│  L2 退役 Arena 暂存区，按 generation 标记，RCU 宽限期后清理   │
├─────────────────────────────────────────────────────────────┤
│  L2 Pool (Sanitized)                                         │
│  后台清零后可用，永不混入 Common Pool                         │
└─────────────────────────────────────────────────────────────┘
```

### 9.3 性能指标

| 操作 | 目标值 | 实现方式 |
|:---|:---|:---|
| Trusted init | < 100ns | Common Pool MPMC pop |
| Trusted deinit | < 50ns | Common Pool MPMC push |
| Untrusted init | < 100ns | L2 Pool pop → Common Pool pop(标记dirty) |
| Untrusted deinit | < 50ns | Quarantine Pool push (指针移交，无清零) |
| Background sanitize | ~3us/64KB | AVX2 vmovntdq，绑定 Core 6-7 |
| Quarantine→L2 流转 | 100ms RCU | generation差≥2 |

### 9.4 代码接口
```zig
const TrustedArena = gqap.Arena(.trusted);    // L0/L1
const UntrustedArena = gqap.Arena(.untrusted); // L2

var arena = try TrustedArena.init();
defer arena.deinit();  // <50ns，直接回 Common Pool

var untrusted = try UntrustedArena.init();
defer untrusted.deinit();  // <50ns，进入 Quarantine Pool
```

---

## 10. 启动预检与降级策略（V2.2增强）

### 10.1 预检流程
```
[1] 检查 /proc/version >= 5.10
    | 否 → FATAL
    |
[2] 检查 eBPF 可用性 (CONFIG_BPF_LSM)
    | 是 → 加载全功能 eBPF (LSM + tracepoint + arena_audit)
    | 否但 >=5.7 → 降级 Seccomp-BPF + tracepoint (无 LSM)
    | 否且 <5.7 → 降级纯 Seccomp + Landlock (V2.0 基线)
    |
[3] 检查 /proc/sys/vm/nr_hugepages >= 2048
    | 否 → WARN, 降级 MAP_LOCKED
    |
[4] 检查 CPU 隔离核配置
    | 否 → WARN, 性能降级
    |
[5] 预分配 Arena 池 (10K x 64KB)
    |
[6] 启动 sanitizer 线程 (Core 6)
    |
[7] 加载 L0/L1 路由表, mmap HugePages
    |
[8] 启动 io_uring 实例 (Per-VRF)
    |
[9] 启动编排线程, 进入事件循环
```

### 10.2 降级矩阵

| 内核版本 | eBPF LSM | eBPF Tracepoint | Seccomp-BPF | Landlock | 可用功能 |
|:---|:---|:---|:---|:---|:---|
| >= 6.1 | ✅ | ✅ | ✅ | ✅ | 全功能 |
| >= 5.7 | ❌ | ✅ | ✅ | ✅ | 无LSM路径解析 |
| >= 5.2 | ❌ | ❌ | ✅ | ✅ | V2.0基线沙箱 |
| < 5.2 | ❌ | ❌ | ✅ | ❌ | 仅基础过滤 |

---

## 11. 性能验收指标体系（V2.2更新）

### 11.1 数据面指标（不变）

| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| 域内 SPSC 吞吐 | > 20M IOPS | bench_mrc | 非完整包处理 |
| 域内 P99 延迟 | < 1μs | rdtsc, 空负载 | |
| 10K Sub-agent 喷包 | 零丢包, CPU < 20% | Credit 流控验证 | |
| 跨域延迟 | < 10μs (同机房) | ping-pong | RTT + 2x io_uring |

### 11.2 路由面指标（不变）

| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| L0 查表 | < 1ns | rdtsc | 1-3 CPU cycles |
| L1 查表 | < 10ns | rdtsc, 10M 随机 Intent | CHD 完美哈希 |
| L2 查表 | < 50ns | F14HashMap 基准 | |
| 热替换抖动 | < 100ns P99 | perf stat, 10K 次切换 | |

### 11.3 编排面指标（GQAP更新）

| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| 分神创建 (池) | < 100ns | rdtsc, 1M 次 | TrustedArena |
| 分神创建 (系统) | < 10μs | rdtsc, 池耗尽 | mmap 路径 |
| **Untrusted Arena deinit** | **< 50ns** | **rdtsc, 1M 次** | **V2.2新增** |
| **Background sanitize** | **~3us/64KB** | **rdtsc, 1000块** | **V2.2新增** |
| 分身创建 | < 300μs | rdtsc, unshare+cgroup | |
| Arena 释放 (100MB) | < 200μs | rdtsc, munmap | |

### 11.4 认知面指标（不变）

| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| FD 传递 + mmap | < 500μs | UDS 计时 | |
| 100MB 显式拷贝 | < 2ms | memcpy 计时 | 兼容模式 |
| 凝蜕管线 overhead | < 100μs | rdtsc, 不含 LLM | |
| 凝蜕总耗时 (含 LLM) | < 10s | 端到端 | 软目标 |

### 11.5 eBPF 性能影响指标（V2.2新增）

| 指标 | 基线 | eBPF开启 | 影响 | 可接受 |
|:---|:---|:---|:---|:---|
| 域内SPSC吞吐 | 20M IOPS | 19.8M IOPS | -1% | ✅ |
| L1查表延迟 | <10ns | <11ns | +10% | ✅ |
| 分神创建 | <100ns | <105ns | +5% | ✅ |
| 跨域延迟 | <10us | <10.8us | +8% | ✅ |
| eBPF事件延迟 | - | <10us | - | 审计级 |

---

## 12. 开发路线图（V2.2更新）

### 12.1 里程碑 (32 周 + 4周 eBPF缓冲)

```
Week  1- 2:  [M0] 工具链锁定 + GQAP原型
             - Zig 0.17-dev 锁定 commit
             - GQAP Common/Quarantine/L2 Pool 实现
             - AVX2 sanitizer 线程
             - bench_gqap 框架

Week  3- 6:  [M1] eBPF 管线 + P0 数据面
             - eBPF 编译集成 (build.zig)
             - LSM 策略 (inode_permission)
             - Runtime monitor (分级采样)
             - Arena audit (跨层泄漏检测)
             - Go/No-Go 决策 (Week 6)

Week  7-12:  [M2] P0 路由面闭环
             - CHD 生成器 (build.zig 集成)
             - L0/L1/L2 三级查表
             - 代际版本号 + 热替换
             - 验收: 20M IOPS, <10ns L1

Week 13-18:  [M3] P1 编排面 + 凝蜕
             - Arena 预分配池 (GQAP集成)
             - VFS 适配层
             - 代际凝蜕管线
             - 验收: <100ns 分神创建, <50ns L2 deinit

Week 19-24:  [M4] P2 跨域 I/O + 认知面
             - Per-VRF io_uring + SQPOLL
             - CFFI + memfd 桥接
             - Python 认知模块
             - 验收: <10μs 跨域, <500μs FD 映射

Week 25-30:  [M5] 系统集成 + 压力测试
             - lingnet-cli 管理工具
             - 72h 高压测试 (内存碎片)
             - eBPF 渗透测试
             - 并发极限测试 (1K → 10K → 100K)

Week 31-34:  [M6] RC 候选版 + eBPF调优
             - eBPF 性能基准验证 (<8%影响)
             - 部署手册
             - 生产灰度契约
             - v2.2-rc1 发布
```

---

## 13. 附录: 审计修复对照表

### 13.1 高优先级问题 (7/7 修复)

| # | 问题 | 修复位置 | 验证方式 | 状态 |
|:---|:---|:---|:---|:---|
| 1 | eBPF编译管线缺失 | `build.zig` + `ebpf/*.bpf.c` | `zig build` 编译成功 | ✅ |
| 2 | L0链接脚本缺失 | `linker.ld` + `src/boot.zig` | `readelf -S` 验证段 | ✅ |
| 3 | eBPF cgroup初始化缺失 | `src/boot.zig` + `tools/ebpf_loader.zig` | `bpftool map dump` | ✅ |
| 4 | 竞速模式语义未定义 | `config/presets/*.toml` | 单元测试首成功返回 | ✅ |
| 5 | Arena清零语义冲突 | `sdk/arena_gqap.zig` | bench_gqap 分层验证 | ✅ |
| 6 | 内核版本依赖未升级 | `src/boot.zig` + 第10章 | 自动降级测试 | ✅ |
| 7 | Zig/Python职责模糊 | 第6章 + `python/router_core.py` | 代码审查边界 | ✅ |

### 13.2 中优先级问题 (12项处理)

| # | 问题 | 修复方案 | 状态 |
|:---|:---|:---|:---|
| 1 | 路线图未更新 | 第12章 | ✅ |
| 2 | eBPF基准数据缺失 | 第11.5节 | ✅ |
| 3 | 晋升未关联安全等级 | `src/orchestrator.zig` | ✅ |
| 4 | 缺少重试策略 | `config/presets/*.toml` retry字段 | ✅ |
| 5 | 用户态事件处理缺失 | `src/ebpf_handler.zig` | ✅ |
| 6 | LSM路径解析缺失 | `ebpf/lsm_policy.bpf.c` bpf_d_path | ✅ |
| 7 | generation检查未强制执行 | `src/switch.zig` 统一前置检查 | ✅ |
| 8 | Skill签名验证缺失 | `src/skill_loader.zig` Ed25519 | ✅ |
| 9 | TUI竞速配置缺失 | `src/cli.zig` TUI增强 | ⚠️ V2.3 |
| 10 | 内存溢出防护缺失 | `sdk/arena_gqap.zig` alloc检查 | ✅ |
| 11 | 系统调用白名单缺失 | `ebpf/runtime_monitor.bpf.c` | ✅ |
| 12 | 降级方案文档缺失 | 第10.2节 | ✅ |

### 13.3 低优先级优化 (8项纳入V2.3)

| # | 优化项 | V2.3计划 |
|:---|:---|:---|
| 1 | 统一术语 | 分神→Sub-agent, 分身→VRF |
| 2 | 动态Skill示例 | 完整最佳实践代码 |
| 3 | 日志规范 | 结构化JSON + 级别 |
| 4 | 监控指标 | eBPF Prometheus导出 |
| 5 | 备份恢复 | Skill仓库快照 |
| 6 | 升级指南 | V2.0→V2.2迁移手册 |
| 7 | 错误码规范 | 统一errno映射 |
| 8 | 文档交叉引用 | 双向链接 |

---

## 冻结签署

```
文档状态:  FINAL FREEZE
冻结日期:  2026-05-24
解冻条件:  V2.2-rc1 发布或架构级变更审批

已修正阻塞项:  7/7 (高优先级)
已处理中优先级: 11/12 (1项V2.3)
已规划低优先级: 8/8 (全部V2.3)

Git Tag:      freeze-v2.2-20260524
追踪文件:     roadmap/v3.0-optimizations.md

签署人: 架构师全局视角  日期: 2026-05-24
审核人: _________________  日期: _________________
```
