// SPDX-License-Identifier: MIT
//! The compressed stream a GIF's pixels are, unpacked.
//!
//! A code stands for a string of pixel numbers. The first codes stand
//! for the numbers themselves, two more mean "start again" and "that is
//! all", and every code after them is added as the decoder goes: each
//! time a code is read, the string it stands for is written out and a
//! new code is made from the string before it and the first number of
//! this one. Because the table is built the same way on both sides,
//! nothing but the codes themselves is in the file.
//!
//! **A code may be one that has not been made yet.** That happens when
//! the coder met a run of the same string twice over, and the answer is
//! the string before it with its own first number on the end. It is the
//! one case that looks wrong and is not.
//!
//! Codes are read low bit first and grow from `min_code_size + 1` bits
//! to twelve as the table fills; "start again" puts both back.
//!
//! **The table is too large to stand on a stack** - four thousand
//! entries and a stack as deep - so it lives in a `Work` block the
//! caller allocates.

pub const Error = error{
    /// The stream says a code that cannot be right.
    Corrupt,
    /// It ended before it said it was done.
    Truncated,
    /// It would write more than the caller said there is.
    Overrun,
};

/// How many codes there can be, and how wide one gets.
pub const max_codes = 4096;
pub const max_code_bits = 12;

/// The table, and the string being written out backwards.
pub const Work = struct {
    /// The code whose string comes before this one's last number.
    prefix: [max_codes]u16 = @splat(0),
    /// That last number.
    suffix: [max_codes]u8 = @splat(0),
    /// A string is walked from its end, so it is written down here and
    /// read back the other way.
    stack: [max_codes]u8 = @splat(0),
};

/// The whole stream unpacked into `into`, one number a pixel. How many
/// it wrote.
///
/// `min_code_size` is the byte the file puts in front of the stream:
/// how many bits the first codes take, before the two the decoder adds.
pub fn decode(work: *Work, min_code_size: u8, from: []const u8, into: []u8) Error!usize {
    if (min_code_size < 2 or min_code_size > 11) return Error.Corrupt;
    const clear: u16 = @as(u16, 1) << @truncate(min_code_size);
    const finish: u16 = clear + 1;

    var code_bits: u5 = @truncate(min_code_size + 1);
    var next: u16 = finish + 1;
    var previous: ?u16 = null;

    var at: usize = 0;
    var bit: u4 = 0;
    var done: usize = 0;

    while (true) {
        const code = takeCode(from, &at, &bit, code_bits) orelse return Error.Truncated;
        if (code == clear) {
            code_bits = @truncate(min_code_size + 1);
            next = finish + 1;
            previous = null;
            continue;
        }
        if (code == finish) return done;

        // How far down the stack this code's string reaches, and the
        // number it starts with.
        var depth: usize = 0;
        var walk: u16 = undefined;
        if (code < next) {
            walk = code;
        } else if (code == next) {
            // The one code that is used before it is made: the string
            // before it with its own first number on the end.
            const before = previous orelse return Error.Corrupt;
            work.stack[depth] = firstOf(work, before, clear);
            depth += 1;
            walk = before;
        } else {
            return Error.Corrupt;
        }
        while (walk >= clear) {
            if (depth >= work.stack.len) return Error.Corrupt;
            work.stack[depth] = work.suffix[walk];
            depth += 1;
            walk = work.prefix[walk];
        }
        if (depth >= work.stack.len) return Error.Corrupt;
        work.stack[depth] = @truncate(walk);
        depth += 1;

        if (done + depth > into.len) return Error.Overrun;
        var left = depth;
        while (left > 0) {
            left -= 1;
            into[done] = work.stack[left];
            done += 1;
        }

        // The new code: what came before, with this string's first
        // number on the end.
        if (previous) |before| {
            if (next < max_codes) {
                work.prefix[next] = before;
                work.suffix[next] = work.stack[depth - 1];
                next += 1;
                if (next == (@as(u16, 1) << @truncate(code_bits)) and code_bits < max_code_bits) code_bits += 1;
            }
        }
        previous = code;
    }
}

/// The first number of a code's string.
fn firstOf(work: *const Work, code: u16, clear: u16) u8 {
    var walk = code;
    var steps: usize = 0;
    while (walk >= clear and steps < max_codes) : (steps += 1) walk = work.prefix[walk];
    return @truncate(walk);
}

/// The next code, low bit first, or null at the end of the stream.
fn takeCode(from: []const u8, at: *usize, bit: *u4, bits: u5) ?u16 {
    var value: u32 = 0;
    var taken: u5 = 0;
    while (taken < bits) : (taken += 1) {
        if (at.* >= from.len) return null;
        value |= @as(u32, (from[at.*] >> @truncate(bit.*)) & 1) << taken;
        bit.* += 1;
        if (bit.* == 8) {
            bit.* = 0;
            at.* += 1;
        }
    }
    return @truncate(value);
}

const std = @import("std");
const testing = std.testing;

test "a coder's own stream comes back as the pixels it was" {
    // Sixteen pixels of three colours, as a coder wrote them: runs, and
    // codes made out of earlier codes.
    var work = Work{};
    const stream = [_]u8{
        0x00, 0x01, 0x08, 0x04, 0x10, 0x20, 0x80, 0x80,
        0x83, 0x02, 0x0a, 0x0e, 0x04, 0x10, 0x10,
    };
    const wanted = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 2, 2, 1, 1, 0, 0, 0, 0 };
    var into: [32]u8 = undefined;
    const written = try decode(&work, 8, &stream, &into);
    try testing.expectEqualSlices(u8, &wanted, into[0..written]);
}

test "a code that cannot be right says so" {
    var work = Work{};
    // Clear at three bits a code, then a code past anything made.
    const stream = [_]u8{ 0x3C, 0x00 };
    var into: [16]u8 = undefined;
    try testing.expectError(Error.Corrupt, decode(&work, 2, &stream, &into));
}

test "a code size the format does not allow says so" {
    var work = Work{};
    var into: [4]u8 = undefined;
    try testing.expectError(Error.Corrupt, decode(&work, 1, &.{}, &into));
}
