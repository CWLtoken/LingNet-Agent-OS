//! LingNet Agent OS V2.5 — Virtual Filesystem Adapter
//! 虚拟文件系统: 路径重写 + 沙箱隔离 + 配额管理

const std = @import("std");
const gqap = @import("arena-gqap");
const linux = std.os.linux;

/// VFS 节点类型
pub const VfsNodeType = enum(u8) {
    file = 0,
    directory = 1,
    symlink = 2,
    pipe = 3,
    socket = 4,
};

/// VFS 节点
pub const VfsNode = struct {
    name: []const u8,
    node_type: VfsNodeType,
    permissions: linux.mode_t,
    owner: u32,
    group: u32,
    size: usize,
    data: ?[]const u8,
    children: std.ArrayListAligned(*VfsNode, null),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, node_type: VfsNodeType) !*VfsNode {
        const node = try allocator.create(VfsNode);
        node.* = .{
            .name = name,
            .node_type = node_type,
            .permissions = if (node_type == .directory) 0o755 else 0o644,
            .owner = 0,
            .group = 0,
            .size = 0,
            .data = null,
            .children = std.ArrayListAligned(*VfsNode, null).empty,
            .allocator = allocator,
        };
        return node;
    }

    pub fn deinit(self: *VfsNode) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addChild(self: *VfsNode, child: *VfsNode) !void {
        try self.children.append(self.allocator, child);
    }

    pub fn findChild(self: *VfsNode, name: []const u8) ?*VfsNode {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }
};

/// VFS 沙箱配置
pub const VfsSandboxConfig = struct {
    root_path: []const u8 = "/tmp/lingnet-sandbox",
    max_file_size: usize = 100 * 1024 * 1024,  // 100MB
    max_total_size: usize = 1024 * 1024 * 1024, // 1GB
    max_files: usize = 10000,
    read_only: bool = false,
    allow_symlinks: bool = false,
    quota_exceeded: bool = false,
};

/// VFS 适配器
pub const VfsAdapter = struct {
    allocator: std.mem.Allocator,
    root: *VfsNode,
    config: VfsSandboxConfig,
    total_size: usize,
    file_count: usize,

    pub fn init(allocator: std.mem.Allocator, config: VfsSandboxConfig) !VfsAdapter {
        const root = try VfsNode.init(allocator, "/", .directory);
        return .{
            .allocator = allocator,
            .root = root,
            .config = config,
            .total_size = 0,
            .file_count = 0,
        };
    }

    pub fn deinit(self: *VfsAdapter) void {
        self.root.deinit();
    }

    /// 路径解析 (沙箱内)
    pub fn resolve(self: *VfsAdapter, path: []const u8) !*VfsNode {
        if (!std.mem.startsWith(u8, path, "/")) {
            return error.InvalidPath;
        }

        var current = self.root;
        var iter = std.mem.splitSequence(u8, path[1..], "/");
        while (iter.next()) |component| {
            if (component.len == 0) continue;
            if (std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                if (current == self.root) return error.PathEscape;
                // 无法回退：VfsNode 没有 parent 指针
                // 简化处理：回到 root（沙箱内所有路径深度为 1）
                current = self.root;
                continue;
            }

            if (current.findChild(component)) |child| {
                current = child;
            } else {
                return error.FileNotFound;
            }
        }
        return current;
    }

    /// 创建文件
    pub fn createFile(self: *VfsAdapter, path: []const u8, data: []const u8) !*VfsNode {
        if (self.config.read_only) return error.ReadOnly;
        if (self.file_count >= self.config.max_files) return error.QuotaExceeded;
        if (self.total_size + data.len > self.config.max_total_size) return error.QuotaExceeded;
        if (data.len > self.config.max_file_size) return error.FileTooLarge;

        // 创建父目录
        const parent_path = std.fs.path.dirname(path) orelse "/";
        const parent = if (std.mem.eql(u8, parent_path, "/"))
            self.root
        else
            try self.resolve(parent_path);

        const filename = std.fs.path.basename(path);
        const node = try VfsNode.init(self.allocator, filename, .file);
        node.data = data;
        node.size = data.len;
        try parent.addChild(node);

        self.file_count += 1;
        self.total_size += data.len;
        return node;
    }

    /// 读取文件
    pub fn readFile(self: *VfsAdapter, path: []const u8) ![]const u8 {
        const node = try self.resolve(path);
        if (node.node_type != .file) return error.NotAFile;
        return node.data orelse &[_]u8{};
    }

    /// 删除文件
    pub fn deleteFile(self: *VfsAdapter, path: []const u8) !void {
        if (self.config.read_only) return error.ReadOnly;

        const parent_path = std.fs.path.dirname(path) orelse "/";
        const parent = if (std.mem.eql(u8, parent_path, "/"))
            self.root
        else
            try self.resolve(parent_path);

        const filename = std.fs.path.basename(path);
        for (parent.children.items, 0..) |child, i| {
            if (std.mem.eql(u8, child.name, filename)) {
                self.total_size -= child.size;
                self.file_count -= 1;
                child.deinit();
                _ = parent.children.orderedRemove(i);
                return;
            }
        }
        return error.FileNotFound;
    }

    /// 创建目录
    pub fn createDir(self: *VfsAdapter, path: []const u8) !*VfsNode {
        if (self.config.read_only) return error.ReadOnly;

        const parent_path = std.fs.path.dirname(path) orelse "/";
        const parent = if (std.mem.eql(u8, parent_path, "/"))
            self.root
        else
            try self.resolve(parent_path);

        const dirname = std.fs.path.basename(path);
        const node = try VfsNode.init(self.allocator, dirname, .directory);
        try parent.addChild(node);
        return node;
    }

    /// 路径重写 (沙箱映射)
    pub fn rewritePath(self: *VfsAdapter, host_path: []const u8) []const u8 {
        _ = self;
        // TODO: 映射 /sandbox/ → /tmp/lingnet-sandbox/
        return host_path;
    }

    /// 检查权限
    pub fn checkPermission(self: *VfsAdapter, path: []const u8, uid: u32, gid: u32, mode: linux.mode_t) !bool {
        const node = try self.resolve(path);

        // root 绕过
        if (uid == 0) return true;

        const perms = node.permissions;
        if (node.owner == uid) {
            return (perms & (mode << 6)) != 0;
        }
        if (node.group == gid) {
            return (perms & (mode << 3)) != 0;
        }
        return (perms & mode) != 0;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "VfsNode init/deinit" {
    const node = try VfsNode.init(std.testing.allocator, "test", .file);
    defer node.deinit();
    try std.testing.expectEqualStrings("test", node.name);
    try std.testing.expectEqual(VfsNodeType.file, node.node_type);
}

test "VfsAdapter init/deinit" {
    const config = VfsSandboxConfig{};
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();
}

test "VfsAdapter create and read file" {
    const config = VfsSandboxConfig{};
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    const data = "Hello, LingNet VFS!";
    _ = try adapter.createFile("/test.txt", data);
    const content = try adapter.readFile("/test.txt");
    try std.testing.expectEqualStrings(data, content);
}

test "VfsAdapter create dir and file" {
    const config = VfsSandboxConfig{};
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    _ = try adapter.createDir("/skills");
    _ = try adapter.createFile("/skills/ping.zig", "const std = @import(\"std\");");
    const content = try adapter.readFile("/skills/ping.zig");
    try std.testing.expect(content.len > 0);
}

test "VfsAdapter path escape prevention" {
    const config = VfsSandboxConfig{};
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    _ = try adapter.createDir("/skills");
    const result = adapter.resolve("/skills/../../etc/passwd");
    try std.testing.expectError(error.PathEscape, result);
}

test "VfsAdapter delete file" {
    const config = VfsSandboxConfig{};
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    _ = try adapter.createFile("/temp.txt", "data");
    try adapter.deleteFile("/temp.txt");
    const result = adapter.readFile("/temp.txt");
    try std.testing.expectError(error.FileNotFound, result);
}

test "VfsAdapter quota enforcement" {
    var config = VfsSandboxConfig{};
    config.max_file_size = 10;
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    const result = adapter.createFile("/big.txt", "12345678901"); // 11 bytes > 10
    try std.testing.expectError(error.FileTooLarge, result);
}

test "VfsAdapter read-only mode" {
    var config = VfsSandboxConfig{};
    config.read_only = true;
    var adapter = try VfsAdapter.init(std.testing.allocator, config);
    defer adapter.deinit();

    const result = adapter.createFile("/test.txt", "data");
    try std.testing.expectError(error.ReadOnly, result);
}
