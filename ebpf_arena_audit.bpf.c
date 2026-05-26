/* SPDX-License-Identifier: GPL-2.0 */
/* LingNet Agent OS V2.2 - Arena Audit eBPF Probe
 * Monitors cross-tier Arena block flows to detect security violations:
 *  - Untrusted block entering common pool (information leak)
 *  - Double-free patterns
 *  - Generation mismatch on reuse
 * Performance target: < 1% overhead via BPF map batching
 */

/* Must define target arch BEFORE any BPF includes */
#ifndef __TARGET_ARCH_x86
#define __TARGET_ARCH_x86
#endif

#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

/* Kernel constants that may not be in vmlinux.h for 6.6 */
#ifndef EPERM
#define EPERM       1
#endif
#ifndef PROT_WRITE
#define PROT_WRITE  0x02
#endif
#ifndef PROT_EXEC
#define PROT_EXEC   0x04
#endif

#define EVENT_ARENA_VIOLATION 1
#define EVENT_DOUBLE_FREE     2
#define EVENT_GEN_MISMATCH    3

struct arena_event {
    u32 pid;
    u32 tid;
    u64 cgroup_id;
    u64 block_id;
    u64 expected_gen;
    u64 actual_gen;
    u8  event_type;
    u8  from_tier;
    u8  to_tier;
    u8  reserved;
};

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(u32));
} arena_events SEC(".maps");

/* Track block state: 0=free, 1=trusted, 2=untrusted, 3=quarantined */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u64);      /* block_id (physical address) */
    __type(value, u8);     /* state */
} blk_state SEC(".maps");

/* Track block generation for mismatch detection */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u64);
    __type(value, u64);
} block_generation SEC(".maps");

/* Whitelist: only monitor LingNet cgroups */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);
    __type(key, u64);
    __type(value, u8);
} lingnet_cgroup SEC(".maps");

static __always_inline bool is_lingnet_cgroup(u64 cgroup_id) {
    return bpf_map_lookup_elem(&lingnet_cgroup, &cgroup_id) != NULL;
}

/* Tracepoint: Arena block allocation (from userspace via USDT or syscall) */
SEC("uprobe//opt/lingnet/bin/lingnet-daemon:arena_alloc")
int trace_arena_alloc(struct pt_regs *ctx) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    u64 block_id = PT_REGS_PARM1(ctx);
    u8 tier = (u8)PT_REGS_PARM2(ctx);  /* 1=trusted, 2=untrusted */
    u64 gen = PT_REGS_PARM3(ctx);

    u8 *old_state = bpf_map_lookup_elem(&blk_state, &block_id);
    if (old_state && *old_state != 0) {
        /* Double-alloc without free: potential use-after-free or corruption */
        struct arena_event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .tid = bpf_get_current_pid_tgid(),
            .cgroup_id = cgroup_id,
            .block_id = block_id,
            .event_type = EVENT_DOUBLE_FREE,
            .from_tier = *old_state,
            .to_tier = tier,
        };
        bpf_perf_event_output(ctx, &arena_events, BPF_F_CURRENT_CPU, &e, sizeof(e));
    }

    bpf_map_update_elem(&blk_state, &block_id, &tier, BPF_ANY);
    bpf_map_update_elem(&block_generation, &block_id, &gen, BPF_ANY);
    return 0;
}

/* Tracepoint: Arena block deinit / pool push */
SEC("uprobe//opt/lingnet/bin/lingnet-daemon:arena_deinit")
int trace_arena_deinit(struct pt_regs *ctx) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    u64 block_id = PT_REGS_PARM1(ctx);
    u8 dest_tier = (u8)PT_REGS_PARM2(ctx);  /* 0=common, 1=l2, 2=quarantine */
    u64 retired_gen = PT_REGS_PARM3(ctx);

    u8 *state = bpf_map_lookup_elem(&blk_state, &block_id);
    if (!state)
        return 0;

    u8 from_tier = *state;

    /* VIOLATION: untrusted (2) -> common (0) */
    if (from_tier == 2 && dest_tier == 0) {
        struct arena_event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .tid = bpf_get_current_pid_tgid(),
            .cgroup_id = cgroup_id,
            .block_id = block_id,
            .event_type = EVENT_ARENA_VIOLATION,
            .from_tier = from_tier,
            .to_tier = dest_tier,
        };
        bpf_perf_event_output(ctx, &arena_events, BPF_F_CURRENT_CPU, &e, sizeof(e));
    }

    /* Update state: quarantine stays 3, l2 becomes 2, common becomes 0 */
    u8 new_state = (dest_tier == 2) ? 3 : ((dest_tier == 1) ? 2 : 0);
    bpf_map_update_elem(&blk_state, &block_id, &new_state, BPF_ANY);
    return 0;
}

/* Tracepoint: Arena block reuse (pop from pool) */
SEC("uprobe//opt/lingnet/bin/lingnet-daemon:arena_reuse")
int trace_arena_reuse(struct pt_regs *ctx) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    u64 block_id = PT_REGS_PARM1(ctx);
    u64 new_gen = PT_REGS_PARM2(ctx);

    u64 *old_gen = bpf_map_lookup_elem(&block_generation, &block_id);
    if (old_gen && *old_gen >= new_gen) {
        /* Generation should always increase; if not, clock corruption or replay */
        struct arena_event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .tid = bpf_get_current_pid_tgid(),
            .cgroup_id = cgroup_id,
            .block_id = block_id,
            .expected_gen = *old_gen + 1,
            .actual_gen = new_gen,
            .event_type = EVENT_GEN_MISMATCH,
        };
        bpf_perf_event_output(ctx, &arena_events, BPF_F_CURRENT_CPU, &e, sizeof(e));
    }

    if (old_gen)
        bpf_map_update_elem(&block_generation, &block_id, &new_gen, BPF_ANY);
    return 0;
}

/* LSM hook: Prevent mprotect on .lingnet_l0 section after boot */
SEC("lsm/mprotect")
int BPF_PROG(lsm_mprotect, struct mm_struct *mm, unsigned long start,
             size_t len, unsigned long prot) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Detect W+X on L0 text segment range (simplified, needs symbol resolution) */
    if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) {
        struct arena_event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .event_type = EVENT_ARENA_VIOLATION,
            .from_tier = 0,
            .to_tier = 0,
        };
        bpf_perf_event_output((void *)ctx, &arena_events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }
    return 0;
}

char _license[] SEC("license") = "GPL";
