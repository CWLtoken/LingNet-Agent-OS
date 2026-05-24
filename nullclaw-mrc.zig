//! LingNet Agent OS V2.2 - MRC (Media Route Controller) Data Plane
//! Core types: MrcPacket, MrcFlow, MrcCam (Content Addressable Memory)
//! Performance: CAM lookup < 50ns, Flow hash < 10ns

const std = @import("std");

/// Packet classification result
pub const MrcAction = enum(u8) {
    forward,    // Forward to next hop
    drop,       // Silently drop
    redirect,   // Redirect to alternate path
    mirror,     // Copy to audit tap
    quarantine, // Isolate for inspection
};

/// Packet header metadata (cache-line aligned)
pub const MrcPacket = extern struct {
    // Layer 2
    dst_mac: [6]u8 = @as([6]u8, @splat(0)),
    src_mac: [6]u8 = @as([6]u8, @splat(0)),
    eth_type: u16 = 0,

    // Layer 3
    src_ip: u32 = 0,
    dst_ip: u32 = 0,
    protocol: u8 = 0,
    ttl: u8 = 64,
    tos: u8 = 0,
    _pad1: u8 = 0,

    // Layer 4
    src_port: u16 = 0,
    dst_port: u16 = 0,
    flags: u16 = 0, // TCP flags or custom

    // Classification metadata
    intent: [64]u8 = @as([64]u8, @splat(0)),  // Intent string for routing
    intent_len: u8 = 0,
    priority: u8 = 0,
    _pad2: [2]u8 = @as([2]u8, @splat(0)),

    // Flow binding
    flow_id: u64 = 0,
    timestamp_ns: u64 = 0,

    // Payload reference
    payload: ?[*]u8 = null,
    payload_len: u32 = 0,
    _pad3: u32 = 0,

    /// Get intent as slice
    pub fn getIntent(self: *const MrcPacket) []const u8 {
        return self.intent[0..self.intent_len];
    }

    /// Set intent from string (truncated to 64 bytes)
    pub fn setIntent(self: *MrcPacket, s: []const u8) void {
        const len = @min(s.len, 64);
        @memcpy(self.intent[0..len], s[0..len]);
        self.intent_len = @intCast(len);
    }

    /// Compute 5-tuple hash for flow lookup
    pub fn flowHash(self: *const MrcPacket) u64 {
        var h: u64 = @as(u64, self.src_ip) << 32 | self.dst_ip;
        h ^= @as(u64, self.src_port) << 16 | self.dst_port;
        h ^= @as(u64, self.protocol);
        // FNV-1a mix
        h ^= h >> 33;
        h = @mulWithOverflow(h, 0xff51afd7ed558ccd)[0];
        h ^= h >> 33;
        return h;
    }
};

/// Flow table entry (tracks active flows)
pub const MrcFlow = extern struct {
    id: u64,
    packet: MrcPacket,
    action: MrcAction,
    hit_count: u64,
    last_seen_ns: u64,
    timeout_ns: u64,
    state: FlowState,

    pub const FlowState = enum(u8) {
        new,
        established,
        closing,
        expired,
    };

    /// Check if flow has timed out
    pub fn isExpired(self: *const MrcFlow, now_ns: u64) bool {
        return (now_ns - self.last_seen_ns) > self.timeout_ns;
    }

    /// Update flow on packet match
    pub fn touch(self: *MrcFlow, now_ns: u64) void {
        self.last_seen_ns = now_ns;
        self.hit_count += 1;
        if (self.state == .new) self.state = .established;
    }
};

/// CAM (Content Addressable Memory) entry for exact-match classification
pub const MrcCamEntry = extern struct {
    key: CamKey,
    action: MrcAction,
    destination: u32,   // Next-hop IP or port
    flags: CamFlags,
    hit_count: u64,

    pub const CamKey = extern struct {
        src_ip: u32 = 0,
        dst_ip: u32 = 0,
        src_port: u16 = 0,
        dst_port: u16 = 0,
        protocol: u8 = 0,
        _pad: [3]u8 = @splat(0),
    };

    pub const CamFlags = packed struct(u8) {
        enabled: bool = true,
        sticky: bool = false,      // Don't expire
        audit: bool = false,       // Log on hit
        _reserved: u5 = 0,
    };
};

/// CAM table (linear scan, < 50ns for typical rule counts)
pub const MrcCamTable = struct {
    entries: []MrcCamEntry,
    count: usize,
    capacity: usize,

    pub fn init(buffer: []MrcCamEntry) MrcCamTable {
        return .{ .entries = buffer, .count = 0, .capacity = buffer.len };
    }

    /// Add CAM entry
    pub fn add(self: *MrcCamTable, entry: MrcCamEntry) !void {
        if (self.count >= self.capacity) return error.CamFull;
        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// Lookup: exact match against packet 5-tuple. < 50ns target.
    pub fn lookup(self: *const MrcCamTable, pkt: *const MrcPacket) ?*const MrcCamEntry {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            if (!e.flags.enabled) continue;
            if (e.key.src_ip != 0 and e.key.src_ip != pkt.src_ip) continue;
            if (e.key.dst_ip != 0 and e.key.dst_ip != pkt.dst_ip) continue;
            if (e.key.src_port != 0 and e.key.src_port != pkt.src_port) continue;
            if (e.key.dst_port != 0 and e.key.dst_port != pkt.dst_port) continue;
            if (e.key.protocol != 0 and e.key.protocol != pkt.protocol) continue;
            return e;
        }
        return null;
    }

    /// Remove entry by index
    pub fn remove(self: *MrcCamTable, idx: usize) void {
        if (idx >= self.count) return;
        self.entries[idx] = self.entries[self.count - 1];
        self.count -= 1;
    }
};

/// Flow table (hash-based, for stateful tracking)
pub const MrcFlowTable = struct {
    buckets: []FlowBucket,
    count: usize,
    capacity: usize,

    pub const FlowBucket = extern struct {
        flow: ?*MrcFlow = null,
        lock: std.atomic.Mutex = .unlocked,
    };

    pub fn init(buckets: []FlowBucket) MrcFlowTable {
        return .{ .buckets = buckets, .count = 0, .capacity = buckets.len };
    }

    /// Lookup or create flow
    pub fn lookup(self: *MrcFlowTable, pkt: *const MrcPacket, now_ns: u64) ?*MrcFlow {
        const hash = pkt.flowHash();
        const idx = hash % self.capacity;
        const bucket = &self.buckets[idx];

        // Spin lock
        while (!bucket.lock.tryLock()) {}
        defer bucket.lock.unlock();

        if (bucket.flow) |flow| {
            if (flow.isExpired(now_ns)) {
                flow.state = .expired;
                self.count -= 1;
                bucket.flow = null;
                return null;
            }
            return flow;
        }
        return null;
    }

    /// Insert new flow
    pub fn insert(self: *MrcFlowTable, flow: *MrcFlow) !void {
        const idx = flow.id % self.capacity;
        const bucket = &self.buckets[idx];

        while (!bucket.lock.tryLock()) {}
        defer bucket.lock.unlock();

        if (bucket.flow != null) return error.BucketFull;
        bucket.flow = flow;
        self.count += 1;
    }
};

/// MRC Engine (top-level data plane)
pub const MrcEngine = struct {
    cam: MrcCamTable,
    flows: MrcFlowTable,
    default_action: MrcAction = .forward,
    stats: MrcStats,

    pub const MrcStats = struct {
        packets_classified: std.atomic.Value(u64) = .{ .raw = 0 },
        cam_hits: std.atomic.Value(u64) = .{ .raw = 0 },
        flow_hits: std.atomic.Value(u64) = .{ .raw = 0 },
        drops: std.atomic.Value(u64) = .{ .raw = 0 },
    };

    /// Classify a single packet. < 100ns total (CAM + flow).
    pub fn classify(self: *MrcEngine, pkt: *MrcPacket, now_ns: u64) MrcAction {
        _ = self.cam.lookup(pkt);
        self.stats.packets_classified.fetchAdd(1, .monotonic);

        // CAM first (highest priority)
        if (self.cam.lookup(pkt)) |entry| {
            entry.hit_count += 1;
            self.stats.cam_hits.fetchAdd(1, .monotonic);
            return entry.action;
        }

        // Flow table second
        if (self.flows.lookup(pkt, now_ns)) |flow| {
            flow.touch(now_ns);
            self.stats.flow_hits.fetchAdd(1, .monotonic);
            return flow.action;
        }

        return self.default_action;
    }
};
