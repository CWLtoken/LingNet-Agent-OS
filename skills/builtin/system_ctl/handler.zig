//! L1 Built-in Skill: system_ctl
//! 预编译 .so, 启动时加载
//! 系统控制

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[system_ctl] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[system_ctl] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[system_ctl] deinitialized", .{});
}
