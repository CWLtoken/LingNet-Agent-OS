//! L1 Built-in Skill: code_review
//! 预编译 .so, 启动时加载
//! 代码审查

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[code_review] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[code_review] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[code_review] deinitialized", .{});
}
