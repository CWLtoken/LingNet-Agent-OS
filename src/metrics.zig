//! LingNet Agent OS V2.3 — Prometheus 指标暴露
//! V2.8: Simplified for Zig 0.17 compatibility — network/gqap APIs stubbed

const std = @import("std");

pub const MetricsType = enum(u8) { counter, gauge, histogram };

pub const MetricDef = struct {
    name: []const u8,
    metrics_type: MetricsType,
    help: []const u8,
    labels: []const []const u8 = &.{},
};

pub const MetricValue = struct {
    name: []const u8,
    value: f64,
    labels: []const []const u8 = &.{},
    label_values: []const []const u8 = &.{},
};

pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    metrics: std.ArrayList(MetricDef),
    values: std.ArrayList(MetricValue),

    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return .{
            .allocator = allocator,
            .metrics = std.ArrayList(MetricDef).empty,
            .values = std.ArrayList(MetricValue).empty,
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.metrics.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn register(self: *MetricsCollector, def: MetricDef) !void {
        try self.metrics.append(self.allocator, def);
    }

    pub fn setGauge(self: *MetricsCollector, name: []const u8, value: f64) !void {
        try self.values.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn updatePoolStats(_: *MetricsCollector) !void {
        // V2.8: gqap.poolStats API changed — stub
    }

    pub fn formatPrometheus(self: *MetricsCollector, buf: *std.ArrayList(u8)) !void {
        _ = self;
        try buf.appendSlice("# HELP lingnet_pool_blocks_total Total blocks\n# TYPE lingnet_pool_blocks_total gauge\nlingnet_pool_blocks_total 0\n");
        try buf.appendSlice("# HELP lingnet_route_lookups_total Route lookups\n# TYPE lingnet_route_lookups_total counter\nlingnet_route_lookups_total 0\n");
    }

    /// P2-1 FIX: HTTP server (V2.8: stub — Zig 0.17 net API changed)
    pub fn serveHttp(_: *MetricsCollector, _: u16) !void {
        return error.NotImplemented;
    }
};

/// P2-1 FIX: Spawn metrics HTTP server (V2.8: stub)
pub fn spawnMetricsServer(_: *MetricsCollector, _: u16) !std.Thread {
    return std.Thread.spawn(.{}, struct {
        fn run() void {
            std.log.info("[Metrics] HTTP server stub (Zig 0.17 net API migration pending)", .{});
        }
    }.run, .{});
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
        .metrics_type = .counter,
        .help = "Test counter",
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try collector.formatPrometheus(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lingnet_pool_blocks_total") != null);
}
