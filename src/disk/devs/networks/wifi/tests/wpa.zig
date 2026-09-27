// SPDX-License-Identifier: MIT
//! Host tests of the supplicant's keys (`wpa/keys.zig`) on crypto.library
//! made on the host, with its engines' software models: the PMK against
//! IEEE 802.11's own examples, the PRF against its test vector, and key
//! unwrap against RFC 3394's.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../../../libs/crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const keys = @import("../wpa/keys.zig");

const testing = std.testing;

const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = library, .cb = @ptrCast(opened) };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "the PMK of IEEE 802.11's examples" {
    var rig = try Rig.init();
    var pmk: [32]u8 = undefined;
    try testing.expect(keys.pairwiseMaster(rig.cb, "password", "IEEE", &pmk));
    try testing.expectEqualSlices(u8, &hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), &pmk);
    try testing.expect(keys.pairwiseMaster(rig.cb, "ThisIsAPassword", "ThisIsASSID", &pmk));
    try testing.expectEqualSlices(u8, &hex("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"), &pmk);
    try rig.deinit();
}

test "the PRF's test vector" {
    var rig = try Rig.init();
    var out: [64]u8 = undefined;
    try testing.expect(keys.prf(rig.cb, &@as([20]u8, @splat(0x0b)), "prefix", "Hi There", &out));
    try testing.expectEqualSlices(u8, &hex("bcd4c650b30b9684951829e0d75f9d54b862175ed9f00606e17d8da35402ffee75df78c3d31e0f889f012120c0862beb67753e7439ae242edb8373698356cf5a"), &out);
    try rig.deinit();
}

test "key unwrap of RFC 3394's examples" {
    var rig = try Rig.init();
    const kek = hex("000102030405060708090A0B0C0D0E0F");
    var key: [16]u8 = undefined;
    try testing.expect(keys.unwrap(rig.cb, &kek, &hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"), &key));
    try testing.expectEqualSlices(u8, &hex("00112233445566778899AABBCCDDEEFF"), &key);
    var longer: [24]u8 = undefined;
    try testing.expect(keys.unwrap(rig.cb, &kek, &hex("889671106535a9f86d9f9a262f674569efa38d7535aac77527cab92855bddd6e"), &longer));
    try testing.expectEqualSlices(u8, &hex("00112233445566778899AABBCCDDEEFF0001020304050607"), &longer);
    var damaged = hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5");
    damaged[20] ^= 1;
    try testing.expect(!keys.unwrap(rig.cb, &kek, &damaged, &key));
    try rig.deinit();
}
