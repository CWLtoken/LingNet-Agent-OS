//! LingNet Agent OS V2.4 — Main Entry Point
//! Integrates: GQAP, eBPF, MRC, Switch, io_uring, Metrics, Boot, V1 Compat

const std = @import("std");
const gqap = @import("arena-gqap");
const ebpf = @import("ebpf-loader");
const mrc = @import("nullclaw-mrc");
const netlink = @import("tools-netlink-nl");
const boot = @import("boot");
const metrics = @import("metrics");
const v1compat = @import("v1-compat");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    std.log.info("[MAIN] LingNet Agent OS V2.4 starting...", .{});

    // ── [1] Boot Pre-flight Checks ──
    const boot_result = boot.bootCheck(.{}) catch |err| {
        std.log.err("[MAIN] Boot check failed: {}", .{err});
        return err;
    };
    std.log.info("[MAIN] Boot: kernel={} ebpf={} hugepages={} arena={}", .{
        boot_result.kernel_ok, boot_result.ebpf_loaded,
        boot_result.hugepages_ok, boot_result.arena_pooled,
    });

    // ── [2] Initialize GQAP Arena pools ──
    try gqap.initPools(allocator, 10000, 64 * 1024);
    std.log.info("[MAIN] GQAP pools: 10000 blocks x 64KB", .{});

    // ── [3] Boot security validation ──
    gqap.bootSecurityValidation() catch |err| {
        std.log.warn("[MAIN] Boot validation warning: {}", .{err});
    };

    // ── [4] Initialize eBPF registry ──
    var ebpf_reg = ebpf.EbpfRegistry.init(allocator);
    defer ebpf_reg.deinit();
    std.log.info("[MAIN] eBPF registry initialized", .{});

    // ── [5] Initialize MRC Data Plane ──
    var cam_buf: [256]mrc.MrcCamEntry = undefined;
    var cam_table = mrc.MrcCamTable.init(&cam_buf);
    try cam_table.add(mrc.MrcCamEntry{
        .key = .{},
        .action = .forward,
        .destination = 0,
        .flags = .{ .enabled = true, .sticky = true },
        .hit_count = 0,
    });

    var flow_buckets: [4096]mrc.MrcFlowTable.FlowBucket = undefined;
    const flow_table = mrc.MrcFlowTable.init(&flow_buckets);
    const engine = mrc.MrcEngine{
        .cam = cam_table,
        .flows = flow_table,
        .default_action = .forward,
        .stats = .{},
    };
    _ = engine;
    std.log.info("[MAIN] MRC engine ready (CAM=256, Flow=4096)", .{});

    // ── [6] Initialize Metrics ──
    var metrics_collector = metrics.MetricsCollector.init(allocator);
    defer metrics_collector.deinit();
    try metrics_collector.updatePoolStats();
    std.log.info("[MAIN] Metrics collector initialized", .{});

    // ── [7] Initialize Netlink ──
    var nl_sock = try netlink.NlSock.socket(allocator, netlink.NETLINK_GENERIC, 0);
    defer nl_sock.close();
    try nl_sock.bind(0, 0);
    std.log.info("[MAIN] Netlink socket ready (fd={d})", .{nl_sock.fd});

    // ── [8] Print system stats ──
    const stats = gqap.getStats();
    std.log.info("[MAIN] Pool stats: common={} quarantine={} l2={}", .{
        stats.common_free, stats.quarantine_pending, stats.l2_free,
    });

    // ── [9] V1 Compat available (no-op if not used) ──
    _ = v1compat.V1Compat.init(allocator);

    std.log.info("[MAIN] LingNet Agent OS V2.4 ready ✅", .{});
    std.log.info("[MAIN] Entering idle loop (signal-driven)...", .{});

    // ── [10] Main loop ──
    while (true) {
        _ = std.os.linux.pause();
    }
}

// ─── Tests ───────────────────────────────────────────────────────────

test "MrcPacket flowHash deterministic" {
    var pkt = mrc.MrcPacket{};
    pkt.src_ip = 0x0A000001;
    pkt.dst_ip = 0x0A000002;
    pkt.src_port = 8080;
    pkt.dst_port = 443;
    pkt.protocol = 6;

    const h1 = pkt.flowHash();
    const h2 = pkt.flowHash();
    try std.testing.expectEqual(h1, h2);
}

test "MrcPacket setIntent/getIntent" {
    var pkt = mrc.MrcPacket{};
    pkt.setIntent("agent.ollama.chat");
    try std.testing.expectEqualStrings("agent.ollama.chat", pkt.getIntent());

    var long_intent: [100]u8 = undefined;
    @memset(&long_intent, 'x');
    pkt.setIntent(&long_intent);
    try std.testing.expectEqual(@as(usize, 64), pkt.getIntent().len);
}

test "MrcCamTable basic lookup" {
    var buf: [16]mrc.MrcCamEntry = undefined;
    var cam = mrc.MrcCamTable.init(&buf);

    try cam.add(mrc.MrcCamEntry{
        .key = .{ .dst_port = 443, .protocol = 6 },
        .action = .forward,
        .destination = 1,
        .flags = .{ .enabled = true },
        .hit_count = 0,
    });

    var pkt = mrc.MrcPacket{};
    pkt.dst_port = 443;
    pkt.protocol = 6;

    const hit = cam.lookup(&pkt);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(mrc.MrcAction.forward, hit.?.action);

    pkt.dst_port = 80;
    const miss = cam.lookup(&pkt);
    try std.testing.expect(miss == null);
}

test "MrcFlow timeout detection" {
    var flow = mrc.MrcFlow{
        .id = 1,
        .packet = .{},
        .action = .forward,
        .hit_count = 0,
        .last_seen_ns = 1000,
        .timeout_ns = 500,
        .state = .established,
    };
    try std.testing.expect(flow.isExpired(2000));
    try std.testing.expect(!flow.isExpired(1400));
}
