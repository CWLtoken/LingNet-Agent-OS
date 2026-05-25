//! L0 Core Skill: health_check
//! ROM硬编码, 编译期链接到 .lingnet_l0 段

const std = @import("std");
const gqap = @import("arena-gqap");

pub fn handler() callconv(.c) void {
    const stats = gqap.getStats();
    std.log.info("[health_check] common_free={} quarantine={} l2_free={}", .{
        stats.common_free, stats.quarantine_pending, stats.l2_free,
    });
}

pub fn init() callconv(.c) void {
    std.log.info("[health_check] initialized", .{});
}

pub fn deinit() callconv(.c) void {
    std.log.info("[health_check] deinitialized", .{});
}
