//! L0 Core Skill: drop
//! ROM硬编码, 编译期链接到 .lingnet_l0 段
//! 丢弃当前请求/数据包

const std = @import("std");

pub fn handler() callconv(.c) void {
    std.log.info("[drop] packet dropped", .{});
}

pub fn init() callconv(.c) void {
    std.log.info("[drop] initialized", .{});
}

pub fn deinit() callconv(.c) void {
    std.log.info("[drop] deinitialized", .{});
}
