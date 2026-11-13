// SPDX-License-Identifier: MIT
//! truetypeshaping.library's types and constants.
//!
//! truetypeshaping.library turns a text into the glyphs a font draws it
//! with, and where each of them goes. A font says both in its
//! layout tables: `GSUB`, which replaces glyphs - a ligature for "f" and
//! "i", the form of a letter that stands at a word's end - `GPOS`, which
//! moves them - a pair set closer, an accent placed on its letter - and
//! `GDEF`, which says what kind of glyph each one is. The library reads
//! the three through truetype.library's `FontTable`, from an outline the
//! caller opened there, and holds nothing of a font itself: an outline is
//! shaped with by any number of tasks at once.
//!
//! What a font does is sorted into features of four letters each
//! (`liga`, `kern`, `mark`), listed per script and language. There are
//! two ways in. `ShapeText` takes the text itself, in UTF-8: it finds
//! the script of each stretch, makes each character its glyph and
//! applies the features a text is shaped with. `ShapeGlyphs` takes a run
//! of glyphs with the script, the language and the features named by the
//! caller, and applies those and no others. Both answer the shaped run:
//! for each glyph its number, how far it moves the point along the line,
//! how far from the point it is drawn, and which part of the text it
//! stands for.
//!
//! Open it with OpenLibrary(TRUETYPESHAPINGNAME, 1); its functions are in
//! sdk/interface/truetypeshaping.zig.

const truetype = @import("../truetype/truetype.zig");

/// The name to open it by.
pub const TRUETYPESHAPINGNAME = "truetypeshaping.library";
/// The version a caller of this SDK asks for.
pub const TRUETYPESHAPING_VERSION = 1;

/// One glyph of a shaped run. Its measures are in the font's units, y up.
pub const ShapedGlyph = extern struct {
    /// The glyph's number in the font.
    glyph: u32 = 0,
    /// Which part of the text it stands for. `ShapeText` sets the place
    /// of the first byte of the glyph's character; to `ShapeGlyphs` it is
    /// a number the caller gives each glyph - the place of its character
    /// in the text - and the shaping carries along. A ligature has the
    /// lowest of its parts'; the glyphs one glyph was replaced by all
    /// have its own.
    cluster: u32 = 0,
    /// How far it moves the point along the line.
    advance: i32 = 0,
    /// Where it is drawn, from the point: to the right, and up.
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// A run of glyphs, in the caller's array.
pub const ShapedRun = extern struct {
    glyphs: [*]ShapedGlyph,
    /// How many glyphs the array holds.
    room: u32,
    /// How many are in it - or, when the shaped run did not fit, how many
    /// it needs.
    count: u32 = 0,
};

/// A feature of a font, and where in the run it holds.
pub const Feature = extern struct {
    /// Its four letters, as `featureTag` makes them. 0 ends a list.
    tag: u32 = 0,
    /// 0 leaves the feature out, 1 applies it; where it offers several
    /// forms of a glyph (`salt`, `aalt`), n picks the nth.
    value: u32 = 1,
    /// The glyphs it holds for: those whose cluster is `first` to `last`,
    /// both in. The whole run as they stand here. Where two features of
    /// one tag hold for a glyph, the later of the list does.
    first: u32 = 0,
    last: u32 = 0xFFFF_FFFF,
};

/// A script's, a language's or a feature's four letters as the calls take
/// them, the first letter highest: `scriptTag("latn")`.
pub const scriptTag = truetype.tableTag;
pub const languageTag = truetype.tableTag;
pub const featureTag = truetype.tableTag;

/// A language's code as texts carry it - `de`, `sr`, `zh-Hant`, the
/// codes of BCP 47 - and the tag fonts list the language under.
const Spoken = struct { code: []const u8, tag: *const [4]u8 };
const spoken = [_]Spoken{
    .{ .code = "af", .tag = "AFK " }, .{ .code = "ar", .tag = "ARA " }, .{ .code = "az", .tag = "AZE " },
    .{ .code = "be", .tag = "BEL " }, .{ .code = "bg", .tag = "BGR " }, .{ .code = "bn", .tag = "BEN " },
    .{ .code = "ca", .tag = "CAT " }, .{ .code = "cs", .tag = "CSY " }, .{ .code = "da", .tag = "DAN " },
    .{ .code = "de", .tag = "DEU " }, .{ .code = "el", .tag = "ELL " }, .{ .code = "en", .tag = "ENG " },
    .{ .code = "es", .tag = "ESP " }, .{ .code = "et", .tag = "ETI " }, .{ .code = "eu", .tag = "EUQ " },
    .{ .code = "fa", .tag = "FAR " }, .{ .code = "fi", .tag = "FIN " }, .{ .code = "fr", .tag = "FRA " },
    .{ .code = "ga", .tag = "IRI " }, .{ .code = "gu", .tag = "GUJ " }, .{ .code = "he", .tag = "IWR " },
    .{ .code = "hi", .tag = "HIN " }, .{ .code = "hr", .tag = "HRV " }, .{ .code = "hu", .tag = "HUN " },
    .{ .code = "hy", .tag = "HYE " }, .{ .code = "id", .tag = "IND " }, .{ .code = "is", .tag = "ISL " },
    .{ .code = "it", .tag = "ITA " }, .{ .code = "ja", .tag = "JAN " }, .{ .code = "ka", .tag = "KAT " },
    .{ .code = "kk", .tag = "KAZ " }, .{ .code = "kn", .tag = "KAN " }, .{ .code = "ko", .tag = "KOR " },
    .{ .code = "lt", .tag = "LTH " }, .{ .code = "lv", .tag = "LVI " }, .{ .code = "mk", .tag = "MKD " },
    .{ .code = "ml", .tag = "MAL " }, .{ .code = "mr", .tag = "MAR " }, .{ .code = "ms", .tag = "MLY " },
    .{ .code = "mt", .tag = "MTS " }, .{ .code = "nb", .tag = "NOR " }, .{ .code = "ne", .tag = "NEP " },
    .{ .code = "nl", .tag = "NLD " }, .{ .code = "no", .tag = "NOR " }, .{ .code = "pa", .tag = "PAN " },
    .{ .code = "pl", .tag = "PLK " }, .{ .code = "pt", .tag = "PTG " }, .{ .code = "ro", .tag = "ROM " },
    .{ .code = "ru", .tag = "RUS " }, .{ .code = "sa", .tag = "SAN " }, .{ .code = "sk", .tag = "SKY " },
    .{ .code = "sl", .tag = "SLV " }, .{ .code = "sq", .tag = "SQI " }, .{ .code = "sr", .tag = "SRB " },
    .{ .code = "sv", .tag = "SVE " }, .{ .code = "ta", .tag = "TAM " }, .{ .code = "te", .tag = "TEL " },
    .{ .code = "th", .tag = "THA " }, .{ .code = "tr", .tag = "TRK " }, .{ .code = "uk", .tag = "UKR " },
    .{ .code = "ur", .tag = "URD " }, .{ .code = "vi", .tag = "VIT " },
};

/// The tag fonts list a language under, for a language's code as a text
/// carries it: the two letters of BCP 47, in either case, and whatever
/// follows them behind a hyphen - `de`, `de-AT`, `sr-Latn`. Chinese is
/// its simplified form, or with `Hant`, `TW`, `HK` or `MO` behind it the
/// traditional one. `TTS_LANGUAGE_DEFAULT` for a code not listed here,
/// which shapes a text by the script's default language.
pub fn languageOf(code: []const u8) u32 {
    var first: [2]u8 = undefined;
    if (code.len < 2 or (code.len > 2 and code[2] != '-' and code[2] != '_')) return TTS_LANGUAGE_DEFAULT;
    for (&first, code[0..2]) |*small, letter| small.* = if (letter >= 'A' and letter <= 'Z') letter + 32 else letter;
    if (first[0] == 'z' and first[1] == 'h') {
        var at: usize = 2;
        while (at < code.len) {
            at += 1;
            var end = at;
            while (end < code.len and code[end] != '-' and code[end] != '_') end += 1;
            const part = code[at..end];
            for ([_][]const u8{ "hant", "tw", "hk", "mo" }) |traditional| {
                if (part.len != traditional.len) continue;
                var same = true;
                for (part, traditional) |letter, wanted| {
                    const small = if (letter >= 'A' and letter <= 'Z') letter + 32 else letter;
                    if (small != wanted) same = false;
                }
                if (same) return languageTag("ZHT ");
            }
            at = end;
        }
        return languageTag("ZHS ");
    }
    for (spoken) |one| {
        if (one.code[0] == first[0] and one.code[1] == first[1]) return languageTag(one.tag);
    }
    return TTS_LANGUAGE_DEFAULT;
}

/// The script a font lists what it does without one under.
pub const TTS_SCRIPT_DEFAULT: u32 = 0;
/// A script's default language.
pub const TTS_LANGUAGE_DEFAULT: u32 = 0;

/// The direction a run is read in. Its glyphs are given in the order they
/// are read, and answered in the order they are drawn, from left to
/// right.
pub const TTS_LEFT_TO_RIGHT: u32 = 0;
pub const TTS_RIGHT_TO_LEFT: u32 = 1;

/// What the shaping calls answer.
pub const TTS_OK: i32 = 0;
/// The run's array is too short: its count says how long it must be.
/// Nothing in the array was changed.
pub const TTSERR_ROOM: i32 = -1;
/// There was not the memory to shape it.
pub const TTSERR_NOMEM: i32 = -2;
/// No direction of that number.
pub const TTSERR_DIRECTION: i32 = -3;
/// More features than a call takes: 31 that hold for a part of the run,
/// or whose tag the list has twice.
pub const TTSERR_FEATURES: i32 = -4;
