// SPDX-License-Identifier: MIT
//! Text for WiFi's gadgets and files: a line put together piece by piece,
//! which a gadget keeps pointing at - so it stays where it is and is only
//! ever written over - and the few ways a name is copied and compared.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// The longest line any gadget shows.
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

    /// `bytes` as they are, at the end.
    pub fn put(line: *Line, bytes: []const u8) void {
        for (bytes) |char| putChar(char, line);
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
pub fn spanOf(string: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (string[length] != 0) length += 1;
    return string[0..length];
}

/// `bytes` into `into` with a NUL after them, cut to fit.
pub fn copyInto(into: []u8, bytes: []const u8) []const u8 {
    const count = @min(bytes.len, into.len - 1);
    @memcpy(into[0..count], bytes[0..count]);
    into[count] = 0;
    return into[0..count];
}

/// Whether two names are the same, byte for byte: a network's name is
/// told apart by case.
pub fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (a != b) return false;
    return true;
}

/// Whether two words are the same but for the case of their letters, as
/// a keyword is.
pub fn sameWord(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (lower(a) != lower(b)) return false;
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 0x20 else char;
}

/// `bytes` set to 0 in a way the compiler does not leave out: a
/// passphrase does not stay behind in memory.
pub fn wipe(bytes: []u8) void {
    const volatile_bytes: [*]volatile u8 = @ptrCast(bytes.ptr);
    for (0..bytes.len) |at| volatile_bytes[at] = 0;
}
