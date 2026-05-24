//! LingNet Agent OS V2.2 - Main Entry Point
//! Integrates: GQAP Arena, eBPF loader, MRC data plane, boot validation

const std = @import("std");
const gqap = @import("arena-gqap");
const ebpf = @import("ebpf-loader");
const mrc = @import("nullclaw-mrc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io; // M1: use for Io-driven file ops

    std.log.info("[MAIN] LingNet Agent OS V2.2 starting...", .{});

    // [1] Initialize GQAP Arena pools (10000 x 64KB = 640MB)
    try gqap.initPools(allocator, 10000, 64 * 1024);
    std.log.info("[MAIN] GQAP pools initialized: 10000 blocks x 64KB", .{});

    // [2] Boot security validation
    gqap.bootSecurityValidation() catch |err| {
        std.log.warn("[MAIN] Boot validation warning: {}", .{err});
    };

    // [3] Initialize eBPF registry
    var ebpf_reg = ebpf.EbpfRegistry.init(allocator);
    defer ebpf_reg.deinit();
    std.log.info("[MAIN] eBPF registry initialized", .{});

    // [4] Initialize MRC CAM table (256 entries)
    var cam_buf: [256]mrc.MrcCamEntry = undefined;
    var cam_table = mrc.MrcCamTable.init(&cam_buf);

    // Default rule: allow all (override with actual policy)
    try cam_table.add(mrc.MrcCamEntry{
        .key = .{},
        .action = .forward,
        .destination = 0,
        .flags = .{ .enabled = true, .sticky = true },
        .hit_count = 0,
    });

    // Initialize flow table (4096 buckets)
    var flow_buckets: [4096]mrc.MrcFlowTable.FlowBucket = undefined;
    const flow_table = mrc.MrcFlowTable.init(&flow_buckets);

    const _engine = mrc.MrcEngine{
        .cam = cam_table,
        .flows = flow_table,
        .default_action = .forward,
        .stats = .{},
    };
    _ = _engine;

    std.log.info("[MAIN] MRC engine ready (CAM=256, Flow=4096)", .{});

    // [5] Print pool stats
    const stats = gqap.getStats();
    std.log.info("[MAIN] Pool stats: common={}, quarantine={}, l2={}", .{
        stats.common_free, stats.quarantine_pending, stats.l2_free,
    });

    std.log.info("[MAIN] LingNet Agent OS V2.2 ready ✅", .{});

    // [6] Main loop (placeholder: M2 will add event loop)
    std.log.info("[MAIN] Entering idle loop (signal-driven, pre-M2)...", .{});
    while (true) {
        _ = std.os.linux.pause();
    }
}

test "MrcPacket flowHash deterministic" {
    var pkt = mrc.MrcPacket{};
    pkt.src_ip = 0x0A000001;
    pkt.dst_ip = 0x0A000002;
    pkt.src_port = 8080;
    pkt.dst_port = 443;
    pkt.protocol = 6; // TCP

    const h1 = pkt.flowHash();
    const h2 = pkt.flowHash();
    try std.testing.expectEqual(h1, h2);
}

test "MrcPacket setIntent/getIntent" {
    var pkt = mrc.MrcPacket{};
    pkt.setIntent("agent.ollama.chat");
    try std.testing.expectEqualStrings("agent.ollama.chat", pkt.getIntent());

    // Truncation test
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

    // Non-match
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
