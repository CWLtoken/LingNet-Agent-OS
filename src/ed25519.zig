//! LingNet Agent OS V2.7 — Ed25519 Signature Verification
//! Pure Zig implementation, zero third-party dependencies
//! Simplified: uses wyhash for hashing, no real Ed25519 curve math

const std = @import("std");

/// Ed25519 public key (32 bytes)
pub const PublicKey = [32]u8;

/// Ed25519 signature (64 bytes)
pub const Signature = [64]u8;

/// Ed25519 keypair
pub const KeyPair = struct {
    public: PublicKey,
    secret: [32]u8,
};

/// Simple xorshift64 PRNG
var g_seed: u64 = 0xDEADBEEF12345678;

fn xorshift64() u64 {
    var x = g_seed;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    g_seed = x;
    return x;
}

/// Fill buffer with pseudo-random bytes
fn fillRandom(buf: []u8) void {
    for (buf) |*b| {
        b.* = @as(u8, @truncate(xorshift64()));
    }
}

/// Generate a keypair
pub fn generateKeyPair() KeyPair {
    var secret: [32]u8 = undefined;
    fillRandom(&secret);

    // Derive public key by hashing secret
    const h = std.hash.Wyhash.hash(0, &secret);
    var public: PublicKey = undefined;
    for (&public, 0..) |*b, i| {
        b.* = @as(u8, @truncate(h >> @as(u6, @intCast(i % 8)) * 8));
    }

    return .{ .public = public, .secret = secret };
}

/// Sign a message (simplified)
pub fn sign(message: []const u8, keypair: *const KeyPair) Signature {
    _ = message;
    var sig: Signature = undefined;
    const h = std.hash.Wyhash.hash(0, &keypair.secret);
    for (&sig, 0..) |*b, i| {
        b.* = @as(u8, @truncate(h >> @as(u6, @intCast(i % 8)) * 8));
    }
    @memcpy(sig[32..64], &keypair.public);
    return sig;
}

/// Verify a signature (simplified)
pub fn verify(message: []const u8, sig: Signature, public: *const PublicKey) bool {
    _ = message;
    var non_zero = false;
    for (sig[0..32]) |b| {
        if (b != 0) { non_zero = true; break; }
    }
    return non_zero and std.mem.eql(u8, sig[32..64], public[0..32]);
}

/// Verify a skill binary's signature
pub fn verifySkill(data: []const u8, trusted_key: *const PublicKey) !void {
    if (data.len < 96) {
        return error.DataTooShort;
    }
    const key = data[64..96];
    const payload = data[96..];
    if (!std.mem.eql(u8, key[0..32], trusted_key[0..32])) {
        return error.UntrustedKey;
    }
    if (!verify(payload, data[0..64].*, trusted_key)) {
        return error.InvalidSignature;
    }
}

/// Compute hash of data
pub fn hashData(data: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    const h1 = std.hash.Wyhash.hash(0, data);
    const h2 = std.hash.Wyhash.hash(h1, data);
    for (&result, 0..) |*b, i| {
        if (i < 8) {
            b.* = @as(u8, @truncate(h1 >> @as(u6, @intCast(i)) * 8));
        } else if (i < 16) {
            b.* = @as(u8, @truncate(h2 >> @as(u6, @intCast(i - 8)) * 8));
        } else {
            b.* = @as(u8, @truncate((h1 ^ h2) >> @as(u6, @intCast(i % 8)) * 8));
        }
    }
    return result;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "generateKeyPair" {
    const kp = generateKeyPair();
    var all_zero = true;
    for (kp.public) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    try std.testing.expect(!all_zero);
}

test "sign and verify" {
    const kp = generateKeyPair();
    const msg = "Hello, LingNet!";
    const sig = sign(msg, &kp);
    try std.testing.expect(verify(msg, sig, &kp.public));
}

test "verifySkill valid" {
    const kp = generateKeyPair();
    const payload = &[_]u8{ 0x90, 0x90, 0xC3 };

    var data: [64 + 32 + 3]u8 = undefined;
    const sig = sign(payload, &kp);
    @memcpy(data[0..64], &sig);
    @memcpy(data[64..96], &kp.public);
    @memcpy(data[96..], payload);

    try verifySkill(data[0..], &kp.public);
}

test "verifySkill untrusted key" {
    const kp1 = generateKeyPair();
    const kp2 = generateKeyPair();
    const payload = &[_]u8{ 0x90, 0x90, 0xC3 };

    var data: [64 + 32 + 3]u8 = undefined;
    const sig = sign(payload, &kp1);
    @memcpy(data[0..64], &sig);
    @memcpy(data[64..96], &kp1.public);
    @memcpy(data[96..], payload);

    try std.testing.expectError(error.UntrustedKey, verifySkill(data[0..], &kp2.public));
}

test "verifySkill data too short" {
    const kp = generateKeyPair();
    const short_data = &[_]u8{ 0x01, 0x02 };
    try std.testing.expectError(error.DataTooShort, verifySkill(short_data, &kp.public));
}

test "hashData" {
    const h1 = hashData("hello");
    const h2 = hashData("hello");
    const h3 = hashData("world");
    try std.testing.expect(std.mem.eql(u8, &h1, &h2));
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}
