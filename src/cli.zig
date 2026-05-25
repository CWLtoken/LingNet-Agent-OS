//! LingNet Agent OS V2.2 — CLI (lingnet-cli)
//! Commands: status, create-vrf, destroy-vrf, skill-load, skill-unlist, bench

const std = @import("std");
const gqap = @import("arena-gqap");

pub const CliError = error{
    InvalidCommand,
    MissingArgument,
    VrfNotFound,
    SkillNotFound,
    OutOfMemory,
};

pub const Command = enum {
    status,
    create_vrf,
    destroy_vrf,
    skill_load,
    skill_unload,
    bench,
    help,
};

/// Parse command from args
pub fn parseCommand(args: []const []const u8) !struct { cmd: Command, args: []const []const u8 } {
    if (args.len < 2) return CliError.InvalidCommand;

    const cmd_str = args[1];
    const cmd: Command = if (std.mem.eql(u8, cmd_str, "status"))
        .status
    else if (std.mem.eql(u8, cmd_str, "create-vrf"))
        .create_vrf
    else if (std.mem.eql(u8, cmd_str, "destroy-vrf"))
        .destroy_vrf
    else if (std.mem.eql(u8, cmd_str, "skill-load"))
        .skill_load
    else if (std.mem.eql(u8, cmd_str, "skill-unload"))
        .skill_unload
    else if (std.mem.eql(u8, cmd_str, "bench"))
        .bench
    else if (std.mem.eql(u8, cmd_str, "help"))
        .help
    else
        return CliError.InvalidCommand;

    return .{ .cmd = cmd, .args = args[2..] };
}

/// Format pool stats as human-readable string
pub fn formatPoolStats(stats: gqap.PoolStats, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\ LingNet Agent OS V2.2 — Pool Stats
        \\ ─────────────────────────────────
        \\ Common Pool:     {} free
        \\ Quarantine Pool: {} pending
        \\ L2 Pool:         {} free
        \\ Sanitized:       {} blocks
        \\ Violations:      {} (MUST be 0)
    , .{
        stats.common_free,
        stats.quarantine_pending,
        stats.l2_free,
        stats.total_sanitized,
        stats.total_violations,
    });
}

/// Format orchestrator stats
pub fn formatOrchStats(vrf_count: usize, active_vrfs: u32, skill_count: usize, sanitizer_alive: bool, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\ LingNet Agent OS V2.2 — Orchestrator
        \\ ────────────────────────────────────
        \\ VRFs:       {} total, {} active
        \\ Skills:     {} registered
        \\ Sanitizer:  {s}
    , .{ vrf_count, active_vrfs, skill_count, if (sanitizer_alive) "alive ✅" else "dead ❌" });
}

/// Print usage help
pub fn printHelp() void {
    std.log.info("{s}",
        \\ LingNet Agent OS V2.2 — CLI Usage
        \\ ─────────────────────────────────
        \\ lingnet-cli status              Show pool + orchestrator stats
        \\ lingnet-cli create-vrf          Create a new VRF instance
        \\ lingnet-cli destroy-vrf <id>    Destroy VRF by ID
        \\ lingnet-cli skill-load <name>   Register a skill
        \\ lingnet-cli skill-unload <name> Unregister a skill
        \\ lingnet-cli bench               Run micro-benchmarks
        \\ lingnet-cli help                Show this help
    );
}

// ─── Tests ───────────────────────────────────────────────────────────

test "parseCommand status" {
    const args = &[_][]const u8{ "lingnet-cli", "status" };
    const result = try parseCommand(args);
    try std.testing.expectEqual(Command.status, result.cmd);
}

test "parseCommand create_vrf" {
    const args = &[_][]const u8{ "lingnet-cli", "create-vrf" };
    const result = try parseCommand(args);
    try std.testing.expectEqual(Command.create_vrf, result.cmd);
}

test "parseCommand invalid" {
    const args = &[_][]const u8{ "lingnet-cli", "invalid" };
    try std.testing.expectError(CliError.InvalidCommand, parseCommand(args));
}

test "formatPoolStats" {
    const stats = gqap.PoolStats{
        .common_free = 9990,
        .quarantine_pending = 5,
        .l2_free = 50,
        .total_sanitized = 100,
        .total_violations = 0,
    };
    const buf = try formatPoolStats(stats, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "9990 free") != null);
}

test "formatOrchStats" {
    const buf = try formatOrchStats(2, 2, 5, true, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "2 total") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "alive ✅") != null);
}
