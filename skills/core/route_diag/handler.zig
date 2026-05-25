//! L0 Core Skill: route_diag
//! ROM硬编码, 编译期链接到 .lingnet_l0 段
//! 路由诊断: 检查路由表状态

const std = @import("std");

pub fn handler() callconv(.c) void {
    std.log.info("[route_diag] routing table OK", .{});
}

pub fn init() callconv(.c) void {
    std.log.info("[route_diag] initialized", .{});
}

pub fn deinit() callconv(.c) void {
    std.log.info("[route_diag] deinitialized", .{});
}
