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

    // === Skill Loader Module (M2+) ===

    // === Switch Plane Module ===
    const switch_mod = b.createModule(.{
        .root_source_file = b.path("src_switch.zig"),
        .target = target,
        .optimize = optimize,
    });
    switch_mod.addImport("arena-gqap", gqap_mod);
    switch_mod.addImport("nullclaw-mrc", mrc_mod);

    // === Boot Module ===
    const boot_mod = b.createModule(.{
        .root_source_file = b.path("src_boot.zig"),
        .target = target,
        .optimize = optimize,
    });
    boot_mod.addImport("arena-gqap", gqap_mod);
    boot_mod.addImport("nullclaw-mrc", mrc_mod);

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
}
