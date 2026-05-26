//! L1 Built-in Skill: daemon_spawn
//! 预编译 .so, 启动时加载
//! 守护进程生成

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[daemon_spawn] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[daemon_spawn] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[daemon_spawn] deinitialized", .{});
}
