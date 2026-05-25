//! L1 Built-in Skill: vision
//! 预编译 .so, 启动时加载
//! 视觉处理

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[vision] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[vision] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[vision] deinitialized", .{});
}
