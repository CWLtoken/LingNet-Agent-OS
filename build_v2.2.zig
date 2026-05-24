//! LingNet Agent OS V2.2 - build.zig
//! Integrates: eBPF compilation, GQAP module, CHD routing table, L0 linker script
//! Architecture: Zig 0.17 + libxev + eBPF LSM/Runtime monitoring

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // eBPF Target Definition (bpfel, no Zig std dependency)
    const bpf_target = b.resolveTargetQuery(.{
        .cpu_arch = .bpfel,
        .os_tag = .linux,
        .abi = .none,
    });

    // Compile eBPF LSM Policy (inode_permission hooks)
    const lsm_bpf_obj = b.addObject(.{
        .name = "lsm_policy",
        .root_source_file = b.path("ebpf/lsm_policy.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    lsm_bpf_obj.addIncludePath(b.path("ebpf/vmlinux"));

    // Compile eBPF Runtime Monitor (syscalls + arena audit)
    const monitor_bpf_obj = b.addObject(.{
        .name = "runtime_monitor",
        .root_source_file = b.path("ebpf/runtime_monitor.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    monitor_bpf_obj.addIncludePath(b.path("ebpf/vmlinux"));

    // Compile eBPF Arena Audit Probe (GQAP cross-tier leak detection)
    const arena_audit_bpf_obj = b.addObject(.{
        .name = "arena_audit",
        .root_source_file = b.path("ebpf/arena_audit.bpf.c"),
        .target = bpf_target,
        .optimize = .ReleaseFast,
    });
    arena_audit_bpf_obj.addIncludePath(b.path("ebpf/vmlinux"));

    // Embed BPF bytecode into Zig source via @embedFile
    const bpf_embed_step = b.addWriteFiles();
    _ = bpf_embed_step.addBytes("lsm_policy.bpf.o", "");
    _ = bpf_embed_step.addBytes("runtime_monitor.bpf.o", "");
    _ = bpf_embed_step.addBytes("arena_audit.bpf.o", "");

    // Compile L0 Core Skills (ROM segments, linked via linker.ld)
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

    // Compile L1 Built-in Skills (.so shared objects with sandbox policy)
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

    // Compile GQAP SDK Module (standalone library for testing)
    const gqap_mod = b.createModule(.{
        .root_source_file = b.path("sdk/arena_gqap.zig"),
    });

    const gqap_lib = b.addStaticLibrary(.{
        .name = "arena-gqap",
        .root_source_file = b.path("sdk/arena_gqap.zig"),
        .target = target,
        .optimize = optimize,
    });
    gqap_lib.root_module.addImport("nullclaw-mrc", b.createModule(.{
        .root_source_file = b.path("sdk/mrc.zig"),
    }));
    b.installArtifact(gqap_lib);

    // CHD Perfect Hash Routing Table Generator (comptime tool)
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

    // Main Daemon Binary (lingnet-daemon)
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
