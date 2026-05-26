//! LingNet Agent OS V2.2 - build.zig (Zig 0.17.0-dev.338)
//! M1: GQAP Arena + eBPF loader + MRC data plane + main executable

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === GQAP Arena Module (core dependency) ===
    const gqap_mod = b.createModule(.{
        .root_source_file = b.path("sdk_arena_gqap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === PHF Generator Module ===
    const phf_mod = b.createModule(.{
        .root_source_file = b.path("tools/phf_generator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === V2.3 New Modules ===
    const switch_mod = b.createModule(.{
        .root_source_file = b.path("src/switch.zig"),
        .target = target,
        .optimize = optimize,
    });
    switch_mod.addImport("arena-gqap", gqap_mod);

    const iouring_mod = b.createModule(.{
        .root_source_file = b.path("src/io_uring_route.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hugepages_mod = b.createModule(.{
        .root_source_file = b.path("sdk/hugepages.zig"),
        .target = target,
        .optimize = optimize,
    });

    const metrics_mod = b.createModule(.{
        .root_source_file = b.path("src/metrics.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_mod.addImport("arena-gqap", gqap_mod);

    // === MRC Data Plane Module ===
    const mrc_mod = b.createModule(.{
        .root_source_file = b.path("nullclaw-mrc.zig"),
        .target = target,
        .optimize = optimize,
    });
    mrc_mod.addImport("arena-gqap", gqap_mod);

    // === eBPF Loader Module ===
    const ebpf_mod = b.createModule(.{
        .root_source_file = b.path("tools_ebpf_loader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === Netlink API Module (libU_nl) ===
    const netlink_mod = b.createModule(.{
        .root_source_file = b.path("tools_netlink_nl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === ZMQ-ng Module (libzmq replacement) ===
    const zmq_mod = b.createModule(.{
        .root_source_file = b.path("tools_zmq_ng.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === Orchestrator Module ===
    const orch_mod = b.createModule(.{
        .root_source_file = b.path("src/orchestrator.zig"),
        .target = target,
        .optimize = optimize,
    });
    orch_mod.addImport("arena-gqap", gqap_mod);
    orch_mod.addImport("nullclaw-mrc", mrc_mod);

    // === CLI Module ===
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("arena-gqap", gqap_mod);

    // === Cognitive Bridge Module ===
    const cognitive_mod = b.createModule(.{
        .root_source_file = b.path("src/cognitive.zig"),
        .target = target,
        .optimize = optimize,
    });
    cognitive_mod.addImport("arena-gqap", gqap_mod);

    // === Sandbox Module ===
    const sandbox_mod = b.createModule(.{
        .root_source_file = b.path("sdk/sandbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_mod.addImport("arena-gqap", gqap_mod);

    // === Skill Loader Module (M2+) ===

    // === Boot Module ===
    const boot_mod = b.createModule(.{
        .root_source_file = b.path("src/boot.zig"),
        .target = target,
        .optimize = optimize,
    });
    boot_mod.addImport("arena-gqap", gqap_mod);

    // === V1 Compat Module ===
    const v1compat_mod = b.createModule(.{
        .root_source_file = b.path("src/v1_compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    v1compat_mod.addImport("arena-gqap", gqap_mod);

    // === eBPF Verify Module ===
    const bpf_verify_mod = b.createModule(.{
        .root_source_file = b.path("src/bpf_verify.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === VRF Test Module ===
    const vrf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/vrf_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    vrf_test_mod.addImport("arena-gqap", gqap_mod);

    // === Main Executable ===
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("arena-gqap", gqap_mod);
    main_mod.addImport("ebpf-loader", ebpf_mod);
    main_mod.addImport("nullclaw-mrc", mrc_mod);
    main_mod.addImport("tools-netlink-nl", netlink_mod);
    main_mod.addImport("tools-zmq-ng", zmq_mod);
    main_mod.addImport("switch", switch_mod);
    main_mod.addImport("io-uring-route", iouring_mod);
    main_mod.addImport("hugepages", hugepages_mod);
    main_mod.addImport("metrics", metrics_mod);
    main_mod.addImport("boot", boot_mod);
    main_mod.addImport("v1-compat", v1compat_mod);
    main_mod.addImport("bpf-verify", bpf_verify_mod);
    // === V2.5 Skill System ===
    const skill_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/skill_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    skill_loader_mod.addImport("arena-gqap", gqap_mod);
    const skill_scheduler_mod = b.createModule(.{
        .root_source_file = b.path("src/skill_scheduler.zig"),
        .target = target,
        .optimize = optimize,
    });
    skill_scheduler_mod.addImport("arena-gqap", gqap_mod);
    const vfs_mod = b.createModule(.{
        .root_source_file = b.path("sdk/vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_mod.addImport("arena-gqap", gqap_mod);
    main_mod.addImport("skill-loader", skill_loader_mod);
    main_mod.addImport("skill-scheduler", skill_scheduler_mod);
    main_mod.addImport("vfs", vfs_mod);

    // === V2.7 L2 Dynamic Skill System ===
    const ed25519_mod = b.createModule(.{
        .root_source_file = b.path("src/ed25519.zig"),
        .target = target,
        .optimize = optimize,
    });
    // libsodium headers needed for @cImport in ed25519.zig (used by Translate-C)
    ed25519_mod.linkSystemLibrary("sodium", .{});
    const l2_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/l2_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    l2_loader_mod.addImport("arena-gqap", gqap_mod);
    l2_loader_mod.addImport("ed25519", ed25519_mod);
    const skill_gen_mod = b.createModule(.{
        .root_source_file = b.path("skills/dynamic/generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    skill_gen_mod.addImport("arena-gqap", gqap_mod);
    main_mod.addImport("ed25519", ed25519_mod);
    main_mod.addImport("l2-loader", l2_loader_mod);
    main_mod.addImport("skill-gen", skill_gen_mod);

    // === V2.9 E2E Integration Tests ===
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("arena-gqap", gqap_mod);
    main_mod.addImport("e2e-test", e2e_mod);

    // === V2.6 eBPF Compilation Pipeline ===
    // Note: In production, these would be proper build steps with dependencies
    const bpf_target_triple = "bpfel-unknown-none";

    _ = b.addSystemCommand(&[_][]const u8{
        "clang", "-target", bpf_target_triple, "-O2", "-g",
        "-I", "/usr/include/x86_64-linux-gnu",
        "-I", "/usr/include",
        "-D__TARGET_ARCH_x86",
        "-c", "ebpf_lsm_policy.bpf.c",
        "-o", "ebpf_lsm_policy.o",
    });

    _ = b.addSystemCommand(&[_][]const u8{
        "clang", "-target", bpf_target_triple, "-O2", "-g",
        "-I", "/usr/include/x86_64-linux-gnu",
        "-I", "/usr/include",
        "-D__TARGET_ARCH_x86",
        "-c", "ebpf_runtime_monitor.bpf.c",
        "-o", "ebpf_runtime_monitor.o",
    });

    _ = b.addSystemCommand(&[_][]const u8{
        "clang", "-target", bpf_target_triple, "-O2", "-g",
        "-I", "/usr/include/x86_64-linux-gnu",
        "-I", "/usr/include",
        "-D__TARGET_ARCH_x86",
        "-c", "ebpf_arena_audit.bpf.c",
        "-o", "ebpf_arena_audit.o",
    });

    // Embed BPF ELF objects via @embedFile in boot.zig

    const exe = b.addExecutable(.{
        .name = "lingnet-daemon",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    // === Benchmark Executable ===
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench_gqap.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("arena-gqap", gqap_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench-gqap",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run GQAP benchmarks");
    bench_step.dependOn(&run_bench.step);

    // === Benchmark: MRC Data Plane ===
    const bench_mrc_mod = b.createModule(.{
        .root_source_file = b.path("bench_mrc.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mrc_mod.addImport("arena-gqap", gqap_mod);
    const bench_mrc_exe = b.addExecutable(.{
        .name = "bench-mrc",
        .root_module = bench_mrc_mod,
    });
    b.installArtifact(bench_mrc_exe);
    const run_bench_mrc = b.addRunArtifact(bench_mrc_exe);
    bench_step.dependOn(&run_bench_mrc.step);

    // === Benchmark: Routing Plane ===
    const bench_route_mod = b.createModule(.{
        .root_source_file = b.path("bench_route.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_route_mod.addImport("arena-gqap", gqap_mod);
    bench_route_mod.addImport("phf_generator", phf_mod);
    const bench_route_exe = b.addExecutable(.{
        .name = "bench-route",
        .root_module = bench_route_mod,
    });
    b.installArtifact(bench_route_exe);
    const run_bench_route = b.addRunArtifact(bench_route_exe);
    bench_step.dependOn(&run_bench_route.step);

    // === Benchmark: Performance (rdtsc + P99 histogram) ===
    const bench_perf_mod = b.createModule(.{
        .root_source_file = b.path("bench_perf.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_perf_mod.addImport("arena-gqap", gqap_mod);
    const bench_perf_exe = b.addExecutable(.{
        .name = "bench-perf",
        .root_module = bench_perf_mod,
    });
    b.installArtifact(bench_perf_exe);
    const run_bench_perf = b.addRunArtifact(bench_perf_exe);
    bench_step.dependOn(&run_bench_perf.step);

    // === Unit Tests: sdk_arena_gqap.zig ===
    const gqap_test = b.addTest(.{
        .root_module = gqap_mod,
    });
    const run_gqap_test = b.addRunArtifact(gqap_test);

    // === Unit Tests: nullclaw-mrc.zig ===
    const mrc_test_mod = b.createModule(.{
        .root_source_file = b.path("nullclaw-mrc.zig"),
        .target = target,
        .optimize = optimize,
    });
    mrc_test_mod.addImport("arena-gqap", gqap_mod);
    const mrc_test = b.addTest(.{
        .root_module = mrc_test_mod,
    });
    const run_mrc_test = b.addRunArtifact(mrc_test);

    // === Unit Tests: src/main.zig ===
    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("arena-gqap", gqap_mod);
    main_test_mod.addImport("ebpf-loader", ebpf_mod);
    main_test_mod.addImport("nullclaw-mrc", mrc_mod);
    main_test_mod.addImport("tools-netlink-nl", netlink_mod);
    main_test_mod.addImport("tools-zmq-ng", zmq_mod);
    const main_test = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_test = b.addRunArtifact(main_test);

    // === Unit Tests: tools_netlink_nl.zig (libU_nl) ===
    const netlink_test_mod = b.createModule(.{
        .root_source_file = b.path("tools_netlink_nl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const netlink_test = b.addTest(.{
        .root_module = netlink_test_mod,
    });
    const run_netlink_test = b.addRunArtifact(netlink_test);

    // === Test Step ===
    const test_step = b.step("test", "Run all LingNet unit tests");
    test_step.dependOn(&run_gqap_test.step);
    test_step.dependOn(&run_mrc_test.step);
    test_step.dependOn(&run_main_test.step);
    test_step.dependOn(&run_netlink_test.step);

    // === Unit Tests: tools_zmq_ng.zig (libzmq replacement) ===
    const zmq_test_mod = b.createModule(.{
        .root_source_file = b.path("tools_zmq_ng.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zmq_test = b.addTest(.{
        .root_module = zmq_test_mod,
    });
    const run_zmq_test = b.addRunArtifact(zmq_test);
    test_step.dependOn(&run_zmq_test.step);

    // === Unit Tests: src/orchestrator.zig ===
    const orch_test_mod = b.createModule(.{
        .root_source_file = b.path("src/orchestrator.zig"),
        .target = target,
        .optimize = optimize,
    });
    orch_test_mod.addImport("arena-gqap", gqap_mod);
    orch_test_mod.addImport("nullclaw-mrc", mrc_mod);
    const orch_test = b.addTest(.{ .root_module = orch_test_mod });
    const run_orch_test = b.addRunArtifact(orch_test);
    test_step.dependOn(&run_orch_test.step);

    // === Unit Tests: src/cli.zig ===
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_mod.addImport("arena-gqap", gqap_mod);
    const cli_test = b.addTest(.{ .root_module = cli_test_mod });
    const run_cli_test = b.addRunArtifact(cli_test);
    test_step.dependOn(&run_cli_test.step);

    // === Unit Tests: src/cognitive.zig ===
    const cognitive_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cognitive.zig"),
        .target = target,
        .optimize = optimize,
    });
    cognitive_test_mod.addImport("arena-gqap", gqap_mod);
    const cognitive_test = b.addTest(.{ .root_module = cognitive_test_mod });
    const run_cognitive_test = b.addRunArtifact(cognitive_test);
    test_step.dependOn(&run_cognitive_test.step);

    // === Unit Tests: sdk/sandbox.zig ===
    const sandbox_test_mod = b.createModule(.{
        .root_source_file = b.path("sdk/sandbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_test_mod.addImport("arena-gqap", gqap_mod);
    const sandbox_test = b.addTest(.{ .root_module = sandbox_test_mod });
    const run_sandbox_test = b.addRunArtifact(sandbox_test);
    test_step.dependOn(&run_sandbox_test.step);

    // === Unit Tests: tools/phf_generator.zig ===
    const phf_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/phf_generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const phf_test = b.addTest(.{ .root_module = phf_test_mod });
    const run_phf_test = b.addRunArtifact(phf_test);
    test_step.dependOn(&run_phf_test.step);

    // === Unit Tests: src/switch.zig (V2.3) ===
    const switch_test = b.addTest(.{ .root_module = switch_mod });
    const run_switch_test = b.addRunArtifact(switch_test);
    test_step.dependOn(&run_switch_test.step);

    // === Unit Tests: src/io_uring_route.zig (V2.3) ===
    const iouring_test = b.addTest(.{ .root_module = iouring_mod });
    const run_iouring_test = b.addRunArtifact(iouring_test);
    test_step.dependOn(&run_iouring_test.step);

    // === Unit Tests: sdk/hugepages.zig (V2.3) ===
    const hugepages_test = b.addTest(.{ .root_module = hugepages_mod });
    const run_hugepages_test = b.addRunArtifact(hugepages_test);
    test_step.dependOn(&run_hugepages_test.step);

    // === Unit Tests: src/metrics.zig (V2.3) ===
    const metrics_test = b.addTest(.{ .root_module = metrics_mod });
    const run_metrics_test = b.addRunArtifact(metrics_test);
    test_step.dependOn(&run_metrics_test.step);

    // === Unit Tests: src/boot.zig (V2.3) ===
    const boot_test = b.addTest(.{ .root_module = boot_mod });
    const run_boot_test = b.addRunArtifact(boot_test);
    test_step.dependOn(&run_boot_test.step);

    // === Unit Tests: src/v1_compat.zig (V2.3) ===
    const v1compat_test = b.addTest(.{ .root_module = v1compat_mod });
    const run_v1compat_test = b.addRunArtifact(v1compat_test);
    test_step.dependOn(&run_v1compat_test.step);

    // === Unit Tests: src/bpf_verify.zig (V2.3) ===
    const bpf_verify_test = b.addTest(.{ .root_module = bpf_verify_mod });
    const run_bpf_verify_test = b.addRunArtifact(bpf_verify_test);
    test_step.dependOn(&run_bpf_verify_test.step);

    // === Unit Tests: src/vrf_test.zig (V2.3) ===
    const vrf_test_test = b.addTest(.{ .root_module = vrf_test_mod });
    const run_vrf_test_test = b.addRunArtifact(vrf_test_test);
    test_step.dependOn(&run_vrf_test_test.step);

    // === Unit Tests: bench_perf.zig (V2.4) ===
    const perf_test_mod = b.createModule(.{
        .root_source_file = b.path("bench_perf.zig"),
        .target = target,
        .optimize = optimize,
    });
    perf_test_mod.addImport("arena-gqap", gqap_mod);
    const perf_test = b.addTest(.{ .root_module = perf_test_mod });
    const run_perf_test = b.addRunArtifact(perf_test);
    test_step.dependOn(&run_perf_test.step);

    // === Unit Tests: src/skill_loader.zig (V2.5) ===
    const skill_loader_test = b.addTest(.{ .root_module = skill_loader_mod });
    const run_skill_loader_test = b.addRunArtifact(skill_loader_test);
    test_step.dependOn(&run_skill_loader_test.step);

    // === Unit Tests: src/skill_scheduler.zig (V2.5) ===
    const skill_scheduler_test = b.addTest(.{ .root_module = skill_scheduler_mod });
    const run_skill_scheduler_test = b.addRunArtifact(skill_scheduler_test);
    test_step.dependOn(&run_skill_scheduler_test.step);

    // === Unit Tests: sdk/vfs.zig (V2.5) ===
    const vfs_test = b.addTest(.{ .root_module = vfs_mod });
    const run_vfs_test = b.addRunArtifact(vfs_test);
    test_step.dependOn(&run_vfs_test.step);

    // === Unit Tests: src/ed25519.zig (V2.7) ===
    const ed25519_test = b.addTest(.{ .root_module = ed25519_mod });
    const run_ed25519_test = b.addRunArtifact(ed25519_test);
    test_step.dependOn(&run_ed25519_test.step);

    // === Unit Tests: src/l2_loader.zig (V2.7) ===
    const l2_loader_test = b.addTest(.{ .root_module = l2_loader_mod });
    const run_l2_loader_test = b.addRunArtifact(l2_loader_test);
    test_step.dependOn(&run_l2_loader_test.step);

    // === Unit Tests: skills/dynamic/generator.zig (V2.7) ===
    const skill_gen_test = b.addTest(.{ .root_module = skill_gen_mod });
    const run_skill_gen_test = b.addRunArtifact(skill_gen_test);
    test_step.dependOn(&run_skill_gen_test.step);

    // === E2E Integration Tests: src/e2e_test.zig (V2.9) ===
    const e2e_test = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_test = b.addRunArtifact(e2e_test);
    test_step.dependOn(&run_e2e_test.step);
}
