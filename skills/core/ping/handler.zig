//! L0 Core Skill: ping
//! ROM硬编码, 编译期链接到 .lingnet_l0 段

const std = @import("std");

pub fn handler() callconv(.c) void {
    std.log.info("[ping] pong", .{});
}

pub fn init() callconv(.c) void {
    std.log.info("[ping] initialized", .{});
}

pub fn deinit() callconv(.c) void {
    std.log.info("[ping] deinitialized", .{});
}
