/* SPDX-License-Identifier: GPL-2.0 */
/* LingNet Agent OS V2.2 - Runtime Monitor eBPF
 * Fixes 3 audit traps:
 *  Trap 1: cgroup filtering (only monitor LingNet process tree)
 *  Trap 2: LSM deny audit completion (output denied events)
 *  Trap 3: High-risk syscall full sampling (no missed execve/connect)
 */

#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define RISK_HIGH   1
#define RISK_MID    2
#define RISK_LOW    3

struct event {
    u32 pid;
    u32 tid;
    u64 cgroup_id;
    u64 timestamp_ns;
    int syscall_id;
    u8  risk_level;
    u8  action;     /* 0=allowed, 1=denied, 2=logged */
    u16 reserved;
};

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
} events SEC(".maps");

/* LingNet cgroup whitelist */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);
    __type(key, u64);
    __type(value, u8);
} lingnet_cgroup SEC(".maps");

/* Syscall risk classification map (populated from userspace at boot) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 512);
    __type(key, int);      /* syscall_id */
    __type(value, u8);     /* risk_level */
} syscall_risk SEC(".maps");

static __always_inline bool is_lingnet_cgroup(u64 cgroup_id) {
    return bpf_map_lookup_elem(&lingnet_cgroup, &cgroup_id) != NULL;
}

/* Tracepoint: syscall entry - tiered sampling */
SEC("tracepoint/raw_syscalls/sys_enter")
int trace_syscall_enter(struct trace_event_raw_sys_enter *ctx) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    int syscall_id = ctx->id;
    u8 *risk_ptr = bpf_map_lookup_elem(&syscall_risk, &syscall_id);
    u8 risk = risk_ptr ? *risk_ptr : RISK_LOW;

    u32 sample_rate;
    switch (risk) {
        case RISK_HIGH: sample_rate = 1;   break;  /* 1/1 full capture */
        case RISK_MID:  sample_rate = 10;  break;  /* 1/10 sampling */
        default:        sample_rate = 100; break;  /* 1/100 sampling */
    }

    if (sample_rate > 1 && (bpf_get_prandom_u32() % sample_rate != 0))
        return 0;

    struct event e = {
        .pid = bpf_get_current_pid_tgid() >> 32,
        .tid = bpf_get_current_pid_tgid(),
        .cgroup_id = cgroup_id,
        .timestamp_ns = bpf_ktime_get_ns(),
        .syscall_id = syscall_id,
        .risk_level = risk,
        .action = 2, /* logged */
    };

    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
    return 0;
}

/* LSM: inode_permission - Trap 2 fix (deny audit completion) */
SEC("lsm/inode_permission")
int BPF_PROG(lsm_inode_permission, struct inode *inode, int mask) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Deny write+execute on any path within LingNet process */
    if ((mask & MAY_WRITE) && (mask & MAY_EXEC)) {
        struct event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .tid = bpf_get_current_pid_tgid(),
            .cgroup_id = cgroup_id,
            .timestamp_ns = bpf_ktime_get_ns(),
            .syscall_id = __NR_openat,
            .risk_level = RISK_HIGH,
            .action = 1, /* denied */
        };
        bpf_perf_event_output((void *)ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }

    return 0;
}

/* LSM: socket_create - network sandbox enforcement */
SEC("lsm/socket_create")
int BPF_PROG(lsm_socket_create, int family, int type, int protocol, int kern) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Dynamic Skills (L2) have no network access per V2.2 sandbox spec */
    /* Userspace passes tier via BPF map; here simplified to always deny raw socket */
    if (family == AF_PACKET || family == AF_INET) {
        struct event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .cgroup_id = cgroup_id,
            .timestamp_ns = bpf_ktime_get_ns(),
            .syscall_id = __NR_socket,
            .risk_level = RISK_HIGH,
            .action = 1,
        };
        bpf_perf_event_output((void *)ctx, &events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }
    return 0;
}

char _license[] SEC("license") = "GPL";
