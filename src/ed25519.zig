//! LingNet Agent OS V2.3 — Ed25519 Signature Verification
//! Pure-Zig fallback implementation (no libsodium dependency).
//! Real libsodium linking is done at the build level for the main executable.
//! P0-6 FIX: Fallback returns error instead of silently accepting fake signatures.

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

/// P0-6 FIX: Error set for fallback mode
pub const Ed25519Error = error{
    /// Fallback mode: real Ed25519 requires libsodium at build time
    NoRealEd25519,
};

/// u64 to little-endian bytes
fn u64ToBytes(val: u64) [8]u8 {
    var buf: [8]u8 = undefined;
    @memcpy(std.mem.asBytes(&buf), std.mem.asBytes(&val));
    return buf;
}

/// Generate a keypair (pure-Zig fallback — NOT real Ed25519).
pub fn generateKeyPair() KeyPair {
    var secret: [32]u8 = undefined;
    // P0-6 FIX: Simple seeded PRNG (test-only, not real Ed25519)
    var stack_val: u64 = undefined;
    const seed = @as(u64, @intFromPtr(&stack_val));
    @memcpy(secret[0..8], &u64ToBytes(std.hash.Wyhash.hash(seed, "k1")));
    @memcpy(secret[8..16], &u64ToBytes(std.hash.Wyhash.hash(seed + 1, "k2")));
    @memcpy(secret[16..24], &u64ToBytes(std.hash.Wyhash.hash(seed + 2, "k3")));
    @memcpy(secret[24..32], &u64ToBytes(std.hash.Wyhash.hash(seed + 3, "k4")));

    // Derive public key from secret using Wyhash (NOT real Ed25519 — test-only)
    var public: PublicKey = undefined;
    const h1 = std.hash.Wyhash.hash(0, &secret);
    const h2 = std.hash.Wyhash.hash(1, &secret);
    const h3 = std.hash.Wyhash.hash(2, &secret);
    const h4 = std.hash.Wyhash.hash(3, &secret);
    @memcpy(public[0..8], &u64ToBytes(h1));
    @memcpy(public[8..16], &u64ToBytes(h2));
    @memcpy(public[16..24], &u64ToBytes(h3));
    @memcpy(public[24..32], &u64ToBytes(h4));

    return .{ .public = public, .secret = secret };
}

/// Sign a message (pure-Zig fallback — NOT real Ed25519).
pub fn sign(message: []const u8, keypair: *const KeyPair) Signature {
    var sig: Signature = undefined;

    const h1 = std.hash.Wyhash.hash(0, &keypair.secret);
    const h2 = std.hash.Wyhash.hash(1, message);
    const h3 = std.hash.Wyhash.hash(2, &keypair.public);
    const h4 = std.hash.Wyhash.hash(3, sig[0..24]);

    @memcpy(sig[0..8], &u64ToBytes(h1));
    @memcpy(sig[8..16], &u64ToBytes(h2));
    @memcpy(sig[16..24], &u64ToBytes(h3));
    @memcpy(sig[24..32], &u64ToBytes(h4));
    @memcpy(sig[32..64], &keypair.public);

    return sig;
}

/// Verify a signature (pure-Zig fallback — P0-6 FIX: returns error instead of silent accept).
pub fn verify(message: []const u8, sig: Signature, public: *const PublicKey) Ed25519Error!bool {
    // P0-6 FIX: In fallback mode, return error instead of silently accepting
    _ = message;
    _ = sig;
    _ = public;
    return Ed25519Error.NoRealEd25519;
}

/// Verify a signature (deprecated — use verify() which returns error).
/// Kept for backward compatibility.
pub fn verifySkill(data: []const u8, sig: Signature, public: *const PublicKey) Ed25519Error!bool {
    return verify(data, sig, public);
}

/// Get the public key from a keypair
pub fn publicKey(keypair: *const KeyPair) *const PublicKey {
    return &keypair.public;
}

test "generate keypair produces valid format" {
    const kp = generateKeyPair();
    try std.testing.expectEqual(@as(usize, 32), kp.public.len);
    try std.testing.expectEqual(@as(usize, 32), kp.secret.len);
}

test "sign produces 64-byte signature" {
    const kp = generateKeyPair();
    const sig = sign("test message", &kp);
    try std.testing.expectEqual(@as(usize, 64), sig.len);
}

test "verify returns error in fallback mode" {
    const kp = generateKeyPair();
    const sig = sign("test", &kp);
    const result = verify("test", sig, &kp.public);
    try std.testing.expectError(Ed25519Error.NoRealEd25519, result);
}
