// SPDX-License-Identifier: MPL-2.0
//! What a core says of itself, made a name and a set of features: the
//! part of platform.resource's CpuName and CpuFeature that reads no
//! register. platform.zig fetches the words - an x86-64 core's
//! identification leaves, an AArch64 core's ID registers, a RISC-V
//! machine's ids and its ISA string - and the functions here say what
//! they mean, so the host's tests run them on words written down.
//!
//! A name is a C string in a buffer of CPU_NAME_SIZE bytes, cut where it
//! would not fit. A set of features is a word with bit CPUF_x set for
//! each feature a task may use: the core has the instructions, and the
//! kernel keeps the registers they work in across a task switch. What
//! needs registers the kernel does not keep is left out, whatever the
//! core says.

const types = @import("sdk").resources.platform;

/// A name's buffer.
pub const Name = [types.CPU_NAME_SIZE]u8;

/// The bit a feature has in a set.
pub fn bit(feature: u32) u32 {
    return @as(u32, 1) << @intCast(feature);
}

/// Whether `set` has `feature`. A number that names no feature is in no
/// set.
pub fn has(set: u32, feature: u32) bool {
    if (feature >= types.CPUF_COUNT) return false;
    return set & bit(feature) != 0;
}

/// `text` added to the name at `at`, as much of it as leaves room for
/// the NUL; answers where the name ends now.
fn add(name: *Name, at: usize, text: []const u8) usize {
    var end = at;
    for (text) |character| {
        if (end + 1 >= name.len) break;
        name[end] = character;
        end += 1;
    }
    name[end] = 0;
    return end;
}

/// `value` added in hexadecimal, `digits` of them.
fn addHex(name: *Name, at: usize, value: u64, digits: u32) usize {
    var end = at;
    var left = digits;
    while (left > 0) : (left -= 1) {
        const nibble: u8 = @intCast((value >> @intCast((left - 1) * 4)) & 0xF);
        end = add(name, end, &.{"0123456789abcdef"[nibble]});
    }
    return end;
}

/// A name that is the same on every chip of its kind.
pub fn fixed(name: *Name, text: []const u8) void {
    name.* = @splat(0);
    _ = add(name, 0, text);
}

/// `text` up to its NUL, with the spaces around it dropped and each run
/// of them inside made one; answers where the name ends.
fn addTidy(name: *Name, text: []const u8) usize {
    var end: usize = 0;
    var gap = false;
    for (text) |character| {
        if (character == 0) break;
        if (character == ' ') {
            gap = end != 0;
            continue;
        }
        if (gap) end = add(name, end, " ");
        gap = false;
        end = add(name, end, &.{character});
    }
    return end;
}

// --- x86-64 ------------------------------------------------------------------------

/// Leaf 1's ECX: PCLMULQDQ, SSE4.2 (whose CRC32 instruction is CRC-32C)
/// and AES-NI.
const LEAF1_PCLMULQDQ: u32 = 1 << 1;
const LEAF1_SSE42: u32 = 1 << 20;
const LEAF1_AES: u32 = 1 << 25;
/// Leaf 7's EBX: the SHA extensions, SHA-1 and SHA-256 both.
const LEAF7_SHA: u32 = 1 << 29;

/// An x86-64 core's name: its brand string (leaves 0x8000_0002 to
/// 0x8000_0004, zeroes from a core without them), else its vendor's
/// (leaf 0), else the architecture's.
pub fn x86Name(name: *Name, brand: *const [48]u8, vendor: *const [12]u8) void {
    name.* = @splat(0);
    if (addTidy(name, brand) != 0) return;
    if (addTidy(name, vendor) != 0) return;
    _ = add(name, 0, "x86-64");
}

/// An x86-64 core's features, from leaf 1's ECX and leaf 7's EBX (0 from
/// a core without leaf 7). All of them work in the SSE registers, which
/// every task has. The SHA-512 instructions work in the registers above
/// those, which no task has: never set.
pub fn x86Features(leaf1_ecx: u32, leaf7_ebx: u32) u32 {
    var set: u32 = 0;
    if (leaf1_ecx & LEAF1_AES != 0) set |= bit(types.CPUF_AES);
    if (leaf1_ecx & LEAF1_PCLMULQDQ != 0) set |= bit(types.CPUF_CLMUL);
    if (leaf1_ecx & LEAF1_SSE42 != 0) set |= bit(types.CPUF_CRC32C);
    if (leaf7_ebx & LEAF7_SHA != 0) set |= bit(types.CPUF_SHA1) | bit(types.CPUF_SHA256);
    return set;
}

// --- AArch64 -----------------------------------------------------------------------

/// MIDR_EL1's implementer that is ARM itself, and its cores this names,
/// by their part numbers.
const IMPLEMENTER_ARM = 0x41;
const ArmPart = struct { part: u12, name: []const u8 };
const arm_parts = [_]ArmPart{
    .{ .part = 0xD03, .name = "Cortex-A53" },
    .{ .part = 0xD04, .name = "Cortex-A35" },
    .{ .part = 0xD05, .name = "Cortex-A55" },
    .{ .part = 0xD07, .name = "Cortex-A57" },
    .{ .part = 0xD08, .name = "Cortex-A72" },
    .{ .part = 0xD09, .name = "Cortex-A73" },
    .{ .part = 0xD0A, .name = "Cortex-A75" },
    .{ .part = 0xD0B, .name = "Cortex-A76" },
    .{ .part = 0xD0C, .name = "Neoverse-N1" },
    .{ .part = 0xD0D, .name = "Cortex-A77" },
    .{ .part = 0xD40, .name = "Neoverse-V1" },
    .{ .part = 0xD41, .name = "Cortex-A78" },
    .{ .part = 0xD44, .name = "Cortex-X1" },
    .{ .part = 0xD46, .name = "Cortex-A510" },
    .{ .part = 0xD47, .name = "Cortex-A710" },
    .{ .part = 0xD48, .name = "Cortex-X2" },
    .{ .part = 0xD49, .name = "Neoverse-N2" },
};

/// An AArch64 core's name, from MIDR_EL1: "ARM Cortex-A76" for a part
/// of ARM's this knows, "AArch64 41:d0b" - the implementer and the part,
/// in hexadecimal - for any other.
pub fn armName(name: *Name, midr: u64) void {
    name.* = @splat(0);
    const implementer: u8 = @truncate(midr >> 24);
    const part: u12 = @truncate(midr >> 4);
    if (implementer == IMPLEMENTER_ARM) {
        for (arm_parts) |known| {
            if (known.part != part) continue;
            _ = add(name, add(name, 0, "ARM "), known.name);
            return;
        }
    }
    var end = add(name, 0, "AArch64 ");
    end = addHex(name, end, implementer, 2);
    end = add(name, end, ":");
    _ = addHex(name, end, part, 3);
}

/// An AArch64 core's features, from ID_AA64ISAR0_EL1: AES in bits 4-7
/// (2: with the 64-bit polynomial product), SHA1 in 8-11, SHA2 in 12-15
/// (2: with SHA-512) and CRC32, both polynomials, in 16-19. They work in
/// the general and the vector registers, which every task has.
pub fn armFeatures(isar0: u64) u32 {
    const aes: u4 = @truncate(isar0 >> 4);
    const sha1: u4 = @truncate(isar0 >> 8);
    const sha2: u4 = @truncate(isar0 >> 12);
    const crc32: u4 = @truncate(isar0 >> 16);
    var set: u32 = 0;
    if (aes >= 1) set |= bit(types.CPUF_AES);
    if (aes >= 2) set |= bit(types.CPUF_CLMUL);
    if (sha1 >= 1) set |= bit(types.CPUF_SHA1);
    if (sha2 >= 1) set |= bit(types.CPUF_SHA256);
    if (sha2 >= 2) set |= bit(types.CPUF_SHA512);
    if (crc32 >= 1) set |= bit(types.CPUF_CRC32) | bit(types.CPUF_CRC32C);
    return set;
}

// --- RISC-V ------------------------------------------------------------------------

/// mvendorid of SiFive, and marchid of its 7 series core with an MMU.
const VENDOR_SIFIVE = 0x489;
const ARCH_SIFIVE_U7 = 0x8000_0000_0000_0007;

/// A RISC-V 64 core's name, from the machine's mvendorid and marchid as
/// the firmware gives them: the core's own for one this knows, the
/// architecture's for any other.
pub fn riscvName(name: *Name, vendor: u64, architecture: u64) void {
    name.* = @splat(0);
    if (vendor == VENDOR_SIFIVE and architecture == ARCH_SIFIVE_U7) {
        _ = add(name, 0, "SiFive U74");
        return;
    }
    _ = add(name, 0, "RISC-V RV64GC");
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

/// A RISC-V core's features, from its ISA string
/// (`rv64imafdc_zicsr_zbc...`): the extensions after the first `_`, each
/// up to the next. Zkne and Zknd together are AES, Zbc or Zbkc the
/// carry-less product, Zknh SHA-256 and SHA-512; Zkn and Zk stand for
/// all of those. They work in the general registers, which every task
/// has. No extension has SHA-1 or a CRC.
pub fn riscvFeatures(isa: []const u8) u32 {
    var encrypt = false;
    var decrypt = false;
    var set: u32 = 0;
    var at: usize = 0;
    var first = true;
    while (at <= isa.len) {
        var end = at;
        while (end < isa.len and isa[end] != '_') end += 1;
        const extension = isa[at..end];
        at = end + 1;
        // The first is the base and its single letters.
        if (first) {
            first = false;
            continue;
        }
        if (same(extension, "zkne")) encrypt = true;
        if (same(extension, "zknd")) decrypt = true;
        if (same(extension, "zbc") or same(extension, "zbkc")) set |= bit(types.CPUF_CLMUL);
        if (same(extension, "zknh")) set |= bit(types.CPUF_SHA256) | bit(types.CPUF_SHA512);
        if (same(extension, "zkn") or same(extension, "zk")) {
            encrypt = true;
            decrypt = true;
            set |= bit(types.CPUF_CLMUL) | bit(types.CPUF_SHA256) | bit(types.CPUF_SHA512);
        }
    }
    if (encrypt and decrypt) set |= bit(types.CPUF_AES);
    return set;
}

// --- tests -------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn named(name: *const Name) []const u8 {
    return std.mem.sliceTo(name, 0);
}

test "an x86-64 brand string loses the spaces around it and the runs inside" {
    var name: Name = undefined;
    var brand: [48]u8 = @splat(0);
    const said = "     Intel(R) Core(TM)  i7-8550U CPU @ 1.80GHz  ";
    @memcpy(brand[0..said.len], said);
    x86Name(&name, &brand, "GenuineIntel");
    try testing.expectEqualStrings("Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz", named(&name));
}

test "an x86-64 core without a brand string is named for its vendor, then its architecture" {
    var name: Name = undefined;
    const none: [48]u8 = @splat(0);
    x86Name(&name, &none, "AuthenticAMD");
    try testing.expectEqualStrings("AuthenticAMD", named(&name));
    const nobody: [12]u8 = @splat(0);
    x86Name(&name, &none, &nobody);
    try testing.expectEqualStrings("x86-64", named(&name));
}

test "a name longer than its buffer is cut and still ends" {
    var name: Name = undefined;
    const brand: [48]u8 = @splat('x');
    x86Name(&name, &brand, "AuthenticAMD");
    try testing.expectEqual(@as(usize, 48), named(&name).len);
    fixed(&name, "a" ** 100);
    try testing.expectEqual(@as(usize, types.CPU_NAME_SIZE - 1), named(&name).len);
}

test "x86-64 features follow the leaves' bits" {
    try testing.expectEqual(@as(u32, 0), x86Features(0, 0));
    const all = x86Features(LEAF1_AES | LEAF1_PCLMULQDQ | LEAF1_SSE42, LEAF7_SHA);
    try testing.expect(has(all, types.CPUF_AES));
    try testing.expect(has(all, types.CPUF_CLMUL));
    try testing.expect(has(all, types.CPUF_SHA1));
    try testing.expect(has(all, types.CPUF_SHA256));
    try testing.expect(has(all, types.CPUF_CRC32C));
    // Every bit set gives no more: these two no x86-64 task can use.
    const most = x86Features(0xFFFF_FFFF, 0xFFFF_FFFF);
    try testing.expect(!has(most, types.CPUF_SHA512));
    try testing.expect(!has(most, types.CPUF_CRC32));
    try testing.expect(!has(x86Features(LEAF1_AES, 0), types.CPUF_SHA256));
}

test "a number that names no feature is in no set" {
    try testing.expect(!has(0xFFFF_FFFF, types.CPUF_COUNT));
    try testing.expect(!has(0xFFFF_FFFF, 31));
    try testing.expect(!has(0xFFFF_FFFF, 32));
    try testing.expect(!has(0xFFFF_FFFF, 0xFFFF_FFFF));
}

test "an AArch64 core is named by its part, or by its numbers" {
    var name: Name = undefined;
    // The BCM2712's: ARM, Cortex-A76 r4p1.
    armName(&name, 0x414F_D0B1);
    try testing.expectEqualStrings("ARM Cortex-A76", named(&name));
    // An emulator's own core.
    armName(&name, 0x000F_0510);
    try testing.expectEqualStrings("AArch64 00:051", named(&name));
    // ARM's, of a part not listed.
    armName(&name, 0x410F_D4F0);
    try testing.expectEqualStrings("AArch64 41:d4f", named(&name));
}

test "AArch64 features follow ID_AA64ISAR0_EL1's fields" {
    try testing.expectEqual(@as(u32, 0), armFeatures(0));
    // The Cortex-A76's: AES with PMULL, SHA1, SHA2 without SHA-512, CRC32.
    const a76 = armFeatures(0x0000_1000_1021_1120);
    try testing.expect(has(a76, types.CPUF_AES));
    try testing.expect(has(a76, types.CPUF_CLMUL));
    try testing.expect(has(a76, types.CPUF_SHA1));
    try testing.expect(has(a76, types.CPUF_SHA256));
    try testing.expect(!has(a76, types.CPUF_SHA512));
    try testing.expect(has(a76, types.CPUF_CRC32));
    try testing.expect(has(a76, types.CPUF_CRC32C));
    // AES without the product, and SHA2 with SHA-512.
    const other = armFeatures(0x2010);
    try testing.expect(has(other, types.CPUF_AES));
    try testing.expect(!has(other, types.CPUF_CLMUL));
    try testing.expect(has(other, types.CPUF_SHA512));
}

test "a RISC-V core is named when its ids are known" {
    var name: Name = undefined;
    riscvName(&name, VENDOR_SIFIVE, ARCH_SIFIVE_U7);
    try testing.expectEqualStrings("SiFive U74", named(&name));
    riscvName(&name, 0, 0);
    try testing.expectEqualStrings("RISC-V RV64GC", named(&name));
}

test "RISC-V features follow the ISA string's extensions" {
    try testing.expectEqual(@as(u32, 0), riscvFeatures(""));
    try testing.expectEqual(@as(u32, 0), riscvFeatures("rv64imafdc"));
    // The JH7110's U74.
    try testing.expectEqual(@as(u32, 0), riscvFeatures("rv64imafdc_zba_zbb"));
    const product = riscvFeatures("rv64imafdch_zicsr_zifencei_zba_zbb_zbc_zbs");
    try testing.expectEqual(bit(types.CPUF_CLMUL), product);
    // AES takes both directions.
    try testing.expect(!has(riscvFeatures("rv64gc_zkne"), types.CPUF_AES));
    try testing.expect(has(riscvFeatures("rv64gc_zkne_zknd"), types.CPUF_AES));
    const hashes = riscvFeatures("rv64gc_zknh");
    try testing.expect(has(hashes, types.CPUF_SHA256));
    try testing.expect(has(hashes, types.CPUF_SHA512));
    try testing.expect(!has(hashes, types.CPUF_SHA1));
    const all = riscvFeatures("rv64gc_zk");
    try testing.expect(has(all, types.CPUF_AES));
    try testing.expect(has(all, types.CPUF_CLMUL));
    try testing.expect(has(all, types.CPUF_SHA256));
    // A name that only starts like one is another extension.
    try testing.expectEqual(@as(u32, 0), riscvFeatures("rv64gc_zbcx_zknhq"));
}
