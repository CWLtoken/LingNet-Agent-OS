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
    const exe = b.addExecutable(.{
        .name = "lingnet-daemon",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

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
    const main_test = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_test = b.addRunArtifact(main_test);

    // === Test Step ===
    const test_step = b.step("test", "Run all LingNet unit tests");
    test_step.dependOn(&run_gqap_test.step);
    test_step.dependOn(&run_mrc_test.step);
    test_step.dependOn(&run_main_test.step);
}
