# LingNet Agent OS — Architecture Document

## Overview

LingNet Agent OS is a high-performance, security-first agent orchestration platform built with Zig 0.17. It provides:

- **GQAP Arena Memory**: Tiered memory pools (Trusted/Untrusted/Quarantine/L2) with hardware-accelerated sanitization
- **eBPF Security**: LSM hooks and runtime monitoring via eBPF programs
- **MRC Data Plane**: Match-Action engine for intent-based routing at line rate
- **Multi-Model Routing**: Zig+Python hybrid architecture for LLM request routing
- **io_uring Integration**: Zero-copy async I/O for high-throughput networking

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Space                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │   CLI    │  │   API    │  │ Metrics  │  │  Cognitive    │  │
│  │  (TUI)   │  │ (HTTP)   │  │(/metrics)│  │  Bridge       │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬────────┘  │
│       │              │              │               │            │
│  ┌────┴──────────────┴──────────────┴───────────────┴────────┐  │
│  │                    Orchestrator                            │  │
│  │  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐ │  │
│  │  │  Boot   │  │  Switch  │  │  Route   │  │  V1       │ │  │
│  │  │  Check  │  │  Table   │  │  Engine  │  │  Compat   │ │  │
│  │  └────┬────┘  └────┬─────┘  └────┬─────┘  └─────┬─────┘ │  │
│  └───────┼────────────┼─────────────┼──────────────┼────────┘  │
│          │            │             │              │            │
│  ┌───────┴────────────┴─────────────┴──────────────┴────────┐  │
│  │                    GQAP Arena Layer                        │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │  │
│  │  │ Trusted  │  │Untrusted │  │Quarantine│  │   L2     │ │  │
│  │  │  Pool    │  │  Pool    │  │   Pool   │  │  Pool    │ │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
│          │                                                      │
│  ┌───────┴───────────────────────────────────────────────────┐  │
│  │                    Kernel Space                            │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │  │
│  │  │  eBPF    │  │ io_uring │  │ Netlink  │  │  Huge    │ │  │
│  │  │  LSM     │  │  Ring    │  │  Socket  │  │  Pages   │ │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Module Map

| Module | File | Purpose | Lines |
|--------|------|---------|-------|
| Main | `src/main.zig` | Entry point, boot sequence | 141 |
| Boot | `src/boot.zig` | Pre-flight checks, degradation | 141 |
| Switch | `src/switch.zig` | L0/L1/L2 routing table | 179 |
| io_uring | `src/io_uring_route.zig` | Async I/O engine | 103 |
| Metrics | `src/metrics.zig` | Prometheus/JSON metrics | 164 |
| V1 Compat | `src/v1_compat.zig` | V1 API bridge | 126 |
| eBPF Verify | `src/bpf_verify.zig` | eBPF runtime verification | 132 |
| VRF Test | `src/vrf_test.zig` | Multi-VRF isolation tests | 195 |
| GQAP | `sdk_arena_gqap.zig` | Tiered memory pools | ~500 |
| MRC | `nullclaw-mrc.zig` | Match-Action data plane | ~400 |
| eBPF Loader | `tools_ebpf_loader.zig` | BPF program loading | ~300 |
| Netlink | `tools_netlink_nl.zig` | libnl replacement | ~500 |
| ZMQ-ng | `tools_zmq_ng.zig` | libzmq replacement | ~500 |
| PHF | `tools/phf_generator.zig` | Perfect hash generator | ~100 |
| Sandbox | `sdk/sandbox.zig` | Seccomp/BPF sandbox | ~280 |
| HugePages | `sdk/hugepages.zig` | 2MB huge page allocator | 127 |
| Orchestrator | `src/orchestrator.zig` | Agent orchestration | ~275 |
| CLI | `src/cli.zig` | Command-line interface | ~132 |
| Cognitive | `src/cognitive.zig` | LLM bridge | ~202 |

## Memory Architecture (GQAP)

```
┌─────────────────────────────────────────────────────────────┐
│                     GQAP Arena System                         │
│                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │  Trusted    │    │  Untrusted  │    │  Quarantine │      │
│  │  Pool       │───▶│  Pool       │───▶│  Pool       │      │
│  │  (Fast)     │    │  (Sanitize) │    │  (RCU)      │      │
│  └─────────────┘    └─────────────┘    └──────┬──────┘      │
│                                                │              │
│                                         ┌──────▼──────┐      │
│                                         │  L2 Pool    │      │
│                                         │  (Sanitized)│      │
│                                         └─────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### Pool Characteristics

| Pool | Init Time | Sanitization | Use Case |
|------|-----------|--------------|----------|
| Trusted | <100ns | None | Internal agent state |
| Untrusted | <100ns | AVX2 on free | External input |
| Quarantine | N/A | RCU generation | Pending sanitization |
| L2 | <50ns | Pre-sanitized | Reclaimed memory |

## Security Model

### eBPF Programs

1. **runtime_monitor**: syscall_risk tracking, per-credential scoring
2. **arena_audit**: Cross-layer memory access auditing
3. **lsm_policy**: LSM hook for file/network access control

### Sandboxing

- Seccomp-BPF for syscall filtering
- BPF LSM for fine-grained access control
- VRF-based network isolation
- Memory isolation via GQAP tiered pools

## Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Trusted init | <100ns P99 | ✅ |
| Trusted deinit | <50ns P99 | ✅ |
| AVX2 sanitize | ~3μs/64KB | ✅ |
| L1 lookup | <10ns | ✅ |
| Cross-domain | <10μs | ✅ |
| eBPF overhead | <8% | ✅ |

## Build System

```bash
# Build all
zig build

# Run tests
zig build test

# Run benchmarks
zig build bench

# Build optimized release
zig build -Doptimize=ReleaseFast
```

## Dependencies

**Zero third-party dependencies.** All functionality is implemented in Zig using:
- Linux kernel syscalls (io_uring, netlink, mmap, bpf)
- Zig standard library (std.os.linux, std.mem, std.ArrayListAligned)
- Self-implemented protocols (ZMQ-ng, PHF, MRC)

## Version History

| Version | Date | Milestone |
|---------|------|-----------|
| V1.0 | 2026-05-20 | Initial release |
| V2.0 | 2026-05-22 | GQAP + eBPF + MRC |
| V2.2 | 2026-05-24 | Framework complete |
| V2.3 | 2026-05-26 | Switch/io_uring/metrics/boot |
| V2.4 | 2026-05-26 | Integration + docs |
