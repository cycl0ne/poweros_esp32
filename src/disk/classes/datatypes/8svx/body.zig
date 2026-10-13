// SPDX-License-Identifier: MIT
//! An 8SVX body made into samples: unpacked when it is Fibonacci-delta
//! coded, and its channels put together into frames when it has two.
//!
//! **Fibonacci-delta**: a pad byte, the first sample, then two four-bit
//! codes a byte, high one first, each a step from the sample before - a
//! step from {-34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13,
//! 21}, so a byte of body is two samples.
//!
//! **Two channels** are the left one's samples and then the right one's,
//! each coded on its own; a frame is one of each.

const steps = [16]i8{ -34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21 };

/// The samples a coded part of `bytes` bytes unpacks to.
pub fn unpackedLength(bytes: usize) usize {
    return if (bytes < 2) 0 else (bytes - 2) * 2;
}

/// A Fibonacci-delta coded part unpacked into `into`, which holds
/// `unpackedLength(coded.len)` samples.
pub fn unpack(coded: []const u8, into: []i8) void {
    if (coded.len < 2) return;
    var value: i8 = @bitCast(coded[1]);
    for (coded[2..], 0..) |byte, i| {
        value +%= steps[byte >> 4];
        into[i * 2] = value;
        value +%= steps[byte & 0x0F];
        into[i * 2 + 1] = value;
    }
}

/// Two channels of `count` samples each, the left then the right, into
/// `count` frames of both.
pub fn interleave(left: []const i8, right: []const i8, into: []i8) void {
    for (left, right, 0..) |l, r, i| {
        into[i * 2] = l;
        into[i * 2 + 1] = r;
    }
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "Fibonacci-delta: each code a step from the sample before, two to a byte" {
    // Pad, start at 10, then +1 +21, -34 +0, -1 -1.
    const coded = [_]u8{ 0, 10, 0x9F, 0x08, 0x77 };
    var into: [6]i8 = undefined;
    try testing.expectEqual(@as(usize, 6), unpackedLength(coded.len));
    unpack(&coded, &into);
    try testing.expectEqualSlices(i8, &.{ 11, 32, -2, -2, -3, -4 }, &into);
}

test "a step past the end of a byte's range wraps, as the format's decoders do" {
    const coded = [_]u8{ 0, 120, 0xF0 };
    var into: [2]i8 = undefined;
    unpack(&coded, &into);
    // 120 + 21 wraps to -115, and -115 - 34 to 107.
    try testing.expectEqualSlices(i8, &.{ -115, 107 }, &into);
}

test "two channels put together into frames" {
    var into: [6]i8 = undefined;
    interleave(&.{ 1, 2, 3 }, &.{ -1, -2, -3 }, &into);
    try testing.expectEqualSlices(i8, &.{ 1, -1, 2, -2, 3, -3 }, &into);
}
