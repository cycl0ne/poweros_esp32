// SPDX-License-Identifier: MIT
//! The system's settings as files in ENV:Sys and ENVARC:Sys: their forms
//! (`style`, `font`, `intuition`, `palette`, `anvil`) - each read, checked
//! and written back by the one definition every command and editor uses -
//! and reading and writing a whole file.
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

const dos = @import("../dos/dos.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// A file read whole into `buffer`; what was read, or null when it is not
/// there or cannot be read. A file longer than `buffer` is cut.
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
