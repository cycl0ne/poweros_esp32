// SPDX-License-Identifier: MIT
//! Sheets as CSV files: a line per row, the cells' texts as they were
//! typed - a formula with its `=` - split by a separator.
//!
//! A field that holds the separator, a quote or a line break is put in
//! quotes, and a quote in it doubled. Reading takes whichever separator
//! the first line has most of outside quotes - a comma, a semicolon or a
//! tab - and a file that begins with UTF-8's byte order mark, or is UTF-8
//! throughout, has its characters turned into the system's Latin-1 ones
//! (a character Latin-1 has not is a `?`).
//!
//! A semicolon file is how a spreadsheet writes CSV where the comma is the
//! decimal point, so a field that reads as a number once its one comma is
//! a point is taken as that number; the file then says so
//! (`decimal_comma`), and a number is written back with its comma when
//! the file is saved the same way.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const cells = @import("cells.zig");
const formula = @import("formula.zig");
const number = @import("number.zig");

/// How a file was read, and so how it is written back.
pub const Form = struct {
    separator: u8 = ',',
    decimal_comma: bool = false,
};

pub const ReadResult = struct {
    form: Form = .{},
    /// Fields past the sheet's last row or column were left out.
    cut: bool = false,
    /// There was not memory for everything.
    short: bool = false,
};

/// The separator of the line at the start of `bytes`: a semicolon when it
/// has at least as many of those as commas outside quotes - a line of
/// numbers with decimal commas has one comma a field - a tab when it has
/// more of those than of either, else a comma.
pub fn separatorOf(bytes: []const u8) u8 {
    var counts = [3]u32{ 0, 0, 0 };
    var quoted = false;
    for (bytes) |char| {
        if (char == '"') quoted = !quoted;
        if (quoted) continue;
        if (char == '\n') break;
        switch (char) {
            ',' => counts[0] += 1,
            ';' => counts[1] += 1,
            '\t' => counts[2] += 1,
            else => {},
        }
    }
    if (counts[1] > 0 and counts[1] >= counts[0] and counts[1] >= counts[2]) return ';';
    if (counts[2] > counts[0] and counts[2] > counts[1]) return '\t';
    return ',';
}

/// The length of the UTF-8 character starting with `lead` when the bytes
/// after it continue it, else 0.
fn utf8Length(bytes: []const u8, at: usize) usize {
    const lead = bytes[at];
    const length: usize = if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else return 0;
    if (at + length > bytes.len) return 0;
    for (bytes[at + 1 .. at + length]) |follow| {
        if (follow & 0xC0 != 0x80) return 0;
    }
    return length;
}

/// Whether `bytes` are UTF-8 with at least one character past ASCII.
fn isUtf8(bytes: []const u8) bool {
    var wide = false;
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes[at] < 0x80) {
            at += 1;
            continue;
        }
        const length = utf8Length(bytes, at);
        if (length == 0) return false;
        wide = true;
        at += length;
    }
    return wide;
}

/// UTF-8 turned into Latin-1 where it lies, in place; the shorter text.
fn toLatin1(bytes: []u8) []u8 {
    var used: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const length = if (bytes[at] < 0x80) 0 else utf8Length(bytes, at);
        if (length == 0) {
            bytes[used] = bytes[at];
            used += 1;
            at += 1;
            continue;
        }
        var code: u32 = bytes[at] & (@as(u8, 0x7F) >> @intCast(length));
        for (bytes[at + 1 .. at + length]) |follow| code = code << 6 | (follow & 0x3F);
        bytes[used] = if (code <= 0xFF) @intCast(code) else '?';
        used += 1;
        at += length;
    }
    return bytes[0..used];
}

/// A field that reads as a number with its one comma as the point,
/// written that way into `out`; null for any other.
fn commaNumber(field: []const u8, out: *[64]u8) ?[]const u8 {
    if (field.len > out.len) return null;
    var commas: usize = 0;
    for (field) |char| {
        if (char == '.') return null;
        if (char == ',') commas += 1;
    }
    if (commas != 1) return null;
    for (field, 0..) |char, at| out[at] = if (char == ',') '.' else char;
    const text = out[0..field.len];
    return if (number.parse(text) != null) text else null;
}

/// The CSV in `bytes` read into `sheet` from its first cell on, each field
/// as typed into its cell; the sheet emptied first and worked out after.
/// `bytes` is changed where its characters are made Latin-1.
pub fn read(sheet: *cells.Sheet, given: []u8) ReadResult {
    var result = ReadResult{};
    sheet.clearAll();
    var bytes = given;
    var utf8 = false;
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) {
        bytes = bytes[3..];
        utf8 = true;
    }
    if (utf8 or isUtf8(bytes)) bytes = toLatin1(bytes);
    const separator = separatorOf(bytes);
    result.form.separator = separator;

    var field: [cells.max_text]u8 = undefined;
    var row: u32 = 0;
    var col: u32 = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        // One field, quoted or not, up to its separator or line's end.
        var length: usize = 0;
        if (bytes[at] == '"') {
            at += 1;
            while (at < bytes.len) {
                if (bytes[at] == '"') {
                    if (at + 1 < bytes.len and bytes[at + 1] == '"') {
                        if (length < field.len) field[length] = '"';
                        length += 1;
                        at += 2;
                        continue;
                    }
                    at += 1;
                    break;
                }
                if (length < field.len) field[length] = bytes[at];
                length += 1;
                at += 1;
            }
        }
        while (at < bytes.len and bytes[at] != separator and bytes[at] != '\n') : (at += 1) {
            if (bytes[at] == '\r') continue;
            if (length < field.len) field[length] = bytes[at];
            length += 1;
        }
        var text: []const u8 = field[0..@min(length, field.len)];
        if (text.len > 0) {
            var point: [64]u8 = undefined;
            if (separator == ';' and text[0] != '=') {
                if (commaNumber(text, &point)) |changed| {
                    text = changed;
                    result.form.decimal_comma = true;
                }
            }
            if (row < formula.max_rows and col < formula.max_cols) {
                if (!sheet.changeText(row, col, text)) result.short = true;
            } else result.cut = true;
        }
        if (at >= bytes.len) break;
        if (bytes[at] == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
        at += 1;
    }
    sheet.changed = false;
    sheet.recalculate();
    return result;
}

const Out = struct {
    sys: *ExecBase,
    bytes: sdk.exec.Array(u8) = .{},
    failed: bool = false,

    fn put(out: *Out, text: []const u8) void {
        if (!out.bytes.appendSlice(out.sys, text)) out.failed = true;
    }
};

/// The sheet as CSV in `form`, in memory of its own for the caller to
/// FreeVec; null with no memory. An empty sheet is an empty text, which
/// has no memory (`len` 0, nothing to free).
pub fn write(sheet: *cells.Sheet, form: Form) ?[]const u8 {
    var out = Out{ .sys = sheet.sys };
    const reach = sheet.extent();
    var row: u32 = 0;
    while (row < reach.rows) : (row += 1) {
        // The row's fields up to its last one with something in it.
        var last: u32 = 0;
        var col: u32 = 0;
        while (col < reach.cols) : (col += 1) {
            if (sheet.find(row, col) != null) last = col + 1;
        }
        col = 0;
        while (col < last) : (col += 1) {
            if (col > 0) out.put(&.{form.separator});
            const cell = sheet.find(row, col) orelse continue;
            var text = cell.text();
            var comma: [cells.max_text]u8 = undefined;
            if (form.decimal_comma and form.separator == ';' and cell.content == .number) {
                for (text, 0..) |char, at| comma[at] = if (char == '.') ',' else char;
                text = comma[0..text.len];
            }
            var quote = false;
            for (text) |char| {
                if (char == form.separator or char == '"' or char == '\n' or char == '\r') quote = true;
            }
            if (!quote) {
                out.put(text);
                continue;
            }
            out.put("\"");
            for (text) |char| {
                if (char == '"') out.put("\"");
                out.put(&.{char});
            }
            out.put("\"");
        }
        out.put("\n");
    }
    if (out.failed) {
        out.bytes.deinit(sheet.sys);
        return null;
    }
    if (out.bytes.len == 0) return &.{};
    return out.bytes.slice();
}
