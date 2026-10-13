// SPDX-License-Identifier: MIT
//! Terminal's settings: which serial line, how it runs, and what the
//! terminal does with what crosses it - and the one line they are kept as
//! in `ENV:Terminal.prefs` and `ENVARC:Terminal.prefs`:
//!
//!     DEVICE="serial.device" UNIT=1 BAUD=115200 FRAME=8N1 HANDSHAKE=NONE RETURN=CR ECHO=OFF LFNEWLINE=ON
//!
//! - DEVICE, UNIT: the line, by the name OpenDevice takes and its unit.
//!   No DEVICE is no line yet.
//! - BAUD: bits per second.
//! - FRAME: data bits, parity (N, E or O) and stop bits.
//! - HANDSHAKE: NONE, or XONXOFF.
//! - RETURN: what the Return key sends - CR, LF or CRLF.
//! - ECHO: ON shows what is typed as well as sending it, for a far end
//!   that does not echo.
//! - LFNEWLINE: ON starts a new line at a line feed received, for a far
//!   end that ends its lines with LF alone.
//!
//! A word left out keeps the value it has, so the same words given to the
//! command change only what they name. Nothing here opens or draws: the
//! host tests hold all of it.

const style = @import("sdk").prefs.style;

pub const ENV_FILE = "ENV:Terminal.prefs";
pub const ENVARC_FILE = "ENVARC:Terminal.prefs";

/// A line's character frame.
pub const Frame = struct {
    name: [:0]const u8,
    bits: u8,
    parity: Parity,
    stop_bits: u8,
};

pub const Parity = enum { none, even, odd };

/// The frames offered, the first the default.
pub const frames = [_]Frame{
    .{ .name = "8N1", .bits = 8, .parity = .none, .stop_bits = 1 },
    .{ .name = "8E1", .bits = 8, .parity = .even, .stop_bits = 1 },
    .{ .name = "8O1", .bits = 8, .parity = .odd, .stop_bits = 1 },
    .{ .name = "8N2", .bits = 8, .parity = .none, .stop_bits = 2 },
    .{ .name = "7E1", .bits = 7, .parity = .even, .stop_bits = 1 },
    .{ .name = "7O1", .bits = 7, .parity = .odd, .stop_bits = 1 },
    .{ .name = "7N1", .bits = 7, .parity = .none, .stop_bits = 1 },
};

/// The speeds the settings window offers.
pub const rates = [_]u32{ 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600 };

/// What the Return key sends.
pub const Return = enum(u8) { cr, lf, crlf };
pub const return_names = [3][]const u8{ "CR", "LF", "CRLF" };

pub const Handshake = enum(u8) { none, xonxoff };
pub const handshake_names = [2][]const u8{ "NONE", "XONXOFF" };

/// The longest device name kept, its NUL aside.
pub const device_max = 63;

pub const Settings = struct {
    /// The device's name, NUL-terminated; empty for no line.
    device: [device_max + 1]u8 = @splat(0),
    unit: u32 = 0,
    baud: u32 = 115200,
    /// An index into `frames`.
    frame: u8 = 0,
    handshake: Handshake = .none,
    send_return: Return = .cr,
    echo: bool = false,
    lf_newline: bool = true,

    /// The device's name, or null for none.
    pub fn deviceName(settings: *const Settings) ?[:0]const u8 {
        var len: usize = 0;
        while (settings.device[len] != 0) len += 1;
        if (len == 0) return null;
        return settings.device[0..len :0];
    }

    /// The device named; false when the name is too long to keep.
    pub fn setDevice(settings: *Settings, name: []const u8) bool {
        if (name.len > device_max) return false;
        @memset(&settings.device, 0);
        @memcpy(settings.device[0..name.len], name);
        return true;
    }

    pub fn frameOf(settings: *const Settings) Frame {
        return frames[@min(settings.frame, frames.len - 1)];
    }

    /// Whether `other` names the same line, unit and all.
    pub fn sameLine(settings: *const Settings, other: *const Settings) bool {
        return settings.unit == other.unit and sameBytes(&settings.device, &other.device);
    }
};

fn sameBytes(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (a != b) return false;
    return true;
}

fn onOff(text: []const u8) ?bool {
    if (style.same(text, "ON") or style.same(text, "YES")) return true;
    if (style.same(text, "OFF") or style.same(text, "NO")) return false;
    return null;
}

fn indexOf(names: []const []const u8, text: []const u8) ?usize {
    for (names, 0..) |name, i| if (style.same(text, name)) return i;
    return null;
}

/// The words of `text` read into `settings`: null when they all made
/// sense, else what was wrong with the first that did not, which leaves
/// the words after it unread.
pub fn parse(text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
        if (i >= text.len) return null;
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '=' and text[end] != '\r' and text[end] != '\n') end += 1;
        const word = text[i..end];
        i = end;
        if (i < text.len and text[i] == '=') i += 1;
        // A value in quotes may have spaces in it.
        var value: []const u8 = undefined;
        if (i < text.len and text[i] == '"') {
            var close = i + 1;
            while (close < text.len and text[close] != '"') close += 1;
            if (close >= text.len) return "a quote is not closed";
            value = text[i + 1 .. close];
            i = close + 1;
        } else {
            var value_end = i;
            while (value_end < text.len and text[value_end] != ' ' and text[value_end] != '\t' and text[value_end] != '\r' and text[value_end] != '\n') value_end += 1;
            value = text[i..value_end];
            i = value_end;
        }
        if (style.same(word, "DEVICE")) {
            if (!settings.setDevice(value)) return "DEVICE's name is too long";
        } else if (style.same(word, "UNIT")) {
            settings.unit = style.decimal(value) orelse return "UNIT is a number";
        } else if (style.same(word, "BAUD")) {
            const baud = style.decimal(value) orelse return "BAUD is bits per second";
            if (baud == 0) return "BAUD is bits per second";
            settings.baud = baud;
        } else if (style.same(word, "FRAME")) {
            settings.frame = for (frames, 0..) |frame, k| {
                if (style.same(value, frame.name)) break @intCast(k);
            } else return "FRAME is 8N1, 8E1, 8O1, 8N2, 7E1, 7O1 or 7N1";
        } else if (style.same(word, "HANDSHAKE")) {
            const k = indexOf(&handshake_names, value) orelse return "HANDSHAKE is NONE or XONXOFF";
            settings.handshake = @enumFromInt(k);
        } else if (style.same(word, "RETURN")) {
            const k = indexOf(&return_names, value) orelse return "RETURN is CR, LF or CRLF";
            settings.send_return = @enumFromInt(k);
        } else if (style.same(word, "ECHO")) {
            settings.echo = onOff(value) orelse return "ECHO is ON or OFF";
        } else if (style.same(word, "LFNEWLINE")) {
            settings.lf_newline = onOff(value) orelse return "LFNEWLINE is ON or OFF";
        } else {
            return "a word that is not DEVICE, UNIT, BAUD, FRAME, HANDSHAKE, RETURN, ECHO or LFNEWLINE";
        }
    }
}

/// Text put into `into` from `at`, as far as it fits; where it ends.
fn put(into: []u8, at: usize, text: []const u8) usize {
    const n = @min(text.len, into.len - at);
    @memcpy(into[at..][0..n], text[0..n]);
    return at + n;
}

fn putNumber(into: []u8, at: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var reversed: [10]u8 = undefined;
    for (0..count) |k| reversed[k] = digits[count - 1 - k];
    return put(into, at, reversed[0..count]);
}

/// The settings as their line, with a newline at the end; how many bytes
/// it took. 160 bytes hold any of them.
pub fn write(settings: *const Settings, into: []u8) usize {
    var at: usize = 0;
    if (settings.deviceName()) |name| {
        at = put(into, at, "DEVICE=\"");
        at = put(into, at, name);
        at = put(into, at, "\" UNIT=");
        at = putNumber(into, at, settings.unit);
        at = put(into, at, " ");
    }
    at = put(into, at, "BAUD=");
    at = putNumber(into, at, settings.baud);
    at = put(into, at, " FRAME=");
    at = put(into, at, settings.frameOf().name);
    at = put(into, at, " HANDSHAKE=");
    at = put(into, at, handshake_names[@intFromEnum(settings.handshake)]);
    at = put(into, at, " RETURN=");
    at = put(into, at, return_names[@intFromEnum(settings.send_return)]);
    at = put(into, at, if (settings.echo) " ECHO=ON" else " ECHO=OFF");
    at = put(into, at, if (settings.lf_newline) " LFNEWLINE=ON\n" else " LFNEWLINE=OFF\n");
    return at;
}

/// What the Return key's byte becomes on the line.
pub fn returnBytes(settings: *const Settings) []const u8 {
    return switch (settings.send_return) {
        .cr => "\r",
        .lf => "\n",
        .crlf => "\r\n",
    };
}

/// Bytes received, made ready for the console: with `lf_newline`, a line
/// feed that does not follow a carriage return gets one in front of it,
/// so the next line starts at its left edge. `last` is the byte that came
/// before these, kept from call to call. How many bytes went into `into`,
/// which is twice the size of `bytes`.
pub fn shown(settings: *const Settings, bytes: []const u8, last: *u8, into: []u8) usize {
    var at: usize = 0;
    for (bytes) |byte| {
        if (settings.lf_newline and byte == '\n' and last.* != '\r') {
            into[at] = '\r';
            at += 1;
        }
        into[at] = byte;
        at += 1;
        last.* = byte;
    }
    return at;
}
