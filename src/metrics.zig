//! LingNet Agent OS V2.3 — Prometheus 指标暴露
//! /metrics 端点，暴露 pool stats / 路由延迟 / 系统指标

const std = @import("std");
const gqap = @import("arena-gqap");
const Allocator = std.mem.Allocator;

pub const MetricType = enum { counter, gauge, histogram };

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
            };
            try buf.print(self.allocator, "# TYPE {s} {s}\n", .{ metric.name, type_str });
            if (metric.labels.len == 0) {
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
};

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
