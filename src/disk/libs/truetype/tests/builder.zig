// SPDX-License-Identifier: MIT
//! Font files built by the tests: a writer of big-endian bytes, the
//! tables a font must have written around the ones a test is about, and
//! the character maps and the names in each of their forms.
//!
//! A test says what it wants read - a character map of one format, a
//! name in one encoding, a collection of two fonts - and gets a file that
//! is sound in everything else, so what it then sees of the library is
//! about that one thing. `whole` is a font with something of everything
//! the library reads, for the tests that are about the library rather
//! than a table: that nothing writes to an opened font, and that damaged
//! bytes are read without a fault.

const std = @import("std");

/// A file, or one table of it, being written: big-endian.
pub const File = struct {
    bytes: [room]u8 = @splat(0),
    len: u32 = 0,

    /// How long a built file may be.
    pub const room = 16 * 1024;

    pub fn byte(file: *File, value: u8) void {
        file.bytes[file.len] = value;
        file.len += 1;
    }

    pub fn word(file: *File, value: u16) void {
        file.byte(@truncate(value >> 8));
        file.byte(@truncate(value));
    }

    pub fn signed(file: *File, value: i16) void {
        file.word(@bitCast(value));
    }

    /// Three bytes: a character or a selector of the variation sequences.
    pub fn triple(file: *File, value: u32) void {
        file.byte(@truncate(value >> 16));
        file.word(@truncate(value));
    }

    pub fn long(file: *File, value: u32) void {
        file.word(@truncate(value >> 16));
        file.word(@truncate(value));
    }

    /// Bytes as they are: a tag, a table written elsewhere.
    pub fn text(file: *File, string: []const u8) void {
        @memcpy(file.bytes[file.len..][0..string.len], string);
        file.len += @intCast(string.len);
    }

    /// `count` bytes of 0.
    pub fn skip(file: *File, count: u32) void {
        file.len += count;
    }

    /// To the next place a table may start: a multiple of four.
    pub fn pad(file: *File) void {
        while (file.len % 4 != 0) file.len += 1;
    }

    /// A word and a long written where something was left open.
    pub fn setWord(file: *File, where: u32, value: u16) void {
        file.bytes[where] = @truncate(value >> 8);
        file.bytes[where + 1] = @truncate(value);
    }

    pub fn setLong(file: *File, where: u32, value: u32) void {
        file.setWord(where, @truncate(value >> 16));
        file.setWord(where + 2, @truncate(value));
    }

    /// What was written.
    pub fn written(file: *const File) []const u8 {
        return file.bytes[0..file.len];
    }
};

/// A table a test brings along: its tag and its bytes.
pub const Table = struct {
    tag: *const [4]u8,
    bytes: []const u8,
};

/// What a built font is made of.
pub const Parts = struct {
    /// The `cmap` table, whole.
    cmap: []const u8,
    /// How many glyphs it has. Glyph 0 has no outline; every other is a
    /// square 500 units wide and 700 tall, standing on the baseline at the
    /// glyph's origin.
    glyphs: u16 = 8,
    /// Whether it has outlines at all: `glyf` and `loca`.
    outlines: bool = true,
    /// Every glyph's advance, which tells two fonts of one file apart.
    advance: u16 = 600,
    /// `head`'s style bits: 1 bold, 2 italic.
    style_bits: u16 = 0,
    /// Tables beside the ones every font here has: `name`, `kern`, `OS/2`,
    /// `CFF `.
    more: []const Table = &.{},
    /// What the font starts with: version 1.0, or 'OTTO'.
    tag: u32 = 0x0001_0000,
    /// Whether `maxp` names the largest glyph - version 1.0, the
    /// square's four points in one contour - or only counts the glyphs,
    /// version 0.5, as a font of cubic curves has it.
    largest: bool = true,
    /// Whether the last glyph is put together of glyph 1 twice, the
    /// second 600 units to the right of the first.
    composite: bool = false,
};

/// The measures every built font has.
pub const units_per_em = 1000;
pub const ascender = 800;
pub const descender = -200;
pub const line_gap = 90;

/// A font of `parts` written at the end of `file`: its table directory
/// where the file ended, then its tables, their places counted from the
/// start of the file as a collection's are. Answers where the directory
/// starts.
pub fn font(file: *File, parts: Parts) u32 {
    const own: u32 = if (parts.outlines) 7 else 5;
    const count: u32 = own + @as(u32, @intCast(parts.more.len));
    const directory = file.len;
    file.long(parts.tag);
    file.word(@intCast(count));
    file.skip(6);
    file.skip(count * 16);
    var record = directory + 12;

    begin(file, &record, "cmap");
    file.text(parts.cmap);
    end(file, record);

    begin(file, &record, "head");
    const head = file.len;
    file.skip(54);
    file.setWord(head + 18, units_per_em);
    file.setWord(head + 44, parts.style_bits);
    // The glyphs' places in `loca` are longs.
    file.setWord(head + 50, 1);
    end(file, record);

    begin(file, &record, "hhea");
    const hhea = file.len;
    file.skip(36);
    file.setWord(hhea + 4, ascender);
    file.setWord(hhea + 6, @bitCast(@as(i16, descender)));
    file.setWord(hhea + 8, line_gap);
    // One advance for every glyph.
    file.setWord(hhea + 34, 1);
    end(file, record);

    begin(file, &record, "hmtx");
    file.word(parts.advance);
    for (0..parts.glyphs) |_| file.signed(0);
    end(file, record);

    begin(file, &record, "maxp");
    if (parts.largest) {
        file.long(0x0001_0000);
        file.word(parts.glyphs);
        // The most points and contours of a glyph: the square's.
        file.word(4);
        file.word(1);
        if (parts.composite) {
            // And of one put together: its points and contours, its
            // parts, and how deep parts lie in parts.
            file.word(8);
            file.word(2);
            file.skip(14);
            file.word(2);
            file.word(1);
        } else {
            file.skip(22);
        }
    } else {
        file.long(0x0000_5000);
        file.word(parts.glyphs);
    }
    end(file, record);

    if (parts.outlines) {
        // Where each glyph starts in `glyf`, and where the last one ends.
        var places: [1024]u32 = undefined;
        begin(file, &record, "glyf");
        const glyf = file.len;
        places[0] = 0;
        for (1..parts.glyphs) |glyph| {
            places[glyph] = file.len - glyf;
            if (parts.composite and glyph == parts.glyphs - 1) pair(file) else square(file);
        }
        places[parts.glyphs] = file.len - glyf;
        end(file, record);

        begin(file, &record, "loca");
        for (places[0 .. @as(usize, parts.glyphs) + 1]) |at| file.long(at);
        end(file, record);
    }

    for (parts.more) |table| {
        begin(file, &record, table.tag);
        file.text(table.bytes);
        end(file, record);
    }
    return directory;
}

/// A table of `tag` starts where the file ends: its record says so.
fn begin(file: *File, record: *u32, tag: *const [4]u8) void {
    record.* += 16;
    @memcpy(file.bytes[record.* - 16 ..][0..4], tag);
    file.setLong(record.* - 16 + 8, file.len);
}

/// The table begun last ends here: its record gets the length, and the
/// file is padded for the next.
fn end(file: *File, record: u32) void {
    const start = std.mem.readInt(u32, file.bytes[record - 16 + 8 ..][0..4], .big);
    file.setLong(record - 16 + 12, file.len - start);
    file.pad();
}

/// One glyph: a contour of four points on the curve, every coordinate a
/// word.
fn square(file: *File) void {
    file.signed(1);
    file.signed(0);
    file.signed(0);
    file.signed(500);
    file.signed(700);
    file.word(3);
    file.word(0);
    for (0..4) |_| file.byte(1);
    for ([_]i16{ 0, 0, 500, 0 }) |dx| file.signed(dx);
    for ([_]i16{ 0, 700, 0, -700 }) |dy| file.signed(dy);
    file.pad();
}

/// One glyph put together of glyph 1 twice: at its own place, and 600
/// units to the right.
fn pair(file: *File) void {
    file.signed(-1);
    file.signed(0);
    file.signed(0);
    file.signed(1100);
    file.signed(700);
    // Offsets as words, in the font's units; the first has one after it.
    file.word(0x0023);
    file.word(1);
    file.signed(0);
    file.signed(0);
    file.word(0x0003);
    file.word(1);
    file.signed(600);
    file.signed(0);
    file.pad();
}

/// The header of a collection of `count` fonts at the start of `file`,
/// the places of its fonts left 0 for `place` to say.
pub fn collection(file: *File, count: u32) void {
    file.text("ttcf");
    file.long(0x0001_0000);
    file.long(count);
    file.skip(count * 4);
}

/// The collection's font `index` has its directory at `directory`.
pub fn place(file: *File, index: u32, directory: u32) void {
    file.setLong(12 + index * 4, directory);
}

// --- character maps ------------------------------------------------------------

/// A segment of a format 4 map: characters `first` to `last`.
pub const Segment = struct {
    first: u16,
    last: u16,
    /// Added to a character for its glyph, or to a glyph listed.
    delta: u16 = 0,
    /// The segment's glyphs listed, one a character; null for a segment
    /// whose glyphs are its characters with `delta` added.
    glyphs: ?[]const u16 = null,
};

/// A group of a format 12 or 13 map: characters `first` to `last`, and
/// the glyph of the first (12) or of every one (13).
pub const Group = struct {
    first: u32,
    last: u32,
    glyph: u32,
};

/// One variation selector's sequences.
pub const Selector = struct {
    selector: u32,
    /// Runs of characters that keep their glyph: the first of a run, and
    /// how many follow it.
    keeps: []const [2]u32 = &.{},
    /// Characters that change it: the character, and its glyph.
    changes: []const [2]u32 = &.{},
};

/// A `cmap` table being written: its header and a record for each
/// subtable first, then the subtables, each begun with `begin` and
/// written with the function of its format.
pub const Cmap = struct {
    file: File = .{},
    begun: u32 = 0,

    /// A table of `count` subtables, none written yet.
    pub fn init(count: u16) Cmap {
        var cmap: Cmap = .{};
        cmap.file.word(0);
        cmap.file.word(count);
        cmap.file.skip(@as(u32, count) * 8);
        return cmap;
    }

    /// The next subtable is of `platform` and `encoding` and starts where
    /// the table ends.
    pub fn begin(cmap: *Cmap, platform: u16, encoding: u16) void {
        const record = 4 + cmap.begun * 8;
        cmap.file.setWord(record, platform);
        cmap.file.setWord(record + 2, encoding);
        cmap.file.setLong(record + 4, cmap.file.len);
        cmap.begun += 1;
    }

    /// The table as written.
    pub fn written(cmap: *const Cmap) []const u8 {
        return cmap.file.written();
    }

    /// Format 0: a glyph for each of the first 256 characters.
    pub fn bytes(cmap: *Cmap, glyphs: *const [256]u8) void {
        const file = &cmap.file;
        file.word(0);
        file.word(262);
        file.word(0);
        file.text(glyphs);
    }

    /// Format 4: segments of the basic plane, sorted, the last of them
    /// ending at 0xFFFF.
    pub fn segments(cmap: *Cmap, list: []const Segment) void {
        const file = &cmap.file;
        const count: u16 = @intCast(list.len);
        const start = file.len;
        file.word(4);
        file.word(0);
        file.word(0);
        file.word(count * 2);
        file.skip(6);
        for (list) |segment| file.word(segment.last);
        file.word(0);
        for (list) |segment| file.word(segment.first);
        for (list) |segment| file.word(segment.delta);
        // Where a segment's glyphs are listed, counted from the word that
        // says so: past the words of the segments after it, and the glyphs
        // listed before its own.
        var listed: u16 = 0;
        for (list, 0..) |segment, i| {
            const glyphs = segment.glyphs orelse {
                file.word(0);
                continue;
            };
            file.word((count - @as(u16, @intCast(i))) * 2 + listed * 2);
            listed += @intCast(glyphs.len);
        }
        for (list) |segment| {
            for (segment.glyphs orelse continue) |glyph| file.word(glyph);
        }
        file.setWord(start + 2, @intCast(file.len - start));
    }

    /// Format 6: one run of characters of the basic plane, from `first`.
    pub fn run(cmap: *Cmap, first: u16, glyphs: []const u16) void {
        const file = &cmap.file;
        file.word(6);
        file.word(@intCast(10 + glyphs.len * 2));
        file.word(0);
        file.word(first);
        file.word(@intCast(glyphs.len));
        for (glyphs) |glyph| file.word(glyph);
    }

    /// Format 10: one run of characters of any plane, from `first`.
    pub fn longRun(cmap: *Cmap, first: u32, glyphs: []const u16) void {
        const file = &cmap.file;
        file.word(10);
        file.word(0);
        file.long(@intCast(20 + glyphs.len * 2));
        file.long(0);
        file.long(first);
        file.long(@intCast(glyphs.len));
        for (glyphs) |glyph| file.word(glyph);
    }

    /// Formats 12 and 13: groups of characters, sorted.
    pub fn groups(cmap: *Cmap, format: u16, list: []const Group) void {
        const file = &cmap.file;
        file.word(format);
        file.word(0);
        file.long(@intCast(16 + list.len * 12));
        file.long(0);
        file.long(@intCast(list.len));
        for (list) |group| {
            file.long(group.first);
            file.long(group.last);
            file.long(group.glyph);
        }
    }

    /// Format 14: the variation sequences, a record a selector, sorted;
    /// after the records each selector's characters that keep their
    /// glyph, and the ones that change it.
    pub fn variations(cmap: *Cmap, list: []const Selector) void {
        const file = &cmap.file;
        const start = file.len;
        file.word(14);
        file.long(0);
        file.long(@intCast(list.len));
        const records = file.len;
        file.skip(@intCast(list.len * 11));
        for (list, 0..) |entry, i| {
            const record = records + @as(u32, @intCast(i)) * 11;
            file.bytes[record] = @truncate(entry.selector >> 16);
            file.setWord(record + 1, @truncate(entry.selector));
            if (entry.keeps.len != 0) {
                file.setLong(record + 3, file.len - start);
                file.long(@intCast(entry.keeps.len));
                for (entry.keeps) |keep| {
                    file.triple(keep[0]);
                    file.byte(@intCast(keep[1]));
                }
            }
            if (entry.changes.len != 0) {
                file.setLong(record + 7, file.len - start);
                file.long(@intCast(entry.changes.len));
                for (entry.changes) |change| {
                    file.triple(change[0]);
                    file.word(@intCast(change[1]));
                }
            }
        }
        file.setLong(start + 2, file.len - start);
    }
};

// --- names ---------------------------------------------------------------------

/// One record of a `name` table.
pub const NameRecord = struct {
    platform: u16,
    encoding: u16,
    language: u16,
    id: u16,
    /// The string as the file stores it: `utf16` makes one.
    stored: []const u8,
};

/// A `name` table of `records` written into `file`: the records, then
/// their strings in the same order.
pub fn names(file: *File, records: []const NameRecord) void {
    file.word(0);
    file.word(@intCast(records.len));
    file.word(@intCast(6 + records.len * 12));
    var offset: u16 = 0;
    for (records) |record| {
        file.word(record.platform);
        file.word(record.encoding);
        file.word(record.language);
        file.word(record.id);
        file.word(@intCast(record.stored.len));
        file.word(offset);
        offset += @intCast(record.stored.len);
    }
    for (records) |record| file.text(record.stored);
}

/// A string as the Windows and the Unicode platform store it: UTF-16,
/// the high byte of each unit first.
pub fn utf16(comptime string: []const u8) []const u8 {
    const units = comptime std.unicode.utf8ToUtf16LeStringLiteral(string);
    return unitsOf(units.len, units[0..units.len].*);
}

/// The same of units given as numbers, for what no string says: half of
/// a pair of surrogates, a NUL.
pub fn utf16Of(comptime list: []const u16) []const u8 {
    comptime var units: [list.len]u16 = undefined;
    comptime for (list, 0..) |unit, i| {
        units[i] = std.mem.nativeToLittle(u16, unit);
    };
    return unitsOf(list.len, units);
}

fn unitsOf(comptime count: usize, comptime units: [count]u16) []const u8 {
    const stored = comptime stored: {
        var out: [count * 2]u8 = undefined;
        for (units, 0..) |unit, i| {
            const value = std.mem.littleToNative(u16, unit);
            out[i * 2] = @truncate(value >> 8);
            out[i * 2 + 1] = @truncate(value);
        }
        break :stored out;
    };
    return &stored;
}

// --- a font with something of everything ---------------------------------------

/// What `whole`'s names are.
pub const whole_family = "Built Sans";
pub const whole_style = "Regular";

/// A font of 12 glyphs with something of everything the library reads.
///
/// Its characters: 'A' to 'J' are glyphs 1 to 10 in a map of segments,
/// and the same with U+1F600 as glyph 11 in a map of groups, which is the
/// one read. Variation sequences: 'A' followed by U+FE00 is glyph 5, 'B'
/// and 'C' followed by it keep their glyph. Kerned: glyph 1 then 2 are 50
/// units closer, 2 then 3 are 20 further apart. It has a family and a
/// style name, the measures of `OS/2` and `post`, and the squares every
/// built font has for outlines.
pub fn whole(file: *File) void {
    var cmap = Cmap.init(3);
    cmap.begin(0, 5);
    cmap.variations(&.{.{ .selector = 0xFE00, .keeps = &.{.{ 'B', 1 }}, .changes = &.{.{ 'A', 5 }} }});
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'J', .delta = @bitCast(@as(i16, 1 - 'A')) },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    cmap.begin(3, 10);
    cmap.groups(12, &.{
        .{ .first = 'A', .last = 'J', .glyph = 1 },
        .{ .first = 0x1F600, .last = 0x1F600, .glyph = 11 },
    });

    var name: File = .{};
    names(&name, &.{
        .{ .platform = 1, .encoding = 0, .language = 0, .id = 1, .stored = "Built Sans" },
        .{ .platform = 3, .encoding = 1, .language = 0x0409, .id = 1, .stored = utf16(whole_family) },
        .{ .platform = 3, .encoding = 1, .language = 0x0409, .id = 2, .stored = utf16(whole_style) },
    });

    var kern: File = .{};
    kern.word(0);
    kern.word(1);
    kern.word(0);
    kern.word(14 + 2 * 6);
    kern.word(0x0001);
    kern.word(2);
    kern.skip(6);
    kern.word(1);
    kern.word(2);
    kern.signed(-50);
    kern.word(2);
    kern.word(3);
    kern.signed(20);

    var os2: File = .{};
    os2.word(2);
    os2.skip(94);
    os2.setWord(26, 50);
    os2.setWord(28, 250);
    os2.setWord(86, 480);
    os2.setWord(88, 700);

    var post: File = .{};
    post.skip(32);
    post.setWord(8, @bitCast(@as(i16, -100)));
    post.setWord(10, 40);

    _ = font(file, .{
        .cmap = cmap.written(),
        .glyphs = 12,
        .more = &.{
            .{ .tag = "OS/2", .bytes = os2.written() },
            .{ .tag = "kern", .bytes = kern.written() },
            .{ .tag = "name", .bytes = name.written() },
            .{ .tag = "post", .bytes = post.written() },
        },
    });
}

// --- a table of cubic outlines -------------------------------------------------

/// What a built `CFF ` table is made of.
pub const CffParts = struct {
    /// A program a glyph.
    glyphs: []const []const u8,
    /// The global subroutines, and the local ones of a font that is not
    /// CID-keyed.
    globals: []const []const u8 = &.{},
    locals: []const []const u8 = &.{},
    /// A CID-keyed font's font dictionaries, the local subroutines of
    /// each; with none the font is not CID-keyed.
    fonts: []const []const []const u8 = &.{},
    /// Its `FDSelect`, whole.
    select: []const u8 = &.{},
    /// The size of an offset in every list, 1 to 4.
    off_size: u8 = 2,
    /// The table's version.
    major: u8 = 1,
    /// What kind its programs are, when the top dictionary says so.
    charstring_type: ?u8 = null,
    /// The numbers of the names of the glyphs from 1 on, a list of its
    /// own in the format 0; none for a font that names no list.
    names: []const u16 = &.{},
    /// The top dictionary's font matrix, its six numbers as a
    /// dictionary writes them; none for a font that says none.
    matrix: []const u8 = &.{},
};

/// An offset of a list, in `size` bytes.
fn listOffset(file: *File, size: u8, value: u32) void {
    switch (size) {
        1 => file.byte(@intCast(value)),
        2 => file.word(@intCast(value)),
        3 => file.triple(value),
        else => file.long(value),
    }
}

/// A list of `entries`: their count, the size of an offset, where each
/// starts and the last ends, counted from the byte before the first,
/// and their bytes.
fn listOf(file: *File, entries: []const []const u8, off_size: u8) void {
    file.word(@intCast(entries.len));
    if (entries.len == 0) return;
    file.byte(off_size);
    var offset: u32 = 1;
    listOffset(file, off_size, offset);
    for (entries) |entry| {
        offset += @intCast(entry.len);
        listOffset(file, off_size, offset);
    }
    for (entries) |entry| file.text(entry);
}

/// A number of a dictionary in five bytes, whatever it is, so that it
/// can be set once it is known: answers where its four bytes are.
fn dictNumber(file: *File) u32 {
    file.byte(29);
    file.skip(4);
    return file.len - 4;
}

/// A private dictionary and, when it has any, its subroutines after it;
/// its length and where it starts in the table set at `size` and
/// `where`.
fn private(file: *File, table: u32, subrs: []const []const u8, off_size: u8, size: u32, where: u32) void {
    const start = file.len;
    file.setLong(where, start - table);
    if (subrs.len == 0) {
        // Only a default width, of 0.
        file.byte(139);
        file.byte(20);
        file.setLong(size, 2);
        return;
    }
    // The subroutines, counted from the dictionary's start: right after
    // its six bytes.
    const subrs_at = dictNumber(file);
    file.byte(19);
    file.setLong(subrs_at, file.len - start);
    file.setLong(size, file.len - start);
    listOf(file, subrs, off_size);
}

/// A `CFF ` table of `parts` written at the end of `file`: the header,
/// the name, the top dictionary, no strings, the global subroutines,
/// the programs, and the private dictionary with its subroutines - or,
/// CID-keyed, `FDSelect`, the font dictionaries and each one's private
/// dictionary.
pub fn cff(file: *File, parts: CffParts) void {
    const table = file.len;
    const cid = parts.fonts.len != 0;
    file.byte(parts.major);
    file.byte(0);
    file.byte(4);
    file.byte(parts.off_size);
    listOf(file, &.{"Built"}, parts.off_size);

    // The top dictionary, the one entry of its list.
    const kind: u32 = if (parts.charstring_type != null) 3 else 0;
    const named: u32 = if (parts.names.len != 0) 6 else 0;
    const turned: u32 = if (parts.matrix.len != 0) @intCast(parts.matrix.len + 2) else 0;
    const length: u32 = kind + named + turned + @as(u32, if (cid) 5 + 7 + 7 + 6 else 6 + 11);
    file.word(1);
    file.byte(parts.off_size);
    listOffset(file, parts.off_size, 1);
    listOffset(file, parts.off_size, 1 + length);
    var fonts_at: u32 = 0;
    var select_at: u32 = 0;
    var private_size: u32 = 0;
    var private_at: u32 = 0;
    if (cid) {
        // Registry, ordering and supplement.
        file.text(&.{ 139, 139, 139, 12, 30 });
        fonts_at = dictNumber(file);
        file.text(&.{ 12, 36 });
        select_at = dictNumber(file);
        file.text(&.{ 12, 37 });
    }
    if (parts.charstring_type) |value| file.text(&.{ value + 139, 12, 6 });
    if (parts.matrix.len != 0) {
        file.text(parts.matrix);
        file.text(&.{ 12, 7 });
    }
    var names_at: u32 = 0;
    if (parts.names.len != 0) {
        names_at = dictNumber(file);
        file.byte(15);
    }
    const programs_at = dictNumber(file);
    file.byte(17);
    if (!cid) {
        private_size = dictNumber(file);
        private_at = dictNumber(file);
        file.byte(18);
    }

    // No strings.
    file.word(0);
    listOf(file, parts.globals, parts.off_size);

    file.setLong(programs_at, file.len - table);
    listOf(file, parts.glyphs, parts.off_size);
    if (parts.names.len != 0) {
        file.setLong(names_at, file.len - table);
        file.byte(0);
        for (parts.names) |name| file.word(name);
    }

    if (!cid) {
        private(file, table, parts.locals, parts.off_size, private_size, private_at);
        return;
    }
    file.setLong(select_at, file.len - table);
    file.text(parts.select);
    // The font dictionaries, eleven bytes each: a private dictionary's
    // length and place.
    file.setLong(fonts_at, file.len - table);
    file.word(@intCast(parts.fonts.len));
    file.byte(parts.off_size);
    for (0..parts.fonts.len + 1) |i| listOffset(file, parts.off_size, @intCast(1 + i * 11));
    const dicts = file.len;
    for (parts.fonts) |_| {
        _ = dictNumber(file);
        _ = dictNumber(file);
        file.byte(18);
    }
    for (parts.fonts, 0..) |subrs, i| {
        const dict = dicts + @as(u32, @intCast(i)) * 11;
        private(file, table, subrs, parts.off_size, dict + 1, dict + 6);
    }
}

/// One font dictionary of a built `CFF2` table: its private
/// dictionary's local subroutines, and which of the store's data its
/// glyphs' deltas are for when it says so.
pub const Cff2Font = struct {
    locals: []const []const u8 = &.{},
    data: ?u16 = null,
};

/// What a built `CFF2` table is made of.
pub const Cff2Parts = struct {
    /// A program a glyph.
    glyphs: []const []const u8,
    globals: []const []const u8 = &.{},
    fonts: []const Cff2Font = &.{.{}},
    /// Its `FDSelect`, whole; none when empty.
    select: []const u8 = &.{},
    /// Its store of deltas, whole; none when empty.
    store: []const u8 = &.{},
    /// The length written before the store, when not its own.
    store_length: ?u16 = null,
    /// The size of an offset in every list, 1 to 4.
    off_size: u8 = 2,
    /// The table's version.
    major: u8 = 2,
    /// The header's length; what is past its five bytes is zeroes.
    header: u8 = 5,
};

/// A list of a `CFF2` table: as `listOf`, with its count in four bytes.
fn wideListOf(file: *File, entries: []const []const u8, off_size: u8) void {
    file.long(@intCast(entries.len));
    if (entries.len == 0) return;
    file.byte(off_size);
    var offset: u32 = 1;
    listOffset(file, off_size, offset);
    for (entries) |entry| {
        offset += @intCast(entry.len);
        listOffset(file, off_size, offset);
    }
    for (entries) |entry| file.text(entry);
}

/// A `CFF2` table of `parts` written at the end of `file`: the header,
/// the top dictionary, the global subroutines, the programs,
/// `FDSelect`, the font dictionaries, each one's private dictionary with
/// its subroutines, and the store of deltas behind its length.
pub fn cff2(file: *File, parts: Cff2Parts) void {
    const table = file.len;
    file.byte(parts.major);
    file.byte(0);
    file.byte(parts.header);
    file.word(0);
    if (parts.header > 5) file.skip(parts.header - 5);

    const top = file.len;
    const programs_at = dictNumber(file);
    file.byte(17);
    const fonts_at = dictNumber(file);
    file.text(&.{ 12, 36 });
    var select_at: u32 = 0;
    if (parts.select.len != 0) {
        select_at = dictNumber(file);
        file.text(&.{ 12, 37 });
    }
    var store_at: u32 = 0;
    if (parts.store.len != 0) {
        store_at = dictNumber(file);
        file.byte(24);
    }
    file.setWord(table + 3, @intCast(file.len - top));

    wideListOf(file, parts.globals, parts.off_size);
    file.setLong(programs_at, file.len - table);
    wideListOf(file, parts.glyphs, parts.off_size);
    if (parts.select.len != 0) {
        file.setLong(select_at, file.len - table);
        file.text(parts.select);
    }

    // The font dictionaries, eleven bytes each: a private dictionary's
    // length and place.
    file.setLong(fonts_at, file.len - table);
    file.long(@intCast(parts.fonts.len));
    var dicts = file.len;
    if (parts.fonts.len != 0) {
        file.byte(parts.off_size);
        for (0..parts.fonts.len + 1) |i| listOffset(file, parts.off_size, @intCast(1 + i * 11));
        dicts = file.len;
        for (parts.fonts) |_| {
            _ = dictNumber(file);
            _ = dictNumber(file);
            file.byte(18);
        }
    }
    for (parts.fonts, 0..) |one, i| {
        const dict = dicts + @as(u32, @intCast(i)) * 11;
        const start = file.len;
        file.setLong(dict + 6, start - table);
        if (one.data) |data| {
            file.byte(28);
            file.word(data);
            file.byte(22);
        }
        if (one.locals.len == 0) {
            file.setLong(dict + 1, file.len - start);
            continue;
        }
        // The subroutines, counted from the dictionary's start: right
        // after it.
        const subrs_at = dictNumber(file);
        file.byte(19);
        file.setLong(subrs_at, file.len - start);
        file.setLong(dict + 1, file.len - start);
        wideListOf(file, one.locals, parts.off_size);
    }

    if (parts.store.len != 0) {
        file.setLong(store_at, file.len - table);
        file.word(parts.store_length orelse @intCast(parts.store.len));
        file.text(parts.store);
    }
}

/// The operators of a glyph's program by name; one of two bytes is 12
/// and its second.
const Operator = struct { name: []const u8, code: u16 };
const operators = [_]Operator{
    .{ .name = "hstem", .code = 1 },       .{ .name = "vstem", .code = 3 },
    .{ .name = "vmoveto", .code = 4 },     .{ .name = "rlineto", .code = 5 },
    .{ .name = "hlineto", .code = 6 },     .{ .name = "vlineto", .code = 7 },
    .{ .name = "rrcurveto", .code = 8 },   .{ .name = "callsubr", .code = 10 },
    .{ .name = "return", .code = 11 },     .{ .name = "endchar", .code = 14 },
    .{ .name = "vsindex", .code = 15 },    .{ .name = "blend", .code = 16 },
    .{ .name = "hstemhm", .code = 18 },    .{ .name = "hintmask", .code = 19 },
    .{ .name = "cntrmask", .code = 20 },   .{ .name = "rmoveto", .code = 21 },
    .{ .name = "hmoveto", .code = 22 },    .{ .name = "vstemhm", .code = 23 },
    .{ .name = "rcurveline", .code = 24 }, .{ .name = "rlinecurve", .code = 25 },
    .{ .name = "vvcurveto", .code = 26 },  .{ .name = "hhcurveto", .code = 27 },
    .{ .name = "callgsubr", .code = 29 },  .{ .name = "vhcurveto", .code = 30 },
    .{ .name = "hvcurveto", .code = 31 },  .{ .name = "and", .code = 0x0C03 },
    .{ .name = "or", .code = 0x0C04 },     .{ .name = "not", .code = 0x0C05 },
    .{ .name = "abs", .code = 0x0C09 },    .{ .name = "add", .code = 0x0C0A },
    .{ .name = "sub", .code = 0x0C0B },    .{ .name = "div", .code = 0x0C0C },
    .{ .name = "neg", .code = 0x0C0E },    .{ .name = "eq", .code = 0x0C0F },
    .{ .name = "drop", .code = 0x0C12 },   .{ .name = "put", .code = 0x0C14 },
    .{ .name = "get", .code = 0x0C15 },    .{ .name = "ifelse", .code = 0x0C16 },
    .{ .name = "random", .code = 0x0C17 }, .{ .name = "mul", .code = 0x0C18 },
    .{ .name = "sqrt", .code = 0x0C1A },   .{ .name = "dup", .code = 0x0C1B },
    .{ .name = "exch", .code = 0x0C1C },   .{ .name = "index", .code = 0x0C1D },
    .{ .name = "roll", .code = 0x0C1E },   .{ .name = "hflex", .code = 0x0C22 },
    .{ .name = "flex", .code = 0x0C23 },   .{ .name = "hflex1", .code = 0x0C24 },
    .{ .name = "flex1", .code = 0x0C25 },
};

/// A glyph's program, or a subroutine, from its text: numbers and
/// operators by their names, a space between each two. A number is
/// written the shortest way; `s:` before it writes it in three bytes,
/// and `f:` as sixteen bits of whole number and sixteen of fraction, the
/// way one with a fraction is written anyway. `#` and two hex digits
/// are a byte as it stands: a hint mask's, or one that is no operator.
pub fn program(comptime text: []const u8) []const u8 {
    const stored = comptime stored: {
        @setEvalBranchQuota(400_000);
        var out: [text.len * 5]u8 = undefined;
        var len: usize = 0;
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |word| {
            const bytes = wordOf(word);
            @memcpy(out[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
        const exact: [len]u8 = out[0..len].*;
        break :stored exact;
    };
    return &stored;
}

/// One word of a program's text as its bytes.
fn wordOf(comptime word: []const u8) []const u8 {
    if (word[0] == '#') return &.{std.fmt.parseInt(u8, word[1..], 16) catch @compileError("not a byte: " ++ word)};
    for (operators) |operator| {
        if (!std.mem.eql(u8, operator.name, word)) continue;
        if (operator.code < 0x100) return &.{@intCast(operator.code)};
        return &.{ 12, @intCast(operator.code & 0xFF) };
    }
    const short = std.mem.startsWith(u8, word, "s:");
    const fixed = std.mem.startsWith(u8, word, "f:") or std.mem.indexOfScalar(u8, word, '.') != null;
    const digits = if (word.len > 2 and word[1] == ':') word[2..] else word;
    if (fixed) {
        const value = std.fmt.parseFloat(f64, digits) catch @compileError("not a number: " ++ word);
        const bits: u32 = @bitCast(@as(i32, @intFromFloat(value * 65536.0)));
        return &.{ 255, @intCast(bits >> 24), @intCast(bits >> 16 & 0xFF), @intCast(bits >> 8 & 0xFF), @intCast(bits & 0xFF) };
    }
    const value = std.fmt.parseInt(i32, digits, 10) catch @compileError("neither a number nor an operator: " ++ word);
    if (!short and value >= -107 and value <= 107) return &.{@intCast(value + 139)};
    const size: u32 = @abs(value);
    if (!short and size >= 108 and size <= 1131) {
        const lead: u32 = if (value > 0) 247 else 251;
        return &.{ @intCast(lead + (size - 108) / 256), @intCast((size - 108) % 256) };
    }
    const bits: u16 = @bitCast(@as(i16, @intCast(value)));
    return &.{ 28, @intCast(bits >> 8), @intCast(bits & 0xFF) };
}
