// SPDX-License-Identifier: MIT
//! ShapeGlyphs: a run of glyphs shaped by a font's layout tables.

const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const truetypeshaping = sdk.truetypeshaping;
const _base = @import("../truetypeshaping_base.zig");
const TrueTypeShapingBase = _base.TrueTypeShapingBase;
const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const _shape = @import("_shape.zig");

/// A run of glyphs shaped by a font's layout tables: the glyphs
/// replaced, and each given its advance and its offsets.
///
/// SYNOPSIS:
/// ```zig
/// fn ShapeGlyphs(sb: *TrueTypeShapingBase, outline: *truetype.Outline, script: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `outline` - what truetype.library's `OpenOutline` answered.
/// - `script` - the script's four letters, as `scriptTag` makes them
///   (`scriptTag("latn")`), or `TTS_SCRIPT_DEFAULT`.
/// - `direction` - `TTS_LEFT_TO_RIGHT` or `TTS_RIGHT_TO_LEFT`: the way
///   the run is read.
/// - `language` - the language's four letters (`languageTag("TRK ")`), or
///   `TTS_LANGUAGE_DEFAULT`.
/// - `features` - the features to apply, a list ended by a tag of 0;
///   null for none.
/// - `run` - the glyphs: `count` of them in `glyphs`, each with its
///   `glyph` and its `cluster` set, in the order they are read; `room`
///   says how many `glyphs` holds.
///
/// RESULT:
/// `TTS_OK`, and `run` holds the shaped glyphs in the order they are
/// drawn, from left to right, `count` of them. Otherwise:
/// - `TTSERR_ROOM` - the shaped run has more glyphs than `room`: `count`
///   says how many, and `glyphs` is as it was.
/// - `TTSERR_NOMEM` - there was not the memory.
/// - `TTSERR_DIRECTION` - no direction of that number.
/// - `TTSERR_FEATURES` - more than 31 features that hold for a part of
///   the run or whose tag the list has twice.
/// But for `TTSERR_ROOM`, `run` is as it was.
///
/// BEHAVIOR:
/// The font's `GDEF`, `GSUB` and `GPOS` are read through `FontTable`. In
/// each of the two the script is looked for - then `DFLT`, `dflt` and
/// `latn` - and in the script the language, then the language `dflt`,
/// then the script's default. What the language requires is applied to
/// every glyph. Of the features asked for, those the language lists are
/// applied; the others do nothing.
///
/// A feature holds for the glyphs whose cluster is within its `first`
/// and `last`. Where two of one tag hold for a glyph, the later one of
/// the list does, so a feature is switched off for a part of the run by
/// a second entry of the value 0. Where a feature offers several forms
/// of a glyph, its value picks one, counted from 1.
///
/// First the glyphs are replaced: `GSUB`'s lookups for the features, in
/// the order the table lists them - which is not the order of the
/// features. Then each glyph gets the advance the font gives it, and
/// `GPOS`'s lookups move it: pairs are set closer or apart, marks are
/// put on the glyph they belong to, and the glyphs of a joined script
/// are set to meet. A mark's offsets reach back over the advances
/// between it and its glyph, so each glyph is drawn at the point the
/// advances before it lead to, plus its offsets.
///
/// A ligature has the lowest cluster of its parts, and the glyphs one
/// glyph became all have its own. A run read from right to left is
/// answered turned around.
///
/// What a font asks for is bounded: a sequence a lookup matches is 64
/// glyphs at most, lookups call each other 8 deep, and a run grows to
/// 64 times its length, or to 16384 glyphs where that is more. Past a
/// bound the lookup in question does nothing.
///
/// So is the time a font takes. Each table's work on the run is counted
/// in pieces - a glyph a lookup comes by, a subtable looked at for it,
/// a rule or a ligature tried, a glyph compared or stepped over - and a
/// table has 65536 of them for each glyph of the run, a million for a
/// short one. A table that has spent them does no more to the run: the
/// call answers `TTS_OK` with what was done up to there. Fonts made for
/// use stay far below it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed; any number of tasks shape with one outline.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `run` and its array stay the caller's. What the call allocates it
/// frees before it answers.
///
/// NOTES:
/// The call applies the features it is given and no others: which ones
/// a script needs, and in what order its marks go, is the caller's to
/// say. A mark keeps the advance the font gives it.
///
/// Without a `GDEF` that sorts the glyphs, none is a mark or a ligature
/// to a lookup's flags. Vertical advances and the adjustments a font
/// makes for single sizes or for its variation axes are not read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// truetype.library's `OpenOutline`, `GlyphIndex`, `FontTable`
///
/// EXAMPLES:
/// ```zig
/// const tts = sdk.truetypeshaping;
/// var glyphs: [16]tts.ShapedGlyph = undefined;
/// for ("office", 0..) |letter, place| {
///     glyphs[place] = .{ .glyph = tb.GlyphIndex(outline, letter), .cluster = @intCast(place) };
/// }
/// var run: tts.ShapedRun = .{ .glyphs = &glyphs, .room = glyphs.len, .count = 6 };
/// const features = [_]tts.Feature{
///     .{ .tag = tts.featureTag("liga") },
///     .{ .tag = tts.featureTag("kern") },
///     .{},
/// };
/// if (sb.ShapeGlyphs(outline, tts.scriptTag("latn"), tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run) == tts.TTS_OK) {
///     var x: i32 = 0;
///     for (glyphs[0..run.count]) |shaped| {
///         // Draw shaped.glyph at x + shaped.x_offset, shaped.y_offset.
///         x += shaped.advance;
///     }
/// }
/// ```
pub fn ShapeGlyphs(sb: *TrueTypeShapingBase, outline: *truetype.Outline, script: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) i32 {
    if (direction != truetypeshaping.TTS_LEFT_TO_RIGHT and direction != truetypeshaping.TTS_RIGHT_TO_LEFT) {
        return truetypeshaping.TTSERR_DIRECTION;
    }
    var source: Source = .{ .sb = sb, .outline = outline };
    const memory: _buffer.Memory = .{ .context = &source, .allocFn = allocate, .freeFn = release };
    const font: _shape.Font = .{
        .gdef = tableOf(&source, "GDEF"),
        .gsub = tableOf(&source, "GSUB"),
        .gpos = tableOf(&source, "GPOS"),
        .context = &source,
        .advanceFn = advanceOf,
    };
    var feature_count: usize = 0;
    if (features) |list| {
        while (list[feature_count].tag != 0) feature_count += 1;
    }
    const given = run.glyphs[0..run.count];
    var buffer = _buffer.Buffer.init(memory, run.count) orelse return truetypeshaping.TTSERR_NOMEM;
    defer buffer.deinit();
    for (given) |glyph| buffer.append(.{ .glyph = glyph.glyph, .cluster = glyph.cluster, .mask = 0 });

    const wanted: []const truetypeshaping.Feature = if (features) |list| list[0..feature_count] else &.{};
    const result = _shape.shape(memory, font, script, language, direction == truetypeshaping.TTS_RIGHT_TO_LEFT, wanted, &buffer);
    if (result != truetypeshaping.TTS_OK) return result;
    if (buffer.len > run.room) {
        run.count = buffer.len;
        return truetypeshaping.TTSERR_ROOM;
    }
    for (buffer.slice(), run.glyphs[0..buffer.len]) |item, *shaped| {
        shaped.* = .{
            .glyph = item.glyph,
            .cluster = item.cluster,
            .advance = item.advance,
            .x_offset = item.x_offset,
            .y_offset = item.y_offset,
        };
    }
    run.count = buffer.len;
    return truetypeshaping.TTS_OK;
}

/// What the shaping's callbacks reach the library and the font through.
const Source = struct {
    sb: *TrueTypeShapingBase,
    outline: *truetype.Outline,
};

fn allocate(context: *anyopaque, bytes: usize) ?[*]u8 {
    const source: *Source = @ptrCast(@alignCast(context));
    const block = source.sb.sys_base.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
    return @ptrCast(block);
}

fn release(context: *anyopaque, block: [*]u8) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.sb.sys_base.FreeVec(block);
}

fn advanceOf(context: *anyopaque, glyph: u32) i32 {
    const source: *Source = @ptrCast(@alignCast(context));
    var metrics: truetype.GlyphMetrics = .{};
    _ = source.sb.truetype_base.GlyphMetrics(source.outline, glyph, &metrics);
    return metrics.advance;
}

/// The font's table of the tag `letters`; of no length when it has none.
fn tableOf(source: *Source, comptime letters: *const [4]u8) Table {
    var length: u32 = 0;
    const start = source.sb.truetype_base.FontTable(source.outline, truetype.tableTag(letters), &length) orelse return Table.none;
    return .{ .bytes = start[0..length] };
}
