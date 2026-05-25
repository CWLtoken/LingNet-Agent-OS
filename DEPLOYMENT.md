# Deployment Guide

## System Requirements

### Minimum
- Linux kernel >= 5.10
- x86_64 with AVX2
- 512MB RAM
- Zig 0.17.0-dev.338+

### Recommended
- Linux kernel >= 6.1 (io_uring support)
- x86_64 with AVX2 + BMI2
- 4GB RAM (for 10K x 64KB GQAP pools)
- 2048+ HugePages
- Isolated CPU cores for sanitizer

## Quick Start

### 1. Build

```bash
git clone git@github.com:CWLtoken/LingNet-Agent-OS.git
cd LingNet-Agent-OS
zig build -Doptimize=ReleaseFast
```

### 2. Configure HugePages (optional)

```bash
# Check current HugePages
cat /proc/sys/vm/nr_hugepages

# Set 2048 x 2MB HugePages (4GB)
sudo sysctl vm.nr_hugepages=2048

# Make permanent
echo "vm.nr_hugepages=2048" | sudo tee -a /etc/sysctl.conf
```

### 3. Configure CPU Isolation (optional)

```bash
# Edit kernel cmdline (GRUB)
# isolcpus=6,7 nohz_full=6,7 rcu_nocbs=6,7

# Verify after reboot
cat /sys/devices/system/cpu/isolated
```

### 4. Run

```bash
# Foreground
./zig-out/bin/lingnet-daemon

# Background with logging
nohup ./zig-out/bin/lingnet-daemon > /var/log/lingnet.log 2>&1 &

# Check status
kill -0 $PID && echo "Running" || echo "Stopped"
```

### 5. Run Tests

```bash
# All tests
zig build test

# Specific module
zig build test --filter "SwitchTable"

# Benchmarks
zig build bench
```

## Kernel Configuration

Required kernel config:
```
CONFIG_BPF=y
CONFIG_BPF_LSM=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_HUGETLBFS=y
CONFIG_HUGLBAGE=y
CONFIG_IO_URING=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_AUDIT=y
```

Verify:
```bash
zgrep CONFIG_BPF_LSM /proc/config.gz
zgrep CONFIG_HUGETLBFS /proc/config.gz
```

## WSL Deployment

LingNet runs on WSL2 with graceful degradation:

```bash
# WSL2 kernel supports io_uring
# eBPF LSM may not be available (auto-degrades)
# HugePages not available (auto-falls back to mmap)

cd /mnt/c/Users/yourname/LingNet-Agent-OS
zig build
./zig-out/bin/lingnet-daemon
```

## Monitoring

### Prometheus Metrics

```bash
# Metrics endpoint (when HTTP server enabled)
curl http://localhost:9090/metrics

# Example output
# HELP lingnet_pool_common_free Number of free blocks in common pool
# TYPE lingnet_pool_common_free gauge
# lingnet_pool_common_free 9876
```

### Health Check

```bash
# Pool stats via log
grep "Pool stats" /var/log/lingnet.log

# Boot status
grep "Boot complete" /var/log/lingnet.log
```

## Troubleshooting

### eBPF Not Available
```
[MAIN] eBPF LSM not available, falling back to Seccomp-BPF
```
This is expected on kernels without `CONFIG_BPF_LSM`.

### HugePages Not Available
```
[MAIN] HugePages < 2048, falling back to MAP_LOCKED
```
Normal operation with reduced TLB efficiency.

### Compilation Errors
```
error: expected type expression, found '/'
```
Known Zig 0.17-dev compiler bug. Solution: `rm -rf .zig-cache && zig build`

### Test Failures (ABRT in WSL)
Some eBPF/tracepoint tests may ABRT in WSL due to seccomp restrictions. This is expected.

## Performance Tuning

### Arena Pool Sizing
```zig
// For high-throughput workloads
try gqap.initPools(allocator, 50000, 65536); // 3.2GB

// For embedded/constrained
try gqap.initPools(allocator, 1000, 4096); // 4MB
```

### io_uring Queue Depth
```zig
const config = switch.SwitchConfig{
    .io_uring_entries = 4096, // Default: 256
};
```

## Security Hardening

1. **Enable BPF LSM**: Add `lsm=bpf,locking,yama,integrity` to kernel cmdline
2. **Restrict syscalls**: Seccomp profile loaded automatically
3. **Network isolation**: VRF-based routing with eBPF audit
4. **Memory sanitization**: AVX2-accelerated AVX2 sanitize on all untrusted frees
