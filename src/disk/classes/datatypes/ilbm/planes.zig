// SPDX-License-Identifier: MIT
//! What an ILBM's `BODY` holds, and how it becomes colour.
//!
//! A row is not pixels but **planes**: one bit of every pixel in the
//! first, the next bit of every pixel in the second, and so on. A pixel's
//! number is its bits gathered back up, and what that number means
//! depends on how deep the picture is:
//!
//! - up to eight planes, it is a place in the palette;
//! - with the half-bright bit set, the upper half of the palette is the
//!   lower half at half strength, which is how a machine with thirty-two
//!   colours showed sixty-four;
//! - in hold-and-modify, the top two bits say to keep the pixel to the
//!   left and change one of its three channels to what the rest of the
//!   number says, which is how a machine with a palette showed a
//!   photograph;
//! - twenty-four planes are the three channels themselves, and
//!   thirty-two are those and coverage.
//!
//! The rows are usually packed (`cmpByteRun1`): a count that says either
//! "these bytes as they are" or "this byte that many times".

const datatypes = @import("sdk").datatypes;
const pic = datatypes.pictureclass;

pub const Error = error{
    /// The packed rows end before the picture does.
    Truncated,
};

/// `CAMG`: what the machine's display was set to. Only the two bits that
/// change what a pixel number means matter here.
pub const CAMG_HAM: u32 = 0x0800;
pub const CAMG_HALFBRITE: u32 = 0x0080;

/// Bytes one plane of a row of `width` pixels takes: whole words, as the
/// format has it.
pub fn planeStride(width: u32) u32 {
    return ((width + 15) / 16) * 2;
}

/// One row unpacked from `cmpByteRun1`. How many bytes of `from` it
/// took.
///
/// A count below 128 is that many bytes and one more as they stand; a
/// count above it is the byte after it, repeated; 128 says nothing and
/// is skipped.
pub fn unpackRow(from: []const u8, into: []u8) Error!usize {
    var at: usize = 0;
    var done: usize = 0;
    while (done < into.len) {
        if (at >= from.len) return Error.Truncated;
        const count = from[at];
        at += 1;
        if (count == 128) continue;
        if (count < 128) {
            const run = @as(usize, count) + 1;
            if (at + run > from.len or done + run > into.len) return Error.Truncated;
            @memcpy(into[done..][0..run], from[at..][0..run]);
            at += run;
            done += run;
            continue;
        }
        const run = 257 - @as(usize, count);
        if (at >= from.len or done + run > into.len) return Error.Truncated;
        @memset(into[done..][0..run], from[at]);
        at += 1;
        done += run;
    }
    return at;
}

/// The planes of one row gathered back into a number a pixel: plane 0 is
/// the lowest bit.
///
/// `planes` is `depth` stretches of `stride` bytes, one after another.
pub fn gather(planes: []const u8, stride: u32, depth: u32, width: u32, into: []u32) void {
    @memset(into[0..width], 0);
    var plane: u32 = 0;
    while (plane < depth) : (plane += 1) {
        const from = planes[plane * stride ..];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const bit: u3 = @truncate(7 - (x & 7));
            if (from[x >> 3] & (@as(u8, 1) << bit) != 0) into[x] |= @as(u32, 1) << @truncate(plane);
        }
    }
}

/// A colour of the palette as a pen, black past its end.
pub fn colorOf(palette: []const pic.ColorRegister, index: u32) u32 {
    if (index >= palette.len) return 0xFF000000;
    const color = palette[index];
    return 0xFF << 24 | @as(u32, color.red) << 16 |
        @as(u32, color.green) << 8 | color.blue;
}

/// A row of numbers turned into red, green, blue and coverage.
///
/// `depth` is how many planes the file held, `mode` what `CAMG` said,
/// and `palette` what `CMAP` held.
pub fn toRGBA(numbers: []const u32, width: u32, depth: u32, mode: u32, palette: []const pic.ColorRegister, transparent: ?u32, into: []u8) void {
    if (depth >= 24) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const value = numbers[x];
            const at = into[x * 4 ..];
            at[0] = @truncate(value);
            at[1] = @truncate(value >> 8);
            at[2] = @truncate(value >> 16);
            at[3] = if (depth >= 32) @truncate(value >> 24) else 0xFF;
        }
        return;
    }
    if (mode & CAMG_HAM != 0) {
        hold(numbers, width, depth, palette, into);
        return;
    }
    const half = mode & CAMG_HALFBRITE != 0;
    const plain = @as(u32, 1) << @truncate(@min(depth, 5));
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const value = numbers[x];
        var pen = if (half and value >= plain)
            dim(colorOf(palette, value - plain))
        else
            colorOf(palette, value);
        if (transparent) |nothing| {
            if (value == nothing) pen &= 0x00FF_FFFF;
        }
        write(into[x * 4 ..], pen);
    }
}

/// A colour at half strength, which is what the upper half of a
/// half-bright palette is.
fn dim(pen: u32) u32 {
    return 0xFF << 24 |
        ((pen >> 16 & 0xFF) / 2) << 16 |
        ((pen >> 8 & 0xFF) / 2) << 8 |
        (pen & 0xFF) / 2;
}

fn write(into: []u8, pen: u32) void {
    into[0] = @truncate(pen >> 16);
    into[1] = @truncate(pen >> 8);
    into[2] = @truncate(pen);
    into[3] = @truncate(pen >> 24);
}

/// Hold-and-modify: the top two bits say whether the number is a place
/// in the palette or one channel of the pixel to the left changed.
fn hold(numbers: []const u32, width: u32, depth: u32, palette: []const pic.ColorRegister, into: []u8) void {
    // Six planes leave four bits of value and eight leave six, and the
    // value is spread over the whole range so that all-ones is 0xFF.
    const value_bits: u5 = @truncate(depth - 2);
    const mask: u32 = (@as(u32, 1) << value_bits) - 1;
    const spread: u5 = @truncate(8 - value_bits);
    var pen: u32 = 0xFF000000;
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const number = numbers[x];
        const value = number & mask;
        const channel = (number >> value_bits) & 3;
        // The bits are spread rather than shifted up, so that the
        // largest value a file can hold comes out as the largest a
        // channel can.
        const level = (value << spread) | (value >> @truncate(@max(value_bits, spread) - spread));
        pen = switch (channel) {
            0 => colorOf(palette, number & mask),
            1 => (pen & 0xFFFF_FF00) | (level & 0xFF),
            2 => (pen & 0xFF00_FFFF) | ((level & 0xFF) << 16),
            else => (pen & 0xFFFF_00FF) | ((level & 0xFF) << 8),
        };
        write(into[x * 4 ..], pen);
    }
}

const std = @import("std");
const testing = std.testing;

test "a packed row comes back as it was" {
    // Three bytes as they stand, then five of one byte.
    const packed_row = [_]u8{ 2, 'a', 'b', 'c', 252, 'z' };
    var into: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), try unpackRow(&packed_row, &into));
    try testing.expectEqualStrings("abczzzzz", &into);
}

test "a packed row that ends early says so" {
    const packed_row = [_]u8{ 4, 'a', 'b' };
    var into: [8]u8 = undefined;
    try testing.expectError(Error.Truncated, unpackRow(&packed_row, &into));
}

test "the planes of a row are gathered lowest bit first" {
    // Two planes of eight pixels: the first alternating, the second the
    // left half.
    const planes = [_]u8{ 0b1010_1010, 0b1111_0000 };
    var into: [8]u32 = undefined;
    gather(&planes, 1, 2, 8, &into);
    try testing.expectEqualSlices(u32, &.{ 3, 2, 3, 2, 1, 0, 1, 0 }, &into);
}

test "the upper half of a half-bright palette is the lower half dimmed" {
    const palette = [_]pic.ColorRegister{
        .{ .red = 0, .green = 0, .blue = 0 },
        .{ .red = 255, .green = 200, .blue = 100 },
    } ++ [_]pic.ColorRegister{.{}} ** 30;
    const numbers = [_]u32{ 1, 33 };
    var into: [8]u8 = undefined;
    toRGBA(&numbers, 2, 6, CAMG_HALFBRITE, &palette, null, &into);
    try testing.expectEqualSlices(u8, &.{ 255, 200, 100, 255 }, into[0..4]);
    try testing.expectEqualSlices(u8, &.{ 127, 100, 50, 255 }, into[4..8]);
}

test "hold and modify keeps the pixel before it and changes one channel" {
    const palette = [_]pic.ColorRegister{.{ .red = 0x11, .green = 0x22, .blue = 0x33 }} ++
        [_]pic.ColorRegister{.{}} ** 15;
    // The first pixel from the palette, the second with red set to all
    // ones, which the four bits spread to 0xFF.
    const numbers = [_]u32{ 0, (2 << 4) | 0x0F };
    var into: [8]u8 = undefined;
    toRGBA(&numbers, 2, 6, CAMG_HAM, &palette, null, &into);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0xFF }, into[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x22, 0x33, 0xFF }, into[4..8]);
}

test "twenty-four planes are the channels themselves" {
    const numbers = [_]u32{0x00AABBCC};
    var into: [4]u8 = undefined;
    toRGBA(&numbers, 1, 24, 0, &.{}, null, &into);
    try testing.expectEqualSlices(u8, &.{ 0xCC, 0xBB, 0xAA, 0xFF }, &into);
}
