// SPDX-License-Identifier: MIT
//! Names on a posfs volume: UTF-8, compared without regard to case, and
//! the names dos is given for them.
//!
//! **A name is the bytes it was given**, always valid UTF-8, 1 to 255 of
//! them, never `/`, `:` or NUL. Two names are the same when their code
//! points are the same after simple case folding (`fold1.zig`); nothing
//! is normalized, so the two ways of writing é are two names. A name's
//! place in its directory is the top 24 bits of the crc32 of its folded
//! form, so a lookup reads one bucket of the directory.
//!
//! **Which fold** is part of the format: each directory says which table
//! its names were hashed with, and a volume's new directories get the
//! label's. There is one table so far.
//!
//! **dos's names are UTF-8 too**, so a stored name goes to dos as it is.
//! A name from dos is kept as the text it makes (`utf8.textOf`): bytes
//! that are UTF-8 as they are, a byte that is no UTF-8 as its Latin-1
//! character while such a byte reads as one, and refused once it does
//! not.

const layout = @import("layout.zig");
const fold1 = @import("fold1.zig");
const posfs = @import("posfs.zig");
const utf8 = @import("../../utility/utf8.zig");
const unicode = @import("../../utility/unicode.zig");

// --- UTF-8 ------------------------------------------------------------------------

/// The code point at `bytes[at.*]`, `at` moved past it; null for bytes
/// that are not UTF-8 there: a stray continuation byte, a sequence cut
/// short, an overlong form, a surrogate, or past U+10FFFF.
pub fn decode(bytes: []const u8, at: *usize) ?u21 {
    const step = utf8.decode(bytes[at.*..]);
    if (step.kind != .char) return null;
    at.* += step.length;
    return @intCast(step.char);
}

/// Whether `bytes` are UTF-8 from first to last.
pub fn valid(bytes: []const u8) bool {
    return utf8.valid(bytes);
}

/// A code point as UTF-8 into `into`, which has room for it; the bytes
/// it took.
pub fn encode(code: u21, into: []u8) usize {
    var bytes: [4]u8 = undefined;
    const length = utf8.encode(code, &bytes);
    @memcpy(into[0..length], bytes[0..length]);
    return length;
}

// --- folding ------------------------------------------------------------------------

/// Whether a directory's fold is one this code knows.
pub fn known(table: u32) bool {
    return table == layout.fold_1;
}

/// A code point folded by table 1.
pub fn foldCode(code: u21) u21 {
    if (code < 0x41) return code;
    if (code <= 0x5A) return code + 32;
    if (code < 0xB5) return code;
    return @intCast(unicode.mapped(&fold1.runs, code));
}

/// The hash of a UTF-8 name: the crc32 of its folded form's UTF-8.
pub fn hash(name: []const u8) u32 {
    var crc = layout.crcStart();
    var at: usize = 0;
    var buffer: [4]u8 = undefined;
    while (at < name.len) {
        const code = decode(name, &at) orelse {
            // Not UTF-8: a name on the volume always is, so this is only
            // reached for one that never gets stored; hash the byte.
            crc = layout.crcAdd(crc, name[at .. at + 1]);
            at += 1;
            continue;
        };
        const used = encode(foldCode(code), &buffer);
        crc = layout.crcAdd(crc, buffer[0..used]);
    }
    return layout.crcEnd(crc);
}

/// Whether two UTF-8 names are the same name.
pub fn same(a: []const u8, b: []const u8) bool {
    var at_a: usize = 0;
    var at_b: usize = 0;
    while (at_a < a.len and at_b < b.len) {
        const code_a = decode(a, &at_a) orelse return false;
        const code_b = decode(b, &at_b) orelse return false;
        if (foldCode(code_a) != foldCode(code_b)) return false;
    }
    return at_a == a.len and at_b == b.len;
}

/// A name's hash bucket, and the directory position of the `slot`th name
/// in it (0 to 254). A bucket's positions are one run of keys.
pub fn bucketOf(name_hash: u32) u32 {
    return name_hash >> 8;
}

pub fn position(bucket: u32, slot: u32) u64 {
    return (@as(u64, bucket) << 8) | slot;
}

/// The names a bucket holds at most.
pub const bucket_slots: u32 = 255;

// --- names from and to dos ------------------------------------------------------------

/// Whether `name` (UTF-8) may be a name: 1 to 255 bytes with no `/`, `:`
/// or NUL in them.
pub fn acceptable(name: []const u8) bool {
    if (name.len == 0 or name.len > posfs.max_name) return false;
    for (name) |byte| {
        if (byte == '/' or byte == ':' or byte == 0) return false;
    }
    return valid(name);
}

/// A name from dos as the UTF-8 kept for it (`utf8.textOf`), written
/// into `into` when it is not UTF-8 already. Null when it is refused or
/// longer than `into`.
pub fn fromDos(name: []const u8, into: []u8) ?[]const u8 {
    const text = utf8.textOf(name, into) orelse return null;
    if (text.len > into.len) return null;
    return text;
}
