//! L1 Built-in Skill: bash_exec
//! 预编译 .so, 启动时加载
//! Bash执行

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[bash_exec] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[bash_exec] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[bash_exec] deinitialized", .{});
}
