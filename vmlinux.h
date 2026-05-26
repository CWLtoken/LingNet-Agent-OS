/* Minimal vmlinux.h stub for LingNet Agent OS eBPF compilation
 * Provides essential kernel types without requiring BTF-generated header
 */
#ifndef _VMLINUX_H
#define _VMLINUX_H

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef signed char __s8;
typedef signed short __s16;
typedef signed int __s32;
typedef signed long long __s64;

typedef __u16 __le16;
typedef __u32 __le32;
typedef __u64 __le64;
typedef __u16 __be16;
typedef __u32 __be32;
typedef __u64 __be64;

typedef __u64 __u128 __attribute__((aligned(16)));

typedef __u32 __kernel_ulong_t;
typedef __kernel_ulong_t __kernel_size_t;
typedef __s64 __kernel_ssize_t;

typedef __u32 pid_t;
typedef __u32 uid_t;
typedef __u32 gid_t;
typedef __s64 ssize_t;
typedef __kernel_size_t size_t;

struct task_struct {
    int pid;
    int tgid;
    void *mm;
    void *cred;
};

struct file {
    void *f_path;
    void *f_inode;
    void *f_op;
};

struct inode {
    __u32 i_mode;
    __u32 i_uid;
    __u32 i_gid;
    __u64 i_ino;
};

struct path {
    void *mnt;
    void *dentry;
};

struct dentry {
    void *d_parent;
    void *d_name;
};

struct vfsmount {
    void *mnt_root;
};

struct cred {
    uid_t uid;
    gid_t gid;
};

struct mm_struct {
    void *exe_file;
};

struct socket {
    void *sk;
};

struct sock_common {
    __u16 skc_dport;
    __u32 skc_rcv_saddr;
    __u32 skc_daddr;
};

struct sock {
    struct sock_common __sk_common;
};

struct inet_sock {
    struct sock sk;
};

struct tcp_sock {
    struct inet_sock inet;
};

struct request_sock {
    struct sock_common __sk_common;
};

struct bpf_map_def {
    __u32 type;
    __u32 key_size;
    __u32 value_size;
    __u32 max_entries;
    __u32 map_flags;
};

#endif /* _VMLINUX_H */
