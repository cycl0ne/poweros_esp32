// SPDX-License-Identifier: MIT
//! Comma-separated values, as radio-browser.info answers a search: a
//! record a line, its fields parted by commas, the first record the
//! columns' names. A field in double quotes may hold commas and line
//! ends, and a quote as two; the quotes are taken off in place, so the
//! text is the reader's to change. A record ends at a line feed, a
//! carriage return before it dropped.
//!
//! `Reader.next` hands out a record's fields as slices of the text;
//! `column` finds a column by its name in the first. Nothing here opens
//! anything: the host tests hold all of it.

pub const Reader = struct {
    text: []u8,
    at: usize = 0,

    pub fn init(text: []u8) Reader {
        return .{ .text = text };
    }

    /// The next record's fields into `fields`, as many as fit, the rest
    /// passed over: how many it has; null after the last.
    pub fn next(reader: *Reader, fields: [][]const u8) ?usize {
        const text = reader.text;
        if (reader.at >= text.len) return null;
        var count: usize = 0;
        while (true) {
            const value = reader.field();
            if (count < fields.len) fields[count] = value;
            count += 1;
            if (reader.at >= text.len) return count;
            const parted = text[reader.at];
            reader.at += 1;
            if (parted == '\n') return count;
            // A comma that ends the text leaves one empty field after it.
            if (reader.at >= text.len) {
                if (count < fields.len) fields[count] = text[text.len..];
                return count + 1;
            }
        }
    }

    /// One field, the reader left on the comma or the line feed after
    /// it, or at the end.
    fn field(reader: *Reader) []const u8 {
        const text = reader.text;
        const start = reader.at;
        if (start < text.len and text[start] == '"') {
            var out = start;
            var at = start + 1;
            while (at < text.len) {
                if (text[at] == '"') {
                    if (at + 1 < text.len and text[at + 1] == '"') {
                        text[out] = '"';
                        out += 1;
                        at += 2;
                        continue;
                    }
                    at += 1;
                    break;
                }
                text[out] = text[at];
                out += 1;
                at += 1;
            }
            // Whatever stands between the closing quote and the comma.
            while (at < text.len and text[at] != ',' and text[at] != '\n') at += 1;
            reader.at = at;
            return text[start..out];
        }
        var end = start;
        while (end < text.len and text[end] != ',' and text[end] != '\n') end += 1;
        reader.at = end;
        if (end > start and text[end - 1] == '\r' and (end == text.len or text[end] == '\n')) return text[start .. end - 1];
        return text[start..end];
    }
};

/// Where the column `name` stands among the first record's `names`;
/// null when there is none.
pub fn column(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |each, at| {
        if (each.len != name.len) continue;
        for (each, name) |got, want| {
            if (got != want) break;
        } else return at;
    }
    return null;
}
