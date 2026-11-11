// SPDX-License-Identifier: MIT
//! ShapeText: a text shaped by a font - its characters turned into the
//! font's glyphs, and those replaced and placed by its layout tables.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const truetypeshaping = sdk.truetypeshaping;
const _base = @import("../truetypeshaping_base.zig");
const TrueTypeShapingBase = _base.TrueTypeShapingBase;
const _text = @import("_text.zig");
const Source = @import("_source.zig").Source;

/// A text shaped by a font: the glyphs it is drawn with, each with its
/// advance, its offsets and the place in the text it stands for.
///
/// SYNOPSIS:
/// ```zig
/// fn ShapeText(sb: *TrueTypeShapingBase, outline: *truetype.Outline, text: [*]const u8, length: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) i32
/// ```
///
/// SINCE: 1.1. LVO -24.
///
/// INPUTS:
/// - `outline` - what truetype.library's `OpenOutline` answered.
/// - `text` - the text, in UTF-8.
/// - `length` - how many bytes it has.
/// - `direction` - `TTS_LEFT_TO_RIGHT` or `TTS_RIGHT_TO_LEFT`: the way
///   the whole text is read.
/// - `language` - the language's four letters (`languageTag("TRK ")`), or
///   `TTS_LANGUAGE_DEFAULT`.
/// - `features` - features to switch on or off besides the ones a text
///   is shaped with, a list ended by a tag of 0; null for none. Their
///   `first` and `last` count the text's bytes.
/// - `run` - where the glyphs go: `glyphs` with `room` saying how many
///   it holds. `count` is not read.
///
/// RESULT:
/// `TTS_OK`, and `run` holds the shaped glyphs in the order they are
/// drawn, from left to right, `count` of them. Otherwise:
/// - `TTSERR_ROOM` - the text has more glyphs than `room`: `count` says
///   how many, and `glyphs` holds nothing of use.
/// - `TTSERR_NOMEM` - there was not the memory.
/// - `TTSERR_DIRECTION` - no direction of that number.
/// - `TTSERR_FEATURES` - more than 31 features that hold for a part of
///   the text or whose tag is there twice.
/// But for `TTSERR_ROOM`, `count` is as it was.
///
/// BEHAVIOR:
/// The text is read a character at a time; a byte that is no UTF-8
/// reads as U+FFFD. It is cut into stretches of one script each. A
/// character many scripts share - a space, a digit, a comma - and a mark
/// belong to the stretch before them, those the text starts with to its
/// first stretch. Each stretch is shaped by what the font lists for its
/// script: under the script's four letters in small ones (`latn`,
/// `grek`, `hebr`), and for the scripts that have a newer tag (`dev2`
/// before `deva`) under that one first. A text of shared characters
/// alone is shaped by what the font lists as `DFLT`.
///
/// Each character becomes the glyph `GlyphIndex` has for it. Where a
/// variation selector follows and `GlyphVariant` has a glyph for the
/// two, that glyph stands for both.
///
/// The features applied, where the font lists them for the script and
/// the language: `rvrn`, `ccmp`, `locl`, `rlig`, `liga`, `clig`, `calt`,
/// `rclt`, `curs`, `dist`, `kern`, `mark`, `mkmk`, `abvm`, `blwm`, and
/// by the direction `ltra` and `ltrm`, or `rtla` and `rtlm`. One of
/// them is left out by an entry in `features` of its tag and the value
/// 0 that holds for the whole text; an entry that holds for a part
/// switches it off there. Every other entry adds its feature. What the
/// language requires is applied always.
///
/// The glyphs are replaced by `GSUB` in two goes - `rvrn` first, then
/// the rest - each in the order the table lists its lookups. Then the
/// characters a text does not show are taken out: the soft hyphen, the
/// joiners, the marks of direction, a variation selector the font had no
/// glyph for. One a lookup replaced stays. Until then a sequence a
/// lookup looks for steps over them, so a ligature forms across a soft
/// hyphen. Two kinds stop it: the non-joiner (U+200C) ends the glyphs a
/// lookup replaces, though not what it looks at before and behind
/// them; and Mongolian's variation selectors (U+180B to U+180D, U+180F)
/// and the tag characters (U+E0020 to U+E007F) end both.
///
/// Then each glyph gets the advance the font gives it, and `GPOS`
/// moves it. Where `GPOS` has no `kern` feature for the language, the
/// font's `kern` table is asked through `Kerning` for each glyph and
/// the next one that is no mark, and the left of the two as they are
/// drawn takes the value on its advance. Last, a mark's advance
/// becomes 0. In a font without `GPOS`, in a text read from left to
/// right, the mark moves back by what its advance was, onto the glyph
/// before it.
///
/// What is a mark is `GDEF`'s to say. Where a font does not sort its
/// glyphs, the glyph of a mark character that has no width of its own
/// is one.
///
/// A glyph's cluster is the place in the text of the first byte of its
/// character. A ligature has the lowest of its parts', and the glyphs
/// one glyph became all have its own. The bytes of a character taken out
/// count to the glyph before it, at a stretch's start to the one behind
/// it.
///
/// A text read from right to left is answered turned around as a whole:
/// its last stretch first.
///
/// The bounds are `ShapeGlyphs`'s: sequences of 64 glyphs, lookups 8
/// deep, a stretch growing to 64 times its length or to 16384 glyphs,
/// and for each table 65536 pieces of work a glyph, a million for a
/// short stretch. A table that has spent them does no more, and the
/// call answers `TTS_OK` with what was done up to there.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed; any number of tasks shape with one outline.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text, `run` and its array stay the caller's. What the call
/// allocates it frees before it answers.
///
/// NOTES:
/// The whole text is read in the one direction: a text of both
/// directions is the caller's to cut and to order, and a bracket in a
/// text read from right to left is not mirrored. Stretches are shaped
/// apart, so no pair is kerned and no sequence found across the border
/// of two scripts.
///
/// Every script is shaped by the features above and nothing is
/// rearranged or told apart by its place in a word: the joined forms of
/// Arabic and the syllables of the scripts of India are not made.
///
/// A character and a mark behind it are not put together into the one
/// character a font may have for the two, and a character the font
/// lacks is not taken apart: it is glyph 0. In a font without `GPOS` a
/// mark is not set by its outline's box; it only moves back by its
/// advance.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShapeGlyphs`, truetype.library's `OpenOutline`, `GlyphIndex`,
/// `GlyphVariant`, `Kerning`
///
/// EXAMPLES:
/// ```zig
/// const tts = sdk.truetypeshaping;
/// const text = "Waffle, 1/2";
/// var glyphs: [32]tts.ShapedGlyph = undefined;
/// var run: tts.ShapedRun = .{ .glyphs = &glyphs, .room = glyphs.len };
/// // Without the usual ligatures, with old-style figures for the "1/2".
/// const features = [_]tts.Feature{
///     .{ .tag = tts.featureTag("liga"), .value = 0 },
///     .{ .tag = tts.featureTag("onum"), .first = 8, .last = 10 },
///     .{},
/// };
/// if (sb.ShapeText(outline, text.ptr, text.len, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run) == tts.TTS_OK) {
///     var x: i32 = 0;
///     for (glyphs[0..run.count]) |shaped| {
///         // Draw shaped.glyph at x + shaped.x_offset, shaped.y_offset;
///         // it stands for the text from byte shaped.cluster on.
///         x += shaped.advance;
///     }
/// }
/// ```
pub fn ShapeText(sb: *TrueTypeShapingBase, outline: *truetype.Outline, text: [*]const u8, length: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) i32 {
    if (direction != truetypeshaping.TTS_LEFT_TO_RIGHT and direction != truetypeshaping.TTS_RIGHT_TO_LEFT) {
        return truetypeshaping.TTSERR_DIRECTION;
    }
    var source: Source = .{ .sb = sb, .outline = outline };
    var feature_count: usize = 0;
    if (features) |list| {
        while (list[feature_count].tag != 0) feature_count += 1;
    }
    const request: _text.Text = .{
        .memory = source.memory(),
        .font = source.font(),
        .bytes = text[0..length],
        .backward = direction == truetypeshaping.TTS_RIGHT_TO_LEFT,
        .language = language,
        .features = if (features) |list| list[0..feature_count] else &.{},
    };
    return _text.shapeText(&request, run);
}
