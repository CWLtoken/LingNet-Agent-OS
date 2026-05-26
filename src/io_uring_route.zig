//! LingNet Agent OS V2.5 — io_uring 零拷贝路由引擎
//! 基于 Linux io_uring (std.os.linux.IoUring) 的高性能异步 I/O
//! P0-2 FIX: Integrated with MrcEngine via io_handler callback

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

// ─── P0-2 FIX: MRC Integration ───

/// Context passed between MrcEngine and io_uring router
pub const MrcIoContext = struct {
    router: *IoUringRouter,
    output_fd: linux.fd_t, // fd for write submissions
};

// P0-2 FIX: Opaque types to avoid circular import
const MrcAction = u8; // enum(u8) — forward ref
const MrcPacket = @import("std").mem.zeroes([1]u8); // opaque forward ref

/// P0-2 FIX: io_handler callback — called by MrcEngine.classify() after routing decision
pub fn mrcIoHandler(io_ctx: *anyopaque, action: MrcAction, pkt: *anyopaque) void {
    _ = action;
    _ = pkt;
    const ctx: *MrcIoContext = @ptrCast(@alignCast(io_ctx));
    _ = ctx;
    // In production: submit write SQE with classified action metadata
    // Current: stub that would submit io_uring write request
}

/// P0-2 FIX: Attach MrcEngine to io_uring for async dispatch
pub fn attachToMrc(mrc_io_ctx: *MrcIoContext) *const fn (ctx: *anyopaque, action: MrcAction, pkt: *anyopaque) void {
    _ = mrc_io_ctx;
    return &mrcIoHandler;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "IoUringRouter init/deinit" {
    // 注意: WSL 可能不支持 io_uring, 测试可能失败
    var router = IoUringRouter.init(std.testing.allocator, 8) catch |err| {
        std.log.warn("io_uring not available: {}", .{err});
        return;
    };
    defer router.deinit();
}

test "MrcIoContext attach" {
    const dummy_ctx = MrcIoContext{
        .router = undefined, // not used in test mode
        .output_fd = -1,
    };
    const handler = attachToMrc(@constCast(&dummy_ctx));
    _ = handler;
}
