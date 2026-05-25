//! L1 Built-in Skill: email
//! 预编译 .so, 启动时加载
//! 邮件发送/接收

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[email] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[email] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[email] deinitialized", .{});
}
