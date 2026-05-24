# LingNet Agent OS V2.2 完整技术规格书（合并版）
**文档版本**: v2.2-merged-20260524  
**基线**: V2.0-freeze-20260523  
**主版本**: V2.2 (扩展层叠加，冲突以 V2.2 为准)  
**核心依赖**: Zig 0.17, Python 3.12+ (nogil), Linux 6.1+  
---
## 目录
1. [设计哲学与系统定位](#1-设计哲学与系统定位)
2. [五层架构总览](#2-五层架构总览)
3. [Layer 0: Linux 内核基座](#3-layer-0-linux-内核基座)
4. [Layer 1: 数据面 (nullclaw-mrc)](#4-layer-1-数据面-nullclaw-mrc)
5. [Layer 2: 交换路由面 (nullclaw-switch)](#5-layer-2-交换路由面-nullclaw-switch)
6. [Layer 3: 编排控制面 (lingnet-orchestrator)](#6-layer-3-编排控制面-lingnet-orchestrator)
7. [Layer 4: 认知计算面 (lingnet-cognitive)](#7-layer-4-认知计算面-lingnet-cognitive)
8. [系统集成与运维 (lingnet-cli)](#8-系统集成与运维-lingnet-cli)
9. [性能验收指标体系](#9-性能验收指标体系)
10. [开发路线图](#10-开发路线图)
11. [风险管理与备案策略](#11-风险管理与备案策略)
12. [附录: 方案对比与兼容性矩阵](#12-附录-方案对比与兼容性矩阵)
---
## 1. 设计哲学与系统定位
### 1.1 核心范式转换
```text
传统 OS 模型               LingNet 模型
---------------            -----------------
进程-文件-图灵机     -->    路由-交换-网络流
独立内存沙箱         -->    路由表端点
进程间通信(IPC)      -->    零拷贝内存帧传递
调度器抢占           -->    Credit 流控反压
```
### 1.2 版本策略
```text
首选路径: Zig 0.17 (正式版发布后解冻)
  |
  |-- 锁定 commit hash: 0.17.0-dev.329+ (当前)
  |-- 核心 comptime 逻辑以单元测试为唯一真理源
  |
备案路径: Zig 0.16.0 + 独立 libxev
  |
  |-- 触发条件: 0.17 延迟 > 3个月 或 实验性 bug 阻塞
  |-- 影响: +2周适配, io_uring 抽象层重写
  |-- L1 查表延迟: 10ns (不变, comptime 0.16 已支持)
  |
V2.2 扩展: eBPF + GQAP + 多模型路由
  |
  |-- eBPF: Linux >= 5.7, 推荐 6.1+
  |-- GQAP: AVX2 推荐, SSE2 兼容
  |-- 降级: <6.1 自动回退 Seccomp-BPF
```
### 1.3 关键术语统一
| V2.0 术语 | V2.2 术语 | 统一后术语 | 说明 |
|:---|:---|:---|:---|
| 分神 | Sub-agent | **Sub-agent** | 轻量执行单元 (<64KB) |
| 分身 | VRF | **VRF** | 隔离命名空间+独立路由表 |
| 凝蜕 | Molt Condense | **Molt/Condense** | 上下文压缩+代际递增 |
| 神识 | Daemon | **Daemon** | 后台持久化进程 |
| 内心之声 | Soul | **Soul** | 自我反省循环 Skill |
---
## 2. 五层架构总览
```text
================================================================================
[ 外部世界 ]
  |
  +--------------+--------------+
  | Agent 客户端 / CLI           |
  +--------------+--------------+
  |
================================================================================
Layer 4: 认知计算面 (Cognitive Plane)
---------------------------------------
  | [Molt Condenser 凝蜕引擎]
  |   - LLM 上下文提炼
  |   - 离散页传递 / 显式受控拷贝
  |   - 管线 overhead < 100μs
  |
  | [Suggestion Advisor 建议器]
  |   - 镜像流量分析
  |   - 生成 Suggestion Intent
  |
  | [Multi-Model Router 多模型路由]              ★ V2.2
  |   - Zig 框架: 配置验证 + MRC 路由
  |   - Python 核心: HTTP 客户端 + 策略引擎
  |   - 竞速模式: 首成功返回 <2s
  |   - 智能路由: 加权分配 P99 <3s
  |   - 统一配置: Agent 独立覆盖全局
  |
  | 语言: Python 3.12+ (nogil 实验性)
  | 接口: CFFI + memfd + Unix Domain Socket
  +----------- C FFI / 共享内存边界 -----------+
================================================================================
Layer 3: 编排控制面 (Orchestration Plane)
-----------------------------------------
  | [VFS Adapter 虚拟文件适配器]
  |   - open/read/write -> VLAN 路由
  |   - lseek -> ESPIPE (显式拒绝)
  |   - Stream FD / Mmap FD 语义隔离
  |
  | [Lifecycle Manager 生命周期管理]
  |   - Arena 预分配池 (10K x 64KB)
  |   - 分神创建 < 100ns (池) / < 10μs (系统)
  |   - 分身 VRF 创建 < 300μs
  |   - cgroups v2 硬隔离
  |
  | [GQAP Arena Manager]                          ★ V2.2
  |   - Common Pool: L0/L1 Trusted (不清零)
  |   - Quarantine Pool: L2 Retired (待清理)
  |   - L2 Pool: Sanitized Reuse (已清零)
  |   - Sanitizer Thread: Core 6-7 专用
  |   - AVX2 Zeroing: ~3us/64KB
  |
  | 语言: Zig 0.17 / 0.16 备案
  | 接口: Native Zig API + TOML comptime
  +----------- 原子指针 / 代际版本号 -----------+
================================================================================
Layer 2: 交换路由面 (Switching Plane)
-------------------------------------
  | [SDN Route Table 意图路由表]
  |   +-------------------------------+
  |   | L0: ROM 硬编码 < 1ns         |
  |   | ~16 系统保留 Intent           |
  |   | mprotect(PROT_READ|PROT_EXEC)|  ★ V2.2
  |   +-------------------------------+
  |   | L1: CHD 完美哈希 < 10ns      |
  |   | ~1,000 预编译 Intent          |
  |   | 编译期生成, mmap HugePages    |
  |   +-------------------------------+
  |   | L2: F14HashMap ~50ns         |
  |   | 无上限, 通配符 Trie, 自动晋升 |
  |   +-------------------------------+
  |
  | [ACL Firewall + Generation]
  |   - VLAN 微分段隔离
  |   - 代际版本号: 凝蜕零阻断
  |   - 热替换: 原子指针 + RCU 宽限期
  |   - 抖动 < 100ns P99
  |   - 全路径 generation 强制检查     ★ V2.2
  |
  | 语言: Zig 0.17 / 0.16 备案
  | 接口: 函数指针内联调用 (零分支)
  +----------- Ring Buffer 指针传递 -----------+
================================================================================
Layer 1: 数据传输面 (Data Plane)
--------------------------------
  | [MRC Multipath Engine]
  |   - SPSC Ring Buffer (HugePages)
  |   - Ready-List MPMC 事件聚合
  |   - Credit-based 流控 (64包/10μs)
  |   - 域内: 纯用户态, P99 < 1μs
  |
  | [libxev + io_uring]
  |   - 域间: Per-VRF io_uring 实例
  |   - SQPOLL 内核线程代劳提交
  |   - Linux 6.1+ 推荐
  |
  | 语言: Zig 0.17 / 0.16 备案
  | 接口: @atomicRmw / @atomicLoad/Store
  +----------- mmap / memfd / io_uring -----------+
================================================================================
Layer 0: Linux 内核基座 (Kernel Base)
-------------------------------------
  | - io_uring: 异步 I/O 框架
  | - HugePages: 2MB/1GB, TLB 优化
  | - cgroups v2: CPU/内存硬隔离
  | - memfd_create: 跨进程 FD 传递
  | - unshare: 命名空间隔离
  | - eBPF: LSM + Tracepoint + Arena审计       ★ V2.2
  |   分级采样: 高危1/1, 中危1/10, 低危1/100
  |   LSM: inode_permission, file_open
  |   Arena Audit: 跨层泄漏检测
  |
  | 版本: 5.10+ (推荐 6.1+)
  | 配置: HugePages 预分配, CPU 隔离核
  | 降级: <6.1 自动降级 Seccomp-BPF            ★ V2.2
================================================================================
```
---
## 3. Layer 0: Linux 内核基座
### 3.1 内核版本矩阵
| 功能 | 最低版本 | 推荐版本 | 说明 |
|:---|:---|:---|:---|
| io_uring | 5.1 | 6.1+ | 6.1 引入 SQPOLL 稳定支持 |
| io_uring_clone_buffers | 6.12 | 6.12+ | 跨进程缓冲区克隆优化 |
| cgroups v2 | 5.2 | 6.1+ | 统一层级, 无 v1 兼容负担 |
| memfd_create | 3.17 | - | 长期稳定 |
| HugePages 1GB | 2.6.38 | - | 需 BIOS 支持 |
| **eBPF LSM** | **5.7** | **6.1+** | **V2.2: Skill 文件/进程强制访问控制** |
| **eBPF Tracepoint** | **4.7** | **5.10+** | **V2.2: 运行时行为分级监控** |
| **Landlock** | **5.13** | **6.1+** | **V2.2: Skill 文件系统路径沙箱** |
### 3.2 系统配置模板
```bash
# /etc/sysctl.d/99-lingnet.conf
vm.nr_hugepages = 2048          # 4GB = 2048 x 2MB
vm.nr_overcommit_hugepages = 512 # 应急超额
vm.hugetlb_shm_group = 1001     # lingnet 用户组
vm.swappiness = 1               # 最小交换
# /etc/systemd/system/lingnet-daemon.service
[Unit]
Description=LingNet Agent OS
After=network.target
[Service]
Type=simple
ExecStart=/opt/lingnet/bin/lingnet-daemon
Restart=always
# 资源隔离
LimitMEMLOCK=infinity
CPUAffinity=2-7       # 隔离数据面核心 (0-1 留给系统)
MemoryLimit=14G       # 16G 总内存, 留 2G 给系统
# cgroups v2 委托
Delegate=cpu cpuset io memory pids
[Install]
WantedBy=multi-user.target
```
### 3.3 V2.2 安全基座: eBPF 分级监控
```c
// tools/ebpf/skill_monitor.bpf.c
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
struct event {
    u32 pid;
    u32 tid;
    u64 cgroup_id;
    int syscall_id;
    u8  risk_level; // 1=High, 2=Mid, 3=Low
};
struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
} events SEC(".maps");
// 陷阱1修复: cgroup 过滤, 只监控 LingNet 进程树
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
    // 陷阱3修复: 分级采样 (废弃 1/100 均匀采样)
    switch (ctx->id) {
        case __NR_execve:      // 高危: 进程创建
        case __NR_socket:      // 高危: 网络套接字
        case __NR_connect:     // 高危: 外部连接
        case __NR_ptrace:      // 高危: 调试
            sample_rate = 1;   // 1/1 全量监控
            risk_level = 1;
            break;
        case __NR_openat:      // 中危: 文件打开
        case __NR_unlink:      // 中危: 文件删除
            sample_rate = 10;  // 1/10 采样
            risk_level = 2;
            break;
        default:               // 低危: 其他调用
            sample_rate = 100; // 1/100 采样
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
// 陷阱2修复: LSM 拒绝审计补全
SEC("lsm/inode_permission")
int BPF_PROG(inode_permission, struct inode *inode, int mask) {
    // LSM 拦截逻辑...
    if (denied) {
        struct event e = { .risk_level = 1, .syscall_id = __NR_openat };
        bpf_perf_event_output((void *)ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }
    return 0;
}
```
---
## 4. Layer 1: 数据面 (nullclaw-mrc)
### 4.1 域内通信: SPSC Ring Buffer
```text
内存布局 (单条 Ring Buffer, 缓存行对齐):
+-----------------------------------------------------------+
| head: u64 (生产者写入索引) [@alignTo(64)]                  |
| pad: [56]u8 (填充至 64 字节, 防伪共享)                    |
+-----------------------------------------------------------+
| tail: u64 (消费者读取索引) [@alignTo(64)]                  |
| pad: [56]u8                                               |
+-----------------------------------------------------------+
| buffer: [CAPACITY]MrcPacketPtr (指针数组)                 |
| 每个元素: { ptr: *u8, len: u32, generation: u64 }         |
+-----------------------------------------------------------+
生产者入队 (无锁):
  1. 读取 head (atomic load acquire)
  2. 检查 (head + 1) % CAPACITY != tail (无满)
  3. 写入 packet ptr 到 buffer[head]
  4. @atomicStore(head, new_head, release)
消费者出队 (无锁):
  1. 读取 tail (atomic load acquire)
  2. 检查 tail != head (非空)
  3. 读取 buffer[tail] (指针拷贝)
  4. @atomicStore(tail, new_tail, release)
```
### 4.2 Ready-List 事件聚合
```text
全局 Ready-List 结构 (Per-CPU 分片, 避免 MPMC 争用):
CPU Core 0: [SPSC Ready-List 0] <-- 生产者 0-N 推送
CPU Core 1: [SPSC Ready-List 1] <-- 生产者 0-N 推送
CPU Core 2: [SPSC Ready-List 2] <-- 生产者 0-N 推送
...
CPU Core N: [SPSC Ready-List N] <-- 生产者 0-N 推送
  |
  v
[消费者线程批量轮询所有 Ready-List]
  |
  v
[按优先级/时间顺序消费对应 Ring Buffer]
推送路径 (生产者):
  1. 写入本地 SPSC Ring Buffer
  2. @atomicRmw 推送 QueueID 到所属 CPU 的 Ready-List
  3. 若消费者休眠, 发送 IPI (Inter-Processor Interrupt) 唤醒
轮询路径 (消费者):
  1. for each cpu_ready_list in cpu_affinity:
       if ready_list.pop() -> |queue_id|:
         process_queue(queue_id, batch_size=64)
  2. 若全部空, 进入 monitor/mwait 或 sched_yield
```
### 4.3 Credit-based 流控
```text
Credit 状态机:
+------------+
| Running    | <-- 正常发送, 本地缓存 Credit 消耗
+------------+
  |
  | Credit 耗尽 (本地计数归零)
  v
+------------+
| Awaiting   | <-- 停止入队, 等待 Credit 回包
| Credit     |
+------------+
  |
  | 收到 Credit 回包 或 10μs 超时
  v
+------------+
| Running    | <-- 恢复发送
+------------+
双触发条件 (消除尾部延迟):
  - 条件 A: 累计发送 64 包 -> 批量请求 Credit
  - 条件 B: 距上次请求 > 10μs -> 惰性触发请求
  - 实现: 无定时器线程, 每次包到达时检查时间戳
```
### 4.4 域间通信: Per-VRF io_uring
```text
VRF A 数据面线程                    VRF B I/O 线程
  |                                   |
  | 跨域包                            |
  +---------------------------------->|
  |                                   |
  | [VRF A io_uring]    |  [VRF B io_uring]
  | SQ: 提交 SEND       |  CQ: 接收完成事件
  | CQ: 接收完成事件    |  SQ: 提交 RECV
  |                     |
  | SQPOLL 内核线程     |  SQPOLL 内核线程
  | (绑核, 零系统调用)  |  (绑核, 零系统调用)
CPU 隔离策略:
  Core 0-1: 系统 / 中断
  Core 2-3: 数据面线程 (SPSC 处理)
  Core 4-5: I/O 线程 (io_uring SQPOLL)
  Core 6-7: 编排 / 认知面 / GQAP Sanitizer    ★ V2.2
```
---
## 5. Layer 2: 交换路由面 (nullclaw-switch)
### 5.1 三级查表架构
```text
查表路径 (内联, 零函数调用):
MrcPacket 到达
  |
  v
[检查 generation >= current_generation]          ★ V2.2: 强制全路径检查
  | 否 -> DROP (stale packet)
  | 是 -> 继续
  v
[intent_id < 16 ?]
  | 是 -> L0_TABLE[intent_id] (直接索引, <1ns)
  | 否 -> 继续
  v
[hash = CHD_PERFECT_HASH(intent)]
  |
  v
[L1_TABLE[hash] 验证性比较]
  | 匹配 -> handler (内联调用, <10ns)
  | 不匹配 -> 继续
  v
[L2_F14HashMap.get(intent)]
  | 命中 -> handler (~50ns)
  | 未命中 -> L2_TRIE.wildcard_match(intent)
  |            | 命中 -> handler (~200ns)
  |            | 未命中 -> ACL DROP
  v
[执行 handler, 更新 stats]
```
### 5.2 CHD 完美哈希生成 (编译期)
```text
build.zig 管线:
  config/intents.toml
    |
    v
  [tools/phf_generator.zig] (编译期执行)
    |
    |-- 读取所有 Intent 字符串
    |-- CHD 算法搜索 (seed + displacements)
    |   | 成功: 生成 routing_table.zig
    |   | 超时 (>30s): 回退 F14HashMap 全动态模式
    v
  routing_table.zig
    |
    |-- comptime 验证零碰撞
    |-- @compileError 若检测到冲突
    v
  嵌入主二进制 (ROM 段)
```
### 5.3 代际版本号与热替换
```zig
// V2.2: 强制 MrcPacket 包含 generation 字段
struct SwitchEngine {
    // 原子指针: 指向当前 L1 表
    active_l1: Atomic(*L1Table),
    // 代际版本号: 凝蜕/热替换时递增
    current_generation: Atomic(u64),
    // RCU 宽限期管理
    rcu_epochs: [EPOCH_COUNT]Epoch,
}
```
```text
热替换流程:
  1. 新 L1 表编译完成 (后台线程, 不阻塞)
     |
     v
  2. @atomicStore(&active_l1, new_table, .release)
     |
     v
  3. @atomicRmw(&current_generation, .Add, 1, .acq_rel)
     |
     v
  4. 旧表进入 RCU 宽限期 (100ms)
     - 新包携带新 generation, 自然使用新表
     - 旧包携带旧 generation, 被数据面丢弃     ★ V2.2: 全路径强制
     - 旧表引用计数归零后, delayed_munmap
     |
     v
  5. 旧表物理释放 (100ms 后)
抖动控制:
  - x86_64: TSO 模型, .release 已足够
  - ARM (未来): 需 dmb ish (seq_cst)
  - 实测 P99 抖动: < 100ns
```
### 5.4 自动晋升机制
```text
后台晋升线程 (每分钟):
  1. 扫描 L2_F14HashMap, 收集访问计数 > 1000/分钟的条目
     |
     v
  2. 合并到现有 L1 Intent 列表
     |
     v
  3. 触发 CHD 重新计算 (后台, 低优先级)
     |
     v
  4. 生成新 L1 补丁表
     |
     v
  5. 执行热替换 (原子切换, 数据面零抖动)
```
---
## 6. Layer 3: 编排控制面 (lingnet-orchestrator)
### 6.1 Arena 预分配池 (V2.0 基线)
```text
启动时初始化:
+-----------------------------------------------------------+
| HugePages 内存池 (4GB)                                    |
| +-----------------+ +-----------------+ +-----...         |
| | Arena Block 0   | | Arena Block 1   | | ...             |
| | 64KB            | | 64KB            | | 64KB            |
| | state: FREE     | | state: FREE     | | ...             |
| +-----------------+ +-----------------+ +-----...         |
|                                                           |
| 空闲栈 (MPMC, 无锁): head -> Block 0 -> Block 1 -> ... |
+-----------------------------------------------------------+
```
### 6.2 GQAP Arena Manager (V2.2 核心)
```text
★ V2.2: GQAP (Gradient Quarantine Arena Pool)
+-----------------------------------------------------------+
| GQAP 三层池架构                                           |
|                                                           |
| [Common Pool] L0/L1 Trusted                              |
|   - 不清零 (信任语义, 性能优先)                          |
|   - MPMC push/pop << 50ns                                |
|   - 容量: 10K x 64KB                                     |
|                                                           |
| [Quarantine Pool] L2 Retired                             |
|   - 暂存刚释放的 L2 Arena                                |
|   - 等待 Sanitizer Thread 清理                           |
|   - 容量: 1K x 64KB                                      |
|                                                           |
| [L2 Pool] Sanitized Reuse                                |
|   - 已清零, 可安全分配给新 L2 Skill                      |
|   - AVX2 清零: ~3us/64KB                                 |
|   - SSE2 回退: ~8us/64KB                                 |
|   - 容量: 2K x 64KB                                      |
+-----------------------------------------------------------+
Sanitizer Thread (Core 6-7):
  1. 从 Quarantine Pool pop 待清理块
  2. AVX2 `_mm256_store_si256` 256位并行清零
  3. 移入 L2 Pool (已消毒)
Arena 分配路由:
  L0/L1 Skill → Common Pool (不清零)
  L2 Skill    → L2 Pool (已清零, force_zero_on_free=true)
安全性保证:
  - L2 Skill 绝不可能读取前一个 Skill 的残留数据
  - Quarantine 溢出时: 紧急同步清零 + 告警
```
### 6.3 VFS 语义映射
| POSIX 调用 | LingNet 语义 | 返回值 |
|:---|:---|:---|
| open("/agents/x/in", O_RDONLY) | subscribe(VLAN_X, "x", "in") | fd (Stream) |
| open("/agents/x/out", O_WRONLY) | publish(VLAN_X, "x", "out") | fd (Stream) |
| open("/molt/memory", O_RDWR) | mmap Molt 知识库 | fd (Mmap) |
| read(fd, buf, len) | 从 Ring Buffer 消费包 | bytes_read |
| write(fd, buf, len) | 封装 MrcPacket, 路由发送 | bytes_written |
| lseek(fd, offset, whence) | 流式设备不可寻址 | ESPIPE |
| ftruncate(fd, len) | 流式设备不可截断 | EINVAL |
| close(fd) | 取消订阅 / 释放资源 | 0 |
### 6.4 VRF 创建流程
```text
createVRF(config):
  |
  |-- 1. unshare(CLONE_NEWNS | CLONE_NEWPID)     耗时: ~10-50μs
  |
  |-- 2. cgroup v2 设置 (批量写入)
  |     mkdir /sys/fs/cgroup/lingnet/{name}
  |     write cpu.max, memory.max, cpuset.cpus   耗时: ~50-200μs
  |
  |-- 3. 初始化独立路由表 (L0/L1 拷贝, L2 空)   耗时: ~10-50μs
  |
  +-- 总计: < 300μs (轻量模式)
```
---
## 7. Layer 4: 认知计算面 (lingnet-cognitive)
### 7.1 跨语言边界架构
```text
Zig 底座                          Python 认知层
--------                          -------------
  |                                  |
  | 1. 凝蜕触发                      |
  | @atomicRmw(generation++)        |
  |                                  |
  | 2. 收集 HugePages               |
  | memfd_create (每段)             |
  |                                  |
  | 3. UDS 传递 FD 数组  |----> 4. recvmsg + SCM_RIGHTS
  |                                  |
  | 5. mmap 每个 FD                  |
  |                                  | 6. numpy.frombuffer (零拷贝)
  |                                  | 7. LLM 推理 (1-10s, 异步)
  |                                  |
  |                     <----| 8. UDS 回传新知识 (10KB)
  |                                  |
  | 9. arena.deinit() (旧 Arena)    |
  | munmap 100MB (< 200μs)         |
  |                                  |
  | 10. 写入新 Arena, 恢复转发      |
```
### 7.2 离散页 vs 显式拷贝决策
```text
自动探测逻辑 (初始化时):
  检测 LLM 框架能力:
    |
    |-- vLLM + multi_segment_support ?
    |   |-- 是 -> Strategy.DISCRETE_PAGES (真零拷贝)
    |   |-- 否 -> 继续检测
    |
    |-- transformers + pipeline ?
    |   |-- 是 -> Strategy.CONTIGUOUS_COPY (兼容模式)
    |   |-- 否 -> 报错, 要求显式配置
    |
    +-- 用户强制配置: --condense-strategy={discrete|copy}
性能对比:
  Strategy            延迟    内存拷贝  兼容性
  --------            ----    --------  --------
  DISCRETE_PAGES      ~50μs   0         vLLM 等现代框架
  CONTIGUOUS_COPY     ~2ms    100MB     100% 兼容
```
### 7.3 Multi-Model Router 多模型路由 (V2.2 核心)
```text
★ V2.2: Zig 框架 + Python 核心
架构:
  [Zig 框架 - Layer 1-3]
    ├── 配置解析与 comptime 验证 (TOML → FlatBuffer)
    ├── mrc.llm.request() → 封装 Intent MrcPacket
    ├── Ring Buffer 零拷贝传递到 Python 进程 (P99 < 1μs)
    └── 接收响应 → 解包 → 返回 Skill
  [Python 核心 - Layer 4]
    ├── 策略引擎 (统一/智能/竞速)
    ├── 4 种 API 适配器 (OpenAI/Anthropic/Google/Cohere)
    ├── asyncio + httpx 并发调用
    ├── 流式响应 (SSE) 处理与回传
    └── 计费统计与健康检查
  边界开销: ~4μs/调用 (占 LLM 总耗时 2-60s 的 <0.0001%, 可忽略)
三种路由策略:
  ┌─────────────────────────────────────────────────────────────────────┐
  │ 模式 1: 统一配置 (默认)                                           │
  │   所有 Agent 共享主模型和降级链                                   │
  │   async def route(req): await send(primary, fallback)             │
  ├─────────────────────────────────────────────────────────────────────┤
  │ 模式 2: 智能路由                                                  │
  │   综合评分: 延迟(40%) + 成本(40%) + 权重(20%)                     │
  │   按 agent_id 查表, 动态调整权重                                  │
  ├─────────────────────────────────────────────────────────────────────┤
  │ 模式 3: 竞速 (V2.2 推荐)                                         │
  │   asyncio.wait(FIRST_COMPLETED) 取最快响应                        │
  │   全挂则降级智能路由                                              │
  │   预算硬上限: 令牌桶限流                                          │
  └─────────────────────────────────────────────────────────────────────┘
提供商矩阵 (1+7+2+2+8 原生合并):
  OpenAI 系:  1原生 + 7兼容 (api_compat="openai")
              DeepSeek, Zhipu, Qwen, MiniMax, Moonshot, Baichuan, Stepfun
  Anthropic:  2原生 (Sonnet, Haiku, api_compat="anthropic")
  Google AI:  2原生 (Pro, Flash, api_compat="google")
  Custom:     8槽 (Custom_1=OpenRouter默认, 2-8用户可配)
```
---
## 8. 系统集成与运维 (lingnet-cli)
### 8.1 命令体系
```text
lingnet-cli status
  +-- 显示所有 VRF / Sub-agent 状态
  +-- 内存池水位 (Arena / HugePages / GQAP)      ★ V2.2
  +-- 路由表统计 (L0/L1/L2 命中率)
lingnet-cli trace <agent_id>
  +-- 动态插入 ACL 镜像规则
  +-- 输出到监控 Ring Buffer
  +-- 实时显示 Intent 流 (类似 tcpdump)
lingnet-cli route update <config.toml>
  +-- 解析新 Intent 配置
  +-- 触发 CHD 重新计算 (后台)
  +-- 原子热替换 (<< 1ms 切换)
lingnet-cli condense trigger <agent_id>
  +-- 手动触发凝蜕 (调试)
  +-- 显示管线各阶段耗时
lingnet-cli sandbox status                       ★ V2.2
  +-- 显示 eBPF 监控状态与分级采样统计
  +-- GQAP 三层池水位
  +-- L0 mprotect 状态
lingnet-cli benchmark [mrc|route|condense|sandbox]  ★ V2.2
  +-- 运行内置压测
  +-- 输出 rdtsc 周期数
  +-- sandbox: eBPF 开销基准测试
```
### 8.2 启动预检
```text
lingnet-daemon 启动流程:
  [1] 检查 /proc/version >= 5.10
      | 否 -> FATAL
  [2] 检查 /proc/sys/vm/nr_hugepages >= 2048
      | 否 -> WARN, 降级 MAP_LOCKED
  [3] 检查 /sys/fs/cgroup/cgroup.controllers 包含 cpu memory
      | 否 -> FATAL
  [4] 检查 CPU 隔离核配置 (isolcpus 或 systemd)
      | 否 -> WARN, 性能降级
  [5] 检查 eBPF LSM 支持                             ★ V2.2
      | <5.7 -> WARN, 降级 Seccomp-BPF
  [6] 检查 AVX2 指令集                               ★ V2.2
      | 缺失 -> WARN, GQAP 使用 SSE2
  [7] 预分配 Arena 池 (10K x 64KB)
  [8] 加载 L0/L1 路由表, mmap HugePages
  [9] mprotect L0 代码段 (PROT_READ|PROT_EXEC)       ★ V2.2
  [10] 启动 io_uring 实例
  [11] 启动 GQAP Sanitizer Thread (Core 6-7)         ★ V2.2
  [12] 启动 eBPF 监控程序                            ★ V2.2
  [13] 启动编排线程, 进入事件循环
```
---
## 9. 性能验收指标体系
### 9.1 数据面指标
| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| 域内 SPSC 吞吐 | > 20M IOPS | bench_mrc, 指针传递 | 基线 |
| 域内 P99 延迟 | < 1μs | rdtsc, 空负载 | 基线 |
| 10K Sub-agent 喷包 | 零丢包, CPU < 20% | Credit 流控验证 | 基线 |
| 稀疏包延迟 | P99 < 15μs | 1包/秒 负载 | 基线 |
| 跨域延迟 | < 10μs (同机房) | ping-pong 测试 | 基线 |
| **eBPF 数据面开销** | **< 8%** | **bench_mrc** | **★ V2.2** |
### 9.2 路由面指标
| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| L0 查表 | < 1ns | rdtsc, 直接索引 | 基线 |
| L1 查表 | < 10ns | rdtsc, 10M 随机 Intent | 基线 |
| L2 查表 | < 50ns | F14HashMap 基准 | 基线 |
| 通配符解析 | < 200ns | Trie 深度 <= 5 | 基线 |
| 热替换抖动 | < 100ns P99 | perf stat, 10K 次切换 | 基线 |
| 自动晋升延迟 | < 100ms | 后台批量 100 Intent | 基线 |
| **全路径 generation 检查** | **< 2ns** | **rdtsc** | **★ V2.2** |
### 9.3 编排面指标
| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| 分神创建 (池) | < 100ns | rdtsc, 1M 次 | TrustedArena |
| 分神创建 (系统) | < 10μs | rdtsc, 池耗尽场景 | mmap 路径 |
| 分身创建 | < 300μs | rdtsc, unshare+cgroup | 基线 |
| Arena 释放 (100MB) | < 200μs | rdtsc, munmap | 基线 |
| 内存碎片 (72h) | 零增长 | /proc/pid/maps 监控 | 基线 |
| **Untrusted Arena deinit** | **< 50ns** | **rdtsc** | **★ V2.2 GQAP** |
| **Background sanitize** | **~3us/64KB** | **AVX2 计时** | **★ V2.2 GQAP** |
### 9.4 认知面指标
| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| FD 传递 + mmap | < 500μs | UDS 计时 | 基线 |
| 100MB 显式拷贝 | < 2ms | memcpy 计时 | 兼容模式 |
| 凝蜕管线 overhead | < 100μs | rdtsc, 不含 LLM | 基线 |
| 凝蜕总耗时 (含 LLM) | < 10s | 端到端 | 软目标 |
| **竞速首响应** | **< 2s** | **asyncio FIRST_COMPLETED** | **★ V2.2** |
| **智能路由 P99** | **< 3s** | **加权分配** | **★ V2.2** |
### 9.5 系统级指标
| 指标 | 目标值 | 测试方法 | 备注 |
|:---|:---|:---|:---|
| 隔离性 (死循环) | P99 波动 < 5% | htop + bench_mrc | 基线 |
| 并发极限 | > 100K Sub-agent | 阶梯加压 | 基线 |
| 内存降低 | 80%+ | 同等并发对比 | 去除 Go Runtime |
| 可审计性 | 100% TTL | CLI trace 验证 | 基线 |
| **隔离性 (eBPF)** | **< 5.5%** | **+0.5% 开销** | **★ V2.2 可接受** |
---
## 10. 开发路线图
### 10.1 里程碑 (36 周, 含 4 周 eBPF 缓冲)
```text
Week 1- 2: [M0] 工具链锁定 + GQAP 原型 + eBPF 基线
  - Zig 0.17-dev 锁定 commit
  - GQAP Common/Quarantine/L2 Pool 实现
  - AVX2 sanitizer 线程原型
  - eBPF 编译管线验证 (build.zig + bpf_target)
Week 3- 6: [M1] eBPF 管线 + P0 数据面
  - eBPF LSM 策略 (inode_permission, file_open)
  - Runtime monitor (分级采样: 高危1/1, 中危1/10)
  - Arena audit (跨层泄漏检测 uprobe)
  - SPSC Ring Buffer + Ready-List 验证
  - Go/No-Go 决策 (Week 6)
Week 7-12: [M2] P0 路由面闭环 + L0 保护
  - CHD 生成器 (build.zig 集成)
  - L0/L1/L2 三级查表 + 强制 generation 检查
  - linker.ld + mprotect L0 代码段
  - 验收: 20M IOPS, <10ns L1, <2ns generation 检查
Week 13-18: [M3] P1 编排面 + GQAP 集成
  - Arena 预分配池 (GQAP 三层池)
  - VFS 适配层
  - 代际凝蜕管线
  - 验收: <100ns 分神创建, <50ns L2 deinit, <3us sanitize
Week 19-24: [M4] P2 跨域 I/O + 认知面 + 多模型路由
  - Per-VRF io_uring + SQPOLL
  - CFFI + memfd 桥接
  - Python 认知模块 (nogil)
  - Zig+Python 多模型路由 (竞速/智能)
  - 验收: <10μs 跨域, <500μs FD 映射, <2s 竞速首响应
Week 25-30: [M5] 系统集成 + 压力测试 + 安全渗透
  - lingnet-cli 管理工具
  - 72h 高压测试 (内存碎片, GQAP quarantine GC)
  - eBPF 渗透测试 (绕过检测)
  - 并发极限测试 (1K → 10K → 100K)
  - 安全审计回归测试
Week 31-34: [M6] RC 候选版 + eBPF 调优
  - eBPF 性能基准验证 (<8% 影响)
  - 部署手册 (含降级策略)
  - 生产灰度契约
  - v2.2-rc1 发布
Week 35-36: 缓冲 (vs V2.0 2周)
```
---
## 11. 风险管理与备案策略
### 11.1 V2.0 基线风险 (状态更新)
| 风险 | 概率 | 影响 | 应对策略 | V2.2 状态 |
|:---|:---|:---|:---|:---|
| Zig 0.17 延迟 | 中 | 高 | 切换 0.16 + libxev | 不变 |
| 0.17 实验性 bug | 中 | 高 | 直接 io_uring syscall | 不变 |
| CHD 生成失败 | 低 | 高 | F14HashMap 全动态 | 不变 |
| HugePages 不足 | 中 | 中 | MAP_LOCKED 降级 | 不变 |
| Python GIL 瓶颈 | 中 | 中 | nogil / 子解释器 | **缓解: Zig层承担更多** |
| 100K 并发调度崩溃 | 低 | 高 | 阶梯加压, 限流 | 不变 |
### 11.2 V2.2 新增风险
| 风险 | 概率 | 影响 | 应对策略 | 触发条件 |
|:---|:---|:---|:---|:---|
| eBPF LSM 内核不支持 | 中 | 高 | 自动降级 Seccomp-BPF | Linux < 5.7 |
| eBPF 验证器拒绝加载 | 低 | 高 | 简化 BPF 代码, 分阶段加载 | 内核版本差异 |
| AVX2 指令集缺失 | 低 | 中 | 回退 SSE2 / 标量 memset | 旧 CPU (pre-Haswell) |
| GQAP Quarantine 溢出 | 低 | 高 | 紧急同步清零 + 告警 | L2 创建速度 > 清理速度 |
| Ed25519 签名验证性能 | 低 | 中 | 预验证缓存 + 异步验证 | 大量社区 Skill 加载 |
| 多模型路由竞速风暴 | 中 | 中 | 令牌桶限流 + 预算硬上限 | 高并发竞速请求 |
### 11.3 备案路径 (V2.2 更新)
```text
路径 A: 0.17 + eBPF 全功能 (60% 概率) → 36周
  |
  +-- eBPF LSM + tracepoint + arena_audit
  +-- GQAP 三层池 + AVX2 sanitizer
  +-- 多模型路由 Zig+Python
路径 B: 0.17 + eBPF 降级 (25% 概率) → 34周 (-2)
  |
  +-- 无 LSM, 仅 tracepoint + arena_audit
  +-- GQAP 保留, sanitizer 用 SSE2
  +-- 多模型路由保留
路径 C: 0.16 + libxev + 无 eBPF (10% 概率) → 36周
  |
  +-- 纯 Seccomp + Landlock (V2.0 基线)
  +-- GQAP 保留 (无 eBPF audit)
  +-- 多模型路由保留
路径 D: 0.17 实验性 bug 阻塞 (5% 概率) → 不定
  |
  +-- 等待 0.17 补丁
  +-- 或: 激进方案, 直接 syscall 绕过 std.Io
```
---
## 12. 附录: 方案对比与兼容性矩阵
### 12.1 内核版本功能矩阵
| 内核版本 | io_uring | cgroups v2 | eBPF LSM | eBPF Tracepoint | GQAP Sanitizer | 安全等级 |
|:---|:---|:---|:---|:---|:---|:---|
| >= 6.1 | ✅ SQPOLL | ✅ 完整 | ✅ 全功能 | ✅ 全功能 | ✅ AVX2 | 高 |
| >= 5.7 | ✅ 基础 | ✅ 完整 | ❌ | ✅ 全功能 | ✅ AVX2 | 中高 |
| >= 5.2 | ✅ 基础 | ✅ 完整 | ❌ | ❌ | ✅ SSE2 | 中 |
| >= 5.1 | ✅ 基础 | ✅ 完整 | ❌ | ❌ | ✅ SSE2 | 中 |
| < 5.1 | ❌ | ⚠️ v1 兼容 | ❌ | ❌ | ✅ 标量 | 低 |
### 12.2 Zig 版本功能矩阵
| Zig 版本 | comptime CHD | libxev | GQAP | eBPF 绑定 | 推荐度 |
|:---|:---|:---|:---|:---|:---|
| 0.17 | ✅ | ✅ 内置 | ✅ | ✅ | ⭐⭐⭐⭐⭐ |
| 0.16 | ✅ | ⚠️ 独立 | ✅ | ✅ | ⭐⭐⭐⭐ |
| 0.15 | ⚠️ 部分 | ❌ | ⚠️ 需适配 | ❌ | ⭐⭐ |
### 12.3 V2.2 安全沙箱分层
```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ Skill 安全沙箱分层                                                        │
│ ─────────────────────                                                     │
│                                                                           │
│ L0: Core Skills (6 个)                                                    │
│   无沙箱 (可信)                                                           │
│   + mprotect(PROT_READ|PROT_EXEC) 防篡改                                  │
│   + generation 字段强制检查                                                │
│                                                                           │
│ L1: Built-in Skills (13 个)                                               │
│   轻量沙箱: Seccomp-BPF + Landlock                                        │
│   + Arena 不清零 (Common Pool)                                            │
│                                                                           │
│ L2: Dynamic Skills (auto_*/custom_*/community_*)                          │
│   强化沙箱: Seccomp-BPF + Landlock + eBPF 分级监控                        │
│   + Arena 强制清零 (L2 Pool, force_zero_on_free=true)                     │
│   + 行为监控 + 自动熔断                                                   │
│   + 竞速全挂降级智能路由                                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```
---
## 冻结签署
```text
文档状态: MERGED FINAL FREEZE
基线版本: V2.0 (CONDITIONAL FREEZE 20260523)
主版本: V2.2 (扩展层, 冲突以 V2.2 为准)
合并日期: 2026-05-24
Git Tag: merged-v2.2-20260524
V2.2 新增项: eBPF 分级监控, GQAP Arena, 多模型路由, L0 mprotect
V2.0 基线保持: 数据面/路由面/跨语言边界/性能目标
追踪文件: roadmap/v3.0-optimizations.md
签署人: _________________ 日期: 2026-05-24
审核人: _________________ 日期: _________________
```
