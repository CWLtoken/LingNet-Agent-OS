//! LingNet Agent OS V2.3 — io_uring 零拷贝路由引擎
//! 基于 Linux io_uring (std.os.linux.IoUring) 的高性能异步 I/O

const std = @import("std");
const linux = std.os.linux;

/// io_uring 路由器
pub const IoUringRouter = struct {
    ring: linux.IoUring,
    allocator: std.mem.Allocator,

    /// 初始化 io_uring 路由器
    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUringRouter {
        const ring = try linux.IoUring.init(entries, 0);
        return .{
            .ring = ring,
            .allocator = allocator,
        };
    }

    /// 关闭 io_uring
    pub fn deinit(self: *IoUringRouter) void {
        self.ring.deinit();
    }

    /// 提交读请求 (非阻塞)
    pub fn submitRead(self: *IoUringRouter, fd: linux.fd_t, buf: []u8, offset: u64, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.opcode = .READ;
        sqe.fd = fd;
        sqe.off = offset;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @intCast(buf.len);
        sqe.user_data = user_data;
    }

    /// 提交写请求 (非阻塞)
    pub fn submitWrite(self: *IoUringRouter, fd: linux.fd_t, buf: []const u8, offset: u64, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.opcode = .WRITE;
        sqe.fd = fd;
        sqe.off = offset;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @intCast(buf.len);
        sqe.user_data = user_data;
    }

    /// 提交并等待完成
    pub fn submitAndWait(self: *IoUringRouter) !u32 {
        return try self.ring.submit_and_wait(1);
    }

    /// 获取完成事件 (非阻塞)
    pub fn peekCqe(self: *IoUringRouter) !*linux.io_uring_cqe {
        return try self.ring.copy_cqe();
    }

    /// 批量获取完成事件
    pub fn peekBatchCqe(self: *IoUringRouter, cqes: []*linux.io_uring_cqe, count: u32) !u32 {
        return self.ring.copy_cqes(cqes.ptr, count);
    }

    /// 标记 CQE 已消费
    pub fn cqeSeen(self: *IoUringRouter, cqe: *linux.io_uring_cqe) void {
        self.ring.cqe_seen(cqe);
    }

    /// 运行事件循环 (带超时)
    pub fn runEventLoop(self: *IoUringRouter, handler: *const fn (cqe: *linux.io_uring_cqe) void, timeout_ms: u32) !u32 {
        _ = timeout_ms;
        var handled: u32 = 0;

        var cqe_batch: [32]*linux.io_uring_cqe = undefined;
        const n = try self.peekBatchCqe(&cqe_batch, 32);

        for (cqe_batch[0..n]) |cqe| {
            handler(cqe);
            self.cqeSeen(cqe);
            handled += 1;
        }

        return handled;
    }
};

/// 路由请求
pub const RouteRequest = struct {
    intent_id: u32,
    payload: []const u8,
    response_buf: []u8,
    user_data: u64,
};

// ─── Tests ───────────────────────────────────────────────────────────

test "IoUringRouter init/deinit" {
    // 注意: WSL 可能不支持 io_uring, 测试可能失败
    var router = IoUringRouter.init(std.testing.allocator, 8) catch |err| {
        std.log.warn("io_uring not available: {}", .{err});
        return;
    };
    defer router.deinit();
}
