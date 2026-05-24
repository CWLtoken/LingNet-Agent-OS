//! LingNet Agent OS V2.2 - build.zig (Zig 0.17.0-dev.338)
//! M0: Compile existing modules only (skills/, src/main.zig, nullclaw-mrc deferred to M1+)

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

    // === Unit Tests: sdk_arena_gqap.zig ===
    const gqap_test_mod = b.createModule(.{
        .root_source_file = b.path("sdk_arena_gqap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gqap_test = b.addTest(.{ .root_module = gqap_test_mod });
    const run_gqap_test = b.addRunArtifact(gqap_test);

    // === Benchmark: bench_gqap.zig ===
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench_gqap.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("arena-gqap", gqap_mod);
    const bench = b.addExecutable(.{
        .name = "bench-gqap",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    // === Test Step ===
    const test_step = b.step("test", "Run all LingNet unit tests");
    test_step.dependOn(&run_gqap_test.step);
}
