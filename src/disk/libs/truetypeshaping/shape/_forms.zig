// SPDX-License-Identifier: MIT
//! The presentation forms: a text of Arabic drawn with the glyphs a font
//! has for the characters Unicode encodes each joining form of a letter
//! as, where the font has none of the joining forms' features (`isol`,
//! `fina`, `medi`, `init`) for the script - as a font made of
//! presentation forms has not.
//!
//! The forms are made lookups of `GSUB`, written into memory for the
//! font and applied by the engine the font's own lookups go through
//! (`_lookup.zig`), after the font's `rlig` and in this order:
//!
//!   - one for each form, initial, medial, final and isolated: from the
//!     glyph of each letter to the glyph of its form
//!     (`_joining_table.forms`), holding for the items of that form and
//!     passing over ligatures;
//!   - one each for the ligatures of three letters' forms, of two, and of
//!     two marks (`_joining_table.of_three`, `of_two`, `of_marks`): from
//!     the glyphs of the forms a ligature is made of to its own, holding
//!     where `rlig` does, those of letters passing over marks.
//!
//! A lookup has the entries whose glyphs the font all has, of numbers
//! below 65536; a form whose glyph is the letter's own is none. Being
//! made of glyphs, an entry holds for a glyph an earlier lookup made too,
//! where that is a letter's.

const sdk = @import("sdk");
const truetypeshaping = sdk.truetypeshaping;
const featureTag = truetypeshaping.featureTag;
const _table = @import("_joining_table.zig");
const _joining = @import("_joining.zig");
const _plan = @import("_plan.zig");
const _match = @import("_match.zig");
const _lookup = @import("_lookup.zig");
const _buffer = @import("_buffer.zig");
const _tables = @import("_tables.zig");
const _shape = @import("_shape.zig");
const Gdef = @import("_gdef.zig").Gdef;
const Table = _tables.Table;
const Order = _shape.Order;
const Font = _shape.Font;
const Buffer = _buffer.Buffer;
const Wanted = _plan.Wanted;

const GSUB_SINGLE = 1;
const GSUB_LIGATURE = 4;

/// The forms in the order of the table's columns, which is the order
/// their lookups are applied in.
const form_bits = [4]u8{ _joining.FORM_INIT, _joining.FORM_MEDI, _joining.FORM_FINA, _joining.FORM_ISOL };
const form_tags = [4]u32{ featureTag("init"), featureTag("medi"), featureTag("fina"), featureTag("isol") };

/// The ligatures, in the order their lookups are applied in, and the
/// flags of each lookup.
const ligature_lists = [3][]const _table.Ligature{ &_table.of_three, &_table.of_two, &_table.of_marks };
const ligature_flags = [3]u32{ _match.LOOKUP_IGNORE_MARKS, _match.LOOKUP_IGNORE_MARKS, 0 };

const lookup_count = form_bits.len + ligature_lists.len;
const letter_count = _table.forms.len;
const most_ligatures = most: {
    var most: usize = 0;
    for (ligature_lists) |list| most = @max(most, list.len);
    break :most most;
};

/// The most bytes the lookups take: the list; a form's lookup, with a
/// substitute and a glyph covered for each letter; a ligatures' lookup,
/// with a set, its entry and its glyph covered, and the ligature's two
/// more parts for each ligature.
const size_most = size: {
    var size: usize = 2 + 2 * lookup_count;
    size += form_bits.len * (8 + 6 + 4 + 4 * letter_count);
    for (ligature_lists) |list| size += 8 + 6 + 4 + 16 * list.len;
    break :size size;
};

/// Whether a text `order` asks for is drawn with presentation forms: one
/// of Arabic in a font that has none of the four joining forms' features
/// for it, in `GSUB` or `GPOS`, and says its characters' glyphs.
pub fn needed(order: *const Order) bool {
    if (order.script != featureTag("arab")) return false;
    const font = &order.font;
    if (font.glyphFn == null) return false;
    for ([2]Table{ font.gsub, font.gpos }) |table| {
        const layout = _plan.Layout.init(table, order.script, order.other_script, order.language, font.coords);
        for (form_tags) |tag| {
            if (layout.has(tag)) return false;
        }
    }
    return true;
}

/// Big-endian words written one after another, or at a place before.
const Writer = struct {
    bytes: []u8,
    at: u32 = 0,

    fn word(writer: *Writer, value: u32) void {
        writer.put(writer.at, value);
        writer.at += 2;
    }

    fn put(writer: *Writer, place: u32, value: u32) void {
        writer.bytes[place] = @truncate(value >> 8);
        writer.bytes[place + 1] = @truncate(value);
    }
};

/// A glyph and what stands for it: a form's, or a ligature's with the
/// glyphs of its parts after the first.
const Pair = struct { glyph: u16, other: u16 };
const Made = struct { first: u16, glyph: u16, parts: [2]u16, count: u8 };

/// The font's glyph for `char`, 0 for none and for one of a number
/// above 65535.
fn glyphOf(font: *const Font, char: u32) u16 {
    if (char == 0) return 0;
    const glyph = font.glyphFn.?(font.context, char);
    return if (glyph > 0xFFFF) 0 else @intCast(glyph);
}

/// Writes the lookup of the form of column `column`: false for one of
/// no entries, which is not written.
fn writeForm(font: *const Font, letters: []const u16, pairs: []Pair, column: usize, writer: *Writer) bool {
    var count: usize = 0;
    for (letters, 0..) |letter, index| {
        const form = _table.forms[index][column];
        if (letter == 0 or form == 0) continue;
        const glyph = glyphOf(font, form);
        if (glyph == 0 or glyph == letter) continue;
        // Sorted by the letter's glyph as they come; of two letters of
        // one glyph, the first holds.
        var place = count;
        while (place > 0 and pairs[place - 1].glyph > letter) place -= 1;
        if (place > 0 and pairs[place - 1].glyph == letter) continue;
        var moved = count;
        while (moved > place) : (moved -= 1) pairs[moved] = pairs[moved - 1];
        pairs[place] = .{ .glyph = letter, .other = glyph };
        count += 1;
    }
    if (count == 0) return false;
    const entries = pairs[0..count];
    writer.word(GSUB_SINGLE);
    writer.word(_match.LOOKUP_IGNORE_LIGATURES);
    writer.word(1);
    writer.word(8);
    writer.word(2);
    writer.word(@intCast(6 + 2 * count));
    writer.word(@intCast(count));
    for (entries) |entry| writer.word(entry.other);
    writer.word(1);
    writer.word(@intCast(count));
    for (entries) |entry| writer.word(entry.glyph);
    return true;
}

/// Writes the lookup of the ligatures `list`, with `flags`: false for
/// one of no entries, which is not written.
fn writeLigatures(font: *const Font, list: []const _table.Ligature, flags: u32, made: []Made, writer: *Writer) bool {
    var count: usize = 0;
    next: for (list) |ligature| {
        var entry: Made = .{ .first = glyphOf(font, ligature.parts[0]), .glyph = glyphOf(font, ligature.ligature), .parts = .{ 0, 0 }, .count = 0 };
        if (entry.first == 0 or entry.glyph == 0) continue;
        for (ligature.parts[1..]) |part| {
            if (part == 0) break;
            const glyph = glyphOf(font, part);
            if (glyph == 0) continue :next;
            entry.parts[entry.count] = glyph;
            entry.count += 1;
        }
        // Sorted by the first glyph, those of one keeping their order.
        var place = count;
        while (place > 0 and made[place - 1].first > entry.first) place -= 1;
        var moved = count;
        while (moved > place) : (moved -= 1) made[moved] = made[moved - 1];
        made[place] = entry;
        count += 1;
    }
    if (count == 0) return false;
    const entries = made[0..count];
    var sets: u32 = 0;
    for (entries, 0..) |entry, index| {
        if (index == 0 or entries[index - 1].first != entry.first) sets += 1;
    }
    writer.word(GSUB_LIGATURE);
    writer.word(flags);
    writer.word(1);
    writer.word(8);
    const subtable = writer.at;
    writer.word(1);
    const coverage_at = writer.at;
    writer.word(0);
    writer.word(sets);
    const offsets_at = writer.at;
    writer.at += 2 * sets;
    var set: u32 = 0;
    var first: usize = 0;
    while (first < count) {
        var end = first + 1;
        while (end < count and entries[end].first == entries[first].first) end += 1;
        const set_at = writer.at;
        writer.put(offsets_at + 2 * set, set_at - subtable);
        set += 1;
        writer.word(@intCast(end - first));
        const ligatures_at = writer.at;
        writer.at += @intCast(2 * (end - first));
        for (entries[first..end], 0..) |entry, index| {
            writer.put(ligatures_at + @as(u32, @intCast(2 * index)), writer.at - set_at);
            writer.word(entry.glyph);
            writer.word(@as(u32, entry.count) + 1);
            for (entry.parts[0..entry.count]) |part| writer.word(part);
        }
        first = end;
    }
    writer.put(coverage_at, writer.at - subtable);
    writer.word(1);
    writer.word(sets);
    for (entries, 0..) |entry, index| {
        if (index == 0 or entries[index - 1].first != entry.first) writer.word(entry.first);
    }
    return true;
}

/// Applies the presentation forms to the run in `buffer`, as the lookups
/// of the font's own `GSUB` are: `gdef` sorts the glyphs, `places` is the
/// room for the sequences matched, `wanted` holds where `rlig` does.
/// Answers `TTS_OK`, or `TTSERR_NOMEM` without the memory.
pub fn substitute(order: *const Order, gdef: *const Gdef, buffer: *Buffer, places: [*]u32, wanted: []const Wanted) i32 {
    const font = &order.font;
    var required: u32 = 0;
    for (wanted) |want| {
        if (want.tag == featureTag("rlig") and want.value != 0) required |= want.mask;
    }
    const scratch = letter_count * @sizeOf(u16) + letter_count * @sizeOf(Pair) + most_ligatures * @sizeOf(Made);
    const block = order.memory.alloc(scratch + size_most) orelse return truetypeshaping.TTSERR_NOMEM;
    defer order.memory.free(block);
    const made: [*]Made = @ptrCast(@alignCast(block));
    const pairs: [*]Pair = @ptrCast(@alignCast(block + most_ligatures * @sizeOf(Made)));
    const letters: [*]u16 = @ptrCast(@alignCast(block + most_ligatures * @sizeOf(Made) + letter_count * @sizeOf(Pair)));
    for (letters[0..letter_count], 0..) |*letter, index| letter.* = glyphOf(font, _table.forms_first + @as(u32, @intCast(index)));

    var writer: Writer = .{ .bytes = block[scratch..][0..size_most] };
    writer.word(lookup_count);
    writer.at += 2 * lookup_count;
    var written: [lookup_count]bool = undefined;
    for (0..lookup_count) |index| {
        const at = writer.at;
        written[index] = if (index < form_bits.len)
            writeForm(font, letters[0..letter_count], pairs[0..letter_count], index, &writer)
        else
            writeLigatures(font, ligature_lists[index - form_bits.len], ligature_flags[index - form_bits.len], made[0..most_ligatures], &writer);
        writer.put(2 + 2 * @as(u32, @intCast(index)), if (written[index]) at else 0);
    }

    var apply: _match.Apply = .{
        .buffer = buffer,
        .gdef = gdef,
        .kind = .substitute,
        .lookups = .{ .bytes = writer.bytes[0..writer.at] },
        .backward = order.backward,
        .places = places,
        .work = _shape.workFor(buffer.len),
    };
    for (written, 0..) |present, index| {
        if (!present) continue;
        if (index < form_bits.len) {
            apply.forms = form_bits[index];
            _lookup.run(&apply, @intCast(index), 0, 1);
        } else if (required != 0) {
            apply.forms = 0;
            _lookup.run(&apply, @intCast(index), required, 1);
        }
        if (buffer.failed) return truetypeshaping.TTSERR_NOMEM;
        if (apply.work == 0) break;
    }
    return truetypeshaping.TTS_OK;
}
