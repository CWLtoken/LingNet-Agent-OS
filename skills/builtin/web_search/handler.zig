//! L1 Built-in Skill: web_search
//! 预编译 .so, 启动时加载
//! 网络搜索

const std = @import("std");

pub fn skill_entry() callconv(.c) void {
    std.log.info("[web_search] executing", .{});
}

pub fn skill_init() callconv(.c) void {
    std.log.info("[web_search] initialized", .{});
}

pub fn skill_deinit() callconv(.c) void {
    std.log.info("[web_search] deinitialized", .{});
}
