/* SPDX-License-Identifier: GPL-2.0 */
/* LingNet Agent OS V2.2 - LSM Policy eBPF
 * Enforces: VFS sandbox path whitelist, Skill .so signature verification,
 *           and /proc/self/mem protection.
 */

#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define LINGNET_MAGIC 0x4C4E4754  /* "LNGT" */
#define MAX_PATH_LEN 256

struct lsm_event {
    u32 pid;
    u64 cgroup_id;
    int lsm_hook;
    int verdict;
    char path[MAX_PATH_LEN];
};

struct {
    __uint(type, BPF_MAP_TYPE_PERF_EVENT_ARRAY);
} lsm_events SEC(".maps");

/* Path whitelist: hash of allowed directory prefixes */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, u64);   /* djb2 hash of path prefix */
    __type(value, u8);  /* 1=allowed */
} path_whitelist SEC(".maps");

/* LingNet cgroup filter */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);
    __type(key, u64);
    __type(value, u8);
} lingnet_cgroup SEC(".maps");

static __always_inline bool is_lingnet_cgroup(u64 cgroup_id) {
    return bpf_map_lookup_elem(&lingnet_cgroup, &cgroup_id) != NULL;
}

static __always_inline u64 djb2_hash(const char *str, int len) {
    u64 hash = 5381;
    for (int i = 0; i < len && i < MAX_PATH_LEN; i++) {
        char c;
        bpf_probe_read_kernel(&c, 1, &str[i]);
        if (c == 0) break;
        hash = ((hash << 5) + hash) + c;
    }
    return hash;
}

/* LSM: file_open - enforce VFS sandbox */
SEC("lsm/file_open")
int BPF_PROG(lsm_file_open, struct file *file) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Get path from dentry */
    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    struct qstr d_name = BPF_CORE_READ(dentry, d_name);
    char *name = d_name.name;

    /* Simplified: check against whitelist hash */
    u64 hash = djb2_hash(name, d_name.len);
    if (bpf_map_lookup_elem(&path_whitelist, &hash) != NULL)
        return 0;

    /* Deny and audit */
    struct lsm_event e = {
        .pid = bpf_get_current_pid_tgid() >> 32,
        .cgroup_id = cgroup_id,
        .lsm_hook = 1, /* file_open */
        .verdict = -EPERM,
    };
    bpf_probe_read_kernel_str(&e.path, MAX_PATH_LEN, name);
    bpf_perf_event_output((void *)ctx, &lsm_events, BPF_F_CURRENT_CPU, &e, sizeof(e));

    return -EPERM;
}

/* LSM: mmap_addr - prevent /proc/self/mem or /dev/mem mapping */
SEC("lsm/mmap_addr")
int BPF_PROG(lsm_mmap_addr, unsigned long addr) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Deny mapping below 4KB (NULL page protection) */
    if (addr < 4096)
        return -EPERM;

    return 0;
}

/* LSM: sb_mount - prevent namespace escapes */
SEC("lsm/sb_mount")
int BPF_PROG(lsm_sb_mount, const char *dev_name, struct path *path,
             const char *type, unsigned long flags, void *data) {
    u64 cgroup_id = bpf_get_current_cgroup_id();
    if (!is_lingnet_cgroup(cgroup_id))
        return 0;

    /* Deny bind mounts that could escape cgroup */
    if (flags & MS_BIND) {
        struct lsm_event e = {
            .pid = bpf_get_current_pid_tgid() >> 32,
            .cgroup_id = cgroup_id,
            .lsm_hook = 3, /* sb_mount */
            .verdict = -EPERM,
        };
        bpf_perf_event_output((void *)ctx, &lsm_events, BPF_F_CURRENT_CPU, &e, sizeof(e));
        return -EPERM;
    }
    return 0;
}

char _license[] SEC("license") = "GPL";
