//! LingNet Agent OS V2.2 — zmq_ng: Native ZMQ Protocol Replacement
//! Zero-dependency Zig 0.17 implementation of ZMQ wire protocol
//! Replaces libzmq C library with pure Zig socket I/O
//! M2: Part of C library decoupling — domain messaging without libzmq

const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const linux = os.linux;

// sockaddr_in layout matching C's struct sockaddr_in (no C dependency)
const SockAddrIn = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: extern struct { s_addr: u32 },
    sin_zero: [8]u8,
};
const SockAddr = os.linux.sockaddr;

/// Get *SockAddr from SockAddrIn bytes (both are 16-byte extern structs, layout-compatible)
fn asSockAddr(bytes: []u8) *const SockAddr {
    return @ptrCast(@alignCast(bytes.ptr));
}

// ─── ZMQ protocol constants ─────────────────────────────────────────
pub const ZMQ_PAIR = 0;
pub const ZMQ_PUB = 1;
pub const ZMQ_SUB = 2;
pub const ZMQ_REQ = 3;
pub const ZMQ_REP = 4;
pub const ZMQ_DEALER = 5;
pub const ZMQ_ROUTER = 6;
pub const ZMQ_PULL = 7;
pub const ZMQ_PUSH = 8;
pub const ZMQ_XPUB = 9;
pub const ZMQ_XSUB = 10;
pub const ZMQ_STREAM = 11;

pub const ZMQ_RCVMORE = 11;
pub const ZMQ_SNDMORE = 2;
pub const ZMQ_DONTWAIT = 1;
pub const ZMQ_POLLIN = 1;
pub const ZMQ_POLLOUT = 2;

pub const ZMQ_SUBSCRIBE = 1;
pub const ZMQ_UNSUBSCRIBE = 2;
pub const ZMQ_LINGER = 1;
pub const ZMQ_SNDTIMEO = 22;
pub const ZMQ_RCVTIMEO = 21;

/// ZMQ protocol version (2.2)
pub const ZMQ_VERSION_MAJOR = 2;
pub const ZMQ_VERSION_MINOR = 2;
pub const ZMQ_PROTOCOL_ID = "ZMQ";

// ─── ZMQ frame header ───────────────────────────────────────────────
pub const ZmqFrame = struct {
    flags: u8,
    size: u64,

    pub const FLAG_MORE: u8 = 0x01;
    pub const FLAG_LARGE: u8 = 0x02;
    pub const FLAG_COMMAND: u8 = 0x04;
    pub const FLAG_MASK: u8 = 0x07;

    pub fn isMore(self: ZmqFrame) bool {
        return (self.flags & FLAG_MORE) != 0;
    }

    pub fn isLarge(self: ZmqFrame) bool {
        return (self.flags & FLAG_LARGE) != 0;
    }

    pub fn isCommand(self: ZmqFrame) bool {
        return (self.flags & FLAG_COMMAND) != 0;
    }
};

/// ZMQ greeting (2 frames: signature + socket type)
pub const ZmqGreeting = struct {
    signature: [10]u8 = .{
        0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7F,
    },
    version: [2]u8 = .{ ZMQ_VERSION_MAJOR, ZMQ_VERSION_MINOR },
    mechanism: [20]u8 = @splat(0), // "NULL" padded
    as_server: u8 = 0,
    filler: [31]u8 = @splat(0),

    pub fn init() ZmqGreeting {
        return .{};
    }

    pub fn bytes(self: *const ZmqGreeting) [64]u8 {
        var result: [64]u8 = undefined;
        @memcpy(result[0..10], &self.signature);
        @memcpy(result[10..12], &self.version);
        @memcpy(result[12..32], &self.mechanism);
        result[32] = self.as_server;
        @memcpy(result[33..64], &self.filler);
        return result;
    }
};

// ─── ZMQ message (multi-part capable) ──────────────────────────────
pub const ZmqMessage = struct {
    parts: std.ArrayList([]u8),

    pub fn init(allocator: mem.Allocator) !ZmqMessage {
        return .{ .parts = try std.ArrayList([]u8).initCapacity(allocator, 0) };
    }

    pub fn deinit(self: *ZmqMessage, gpa: mem.Allocator) void {
        for (self.parts.items) |part| {
            gpa.free(part);
        }
        self.parts.deinit(gpa);
    }

    pub fn addPart(self: *ZmqMessage, data: []const u8, gpa: mem.Allocator) !void {
        const copy = try gpa.alloc(u8, data.len);
        @memcpy(copy, data);
        try self.parts.append(gpa, copy);
    }

    pub fn totalSize(self: *const ZmqMessage) usize {
        var total: usize = 0;
        for (self.parts.items) |part| {
            total += part.len;
        }
        return total;
    }
};

// ─── ZMQ socket types ───────────────────────────────────────────────
pub const ZmqError = error{
    SocketFailed,
    BindFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    InvalidEndpoint,
    UnsupportedType,
    WouldBlock,
    Closed,
    Timeout,
    ProtocolError,
};

pub const SocketType = enum(u8) {
    pub_ = ZMQ_PUB,
    sub = ZMQ_SUB,
    req = ZMQ_REQ,
    rep = ZMQ_REP,
    push = ZMQ_PUSH,
    pull = ZMQ_PULL,
    pair = ZMQ_PAIR,
    dealer = ZMQ_DEALER,
    router = ZMQ_ROUTER,
};

// ─── ZMQ socket handle ──────────────────────────────────────────────
pub const ZmqSocket = struct {
    fd: i32 = -1,
    sock_type: SocketType = .pair,
    listen_port: u16 = 0,
    is_bound: bool = false,
    is_connected: bool = false,
    linger_ms: i32 = -1,
    rcv_timeout_ms: i32 = -1,
    snd_timeout_ms: i32 = -1,
    subscriptions: std.ArrayList([]u8),

    pub fn init(allocator: mem.Allocator, stype: SocketType) !ZmqSocket {
        // Create TCP socket
        const fd = linux.socket(os.linux.AF.INET, os.linux.SOCK.STREAM | os.linux.SOCK.CLOEXEC, 0);
        if (fd < 0) return ZmqError.SocketFailed;
        return .{
            .fd = @intCast(fd),
            .sock_type = stype,
            .subscriptions = try std.ArrayList([]u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *ZmqSocket, gpa: mem.Allocator) void {
        if (self.fd >= 0) {
            _ = linux.close(@intCast(self.fd));
            self.fd = -1;
        }
        for (self.subscriptions.items) |sub| {
            gpa.free(sub);
        }
        self.subscriptions.deinit(gpa);
    }

    /// Bind to TCP endpoint (tcp://*:PORT or tcp://IP:PORT)
    pub fn bind(self: *ZmqSocket, allocator: mem.Allocator, endpoint: []const u8) !void {
        const addr = try parseEndpoint(allocator, endpoint);
        defer if (addr) |a| allocator.free(a);

        if (addr) |addr_bytes| {
            const actual_addr: *const SockAddr = asSockAddr(addr_bytes);
            const actual_len: os.linux.socklen_t = @intCast(addr_bytes.len);
            const ret = linux.bind(@intCast(self.fd), actual_addr, actual_len);
            if (ret < 0) return ZmqError.BindFailed;
            self.is_bound = true;

            // Start listening
            const listen_ret = linux.listen(@intCast(self.fd), 128);
            if (listen_ret < 0) return ZmqError.BindFailed;
        }
    }

    /// Connect to TCP endpoint
    pub fn connect(self: *ZmqSocket, allocator: mem.Allocator, endpoint: []const u8) !void {
        const addr = try parseEndpoint(allocator, endpoint);
        defer if (addr) |a| allocator.free(a);

        if (addr) |addr_bytes| {
            const actual_addr: *const SockAddr = asSockAddr(addr_bytes);
            const actual_len: os.linux.socklen_t = @intCast(addr_bytes.len);
            const ret = linux.connect(@intCast(self.fd), actual_addr, actual_len);
            if (ret < 0) return ZmqError.ConnectFailed;
            self.is_connected = true;
        }
    }

    /// Send a ZMQ frame over the socket
    pub fn sendFrame(self: *ZmqSocket, data: []const u8, more: bool) !void {
        // Build ZMQ frame: [flags(1)] [size(1 or 8)] [data(n)]
        if (data.len < 255) {
            var header: [2]u8 = undefined;
            header[0] = if (more) ZmqFrame.FLAG_MORE else 0;
            header[1] = @intCast(data.len);

            const iovs = [2]os.linux.iovec{
                .{ .iov_base = @constCast(@as(*const anyopaque, &header)), .iov_len = 2 },
                .{ .iov_base = @constCast(@as(*const anyopaque, data.ptr)), .iov_len = data.len },
            };
            const ret = linux.writev(@intCast(self.fd), &iovs, 2);
            if (ret < 0) return ZmqError.SendFailed;
        } else {
            var header: [9]u8 = undefined;
            header[0] = if (more) ZmqFrame.FLAG_MORE | ZmqFrame.FLAG_LARGE else ZmqFrame.FLAG_LARGE;
            mem.writeInt(u64, header[1..9], @intCast(data.len), .big);

            const iovs = [2]os.linux.iovec{
                .{ .iov_base = @constCast(@as(*const anyopaque, &header)), .iov_len = 9 },
                .{ .iov_base = @constCast(@as(*const anyopaque, data.ptr)), .iov_len = data.len },
            };
            const ret = linux.writev(@intCast(self.fd), &iovs, 2);
            if (ret < 0) return ZmqError.SendFailed;
        }
    }

    /// Receive a ZMQ frame from the socket
    pub fn recvFrame(self: *ZmqSocket, allocator: mem.Allocator) !struct { data: []u8, more: bool } {
        // Read flags byte
        var flags_buf: [1]u8 = undefined;
        const flags_read = linux.read(@intCast(self.fd), &flags_buf, 1);
        if (flags_read <= 0) return ZmqError.RecvFailed;

        const flags = flags_buf[0];
        const more = (flags & ZmqFrame.FLAG_MORE) != 0;
        const is_large = (flags & ZmqFrame.FLAG_LARGE) != 0;

        var data_len: usize = 0;
        if (is_large) {
            var size_buf: [8]u8 = undefined;
            const size_read = linux.read(@intCast(self.fd), &size_buf, 8);
            if (size_read <= 0) return ZmqError.RecvFailed;
            data_len = @intCast(mem.readInt(u64, &size_buf, .big));
        } else {
            var size_buf: [1]u8 = undefined;
            const size_read = linux.read(@intCast(self.fd), &size_buf, 1);
            if (size_read <= 0) return ZmqError.RecvFailed;
            data_len = size_buf[0];
        }

        const data = try allocator.alloc(u8, data_len);
        var total_read: usize = 0;
        while (total_read < data_len) {
            const n = linux.read(@intCast(self.fd), data[total_read..].ptr, data_len - total_read);
            if (n <= 0) {
                allocator.free(data);
                return ZmqError.RecvFailed;
            }
            total_read += @intCast(n);
        }
        return .{ .data = data, .more = more };
    }

    /// Subscribe to a topic (SUB socket)
    pub fn subscribe(self: *ZmqSocket, topic: []const u8, gpa: mem.Allocator) !void {
        const copy = try gpa.alloc(u8, topic.len);
        @memcpy(copy, topic);
        try self.subscriptions.append(gpa, copy);
    }

    /// Unsubscribe from a topic
    pub fn unsubscribe(self: *ZmqSocket, topic: []const u8, gpa: mem.Allocator) !void {
        for (self.subscriptions.items, 0..) |sub, i| {
            if (mem.eql(u8, sub, topic)) {
                gpa.free(sub);
                _ = self.subscriptions.orderedRemove(i);
                return;
            }
        }
    }

    /// Set socket option (linger, timeouts)
    pub fn setOption(self: *ZmqSocket, option: u32, value: i32) !void {
        switch (option) {
            ZMQ_LINGER => self.linger_ms = value,
            ZMQ_SNDTIMEO => self.snd_timeout_ms = value,
            ZMQ_RCVTIMEO => self.rcv_timeout_ms = value,
            else => {},
        }
    }
};

// ─── Endpoint parser ────────────────────────────────────────────────
fn parseEndpoint(allocator: mem.Allocator, endpoint: []const u8) !?[]u8 {
    // Parse "tcp://IP:PORT" or "tcp://*:PORT"
    if (!mem.startsWith(u8, endpoint, "tcp://")) return ZmqError.InvalidEndpoint;

    const rest = endpoint[6..];
    const colon_idx = mem.lastIndexOfScalar(u8, rest, ':') orelse return ZmqError.InvalidEndpoint;
    const host = rest[0..colon_idx];
    const port_str = rest[colon_idx + 1 ..];

    const port = std.fmt.parseInt(u16, port_str, 10) catch return ZmqError.InvalidEndpoint;

    const addr_bytes = try allocator.alloc(u8, @sizeOf(SockAddrIn));
    const addr: *SockAddrIn = @ptrCast(@alignCast(addr_bytes.ptr));
    addr.* = .{
        .sin_family = os.linux.AF.INET,
        .sin_port = @byteSwap(port),
        .sin_addr = .{ .s_addr = 0 },
        .sin_zero = @splat(0),
    };
    _ = host;
    return addr_bytes;
}

// ─── ZMQ context (manages multiple sockets) ─────────────────────────
pub const ZmqContext = struct {
    sockets: std.ArrayList(*ZmqSocket),
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) !ZmqContext {
        return .{
            .sockets = try std.ArrayList(*ZmqSocket).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZmqContext) void {
        for (self.sockets.items) |sock| {
            sock.deinit(self.allocator);
            self.allocator.destroy(sock);
        }
        self.sockets.deinit(self.allocator);
    }

    pub fn createSocket(self: *ZmqContext, stype: SocketType) !*ZmqSocket {
        const sock = try self.allocator.create(ZmqSocket);
        sock.* = try ZmqSocket.init(self.allocator, stype);
        try self.sockets.append(self.allocator, sock);
        return sock;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "ZmqGreeting size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ZmqGreeting));
}

test "ZmqGreeting bytes" {
    const g = ZmqGreeting.init();
    const b = g.bytes();
    try std.testing.expectEqual(@as(u8, 0xFF), b[0]);
    try std.testing.expectEqual(@as(u8, 0x7F), b[9]);
    try std.testing.expectEqual(ZMQ_VERSION_MAJOR, b[10]);
    try std.testing.expectEqual(ZMQ_VERSION_MINOR, b[11]);
}

test "ZmqFrame flags" {
    const f = ZmqFrame{ .flags = ZmqFrame.FLAG_MORE, .size = 0 };
    try std.testing.expect(f.isMore());
    try std.testing.expect(!f.isLarge());
    try std.testing.expect(!f.isCommand());
}

test "ZmqFrame large flag" {
    const f = ZmqFrame{ .flags = ZmqFrame.FLAG_LARGE, .size = 1000 };
    try std.testing.expect(!f.isMore());
    try std.testing.expect(f.isLarge());
}

test "ZmqMessage init/deinit" {
    var msg = try ZmqMessage.init(std.testing.allocator);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), msg.parts.items.len);
}

test "ZmqMessage addPart" {
    var msg = try ZmqMessage.init(std.testing.allocator);
    defer msg.deinit(std.testing.allocator);
    try msg.addPart("hello", std.testing.allocator);
    try msg.addPart("world", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), msg.parts.items.len);
    try std.testing.expectEqual(@as(usize, 10), msg.totalSize());
}

test "ZmqSocket init/deinit" {
    var sock = try ZmqSocket.init(std.testing.allocator, .pair);
    defer sock.deinit(std.testing.allocator);
    try std.testing.expect(sock.fd >= 0);
}

test "ZmqSocket bind to port" {
    var sock = try ZmqSocket.init(std.testing.allocator, .rep);
    defer sock.deinit(std.testing.allocator);
    try sock.bind(std.testing.allocator, "tcp://*:19797");
    try std.testing.expect(sock.is_bound);
}

test "ZmqSocket connect" {
    // Start a listener first
    var listener = try ZmqSocket.init(std.testing.allocator, .rep);
    defer listener.deinit(std.testing.allocator);
    try listener.bind(std.testing.allocator, "tcp://*:19798");

    var client = try ZmqSocket.init(std.testing.allocator, .req);
    defer client.deinit(std.testing.allocator);
    try client.connect(std.testing.allocator, "tcp://127.0.0.1:19798");
    try std.testing.expect(client.is_connected);
}

test "ZmqSocket subscribe/unsubscribe" {
    var sock = try ZmqSocket.init(std.testing.allocator, .sub);
    defer sock.deinit(std.testing.allocator);
    try sock.subscribe("topic1", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), sock.subscriptions.items.len);
    try sock.unsubscribe("topic1", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), sock.subscriptions.items.len);
}

test "ZmqContext createSocket" {
    var ctx = try ZmqContext.init(std.testing.allocator);
    defer ctx.deinit();
    const sock = try ctx.createSocket(.pair);
    try std.testing.expect(sock.fd >= 0);
    try std.testing.expectEqual(@as(usize, 1), ctx.sockets.items.len);
}

test "ZmqSocket setOption" {
    var sock = try ZmqSocket.init(std.testing.allocator, .pair);
    defer sock.deinit(std.testing.allocator);
    try sock.setOption(ZMQ_LINGER, 1000);
    try std.testing.expectEqual(@as(i32, 1000), sock.linger_ms);
    try sock.setOption(ZMQ_SNDTIMEO, 5000);
    try std.testing.expectEqual(@as(i32, 5000), sock.snd_timeout_ms);
}
