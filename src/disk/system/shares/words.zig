// SPDX-License-Identifier: MIT
//! A line of text put together piece by piece: what a gadget shows, which
//! keeps pointing at the buffer rather than copying it, so the line stays
//! where it is and is only ever written over.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// The longest line any of them shows.
pub const line_max: usize = 160;

pub const Line = struct {
    text: [line_max:0]u8 = @splat(0),
    length: usize = 0,

    pub fn clear(line: *Line) void {
        @memset(&line.text, 0);
        line.length = 0;
    }

    /// What it says, as a C string for a gadget.
    pub fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    pub fn slice(line: *const Line) []const u8 {
        return line.text[0..line.length];
    }

    /// `text` as it is, at the end.
    pub fn put(line: *Line, text: []const u8) void {
        for (text) |char| putChar(char, line);
    }

    /// `format` with `args`, at the end.
    pub fn add(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, &putChar, line);
    }

    /// The line set to `format` with `args`, whatever it said before.
    pub fn say(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        line.clear();
        line.add(sys, format, args);
    }

    fn putChar(char: u8, data: ?*anyopaque) callconv(.c) void {
        const line: *Line = @ptrCast(@alignCast(data.?));
        if (char == 0 or line.length >= line.text.len) return;
        line.text[line.length] = char;
        line.length += 1;
    }
};

/// The bytes of a NUL-terminated array up to its NUL.
pub fn untilNul(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, at| if (byte == 0) return bytes[0..at];
    return bytes;
}

/// The bytes a NUL-terminated pointer points at, up to its NUL.
pub fn spanOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// `text` into `into` with its NUL, cut to fit.
pub fn copyInto(into: []u8, text: []const u8) []const u8 {
    const count = @min(text.len, into.len - 1);
    @memcpy(into[0..count], text[0..count]);
    into[count] = 0;
    return into[0..count];
}

/// A number written into the front of `into`, in decimal: how many
/// characters it took. Nothing is written where there is no room.
pub fn putNumber(into: []u8, number: u16) usize {
    var digits: [5]u8 = undefined;
    var count: usize = 0;
    var rest = number;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    if (count > into.len) return 0;
    for (0..count) |at| into[at] = digits[count - 1 - at];
    return count;
}
