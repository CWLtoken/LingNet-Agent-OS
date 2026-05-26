//! L1 Built-in Skill: soul
//! 预编译 .so, 启动时加载
//! Soul引擎: 人格模拟

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[soul] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[soul] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[soul] deinitialized", .{});
}
