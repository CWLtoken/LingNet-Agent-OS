//! L1 Built-in Skill: library
//! 预编译 .so, 启动时加载
//! 库管理

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[library] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[library] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[library] deinitialized", .{});
}
