// SPDX-License-Identifier: MIT
//! The icon file: a PNG whose `icOn` chunk holds the icon's fields as
//! text. icon.library reads and writes icons with this, and
//! tools/mkicon makes them.
//!
//! **The chunk** comes right after `IHDR`. Its name's four cases say what
//! a PNG reader that does not know it may do: it is ancillary (the
//! picture shows without it), private, and safe to copy (a program that
//! changes the picture keeps it). Its text is a field a line, `KEY=value`:
//!
//!   KIND=TOOL                  DISK, DRAWER, TOOL, PROJECT, TRASHCAN
//!   AT=120,40                  its place in its drawer
//!   TOOL=SYS:Programs/MultiView
//!   TYPE=FILETYPE=text         a tool type, a line each, in order
//!   STACK=16384
//!   WINDOW=40,30,400,200       a drawer's window: left, top, width, height
//!   SCROLL=0,0                 how far a drawer's view is scrolled
//!   VIEW=NAME                  ICON, NAME, DATE, SIZE
//!   SHOW=ALL                   ICONS, ALL
//!
//! A field left out has its default: no place, no tool, no tool types,
//! the usual stack, a drawer's window chosen by whoever opens it. A line
//! with another key, or a value that does not read, is passed over, so a
//! file written by a later version still reads. Keys and the words of a
//! value are taken in any case.
//!
//! **Writing an icon** keeps its picture's chunks as they were and puts a
//! new `icOn` after `IHDR`: `headerChunk` is `IHDR` whole, `keepChunks`
//! copies every chunk after it but an old `icOn`, `putChunk` writes one
//! chunk with its checksum.

const decode = @import("../datatypes/png/decode.zig");
const icon = @import("icon.zig");

pub const Error = decode.Error;

/// The chunk's name, and as the number a chunk walk gives.
pub const CHUNK_NAME = "icOn";
pub const CHUNK_ID: u32 = @as(u32, 'i') << 24 | @as(u32, 'c') << 16 | @as(u32, 'O') << 8 | 'n';

/// The most text the chunk holds, and the largest picture an icon may
/// have either way.
pub const FIELDS_MAX = 16 * 1024;
pub const PICTURE_MAX = 256;

/// The keys of the fields.
pub const Key = enum { kind, at, tool, type, stack, window, scroll, view, show };
const key_names = [_][]const u8{ "KIND", "AT", "TOOL", "TYPE", "STACK", "WINDOW", "SCROLL", "VIEW", "SHOW" };

/// The words of KIND, by the kind's number; VIEW's by `DDVM_*`; SHOW's
/// by `DDFLAGS_*`.
pub const kind_names = [_][]const u8{ "", "DISK", "DRAWER", "TOOL", "PROJECT", "TRASHCAN" };
pub const view_names = [_][]const u8{ "DEFAULT", "ICON", "NAME", "DATE", "SIZE" };
pub const show_names = [_][]const u8{ "DEFAULT", "ICONS", "ALL" };

/// One field: its key and its value as written.
pub const Field = struct {
    key: Key,
    value: []const u8,
};

/// The fields of a chunk's text, one at a time, in the order they are
/// written; the lines that are not fields passed over.
pub const Fields = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Fields) ?Field {
        while (self.at < self.text.len) {
            const start = self.at;
            var end = start;
            while (end < self.text.len and self.text[end] != '\n') end += 1;
            self.at = if (end < self.text.len) end + 1 else end;
            var line = self.text[start..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const equals = indexOf(line, '=') orelse continue;
            const key = wordIn(&key_names, line[0..equals]) orelse continue;
            return .{ .key = @enumFromInt(key), .value = line[equals + 1 ..] };
        }
        return null;
    }
};

/// A kind's word as its number (`WBDISK` to `WBGARBAGE`).
pub fn kindOf(value: []const u8) ?u32 {
    const at = wordIn(&kind_names, value) orelse return null;
    return if (at == 0) null else @intCast(at);
}

/// VIEW's word as its `DDVM_*`, SHOW's as its `DDFLAGS_*`.
pub fn viewOf(value: []const u8) ?u32 {
    return if (wordIn(&view_names, value)) |at| @intCast(at) else null;
}
pub fn showOf(value: []const u8) ?u32 {
    return if (wordIn(&show_names, value)) |at| @intCast(at) else null;
}

/// `count` whole numbers, a comma between each, as a value holds them:
/// null unless there are exactly that many and each reads.
pub fn numbers(comptime count: usize, value: []const u8) ?[count]i32 {
    var result: [count]i32 = undefined;
    var at: usize = 0;
    for (0..count) |index| {
        var end = at;
        while (end < value.len and value[end] != ',') end += 1;
        result[index] = number(trim(value[at..end])) orelse return null;
        if (index + 1 < count) {
            if (end == value.len) return null;
            at = end + 1;
        } else if (end != value.len) return null;
    }
    return result;
}

/// A whole number, a minus sign in front of it or not.
pub fn number(text: []const u8) ?i32 {
    var digits = text;
    var negative = false;
    if (digits.len > 0 and digits[0] == '-') {
        negative = true;
        digits = digits[1..];
    }
    if (digits.len == 0 or digits.len > 10) return null;
    var value: i64 = 0;
    for (digits) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    if (negative) value = -value;
    if (value < -0x7FFF_FFFF or value > 0x7FFF_FFFF) return null;
    return @intCast(value);
}

/// The text of an icon's fields, into `into`: how many bytes it took, or
/// null when they do not fit. A string ends at its NUL or at a line's end,
/// whichever comes first: a field is one line.
pub fn writeFields(object: *const icon.DiskObject, into: []u8) ?usize {
    var out = Writer{ .into = into };
    if (object.kind >= 1 and object.kind < kind_names.len) {
        out.text("KIND=");
        out.text(kind_names[object.kind]);
        out.text("\n");
    }
    if (object.current_x != icon.NO_ICON_POSITION and object.current_y != icon.NO_ICON_POSITION) {
        out.text("AT=");
        out.numbers(&.{ object.current_x, object.current_y });
    }
    if (object.default_tool) |tool| {
        out.text("TOOL=");
        out.line(tool);
    }
    if (object.tool_types) |types| {
        var index: usize = 0;
        while (types[index]) |entry| : (index += 1) {
            out.text("TYPE=");
            out.line(entry);
        }
    }
    if (object.stack_size != 0) {
        out.text("STACK=");
        out.numbers(&.{@as(i32, @intCast(@min(object.stack_size, 0x7FFF_FFFF)))});
    }
    if (object.drawer_data) |drawer| {
        if (drawer.width > 0 and drawer.height > 0) {
            out.text("WINDOW=");
            out.numbers(&.{ drawer.left, drawer.top, drawer.width, drawer.height });
        }
        if (drawer.current_x != 0 or drawer.current_y != 0) {
            out.text("SCROLL=");
            out.numbers(&.{ drawer.current_x, drawer.current_y });
        }
        if (drawer.view_modes != icon.DDVM_BYDEFAULT and drawer.view_modes < view_names.len) {
            out.text("VIEW=");
            out.text(view_names[drawer.view_modes]);
            out.text("\n");
        }
        if (drawer.flags != icon.DDFLAGS_SHOWDEFAULT and drawer.flags < show_names.len) {
            out.text("SHOW=");
            out.text(show_names[drawer.flags]);
            out.text("\n");
        }
    }
    return if (out.full) null else out.length;
}

const Writer = struct {
    into: []u8,
    length: usize = 0,
    full: bool = false,

    fn text(out: *Writer, bytes: []const u8) void {
        if (out.full or out.length + bytes.len > out.into.len) {
            out.full = true;
            return;
        }
        @memcpy(out.into[out.length..][0..bytes.len], bytes);
        out.length += bytes.len;
    }

    /// A string up to its NUL or its first line end, then the line's end.
    fn line(out: *Writer, string: [*:0]const u8) void {
        var length: usize = 0;
        while (string[length] != 0 and string[length] != '\n' and string[length] != '\r') length += 1;
        out.text(string[0..length]);
        out.text("\n");
    }

    /// Numbers with a comma between each, then the line's end.
    fn numbers(out: *Writer, values: []const i32) void {
        for (values, 0..) |value, index| {
            if (index > 0) out.text(",");
            var digits: [11]u8 = undefined;
            var at: usize = digits.len;
            var rest: u32 = @abs(value);
            while (true) {
                at -= 1;
                digits[at] = '0' + @as(u8, @intCast(rest % 10));
                rest /= 10;
                if (rest == 0) break;
            }
            if (value < 0) {
                at -= 1;
                digits[at] = '-';
            }
            out.text(digits[at..]);
        }
        out.text("\n");
    }
};

// --- the chunks ---------------------------------------------------------------

/// The text of the file's `icOn` chunk; null when it has none.
pub fn fieldsOf(file: []const u8) Error!?[]const u8 {
    var walk = try decode.Walk.start(file);
    while (try walk.next()) |chunk| {
        if (chunk.id == CHUNK_ID) return chunk.data;
        if (chunk.id == decode.ID_IEND) break;
    }
    return null;
}

/// `IHDR` as a whole chunk - its length, its name, its bytes, its
/// checksum - as the file holds it.
pub fn headerChunk(file: []const u8) Error![]const u8 {
    var walk = try decode.Walk.start(file);
    const first = try walk.next() orelse return Error.Corrupt;
    if (first.id != decode.ID_IHDR) return Error.Corrupt;
    return whole(file, first);
}

/// How many bytes the chunks after `IHDR` take, `icOn` left out.
pub fn keptSize(file: []const u8) Error!usize {
    var walk = try decode.Walk.start(file);
    _ = try walk.next() orelse return Error.Corrupt;
    var total: usize = 0;
    while (try walk.next()) |chunk| {
        if (chunk.id != CHUNK_ID) total += chunk.data.len + 12;
        if (chunk.id == decode.ID_IEND) break;
    }
    return total;
}

/// The chunks after `IHDR`, `icOn` left out, copied into `into`, which
/// holds `keptSize` bytes.
pub fn keepChunks(file: []const u8, into: []u8) Error!void {
    var walk = try decode.Walk.start(file);
    _ = try walk.next() orelse return Error.Corrupt;
    var at: usize = 0;
    while (try walk.next()) |chunk| {
        if (chunk.id != CHUNK_ID) {
            const bytes = whole(file, chunk);
            @memcpy(into[at..][0..bytes.len], bytes);
            at += bytes.len;
        }
        if (chunk.id == decode.ID_IEND) break;
    }
}

/// One chunk written into `into`, which holds `data.len + 12` bytes: its
/// length, its name, `data`, its checksum. How many bytes that is.
pub fn putChunk(id: u32, data: []const u8, into: []u8) usize {
    putWord(into[0..4], @intCast(data.len));
    putWord(into[4..8], id);
    @memcpy(into[8..][0..data.len], data);
    putWord(into[8 + data.len ..][0..4], decode.crc32(into[4 .. 8 + data.len]));
    return data.len + 12;
}

/// The bytes a chunk takes in the file, from its length to its checksum.
fn whole(file: []const u8, chunk: decode.Chunk) []const u8 {
    const start = @intFromPtr(chunk.data.ptr) - @intFromPtr(file.ptr) - 8;
    return file[start..][0 .. chunk.data.len + 12];
}

fn putWord(into: *[4]u8, value: u32) void {
    into.* = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

fn indexOf(text: []const u8, char: u8) ?usize {
    for (text, 0..) |each, index| if (each == char) return index;
    return null;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and text[start] == ' ') start += 1;
    while (end > start and text[end - 1] == ' ') end -= 1;
    return text[start..end];
}

/// Where `word` is in `words`, in any case and with spaces round it.
fn wordIn(words: []const []const u8, word: []const u8) ?usize {
    const bare = trim(word);
    for (words, 0..) |each, index| {
        if (each.len == bare.len and sameLetters(each, bare)) return index;
    }
    return null;
}

fn sameLetters(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}
