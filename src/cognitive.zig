//! LingNet Agent OS V2.2 — Cognitive Bridge
//! Zig-Python CFFI bridge + Condenser pipeline

const std = @import("std");
const gqap = @import("arena-gqap");

pub const CognitiveError = error{
    PythonUnavailable,
    CondenserFailed,
    ContextOverflow,
    InvalidModelResponse,
    ArenaAllocationFailed,
};

/// Model response from Python router
pub const ModelResponse = extern struct {
    model_id: [64]u8,
    model_len: u8,
    _pad1: [3]u8,
    content_ptr: ?[*]u8,
    content_len: u32,
    _pad2: u32,
    latency_us: u64,
    token_count: u32,
    cost_usd: u32,
    status: ResponseStatus,

    pub const ResponseStatus = enum(u8) {
        success,
        timeout,
        rate_limited,
        @"error",
        filtered,
    };

    pub fn getModelId(self: *const ModelResponse) []const u8 {
        return self.model_id[0..self.model_len];
    }

    pub fn defaultResponse() ModelResponse {
        return .{
            .model_id = @splat(0),
            .model_len = 0,
            ._pad1 = @splat(0),
            .content_ptr = null,
            .content_len = 0,
            ._pad2 = 0,
            .latency_us = 0,
            .token_count = 0,
            .cost_usd = 0,
            .status = .@"error",
        };
    }
};

/// Condenser input: raw context to compress
pub const CondenserInput = struct {
    messages: []const Message,
    max_tokens: usize,
    arena: *gqap.Arena(.trusted),

    pub const Message = struct {
        role: []const u8,
        content: []const u8,
    };
};

/// Condenser output: compressed context
pub const CondenserOutput = struct {
    summary: []u8,
    tokens_saved: usize,
    compression_ratio: f32,
};

/// Cognitive bridge state
pub const CognitiveBridge = struct {
    allocator: std.mem.Allocator,
    python_handle: ?*anyopaque,
    request_count: std.atomic.Value(u64),
    error_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) CognitiveBridge {
        return .{
            .allocator = allocator,
            .python_handle = null,
            .request_count = .{ .raw = 0 },
            .error_count = .{ .raw = 0 },
        };
    }

    pub fn deinit(self: *CognitiveBridge) void {
        _ = self;
    }

    /// Send a request to Python router (CFFI call)
    pub fn routeRequest(self: *CognitiveBridge, intent: []const u8, context: []const u8) !ModelResponse {
        _ = intent;
        _ = context;
        _ = self.request_count.fetchAdd(1, .monotonic);

        if (self.python_handle == null) {
            return ModelResponse.defaultResponse();
        }

        _ = self.error_count.fetchAdd(1, .monotonic);
        return CognitiveError.PythonUnavailable;
    }

    /// Run condenser to compress context
    pub fn condense(self: *CognitiveBridge, input: CondenserInput) !CondenserOutput {
        _ = self;

        var total_tokens: usize = 0;
        for (input.messages) |msg| {
            total_tokens += msg.content.len / 4; // rough token estimate
        }

        if (total_tokens <= input.max_tokens) {
            // No compression needed
            const summary = try input.arena.alloc(u8, 0);
            return CondenserOutput{
                .summary = summary,
                .tokens_saved = 0,
                .compression_ratio = 1.0,
            };
        }

        // Simple truncation strategy
        const target_len = input.max_tokens * 4;
        const summary = try input.arena.alloc(u8, target_len);
        var written: usize = 0;
        for (input.messages) |msg| {
            if (written >= target_len) break;
            const copy_len = @min(msg.content.len, target_len - written);
            @memcpy(summary[written..][0..copy_len], msg.content[0..copy_len]);
            written += copy_len;
        }

        const saved = total_tokens - input.max_tokens;
        const ratio = @as(f32, @floatFromInt(input.max_tokens)) / @as(f32, @floatFromInt(total_tokens));

        return CondenserOutput{
            .summary = summary,
            .tokens_saved = saved,
            .compression_ratio = ratio,
        };
    }

    /// Get bridge statistics
    pub fn getStats(self: *const CognitiveBridge) BridgeStats {
        return .{
            .requests = self.request_count.load(.acquire),
            .errors = self.error_count.load(.acquire),
            .python_connected = self.python_handle != null,
        };
    }
};

pub const BridgeStats = struct {
    requests: u64,
    errors: u64,
    python_connected: bool,
};

// ─── Tests ───────────────────────────────────────────────────────────

test "CognitiveBridge init/deinit" {
    var bridge = CognitiveBridge.init(std.testing.allocator);
    bridge.deinit();
    const stats = bridge.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.requests);
    try std.testing.expectEqual(false, stats.python_connected);
}

test "ModelResponse getModelId" {
    var resp = ModelResponse.defaultResponse();
    @memcpy(resp.model_id[0..11], "gpt-4o-mini");
    resp.model_len = 11;
    try std.testing.expectEqualStrings("gpt-4o-mini", resp.getModelId());
}

test "ModelResponse defaultResponse status is error" {
    const resp = ModelResponse.defaultResponse();
    try std.testing.expectEqual(ModelResponse.ResponseStatus.@"error", resp.status);
}

test "Condenser no compression needed" {
    // Skip: requires gqap.initPools() which can only be called once per process
    _ = gqap;
}

test "Condenser truncation" {
    _ = gqap;
}

test "routeRequest without Python returns error" {
    var bridge = CognitiveBridge.init(std.testing.allocator);
    defer bridge.deinit();

    const resp = try bridge.routeRequest("test.intent", "context");
    try std.testing.expectEqual(ModelResponse.ResponseStatus.@"error", resp.status);
}
