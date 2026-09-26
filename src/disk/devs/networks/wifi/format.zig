// SPDX-License-Identifier: MIT
//! C's printf formats, for the radio's libraries: their `sprintf`, their
//! log calls and their own printf hooks hand over a C format string and a
//! C variable argument list, which exec's RawDoFmt does not read.
//!
//! What is understood: the flags `-0+ #`, a width and a precision (a
//! number or `*`), the lengths `hh h l ll z j t`, and `d i u x X o c s p %`.
//! A floating-point argument is taken from the list and printed as `?`;
//! the libraries format none that anyone reads.
//!
//! The output goes to a `Sink`, a buffer that counts what did not fit, so
//! `vsnprintf` answers the length the whole text would have had.

const std = @import("std");

pub const Sink = struct {
    buffer: []u8,
    length: usize = 0,

    pub fn put(sink: *Sink, char: u8) void {
        if (sink.length < sink.buffer.len) sink.buffer[sink.length] = char;
        sink.length += 1;
    }

    /// The text, NUL-terminated inside the buffer (cut if it had to be).
    pub fn finish(sink: *Sink) void {
        if (sink.buffer.len == 0) return;
        sink.buffer[@min(sink.length, sink.buffer.len - 1)] = 0;
    }
};

const Spec = struct {
    left: bool = false,
    zero: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

fn pad(sink: *Sink, count: usize, char: u8) void {
    for (0..count) |_| sink.put(char);
}

fn number(sink: *Sink, spec: Spec, value: u64, negative: bool, base: u8, upper: bool) void {
    var digits: [24]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    const alphabet: []const u8 = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    while (rest != 0 or count == 0) : (rest /= base) {
        digits[count] = alphabet[@intCast(rest % base)];
        count += 1;
    }
    if (spec.precision) |precision| if (precision == 0 and value == 0) {
        count = 0;
    };
    const minimum = spec.precision orelse 0;
    const zeros = if (minimum > count) minimum - count else 0;
    var prefix: [2]u8 = undefined;
    var prefix_len: usize = 0;
    if (negative) {
        prefix[0] = '-';
        prefix_len = 1;
    } else if (spec.plus) {
        prefix[0] = '+';
        prefix_len = 1;
    } else if (spec.space) {
        prefix[0] = ' ';
        prefix_len = 1;
    }
    if (spec.alt and base == 16 and value != 0) {
        prefix[0] = '0';
        prefix[1] = if (upper) 'X' else 'x';
        prefix_len = 2;
    }
    const body = prefix_len + zeros + count;
    const fill = if (spec.width > body) spec.width - body else 0;
    const zero_fill = spec.zero and !spec.left and spec.precision == null;
    if (!spec.left and !zero_fill) pad(sink, fill, ' ');
    for (prefix[0..prefix_len]) |char| sink.put(char);
    if (zero_fill) pad(sink, fill, '0');
    pad(sink, zeros, '0');
    while (count > 0) {
        count -= 1;
        sink.put(digits[count]);
    }
    if (spec.left) pad(sink, fill, ' ');
}

fn text(sink: *Sink, spec: Spec, string: [*:0]const u8) void {
    var length: usize = 0;
    while (string[length] != 0 and (spec.precision == null or length < spec.precision.?)) length += 1;
    const fill = if (spec.width > length) spec.width - length else 0;
    if (!spec.left) pad(sink, fill, ' ');
    for (string[0..length]) |char| sink.put(char);
    if (spec.left) pad(sink, fill, ' ');
}

/// `format` with the arguments in `args`, into `sink`.
/// C calling convention: the list is read with @cVaArg, which only a C
/// function may do on every target.
pub fn format(sink: *Sink, format_string: [*:0]const u8, args: *std.builtin.VaList) callconv(.c) void {
    var at: usize = 0;
    while (format_string[at] != 0) : (at += 1) {
        const char = format_string[at];
        if (char != '%') {
            sink.put(char);
            continue;
        }
        at += 1;
        var spec: Spec = .{};
        while (true) : (at += 1) switch (format_string[at]) {
            '-' => spec.left = true,
            '0' => spec.zero = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alt = true,
            else => break,
        };
        if (format_string[at] == '*') {
            const width = @cVaArg(args, c_int);
            if (width < 0) {
                spec.left = true;
                spec.width = @intCast(-width);
            } else spec.width = @intCast(width);
            at += 1;
        } else while (format_string[at] >= '0' and format_string[at] <= '9') : (at += 1) {
            spec.width = spec.width * 10 + (format_string[at] - '0');
        }
        if (format_string[at] == '.') {
            at += 1;
            var precision: usize = 0;
            if (format_string[at] == '*') {
                const given = @cVaArg(args, c_int);
                precision = if (given < 0) 0 else @intCast(given);
                at += 1;
            } else while (format_string[at] >= '0' and format_string[at] <= '9') : (at += 1) {
                precision = precision * 10 + (format_string[at] - '0');
            }
            spec.precision = precision;
        }
        // Lengths: only `ll` (and `j`) is wider than a word here.
        var wide = false;
        while (true) : (at += 1) switch (format_string[at]) {
            'h', 'z', 't' => {},
            'l' => if (format_string[at + 1] == 'l') {
                wide = true;
                at += 1;
            },
            'j' => wide = true,
            else => break,
        };
        switch (format_string[at]) {
            'd', 'i' => {
                const value: i64 = if (wide) @cVaArg(args, i64) else @cVaArg(args, c_int);
                number(sink, spec, @abs(value), value < 0, 10, false);
            },
            'u', 'x', 'X', 'o' => |conversion| {
                const value: u64 = if (wide) @cVaArg(args, u64) else @cVaArg(args, c_uint);
                const base: u8 = switch (conversion) {
                    'u' => 10,
                    'o' => 8,
                    else => 16,
                };
                number(sink, spec, value, false, base, conversion == 'X');
            },
            'p' => {
                const value = @cVaArg(args, usize);
                number(sink, .{ .alt = true, .width = spec.width, .left = spec.left }, value, false, 16, false);
            },
            'c' => {
                const value = @cVaArg(args, c_int);
                const fill = if (spec.width > 1) spec.width - 1 else 0;
                if (!spec.left) pad(sink, fill, ' ');
                sink.put(@truncate(@as(c_uint, @bitCast(value))));
                if (spec.left) pad(sink, fill, ' ');
            },
            's' => {
                const value = @cVaArg(args, ?[*:0]const u8);
                text(sink, spec, value orelse "(null)");
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                _ = @cVaArg(args, f64);
                sink.put('?');
            },
            '%' => sink.put('%'),
            0 => return,
            else => |other| {
                sink.put('%');
                sink.put(other);
            },
        }
    }
}

fn testFormat(buffer: [*]u8, size: usize, format_string: [*:0]const u8, ...) callconv(.c) usize {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    var sink: Sink = .{ .buffer = buffer[0..size] };
    format(&sink, format_string, &args);
    sink.finish();
    return sink.length;
}

test format {
    const testing = std.testing;
    var buffer: [64]u8 = undefined;
    _ = testFormat(&buffer, buffer.len, "%d|%5u|%-4x|%04X|%s|%c", @as(c_int, -42), @as(c_uint, 7), @as(c_uint, 0xab), @as(c_uint, 0xbe), "ok", @as(c_int, 'z'));
    try testing.expectEqualStrings("-42|    7|ab  |00BE|ok|z", std.mem.sliceTo(&buffer, 0));
    _ = testFormat(&buffer, buffer.len, "%02x:%02x %lld %.2s %%", @as(c_uint, 1), @as(c_uint, 0xff), @as(i64, -5000000000), "abc");
    try testing.expectEqualStrings("01:ff -5000000000 ab %", std.mem.sliceTo(&buffer, 0));
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), testFormat(&small, small.len, "%s", "abcdef"));
    try testing.expectEqualStrings("abc", std.mem.sliceTo(&small, 0));
}
