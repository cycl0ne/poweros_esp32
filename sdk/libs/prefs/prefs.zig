// SPDX-License-Identifier: MIT
//! The system's settings as files in ENV:Sys and ENVARC:Sys: their forms
//! (`style`, `font`, `intuition`, `palette`, `anvil`, `sound`, `audio`,
//! `dock`) - each read, checked and written back by the one definition
//! every command and editor uses - and reading and writing a whole file
//! (`loadWhole`, `save`).
//!
//! Every form is lines of `KEY=value` pairs, read with `Pairs`, which goes
//! through utility.library's NextSetting: so they all take `KEY value` as
//! well, and a value in quotes with blanks in it.
//!
//! A setting is in force from ENV:, which is in RAM; ENVARC: keeps it
//! across a boot, and S:Startup-Sequence copies it to ENV: and hands it to
//! the system. A program that changes a setting for now writes ENV:; one
//! that keeps it writes both.

pub const style = @import("style.zig");
pub const font = @import("font.zig");
pub const intuition = @import("intuition.zig");
pub const palette = @import("palette.zig");
pub const anvil = @import("anvil.zig");
pub const sound = @import("sound.zig");
pub const audio = @import("audio.zig");
pub const dock = @import("dock.zig");

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;
const SettingScan = @import("../utility/setting.zig").SettingScan;

/// A line's `KEY=value` pairs, one at a time, as utility.library's
/// NextSetting reads them.
pub const Pairs = struct {
    ub: *UtilityBase,
    scan: SettingScan,

    pub const Pair = struct { key: []const u8, value: []const u8 };

    /// What a form says of a value whose quote is not closed.
    pub const quote_not_closed = "a quote is not closed";

    pub fn init(ub: *UtilityBase, text: []const u8) Pairs {
        return .{ .ub = ub, .scan = .{ .text = text.ptr, .length = text.len } };
    }

    /// The next pair, null at the line's end; error.QuoteNotClosed for a
    /// value whose quote is not closed, which ends the line.
    pub fn next(pairs: *Pairs) error{QuoteNotClosed}!?Pair {
        return switch (pairs.ub.NextSetting(&pairs.scan)) {
            0 => null,
            1 => .{ .key = pairs.scan.keyText(), .value = pairs.scan.valueText() },
            else => error.QuoteNotClosed,
        };
    }
};

/// The words of a setting that is on or off, by their value.
pub const yes_no = [2][]const u8{ "NO", "YES" };

/// YES or NO, any case, as true or false; null for anything else.
pub fn yesOrNo(value: []const u8) ?bool {
    if (style.same(value, yes_no[1])) return true;
    if (style.same(value, yes_no[0])) return false;
    return null;
}

/// `value` in decimal digits, into `into`; how many.
pub fn number(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..n) |i| into[i] = digits[n - 1 - i];
    return n;
}

/// A file read whole, however long, into memory of its own, which the
/// caller gives back with `FreeVec`; null when it is not there, is empty,
/// or cannot be read or held. A settings file's line comes after its
/// explanation, so a file read only in part would lose the line as soon
/// as the explanation grew.
pub fn loadWhole(sys: *ExecBase, dl: *DosBase, path: [*:0]const u8) ?[]u8 {
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib)) return null;
    if (fib.size == 0 or fib.size > ~@as(usize, 0)) return null;
    const length: usize = @intCast(fib.size);
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    const got = dl.Read(fh, bytes, @intCast(length));
    if (got <= 0) {
        sys.FreeVec(memory);
        return null;
    }
    return bytes[0..@intCast(got)];
}

/// A file read whole into `buffer`; what was read, or null when it is not
/// there or cannot be read. A file longer than `buffer` is cut: for a
/// settings file whose length its form bounds, as audio.prefs'; any other
/// is read with `loadWhole`.
pub fn load(dl: *DosBase, path: [*:0]const u8, buffer: []u8) ?[]u8 {
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    const got = dl.Read(fh, buffer.ptr, @intCast(buffer.len));
    if (got < 0) return null;
    return buffer[0..@intCast(got)];
}

/// `text` written as the whole of a file; whether it all went.
pub fn save(dl: *DosBase, path: [*:0]const u8, text: []const u8) bool {
    const fh = dl.Open(path, dos.MODE_NEWFILE) orelse return false;
    defer _ = dl.Close(fh);
    return dl.Write(fh, text.ptr, @intCast(text.len)) == @as(isize, @intCast(text.len));
}

/// The first line of `text` with words in it - not blank, not a comment -
/// or null.
pub fn firstLine(text: []const u8) ?[]const u8 {
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        if (style.hasWords(line.text)) return line.text;
    }
    return null;
}

/// The lines of a text, each with its number from 1.
pub const Lines = struct {
    text: []const u8,
    at: usize = 0,
    number: u32 = 0,

    pub fn next(l: *Lines) ?struct { text: []const u8, number: u32 } {
        if (l.at >= l.text.len) return null;
        var end = l.at;
        while (end < l.text.len and l.text[end] != '\n') end += 1;
        const line = l.text[l.at..end];
        l.at = end + 1;
        l.number += 1;
        return .{ .text = line, .number = l.number };
    }
};
