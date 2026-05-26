//! L1 Built-in Skill: data_query
//! 预编译 .so, 启动时加载
//! 数据查询

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[data_query] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[data_query] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[data_query] deinitialized", .{});
}
