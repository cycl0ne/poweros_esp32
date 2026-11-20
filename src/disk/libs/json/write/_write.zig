// SPDX-License-Identifier: MIT
//! A value written out as JSON text, into memory or a file.
//!
//! The tree is walked without recursion: down into an array or object to
//! its first value, on to the next, and up out of each that ends - its
//! closing bracket written then - until the value it began at is done.
//! What is written goes to a `Sink`: memory, of which it fills what there
//! is room for while it counts all of it, or a file, through a buffer of
//! its own.
//!
//! A string's quote, backslash and control characters are escaped - the
//! short escapes where JSON has them, `\u00XX` for the rest - and so, with
//! JSONF_ASCII, is everything past ASCII. Bytes that are not UTF-8 are
//! written as U+FFFD, so the text is always JSON. A number takes the
//! fewest digits that read back as the same double (`number/_number.zig`),
//! a whole one kept exactly its digits; infinity and NaN, which JSON
//! cannot write, are `null`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const DosBase = sdk.interface.dos.DosBase;
const _number = @import("../number/_number.zig");
const _utf8 = @import("../utf8/_utf8.zig");
const Value = json.Value;

/// Where the text goes, and how much of it there is.
pub const Sink = struct {
    /// Memory: `size` bytes, a NUL kept room for.
    buffer: ?[*]u8 = null,
    size: usize = 0,
    /// A file, written through `chunk`.
    dl: ?*DosBase = null,
    file: ?*dos.FileHandle = null,
    chunk: [512]u8 = undefined,
    waiting: usize = 0,
    /// The text's whole length so far.
    total: usize = 0,
    /// A write to the file failed.
    failed: bool = false,

    pub fn put(sink: *Sink, bytes: []const u8) void {
        if (sink.buffer) |into| {
            if (sink.size > 0 and sink.total < sink.size - 1) {
                const fits = @min(bytes.len, sink.size - 1 - sink.total);
                @memcpy(into[sink.total..][0..fits], bytes[0..fits]);
            }
        }
        if (sink.file != null) {
            var from: usize = 0;
            while (from < bytes.len) {
                if (sink.waiting == sink.chunk.len) sink.flush();
                const fits = @min(bytes.len - from, sink.chunk.len - sink.waiting);
                @memcpy(sink.chunk[sink.waiting..][0..fits], bytes[from..][0..fits]);
                sink.waiting += fits;
                from += fits;
            }
        }
        sink.total += bytes.len;
    }

    pub fn byte(sink: *Sink, char: u8) void {
        sink.put(&.{char});
    }

    /// What waits for the file written.
    pub fn flush(sink: *Sink) void {
        const file = sink.file orelse return;
        if (sink.waiting == 0) return;
        const length: isize = @intCast(sink.waiting);
        if (!sink.failed and sink.dl.?.Write(file, &sink.chunk, length) != length) sink.failed = true;
        sink.waiting = 0;
    }
};

/// `top` written into `sink` as `flags` say; false when there was no
/// memory to write a number in.
pub fn write(base: *JSONBase, top: *const Value, flags: u32, sink: *Sink) bool {
    var writer = Writer{ .base = base, .sink = sink, .flags = flags };
    const done = writer.tree(top);
    if (writer.work) |room| base.sys_base.FreeVec(room);
    return done;
}

const Writer = struct {
    base: *JSONBase,
    sink: *Sink,
    flags: u32,
    /// Where a number is worked out, made the first time one needs it.
    work: ?*_number.Work = null,

    fn pretty(writer: *const Writer) bool {
        return writer.flags & json.JSONF_PRETTY != 0;
    }

    /// A line end and the indent of `depth`, when pretty.
    fn newLine(writer: *Writer, depth: u32) void {
        if (!writer.pretty()) return;
        writer.sink.byte('\n');
        var left = depth;
        while (left > 0) : (left -= 1) writer.sink.put("  ");
    }

    fn tree(writer: *Writer, top: *const Value) bool {
        const sink = writer.sink;
        var value = top;
        var depth: u32 = 0;
        while (true) {
            if (value != top) {
                if (value.parent) |container| {
                    if (container.kind == json.JSON_OBJECT) {
                        writer.string(value.name orelse "", value.name_length);
                        sink.byte(':');
                        if (writer.pretty()) sink.byte(' ');
                    }
                }
            }
            if (value.kind == json.JSON_ARRAY or value.kind == json.JSON_OBJECT) {
                sink.byte(if (value.kind == json.JSON_ARRAY) '[' else '{');
                if (value.first) |first| {
                    depth += 1;
                    writer.newLine(depth);
                    value = first;
                    continue;
                }
                sink.byte(if (value.kind == json.JSON_ARRAY) ']' else '}');
            } else if (!writer.scalar(value)) {
                return false;
            }
            // On to the next value: after this one, or after each array
            // and object that ends with it.
            while (true) {
                if (value == top) return true;
                if (value.next) |next| {
                    sink.byte(',');
                    writer.newLine(depth);
                    value = next;
                    break;
                }
                const container = value.parent.?;
                depth -= 1;
                writer.newLine(depth);
                sink.byte(if (container.kind == json.JSON_ARRAY) ']' else '}');
                value = container;
            }
        }
    }

    fn scalar(writer: *Writer, value: *const Value) bool {
        const sink = writer.sink;
        switch (value.kind) {
            json.JSON_NULL => sink.put("null"),
            json.JSON_BOOLEAN => sink.put(if (value.truth) "true" else "false"),
            json.JSON_STRING => writer.string(value.string orelse "", value.length),
            json.JSON_NUMBER => {
                var text: [_number.text_max]u8 = undefined;
                if (value.flags & json.JSONVF_INTEGER != 0) {
                    sink.put(_number.writeWhole(value.integer, &text));
                } else if (value.number - value.number != 0) {
                    // Infinity or NaN: neither is JSON.
                    sink.put("null");
                } else {
                    sink.put(_number.write(value.number, &text, writer, workRoom) orelse return false);
                }
            },
            else => sink.put("null"),
        }
        return true;
    }

    fn workRoom(writer: *Writer) ?*_number.Work {
        if (writer.work == null) {
            const memory = writer.base.sys_base.AllocVec(@sizeOf(_number.Work), exec.MEMF_ANY) orelse return null;
            writer.work = @ptrCast(@alignCast(memory));
        }
        return writer.work;
    }

    /// `length` bytes of text as a JSON string, quotes and escapes and
    /// all.
    fn string(writer: *Writer, text: [*]const u8, length: usize) void {
        const sink = writer.sink;
        const ascii = writer.flags & json.JSONF_ASCII != 0;
        sink.byte('"');
        var at: usize = 0;
        var plain_from: usize = 0;
        while (at < length) {
            const char = text[at];
            if (char >= 0x20 and char < 0x80 and char != '"' and char != '\\') {
                at += 1;
                continue;
            }
            sink.put(text[plain_from..at]);
            if (char < 0x80) {
                switch (char) {
                    '"' => sink.put("\\\""),
                    '\\' => sink.put("\\\\"),
                    0x08 => sink.put("\\b"),
                    0x0C => sink.put("\\f"),
                    '\n' => sink.put("\\n"),
                    '\r' => sink.put("\\r"),
                    '\t' => sink.put("\\t"),
                    else => writer.escape(char),
                }
                at += 1;
            } else {
                const bytes = _utf8.lengthAt(text, at, length);
                if (bytes == 0) {
                    writer.character(_utf8.replacement, ascii);
                    at += 1;
                } else if (ascii) {
                    writer.character(_utf8.decode(text, at, bytes), true);
                    at += bytes;
                } else {
                    sink.put(text[at..][0..bytes]);
                    at += bytes;
                }
            }
            plain_from = at;
        }
        sink.put(text[plain_from..at]);
        sink.byte('"');
    }

    /// A character past ASCII: as `\u` escapes, or as its UTF-8.
    fn character(writer: *Writer, point: u21, ascii: bool) void {
        if (!ascii) {
            var bytes: [4]u8 = undefined;
            const length = _utf8.encode(point, &bytes);
            writer.sink.put(bytes[0..length]);
            return;
        }
        if (point < 0x10000) return writer.escape(@intCast(point));
        const above = point - 0x10000;
        writer.escape(@intCast(0xD800 + (above >> 10)));
        writer.escape(@intCast(0xDC00 + (above & 0x3FF)));
    }

    /// `\u` and four hexadecimal digits.
    fn escape(writer: *Writer, unit: u16) void {
        const hex = "0123456789abcdef";
        writer.sink.put(&.{ '\\', 'u', hex[unit >> 12], hex[(unit >> 8) & 0xF], hex[(unit >> 4) & 0xF], hex[unit & 0xF] });
    }
};
