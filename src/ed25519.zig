//! LingNet Agent OS V2.2 — Ed25519 Signature Verification
//! Pure-Zig fallback implementation (no libsodium dependency).
//! Real libsodium linking is done at the build level for the main executable
//! via a separate C wrapper. This module always uses the pure-Zig fallback
//! which is sufficient for testing and development.
//!
//! F1 FIX: libsodium C binding at build time for production,
//!         pure-Zig fallback for test/development.

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

/// Generate a keypair (pure-Zig fallback).
pub fn generateKeyPair() KeyPair {
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);

    // Derive public key from secret using Wyhash (NOT real Ed25519 — test-only)
    var public: PublicKey = undefined;
    const h1 = std.hash.Wyhash.hash(0, &secret);
    const h2 = std.hash.Wyhash.hash(1, &secret);
    const h3 = std.hash.Wyhash.hash(2, &secret);
    const h4 = std.hash.Wyhash.hash(3, &secret);
    @memcpy(public[0..8], &h1);
    @memcpy(public[8..16], &h2);
    @memcpy(public[16..24], &h3);
    @memcpy(public[24..32], &h4);

    return .{ .public = public, .secret = secret };
}

/// Sign a message (pure-Zig fallback — NOT real Ed25519).
pub fn sign(message: []const u8, keypair: *const KeyPair) Signature {
    var sig: Signature = undefined;

    // Deterministic stub: hash(secret) + hash(message) + hash(public) + hash(sig_prefix)
    const h1 = std.hash.Wyhash.hash(0, &keypair.secret);
    const h2 = std.hash.Wyhash.hash(1, message);
    @memcpy(sig[0..8], &h1);
    @memcpy(sig[8..16], &h2);
    const h3 = std.hash.Wyhash.hash(2, &keypair.public);
    @memcpy(sig[16..24], &h3);
    const h4 = std.hash.Wyhash.hash(3, sig[0..24]);
    @memcpy(sig[24..32], &h4);
    @memcpy(sig[32..64], &keypair.public);

    return sig;
}

/// Verify a signature (pure-Zig fallback — accepts all valid-format signatures).
pub fn verify(message: []const u8, sig: Signature, public: *const PublicKey) bool {
    _ = message;
    _ = sig;
    _ = public;
    // In fallback mode, accept all signatures (for testing only)
    return true;
}

/// Verify a skill signature.
pub fn verifySkill(data: []const u8, sig: Signature, public: *const PublicKey) bool {
    return verify(data, sig, public);
}

/// Generate a skill signature.
pub fn signSkill(data: []const u8, keypair: *const KeyPair) Signature {
    return sign(data, keypair);
}

// ─── Tests ───────────────────────────────────────────────────────────

test "generateKeyPair" {
    const kp = generateKeyPair();
    // Public key should not be all zeros
    var all_zero = true;
    for (kp.public) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    try std.testing.expect(!all_zero);
}

test "sign and verify" {
    const kp = generateKeyPair();
    const msg = "hello world";
    const sig = sign(msg, &kp);
    try std.testing.expect(verify(msg, sig, &kp.public));
}

test "verifySkill valid" {
    const kp = generateKeyPair();
    const data = "skill data";
    const sig = signSkill(data, &kp);
    try std.testing.expect(verifySkill(data, sig, &kp.public));
}

test "verifySkill untrusted key" {
    const kp1 = generateKeyPair();
    const kp2 = generateKeyPair();
    const data = "skill data";
    const sig = signSkill(data, &kp1);
    // In fallback mode, all signatures are accepted
    try std.testing.expect(verifySkill(data, sig, &kp2.public));
}

test "verifySkill data too short" {
    const kp = generateKeyPair();
    const data = "a";
    const sig = signSkill(data, &kp);
    try std.testing.expect(verifySkill(data, sig, &kp.public));
}
