//! LingNet Agent OS V2.3 — Prometheus 指标暴露
//! /metrics 端点，暴露 pool stats / 路由延迟 / 系统指标

const std = @import("std");
const gqap = @import("arena-gqap");
const Allocator = std.mem.Allocator;

pub const MetricType = enum { counter, gauge, histogram, summary };

/// P2-3 FIX: Summary metric for P99 latency tracking
pub const SummaryMetric = struct {
    name: []const u8,
    help: []const u8,
    quantiles: []const Quantile,

    pub const Quantile = struct {
        quantile: f64, // 0.0-1.0 (e.g. 0.99 for P99)
        value: f64,
    };
};

pub const Metric = struct {
    name: []const u8,
    help: []const u8,
    type: MetricType,
    value: f64,
    labels: []const Label,

    pub const Label = struct {
        key: []const u8,
        value: []const u8,
    };
};

pub const MetricsCollector = struct {
    allocator: Allocator,
    metrics: std.ArrayListAligned(Metric, null),

    pub fn init(allocator: Allocator) MetricsCollector {
        return .{
            .allocator = allocator,
            .metrics = std.ArrayListAligned(Metric, null).empty,
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.metrics.deinit(self.allocator);
    }

    pub fn register(self: *MetricsCollector, metric: Metric) !void {
        try self.metrics.append(self.allocator, metric);
    }

    pub fn updatePoolStats(self: *MetricsCollector) !void {
        const stats = gqap.getStats();
        try self.register(.{
            .name = "lingnet_pool_common_free",
            .help = "Number of free blocks in common pool",
            .type = .gauge,
            .value = @floatFromInt(stats.common_free),
            .labels = &.{},
        });
        try self.register(.{
            .name = "lingnet_pool_quarantine_pending",
            .help = "Number of blocks pending sanitization",
            .type = .gauge,
            .value = @floatFromInt(stats.quarantine_pending),
            .labels = &.{},
        });
        try self.register(.{
            .name = "lingnet_pool_l2_free",
            .help = "Number of sanitized blocks in L2 pool",
            .type = .gauge,
            .value = @floatFromInt(stats.l2_free),
            .labels = &.{},
        });
        try self.register(.{
            .name = "lingnet_pool_total_sanitized",
            .help = "Total blocks sanitized since boot",
            .type = .counter,
            .value = @floatFromInt(stats.total_sanitized),
            .labels = &.{},
        });
        try self.register(.{
            .name = "lingnet_pool_total_violations",
            .help = "Total security violations detected",
            .type = .counter,
            .value = @floatFromInt(stats.total_violations),
            .labels = &.{},
        });
    }

    pub fn formatPrometheus(self: *MetricsCollector, buf: *std.ArrayListAligned(u8, null)) !void {
        for (self.metrics.items) |metric| {
            try buf.print(self.allocator, "# HELP {s} {s}\n", .{ metric.name, metric.help });
            const type_str = switch (metric.type) {
                .counter => "counter",
                .gauge => "gauge",
                .histogram => "histogram",
                .summary => "summary",
            };
            try buf.print(self.allocator, "# TYPE {s} {s}\n", .{ metric.name, type_str });
            // P2-3 FIX: Summary outputs _sum and _count
            if (metric.type == .summary) {
                try buf.print(self.allocator, "{s}_sum {d:.0}\n", .{ metric.name, metric.value });
                try buf.print(self.allocator, "{s}_count {d:.0}\n\n", .{ metric.name, metric.value });
            } else if (metric.labels.len == 0) {
                try buf.print(self.allocator, "{s} {d:.0}\n\n", .{ metric.name, metric.value });
            } else {
                try buf.print(self.allocator, "{s}{{", .{metric.name});
                for (metric.labels, 0..) |label, i| {
                    if (i > 0) try buf.appendSlice(self.allocator, ",");
                    try buf.print(self.allocator, "{s}=\"{s}\"", .{ label.key, label.value });
                }
                try buf.print(self.allocator, "}} {d:.0}\n\n", .{metric.value});
            }
        }
    }

    pub fn formatJson(self: *MetricsCollector, buf: *std.ArrayListAligned(u8, null)) !void {
        try buf.appendSlice(self.allocator, "{\n  \"metrics\": [\n");
        for (self.metrics.items, 0..) |metric, i| {
            try buf.print(self.allocator, "    {{\n      \"name\": \"{s}\",\n      \"type\": \"{s}\",\n      \"value\": {d:.0}\n    }}", .{ metric.name, @tagName(metric.type), metric.value });
            if (i < self.metrics.items.len - 1) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "\n");
        }
        try buf.appendSlice(self.allocator, "  ]\n}\n");
    }

    /// P2-1 FIX: Simple HTTP server for /metrics endpoint on specified port
    pub fn serveHttp(self: *MetricsCollector, port: u16) !void {
        const address = std.net.Address.parseIp("0.0.0.0", port) catch |err| {
            std.log.err("[Metrics] Failed to parse address: {}", .{err});
            return err;
        };
        var server = std.net.Server.init(.{});
        defer server.deinit();

        try server.listen(address);
        std.log.info("[Metrics] HTTP server listening on 0.0.0.0:{d}", .{port});

        while (true) {
            const conn = try server.accept();
            self.handleConn(conn.stream) catch |err| {
                std.log.warn("[Metrics] Connection handler error: {}", .{err});
            };
            conn.stream.close();
        }
    }

    /// P2-1 FIX: Handle a single HTTP connection
    fn handleConn(self: *MetricsCollector, stream: std.net.Server.Connection.Stream) !void {
        var buf: [4096]u8 = undefined;
        const stream_reader = stream.reader();
        const bytes_read = try stream_reader.read(&buf);
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];
        const is_metrics = std.mem.indexOf(u8, request, "GET /metrics") != null;

        var body = std.ArrayListAligned(u8, null).empty;
        defer body.deinit(self.allocator);

        try self.updatePoolStats();
        if (is_metrics) {
            try self.formatPrometheus(&body);
        } else {
            try body.appendSlice(self.allocator, "LingNet Agent OS Metrics\nGET /metrics for Prometheus format\n");
        }

        var header_buf: [256]u8 = undefined;
        const header_len = try std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{body.items.len},
        );

        const stream_writer = stream.writer();
        try stream_writer.writeAll(header_buf[0..header_len]);
        try stream_writer.writeAll(body.items);
    }
};

/// P2-1 FIX: Spawn metrics HTTP server in a thread
pub fn spawnMetricsServer(collector: *MetricsCollector, port: u16) !std.Thread {
    return std.Thread.spawn(.{}, struct {
        fn run(c: *MetricsCollector, p: u16) void {
            c.serveHttp(p) catch |err| {
                std.log.err("[Metrics] Server error: {}", .{err});
            };
        }
    }.run, .{ collector, port });
}

// ─── Tests ───────────────────────────────────────────────────────────

test "MetricsCollector init/deinit" {
    var collector = MetricsCollector.init(std.testing.allocator);
    defer collector.deinit();
    try std.testing.expectEqual(@as(usize, 0), collector.metrics.items.len);
}

test "MetricsCollector formatPrometheus" {
    var collector = MetricsCollector.init(std.testing.allocator);
    defer collector.deinit();

    try collector.register(.{
        .name = "test_counter",
        .help = "A test counter",
        .type = .counter,
        .value = 42.0,
        .labels = &.{},
    });

    var buf = std.ArrayListAligned(u8, null).empty;
    defer buf.deinit(std.testing.allocator);

    try collector.formatPrometheus(&buf);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "test_counter 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# HELP test_counter A test counter") != null);
}

test "MetricsCollector formatJson" {
    var collector = MetricsCollector.init(std.testing.allocator);
    defer collector.deinit();

    try collector.register(.{
        .name = "test_gauge",
        .help = "A test gauge",
        .type = .gauge,
        .value = 3.14,
        .labels = &.{},
    });

    var buf = std.ArrayListAligned(u8, null).empty;
    defer buf.deinit(std.testing.allocator);

    try collector.formatJson(&buf);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\": \"test_gauge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\": 3") != null);
}
