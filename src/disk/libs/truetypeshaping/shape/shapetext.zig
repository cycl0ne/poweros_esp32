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
/// Each stretch is first made the characters the font draws it with. A
/// character with no mark behind it stays as it is where `GlyphIndex`
/// has a glyph for it; where it has none, the character becomes its
/// parts - U+00E9 an `e` and the acute U+0301 - a step at a time, as
/// soon as the font has all of them. A character with marks behind it
/// is taken apart as far as the font has the parts. The marks on a
/// letter are then put in the order of their combining classes, those
/// of one class staying as they were written, and a letter and a mark
/// become the one character there is for the two where the font has a
/// glyph for it: `e` and U+0301 are drawn with the font's U+00E9. A
/// character the font has no form of is glyph 0. The combining grapheme
/// joiner (U+034F) keeps the marks on its two sides apart: they are not
/// sorted across it.
///
/// A space of a set width the font lacks (U+2000 to U+200A, U+202F,
/// U+205F, U+3000, and the no-break space U+00A0) is drawn with the
/// font's space and has its width by the em - U+2003 an em, U+2009 a
/// fifth of one - or by a glyph: U+2007 a digit's width, U+2008 a full
/// stop's, U+202F half the space's. The non-breaking hyphen (U+2011)
/// the font lacks is its hyphen (U+2010).
///
/// Then each character becomes the glyph `GlyphIndex` has for it. Where
/// a variation selector follows and `GlyphVariant` has a glyph for the
/// two, that glyph stands for both, and the character and its marks
/// stay as they were written.
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
/// character. The parts a character was taken apart into all have its
/// own; a letter and a mark put together have the letter's; a mark
/// sorted before others and the ones it passed have the lowest among
/// them. A ligature has the lowest of its parts', and the glyphs one
/// glyph became all have its own. The bytes of a character taken out
/// count to the glyph drawn before it - in a text read from right to
/// left the one behind it in the text - and for the first glyph drawn
/// to the one drawn next.
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
/// Only a letter and its marks are put together: two letters that
/// make one character - the single letters of a Hangul syllable - stay
/// two. A run of more than 32 marks on one letter is left in the order
/// it was written. In a font without `GPOS` a mark is not set by its
/// outline's box; it only moves back by its advance.
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
