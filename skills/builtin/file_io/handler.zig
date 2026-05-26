//! L1 Built-in Skill: file_io
//! 预编译 .so, 启动时加载
//! 文件I/O

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[file_io] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[file_io] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[file_io] deinitialized", .{});
}
