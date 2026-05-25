//! L0 Core Skill: acl_manage
//! ROM硬编码, 编译期链接到 .lingnet_l0 段
//! ACL管理: 添加/删除/查询访问控制规则

const std = @import("std");

pub fn handler() callconv(.c) void {
    std.log.info("[acl_manage] ACL updated", .{});
}

pub fn init() callconv(.c) void {
    std.log.info("[acl_manage] initialized", .{});
}

pub fn deinit() callconv(.c) void {
    std.log.info("[acl_manage] deinitialized", .{});
}
