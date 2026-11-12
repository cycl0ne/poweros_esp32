// SPDX-License-Identifier: MPL-2.0
//! foldgen: the system's character tables from the Unicode Character
//! Database, which scripts/fetch-unicode.sh fetches into
//! toolchain/unicode/<version>. Run by hand; the tables it writes are
//! committed, and the build never runs it.
//!
//!   foldgen posfs <CaseFolding.txt> <out.zig>
//!   foldgen case <CaseFolding.txt> <UnicodeData.txt> <out.zig>
//!   foldgen base <CaseFolding.txt> <UnicodeData.txt> <out.zig>
//!   foldgen width <UnicodeData.txt> <EastAsianWidth.txt> <out.zig>
//!   foldgen class <CaseFolding.txt> <UnicodeData.txt> <out.zig>
//!   foldgen script <Scripts.txt> <PropertyValueAliases.txt> <out.zig>
//!   foldgen normal <UnicodeData.txt> <CompositionExclusions.txt> <out.zig>
//!   foldgen cluster <GraphemeBreakProperty.txt> <emoji-data.txt> <DerivedCoreProperties.txt> <out.zig>
//!   foldgen collate <allkeys.txt> <out.zig>
//!   foldgen kana <allkeys.txt> <out.zig>
//!
//! `posfs` writes posfs's case fold table (sdk/libs/dos/posfs/fold1.zig):
//! simple case folding, the file's C and S lines, one code point to one,
//! without the full (F) and the Turkic (T) ones. It is part of posfs's
//! format - a name's hash is the hash of its folded form - so a table once
//! written is never written again: a later Unicode version becomes a table
//! of its own (`fold2.zig`), and a directory says which it was made with.
//!
//! `case` writes the system's case tables (sdk/libs/utility/unicode_case.zig),
//! which utility.library's case calls and every name compare use: the same
//! simple folding, and the simple upper and lower case - UnicodeData.txt's
//! thirteenth and fourteenth fields. These follow the Unicode version the
//! system is at, and are written again for a new one.
//!
//! `base` writes the base letters (sdk/libs/utility/unicode_base.zig):
//! for each Latin, Greek and Cyrillic letter of the BMP that is another
//! letter with marks, that letter - `Ā` is `A`, `ἀ` is `α` - which a
//! font that lacks the one draws instead. The base is the first code
//! point of a canonical decomposition; a letter with none whose name is
//! another letter's name followed by " WITH ..." (`Ħ`, `ł`, `Ґ`) has that
//! letter. One step only: `Ǻ` is `Å`, whose base is `A`. The version is
//! CaseFolding.txt's, as `case` takes it.
//!
//! `width` writes how many cells of a console a character takes
//! (sdk/libs/utility/unicode_width.zig): none for the marks written on
//! the character before (general categories Mn and Me), the format
//! characters (Cf) but the soft hyphen, and the Hangul vowels and
//! finals that join the syllable before them (U+1160 to U+11FF, U+D7B0
//! to U+D7FF); two for what EastAsianWidth.txt calls wide (W) or full
//! width (F), emoji among them; one for the rest. Both lists are ranges,
//! sorted, a character of no width taken out of the wide ones. The
//! version is EastAsianWidth.txt's.
//!
//! `class` writes what each character is (sdk/libs/utility/unicode_class.zig),
//! by its general category in UnicodeData.txt, a range's First and Last
//! lines taken for every code point between: a letter of either case or
//! neither, a digit, a mark, a number, punctuation, a symbol, a space, a
//! line or paragraph separator, a control, a format character, one for
//! private use, or none at all. The table is where the class changes,
//! each entry a code point and the class from it on - a stretch of
//! capitals each followed by its small letter (`Ā ā Ă ă ...`) one entry
//! of its own kind. The version is CaseFolding.txt's, as `case` takes it.
//!
//! `script` writes the script each character is written in
//! (src/disk/libs/truetypeshaping/shape/_script_table.zig), which
//! truetypeshaping.library splits a text by: Scripts.txt's Script
//! property, each script named by the four letters of ISO 15924 that
//! PropertyValueAliases.txt's `sc` lines give it. The scripts are
//! numbered in the order of those letters, behind `Zyyy` (what every
//! script uses) and `Zinh` (the marks that take their letter's script).
//! The table is where the script changes, as `class`'s is. A code point
//! Scripts.txt leaves out has the script of the code points on both its
//! sides when that is one script, and is `Zyyy` otherwise - the private
//! use areas are. The version is Scripts.txt's.
//!
//! `normal` writes what truetypeshaping.library takes characters apart
//! and puts them together by
//! (src/disk/libs/truetypeshaping/shape/_normal_table.zig), three lists
//! from UnicodeData.txt: where the combining class changes, as `class`'s
//! table has the classes; each character that is one or two others, by
//! its canonical decomposition - the mappings with a `<tag>` are left
//! out; and of those the pairs two characters are put together by,
//! sorted by the two. A pair is left out of the last list where
//! CompositionExclusions.txt names its character, or where the
//! character or the first of its two has a combining class, so that
//! putting together never changes the order a text's marks are read in.
//! It stops where the data are not what the code is written for: a
//! character with a combining class that is no mark, a decomposition of
//! more than two, or a character that is more than four once every part
//! is taken apart. The version is CompositionExclusions.txt's.
//!
//! `cluster` writes what each character is to the clusters of a text
//! (sdk/libs/utility/unicode_cluster.zig), which `unicode.clusterEnd`
//! cuts a text by - a letter with its marks, a syllable of Hangul, a
//! conjunct, an emoji of several characters. A character has one part:
//! its Grapheme_Cluster_Break in GraphemeBreakProperty.txt; a character
//! with none that emoji-data.txt lists as Extended_Pictographic is a
//! pictograph; and DerivedCoreProperties.txt's Indic_Conjunct_Break
//! makes a character with none a consonant, a mark the linker of a
//! conjunct, or a mark that may stand inside one - which nearly every
//! mark may. The table is where
//! the part changes, as `class`'s is, the Hangul syllables - one of a
//! lead and a vowel, then 27 with a trail - an entry of their own kind.
//! It stops where the three files are not what the rules are written
//! for: a pictograph or a consonant with a break property, a linker
//! that is no mark. The version is GraphemeBreakProperty.txt's.
//!
//! `collate` writes the order locale.library sorts the Devanagari block
//! in (src/disk/libs/locale/compare/_devanagari.zig), from the Default
//! Unicode Collation Element Table, allkeys.txt: each character of
//! U+0900 to U+097F whose first collation element has a primary weight
//! gets the place of that weight among the block's, from 1, characters
//! of one weight - a letter and the same letter with a nukta - one
//! place. A character has none where the weight is 0 (the nukta, the
//! accents, the candrabindu, the anusvara and the visarga, which the
//! table tells apart only among what is otherwise the same), where the
//! element is a variable one (punctuation), and where the weight is a
//! digit's - one of U+0030 to U+0039 has it too. It stops where a
//! character's later elements have a primary weight, or where a line
//! starting in the block is more than one character. The version is
//! allkeys.txt's.
//!
//! `kana` writes the order locale.library sorts the kana in
//! (src/disk/libs/locale/compare/_kana.zig), from the same table and in
//! the same way, for U+3040 to U+30FF - hiragana and katakana - and
//! U+FF66 to U+FF9F, the halfwidth katakana, as one set of places: the
//! hiragana, the katakana and the halfwidth katakana of one sound have
//! one weight, the small letter and the voiced one their letter's. A
//! character of two letters (`ゟ`, `ヿ`) has its first letter's place.
//!
//! A case table is runs: code points one or two apart that all move by the same
//! amount (A-Z by +32; Ā, Ă, Ą... by +1 every second one), each run packed
//! into a u64 and found by a binary search - 210 runs for Unicode 16's 1484
//! foldings.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const Mapping = struct { from: u21, to: u21 };
const Run = struct { first: u21, count: u8, stride: u2, delta: i32 };

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("foldgen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const usage = "usage: foldgen posfs <CaseFolding.txt> <out.zig> | foldgen case|base <CaseFolding.txt> <UnicodeData.txt> <out.zig> | foldgen width <UnicodeData.txt> <EastAsianWidth.txt> <out.zig> | foldgen class <CaseFolding.txt> <UnicodeData.txt> <out.zig> | foldgen script <Scripts.txt> <PropertyValueAliases.txt> <out.zig> | foldgen normal <UnicodeData.txt> <CompositionExclusions.txt> <out.zig> | foldgen cluster <GraphemeBreakProperty.txt> <emoji-data.txt> <DerivedCoreProperties.txt> <out.zig> | foldgen collate|kana <allkeys.txt> <out.zig>";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatal(usage, .{});
    const cwd = Io.Dir.cwd();
    const limit: Io.Limit = .limited(8 * 1024 * 1024);
    var out: std.ArrayList(u8) = .empty;

    if (mem.eql(u8, args[1], "posfs")) {
        if (args.len != 4) fatal(usage, .{});
        const folding = try cwd.readFileAlloc(io, args[2], arena, limit);
        const version = try versionOf(folding, args[2]);
        const mappings = try foldings(arena, folding);
        const runs = try runsOf(arena, mappings);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! posfs's case fold 1: Unicode {s} simple case folding (the C and S
            \\//! lines of CaseFolding.txt), as runs of code points that fold by the
            \\//! same amount. Written by tools/foldgen and frozen: it is part of the
            \\//! format, and a later table is a file of its own.
            \\//!
            \\//! {d} mappings in {d} runs, sorted by their first code point.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// Code points `first`, `first + stride`, ... (`count` of them) each
            \\/// fold to themselves plus `delta`.
            \\
        , .{ version, mappings.len, runs.len, version });
        try writeRunType(arena, &out);
        try out.appendSlice(arena, "\n");
        try writeRuns(arena, &out, "runs", runs);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "case")) {
        if (args.len != 5) fatal(usage, .{});
        const folding = try cwd.readFileAlloc(io, args[2], arena, limit);
        const data = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionOf(folding, args[2]);
        const fold = try foldings(arena, folding);
        const upper = try caseMappings(arena, data, 12);
        const lower = try caseMappings(arena, data, 13);
        const fold_runs = try runsOf(arena, fold);
        const upper_runs = try runsOf(arena, upper);
        const lower_runs = try runsOf(arena, lower);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The system's case tables, from Unicode {s}: simple case folding (the
            \\//! C and S lines of CaseFolding.txt) and simple upper and lower case
            \\//! (UnicodeData.txt's thirteenth and fourteenth fields), each as runs
            \\//! of code points that move by the same amount, sorted by their first
            \\//! code point. Written by tools/foldgen (`foldgen case`) from the files
            \\//! scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! Folding: {d} mappings in {d} runs. Upper case: {d} in {d}. Lower
            \\//! case: {d} in {d}.
            \\
            \\/// The Unicode version the tables are from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// Code points `first`, `first + stride`, ... (`count` of them) each
            \\/// map to themselves plus `delta`.
            \\
        , .{ version, fold.len, fold_runs.len, upper.len, upper_runs.len, lower.len, lower_runs.len, version });
        try writeRunType(arena, &out);
        try out.appendSlice(arena, "\n/// What a character folds to, for comparing without regard to case.\n");
        try writeRuns(arena, &out, "fold", fold_runs);
        try out.appendSlice(arena, "\n/// A character's upper case.\n");
        try writeRuns(arena, &out, "upper", upper_runs);
        try out.appendSlice(arena, "\n/// A character's lower case.\n");
        try writeRuns(arena, &out, "lower", lower_runs);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "base")) {
        if (args.len != 5) fatal(usage, .{});
        const folding = try cwd.readFileAlloc(io, args[2], arena, limit);
        const data = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionOf(folding, args[2]);
        const bases = try baseLetters(arena, data);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The base letters, from Unicode {s}: each Latin, Greek and Cyrillic
            \\//! letter of the BMP that is another letter with marks, and that
            \\//! letter - the first code point of its canonical decomposition, or for
            \\//! a letter with none, the letter its name is followed by " WITH ...".
            \\//! One step: a letter with two marks has the letter with the first.
            \\//! Written by tools/foldgen (`foldgen base`) from the files
            \\//! scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! {d} letters, sorted; `bases[i]` is the base of `letters[i]`.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\
        , .{ version, bases.len, version });
        try writeColumn(arena, &out, "The letters with marks, sorted.", "letters", bases, .from);
        try out.appendSlice(arena, "\n");
        try writeColumn(arena, &out, "The letter each is written on.", "bases", bases, .to);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "width")) {
        if (args.len != 5) fatal(usage, .{});
        const data = try cwd.readFileAlloc(io, args[2], arena, limit);
        const widths = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionNamed(widths, "# EastAsianWidth-", args[3]);
        const zero = try zeroWidth(arena, data);
        const wide = try doubleWidth(arena, widths, zero);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The cells of a console a character takes, from Unicode {s}: none for
            \\//! the marks written on the character before (Mn, Me), the format
            \\//! characters (Cf) but the soft hyphen, and the Hangul vowels and
            \\//! finals that join the syllable before them; two for what
            \\//! EastAsianWidth.txt calls wide or full width, emoji among them; one
            \\//! for the rest. Written by tools/foldgen (`foldgen width`) from the
            \\//! files scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! {d} ranges of no width, {d} of two cells, each `.{{ first, last }}`,
            \\//! sorted.
            \\
            \\/// The Unicode version the tables are from.
            \\pub const unicode_version = "{s}";
            \\
            \\
        , .{ version, zero.len, wide.len, version });
        try writeRanges(arena, &out, "The characters that take no cell.", "zero", zero);
        try out.appendSlice(arena, "\n");
        try writeRanges(arena, &out, "The characters that take two cells.", "wide", wide);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "class")) {
        if (args.len != 5) fatal(usage, .{});
        const folding = try cwd.readFileAlloc(io, args[2], arena, limit);
        const data = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionOf(folding, args[2]);
        const classes = try classesOf(arena, data);
        const starts = try startsOf(arena, classes);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! What each character is, from Unicode {s}: its general category in
            \\//! UnicodeData.txt, as one of the classes below. Written by
            \\//! tools/foldgen (`foldgen class`) from the files
            \\//! scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! `starts` is where the class changes, sorted: each entry the code
            \\//! point it starts at shifted up by 8, its class in the low byte, the
            \\//! class good up to the next entry's code point. An entry of class
            \\//! `pairs` starts a stretch of capitals each followed by its small
            \\//! letter: from its code point on, every second character a capital,
            \\//! the ones between small letters. {d} entries.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// What a character is, by its general category.
            \\pub const Class = enum(u8) {{
            \\    /// No character (Cn), or half of a UTF-16 pair (Cs).
            \\    unassigned = 0,
            \\    /// A control (Cc): 0 to 31, 127 and 128 to 159.
            \\    control = 1,
            \\    /// A format character (Cf): the soft hyphen, the joiners, the marks
            \\    /// of writing direction.
            \\    format = 2,
            \\    /// For private use (Co).
            \\    private = 3,
            \\    /// A capital letter (Lu).
            \\    upper = 4,
            \\    /// A small letter (Ll).
            \\    lower = 5,
            \\    /// A capital followed by a small letter in one character (Lt): `ǅ`.
            \\    title = 6,
            \\    /// A letter of neither case (Lm, Lo): `ª`, the kana, the CJK
            \\    /// ideographs.
            \\    letter = 7,
            \\    /// A mark written on the character before (Mn, Mc, Me).
            \\    mark = 8,
            \\    /// A decimal digit of any script (Nd).
            \\    digit = 9,
            \\    /// Any other number (Nl, No): `²`, `½`, `Ⅻ`.
            \\    number = 10,
            \\    /// Punctuation (Pc, Pd, Ps, Pe, Pi, Pf, Po).
            \\    punctuation = 11,
            \\    /// A symbol (Sm, Sc, Sk, So): `+`, `€`, `©`, the emoji.
            \\    symbol = 12,
            \\    /// A space (Zs), the one that does not break among them.
            \\    space = 13,
            \\    /// A line or paragraph separator (Zl, Zp).
            \\    separator = 14,
            \\}};
            \\
            \\/// The class of an entry that starts capitals and small letters by
            \\/// turns.
            \\pub const pairs: u8 = 15;
            \\
            \\
        , .{ version, starts.len, version });
        try writeStarts(arena, &out, "Where the class changes: `code << 8 | class`, sorted.", starts);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "cluster")) {
        if (args.len != 6) fatal(usage, .{});
        const breaks = try cwd.readFileAlloc(io, args[2], arena, limit);
        const emoji = try cwd.readFileAlloc(io, args[3], arena, limit);
        const derived = try cwd.readFileAlloc(io, args[4], arena, limit);
        const version = try versionNamed(breaks, "# GraphemeBreakProperty-", args[2]);
        const parts = try clusterParts(arena, breaks, emoji, derived);
        const starts = try partStarts(arena, parts);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! What each character is to the clusters of a text, from Unicode
            \\//! {s}: its Grapheme_Cluster_Break, with the pictographs of
            \\//! emoji-data.txt and the consonants, linkers and marks of
            \\//! DerivedCoreProperties.txt's Indic_Conjunct_Break as parts of their
            \\//! own. Written by tools/foldgen (`foldgen cluster`) from the files
            \\//! scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! `starts` is where the part changes, sorted: each entry the code
            \\//! point it starts at shifted up by 8, its part in the low byte, the
            \\//! part good up to the next entry's code point. An entry of part
            \\//! `syllables` starts the Hangul syllables: from its code point on,
            \\//! every 28th character a syllable of a lead and a vowel, the 27
            \\//! behind each with a trail as well. {d} entries.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// What a character is in a cluster.
            \\pub const Part = enum(u8) {{
            \\    /// A character that starts a cluster and takes what joins it.
            \\    other = 0,
            \\    /// The carriage return, one cluster with a line feed behind it.
            \\    cr = 1,
            \\    /// The line feed.
            \\    lf = 2,
            \\    /// A control, a separator of lines or paragraphs, a format
            \\    /// character that joins nothing: a cluster by itself.
            \\    control = 3,
            \\    /// A character that goes on the cluster before and may not
            \\    /// stand inside a conjunct: the zero width non-joiner.
            \\    extend = 4,
            \\    /// A mark on the character before, and whatever else goes on
            \\    /// a cluster - a variation selector, an emoji's skin tone, a
            \\    /// tag. A conjunct may hold it: a nukta.
            \\    conjunct_extend = 5,
            \\    /// The mark that joins two consonants to a conjunct: a virama.
            \\    linker = 6,
            \\    /// The zero width joiner.
            \\    joiner = 7,
            \\    /// A regional indicator: two of them are a flag.
            \\    regional = 8,
            \\    /// A sign that goes before the character behind it.
            \\    prepend = 9,
            \\    /// A mark that takes room of its own behind its letter: a
            \\    /// vowel sign.
            \\    spacing = 10,
            \\    /// A Hangul lead.
            \\    lead = 11,
            \\    /// A Hangul vowel.
            \\    vowel = 12,
            \\    /// A Hangul trail.
            \\    trail = 13,
            \\    /// A Hangul syllable of a lead and a vowel.
            \\    syllable = 14,
            \\    /// A Hangul syllable of a lead, a vowel and a trail.
            \\    syllable_trail = 15,
            \\    /// A pictograph: an emoji, or a place kept for one.
            \\    pictographic = 16,
            \\    /// A consonant that a linker joins to the next.
            \\    consonant = 17,
            \\}};
            \\
            \\/// The part of the entry that starts the Hangul syllables.
            \\pub const syllables: u8 = 18;
            \\
            \\
        , .{ version, starts.len, version });
        try writeStarts(arena, &out, "Where the part changes: `code << 8 | part`, sorted.", starts);
        try cwd.writeFile(io, .{ .sub_path = args[5], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "collate")) {
        if (args.len != 4) fatal(usage, .{});
        const keys = try cwd.readFileAlloc(io, args[2], arena, limit);
        const version = try versionNamed(keys, "# allkeys-", args[2]);
        const order = try blockOrder(keys, &.{.{ .first = collate_first, .last = collate_last }}, false);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The order of the Devanagari block, U+{X:0>4} to U+{X:0>4}, from the
            \\//! Default Unicode Collation Element Table of Unicode {s}: the place
            \\//! of each character's primary weight among the block's. Written by
            \\//! tools/foldgen (`foldgen collate`) from allkeys.txt, and written
            \\//! again for a new version of Unicode.
            \\//!
            \\//! A character without a place is one the table gives no primary
            \\//! weight - the nukta, the accents, the candrabindu, the anusvara,
            \\//! the visarga - a digit, or punctuation. A letter and the same
            \\//! letter with a nukta have one place.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// The first character of the block.
            \\pub const first: u32 = 0x{X:0>4};
            \\
            \\/// How many places there are.
            \\pub const count: u8 = {d};
            \\
            \\/// The place of each character from `first` on, from 1; 0 for one
            \\/// that has none.
            \\pub const places = [_]u8{{
            \\
        , .{ collate_first, collate_last, version, version, collate_first, order.count });
        try writePlaces(arena, &out, order.places[0 .. collate_last - collate_first + 1]);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "kana")) {
        if (args.len != 4) fatal(usage, .{});
        const keys = try cwd.readFileAlloc(io, args[2], arena, limit);
        const version = try versionNamed(keys, "# allkeys-", args[2]);
        const order = try blockOrder(keys, &kana_ranges, true);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The order of the kana - hiragana and katakana, U+{X:0>4} to
            \\//! U+{X:0>4}, and the halfwidth katakana, U+{X:0>4} to U+{X:0>4} -
            \\//! from the Default Unicode Collation Element Table of Unicode
            \\//! {s}: the place of each character's primary weight among
            \\//! theirs. Written by tools/foldgen (`foldgen kana`) from
            \\//! allkeys.txt, and written again for a new version of Unicode.
            \\//!
            \\//! The hiragana, the katakana and the halfwidth katakana of one
            \\//! sound have one place, and so have a small letter and a voiced
            \\//! one with their letter; a character of two letters has its
            \\//! first one's. A character without a place is one the table
            \\//! gives no primary weight - the voiced marks - or punctuation.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// The first character of hiragana and katakana.
            \\pub const first: u32 = 0x{X:0>4};
            \\
            \\/// The first character of the halfwidth katakana.
            \\pub const half_first: u32 = 0x{X:0>4};
            \\
            \\/// How many places there are.
            \\pub const count: u8 = {d};
            \\
            \\/// The place of each character from `first` on, from 1; 0 for one
            \\/// that has none.
            \\pub const places = [_]u8{{
            \\
        , .{ kana_ranges[0].first, kana_ranges[0].last, kana_ranges[1].first, kana_ranges[1].last, version, version, kana_ranges[0].first, kana_ranges[1].first, order.count });
        const full = kana_ranges[0].last - kana_ranges[0].first + 1;
        const half = kana_ranges[1].last - kana_ranges[1].first + 1;
        try writePlaces(arena, &out, order.places[0..full]);
        try out.appendSlice(arena,
            \\
            \\/// The place of each character from `half_first` on, as `places`.
            \\pub const half_places = [_]u8{
            \\
        );
        try writePlaces(arena, &out, order.places[full .. full + half]);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.items });
        return;
    }

    if (mem.eql(u8, args[1], "script")) {
        if (args.len != 5) fatal(usage, .{});
        const listing = try cwd.readFileAlloc(io, args[2], arena, limit);
        const aliases = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionNamed(listing, "# Scripts-", args[2]);
        const scripts = try scriptsOf(arena, listing, aliases);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! The script each character is written in, from Unicode {s}: the
            \\//! Script property of Scripts.txt, each script named by the four
            \\//! letters of ISO 15924 that PropertyValueAliases.txt gives it.
            \\//! Written by tools/foldgen (`foldgen script`) from the files
            \\//! scripts/fetch-unicode.sh fetches; never edited by hand.
            \\//!
            \\//! `starts` is where the script changes, sorted: each entry the code
            \\//! point it starts at shifted up by 8, the script's number in the low
            \\//! byte, the script good up to the next entry's code point. A code
            \\//! point Unicode gives no script has the one of the code points on
            \\//! both its sides when that is one script - a character a later
            \\//! version adds to a block is read as its neighbours are - and is
            \\//! `Zyyy` otherwise, as the private use areas are. {d} entries.
            \\//!
            \\//! `codes` is the scripts' four letters, a script's at its number,
            \\//! {d} of them. The first two are no writing system's: `Zyyy` is what
            \\//! every script uses (digits, punctuation, spaces), `Zinh` the marks
            \\//! that take the script of the letter they sit on.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\/// The number of what every script uses, and of the marks that take
            \\/// their letter's script.
            \\pub const common: u8 = 0;
            \\pub const inherited: u8 = 1;
            \\
            \\
        , .{ version, scripts.starts.len, scripts.codes.len, version });
        try writeCodes(arena, &out, scripts.codes);
        try out.appendSlice(arena, "\n");
        try writeStarts(arena, &out, "Where the script changes: `code << 8 | number`, sorted.", scripts.starts);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }
    if (mem.eql(u8, args[1], "normal")) {
        if (args.len != 5) fatal(usage, .{});
        const data = try cwd.readFileAlloc(io, args[2], arena, limit);
        const exclusions = try cwd.readFileAlloc(io, args[3], arena, limit);
        const version = try versionNamed(exclusions, "# CompositionExclusions-", args[3]);
        const normal = try normalOf(arena, data, exclusions);
        try out.print(arena,
            \\// SPDX-License-Identifier: MIT
            \\//! What characters are taken apart and put together by, from Unicode
            \\//! {s}: the combining classes and the canonical decompositions of
            \\//! UnicodeData.txt, and which of them CompositionExclusions.txt keeps
            \\//! from being put together. Written by tools/foldgen (`foldgen
            \\//! normal`) from the files scripts/fetch-unicode.sh fetches; never
            \\//! edited by hand.
            \\//!
            \\//! `starts` is where the combining class changes, sorted: each entry
            \\//! the code point it starts at shifted up by 8, the class in the low
            \\//! byte, the class good up to the next entry's code point. {d}
            \\//! entries.
            \\//!
            \\//! `parts` is each character that is one or two others, sorted: the
            \\//! character shifted up by 42, the first of the others by 21, the
            \\//! second in the low bits, 0 for a character that is one other. Each
            \\//! entry is one step: a part may be an entry itself. {d} entries.
            \\//! The syllables of Hangul are not listed: their parts are counted
            \\//! out.
            \\//!
            \\//! `joined` is the entries of `parts` two characters are put together
            \\//! by, each the entry's place, sorted by the first of the two and
            \\//! then the second. {d} entries.
            \\
            \\/// The Unicode version the table is from.
            \\pub const unicode_version = "{s}";
            \\
            \\
        , .{ version, normal.starts.len, normal.parts.len, normal.joined.len, version });
        try writeStarts(arena, &out, "Where the combining class changes: `code << 8 | class`, sorted.", normal.starts);
        try out.appendSlice(arena, "\n/// The characters that are others: `char << 42 | first << 21 | second`,\n/// sorted.\npub const parts = [_]u64{\n");
        for (normal.parts, 0..) |part, at| {
            if (at % 4 == 0) try out.appendSlice(arena, "   ");
            try out.print(arena, " 0x{X:0>16},", .{part});
            if (at % 4 == 3 or at + 1 == normal.parts.len) try out.appendSlice(arena, "\n");
        }
        try out.appendSlice(arena, "};\n\n/// The places in `parts` of what two characters are put together by,\n/// sorted by the two.\npub const joined = [_]u16{\n");
        for (normal.joined, 0..) |place, at| {
            if (at % 12 == 0) try out.appendSlice(arena, "   ");
            try out.print(arena, " 0x{X:0>4},", .{place});
            if (at % 12 == 11 or at + 1 == normal.joined.len) try out.appendSlice(arena, "\n");
        }
        try out.appendSlice(arena, "};\n");
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }
    fatal(usage, .{});
}

/// What `normal` writes.
const Normal = struct {
    starts: []u32,
    parts: []u64,
    joined: []u16,
};

const class_mark: u8 = 8;

/// How many characters `code` is once every part is taken apart.
fn fullLength(parts: []const u64, code: u32) usize {
    for (parts) |part| {
        if (part >> 42 != code) continue;
        const first: u32 = @intCast((part >> 21) & 0x1F_FFFF);
        const second: u32 = @intCast(part & 0x1F_FFFF);
        return fullLength(parts, first) + if (second != 0) fullLength(parts, second) else 0;
    }
    return 1;
}

/// The three lists of `normal`, from UnicodeData.txt in `data` and
/// CompositionExclusions.txt in `exclusions`.
fn normalOf(arena: mem.Allocator, data: []const u8, exclusions: []const u8) !Normal {
    const classes = try classesOf(arena, data);
    const combining = try arena.alloc(u8, 0x110000);
    @memset(combining, 0);
    var parts: std.ArrayList(u64) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const code = try std.fmt.parseInt(u21, fields.next() orelse continue, 16);
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const class = try std.fmt.parseInt(u8, fields.next() orelse continue, 10);
        _ = fields.next() orelse continue;
        const mapping = fields.next() orelse continue;
        if (class != 0) {
            if (classes[code] != class_mark) fatal("{X} has the combining class {d} and is no mark", .{ code, class });
            combining[code] = class;
        }
        if (mapping.len == 0 or mapping[0] == '<') continue;
        var others = mem.tokenizeScalar(u8, mapping, ' ');
        const first = try std.fmt.parseInt(u21, others.next() orelse continue, 16);
        const second = if (others.next()) |text| try std.fmt.parseInt(u21, text, 16) else 0;
        if (others.next() != null) fatal("{X} is more than two characters", .{code});
        if (first == 0) fatal("{X}: a decomposition that does not read", .{code});
        try parts.append(arena, @as(u64, code) << 42 | @as(u64, first) << 21 | second);
    }
    std.mem.sort(u64, parts.items, {}, std.sort.asc(u64));
    for (parts.items) |part| {
        const code: u32 = @intCast(part >> 42);
        const length = fullLength(parts.items, code);
        if (length > 4) fatal("{X} is {d} characters once taken apart", .{ code, length });
    }

    const excluded = try arena.alloc(bool, 0x110000);
    @memset(excluded, false);
    lines = mem.splitScalar(u8, exclusions, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        excluded[try std.fmt.parseInt(u21, line, 16)] = true;
    }
    var joined: std.ArrayList(u16) = .empty;
    for (parts.items, 0..) |part, place| {
        const code: u32 = @intCast(part >> 42);
        const first: u32 = @intCast((part >> 21) & 0x1F_FFFF);
        if (part & 0x1F_FFFF == 0 or excluded[code] or combining[code] != 0 or combining[first] != 0) continue;
        try joined.append(arena, std.math.cast(u16, place) orelse fatal("more decompositions than a u16 counts", .{}));
    }
    std.mem.sort(u16, joined.items, parts.items, struct {
        fn lessThan(all: []u64, a: u16, b: u16) bool {
            return all[a] & 0x3FF_FFFF_FFFF < all[b] & 0x3FF_FFFF_FFFF;
        }
    }.lessThan);

    var starts: std.ArrayList(u32) = .empty;
    var code: usize = 0;
    while (code < combining.len) {
        const here = combining[code];
        try starts.append(arena, @as(u32, @intCast(code)) << 8 | here);
        while (code < combining.len and combining[code] == here) code += 1;
    }
    return .{ .starts = starts.items, .parts = parts.items, .joined = joined.items };
}

/// The numbers `Class` in the table gives the classes, and the one for
/// capitals and small letters by turns.
const class_numbers = [_]struct { category: []const u8, number: u8 }{
    .{ .category = "Cn", .number = 0 },  .{ .category = "Cs", .number = 0 },
    .{ .category = "Cc", .number = 1 },  .{ .category = "Cf", .number = 2 },
    .{ .category = "Co", .number = 3 },  .{ .category = "Lu", .number = 4 },
    .{ .category = "Ll", .number = 5 },  .{ .category = "Lt", .number = 6 },
    .{ .category = "Lm", .number = 7 },  .{ .category = "Lo", .number = 7 },
    .{ .category = "Mn", .number = 8 },  .{ .category = "Mc", .number = 8 },
    .{ .category = "Me", .number = 8 },  .{ .category = "Nd", .number = 9 },
    .{ .category = "Nl", .number = 10 }, .{ .category = "No", .number = 10 },
    .{ .category = "Pc", .number = 11 }, .{ .category = "Pd", .number = 11 },
    .{ .category = "Ps", .number = 11 }, .{ .category = "Pe", .number = 11 },
    .{ .category = "Pi", .number = 11 }, .{ .category = "Pf", .number = 11 },
    .{ .category = "Po", .number = 11 }, .{ .category = "Sm", .number = 12 },
    .{ .category = "Sc", .number = 12 }, .{ .category = "Sk", .number = 12 },
    .{ .category = "So", .number = 12 }, .{ .category = "Zs", .number = 13 },
    .{ .category = "Zl", .number = 14 }, .{ .category = "Zp", .number = 14 },
};
const class_upper: u8 = 4;
const class_lower: u8 = 5;
const class_pairs: u8 = 15;

fn classNumber(category: []const u8) u8 {
    for (class_numbers) |entry| {
        if (mem.eql(u8, entry.category, category)) return entry.number;
    }
    fatal("unknown general category {s}", .{category});
}

/// Every code point's class, a range's First and Last lines filling the
/// code points between them; 0 for those UnicodeData.txt leaves out.
fn classesOf(arena: mem.Allocator, data: []const u8) ![]u8 {
    const classes = try arena.alloc(u8, 0x110000);
    @memset(classes, 0);
    var first: ?u21 = null;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const code = try std.fmt.parseInt(u21, fields.next() orelse continue, 16);
        const name = fields.next() orelse continue;
        const number = classNumber(fields.next() orelse continue);
        if (mem.endsWith(u8, name, ", First>")) {
            first = code;
            continue;
        }
        if (mem.endsWith(u8, name, ", Last>")) {
            const from = first orelse fatal("a Last line without its First: {X}", .{code});
            @memset(classes[from .. @as(usize, code) + 1], number);
            first = null;
            continue;
        }
        classes[code] = number;
    }
    return classes;
}

/// Where the class changes, as `code << 8 | class`: a stretch of two
/// capitals each followed by its small letter or more one `pairs` entry.
fn startsOf(arena: mem.Allocator, classes: []const u8) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    var code: usize = 0;
    while (code < classes.len) {
        const here = classes[code];
        if (here == class_upper and code + 3 < classes.len and classes[code + 1] == class_lower and
            classes[code + 2] == class_upper and classes[code + 3] == class_lower)
        {
            try starts.append(arena, @as(u32, @intCast(code)) << 8 | class_pairs);
            while (code + 1 < classes.len and classes[code] == class_upper and classes[code + 1] == class_lower) code += 2;
            continue;
        }
        try starts.append(arena, @as(u32, @intCast(code)) << 8 | here);
        while (code < classes.len and classes[code] == here) code += 1;
    }
    return starts.items;
}

/// `starts` as a `u32` array under the doc comment `doc`, eight to a line.
fn writeStarts(arena: mem.Allocator, out: *std.ArrayList(u8), doc: []const u8, starts: []const u32) !void {
    try out.print(arena, "/// {s}\npub const starts = [_]u32{{\n", .{doc});
    for (starts, 0..) |start, at| {
        if (at % 8 == 0) try out.appendSlice(arena, "   ");
        try out.print(arena, " 0x{X:0>8},", .{start});
        if (at % 8 == 7 or at + 1 == starts.len) try out.appendSlice(arena, "\n");
    }
    try out.appendSlice(arena, "};\n");
}

const Scripts = struct {
    /// The scripts' four letters, a script's at its number.
    codes: []const [4]u8,
    /// Where the script changes: `code << 8 | number`.
    starts: []const u32,
};

/// The scripts of Scripts.txt, named by the four letters
/// PropertyValueAliases.txt's `sc` lines give them and numbered in the
/// order of those letters behind `Zyyy` and `Zinh`; and where the script
/// changes. A code point Scripts.txt leaves out has the script of the
/// code points on both its sides when that is one script, `Zyyy`
/// otherwise.
const part_numbers = [_]struct { name: []const u8, number: u8 }{
    .{ .name = "CR", .number = 1 },                    .{ .name = "LF", .number = 2 },
    .{ .name = "Control", .number = 3 },               .{ .name = "Extend", .number = part_extend },
    .{ .name = "ZWJ", .number = part_joiner },         .{ .name = "Regional_Indicator", .number = 8 },
    .{ .name = "Prepend", .number = 9 },               .{ .name = "SpacingMark", .number = 10 },
    .{ .name = "L", .number = 11 },                    .{ .name = "V", .number = 12 },
    .{ .name = "T", .number = 13 },                    .{ .name = "LV", .number = part_syllable },
    .{ .name = "LVT", .number = part_syllable_trail },
};
const part_other: u8 = 0;
const part_extend: u8 = 4;
const part_conjunct_extend: u8 = 5;
const part_linker: u8 = 6;
const part_joiner: u8 = 7;
const part_syllable: u8 = 14;
const part_syllable_trail: u8 = 15;
const part_pictographic: u8 = 16;
const part_consonant: u8 = 17;
const part_syllables: u8 = 18;

/// The block `collate` writes the order of: Devanagari.
const collate_first: u21 = 0x0900;
const collate_last: u21 = 0x097F;

/// The runs `kana` writes the order of: hiragana and katakana, and the
/// halfwidth katakana.
const kana_ranges = [_]Range{ .{ .first = 0x3040, .last = 0x30FF }, .{ .first = 0xFF66, .last = 0xFF9F } };

/// What `collate` and `kana` write: each character's place, the runs'
/// characters one after the other, and how many places.
const BlockOrder = struct { places: [256]u8, count: u8 };

/// Where `char` is among the characters of `ranges`, one run after the
/// other; null for one in none of them.
fn slotOf(ranges: []const Range, char: u21) ?usize {
    var before: usize = 0;
    for (ranges) |range| {
        if (char >= range.first and char <= range.last) return before + (char - range.first);
        before += range.last - range.first + 1;
    }
    return null;
}

/// The places as a table's lines, sixteen to a line, and its end.
fn writePlaces(arena: mem.Allocator, out: *std.ArrayList(u8), places: []const u8) !void {
    for (places, 0..) |place, at| {
        if (at % 16 == 0) try out.appendSlice(arena, "   ");
        // Two digits each: entries of one width are what zig fmt
        // leaves as they are.
        try out.print(arena, " 0x{X:0>2},", .{place});
        if (at % 16 == 15 or at == places.len - 1) try out.appendSlice(arena, "\n");
    }
    try out.appendSlice(arena, "};\n");
}

/// A line of allkeys.txt: the characters it is for, the primary weight
/// of its first element and whether that is a variable one, and whether
/// a later element has a primary weight too.
const KeyLine = struct { first: u21, single: bool, primary: u16, variable: bool, more: bool };

/// `raw` as a line of allkeys.txt; null for a comment, a blank line or
/// an `@` line.
fn keyLine(raw: []const u8) !?KeyLine {
    const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
    if (line.len == 0 or line[0] == '@') return null;
    const cut = mem.indexOfScalar(u8, line, ';') orelse return null;
    var chars = mem.tokenizeScalar(u8, line[0..cut], ' ');
    const first = try std.fmt.parseInt(u21, chars.next() orelse return null, 16);
    var found: KeyLine = .{ .first = first, .single = chars.next() == null, .primary = 0, .variable = false, .more = false };
    var elements = mem.tokenizeAny(u8, line[cut + 1 ..], " []");
    var at: usize = 0;
    while (elements.next()) |element| : (at += 1) {
        // `.PPPP.SSSS.TTTT`, or `*PPPP...` for a variable element.
        if (element.len < 5) fatal("{X}: a collation element {s}", .{ first, element });
        const primary = try std.fmt.parseInt(u16, element[1..5], 16);
        if (at == 0) {
            found.primary = primary;
            found.variable = element[0] == '*';
        } else if (primary != 0) found.more = true;
    }
    return found;
}

/// The places of the characters of `ranges` in allkeys.txt's order, at
/// most 256 of them. With `digraphs`, a character whose later elements
/// have a primary weight too has its first one's place; without, there
/// must be none.
fn blockOrder(keys: []const u8, ranges: []const Range, digraphs: bool) !BlockOrder {
    var weights: [256]u16 = @splat(0);
    var digits: [10]u16 = @splat(0);
    var lines = mem.splitScalar(u8, keys, '\n');
    while (lines.next()) |raw| {
        const line = try keyLine(raw) orelse continue;
        if (line.single and line.first >= '0' and line.first <= '9') digits[line.first - '0'] = line.primary;
        const slot = slotOf(ranges, line.first) orelse continue;
        if (!line.single) fatal("{X} starts a line of several characters", .{line.first});
        if (line.variable or line.primary == 0) continue;
        if (line.more and !digraphs) fatal("{X} has two primary weights", .{line.first});
        weights[slot] = line.primary;
    }
    for (digits) |digit| {
        if (digit == 0) fatal("no weight of a digit", .{});
        for (&weights) |*weight| {
            if (weight.* == digit) weight.* = 0;
        }
    }
    var order: BlockOrder = .{ .places = @splat(0), .count = 0 };
    var below: u16 = 0;
    while (true) {
        // The lowest weight above the last one placed.
        var lowest: u16 = 0;
        for (weights) |weight| {
            if (weight > below and (lowest == 0 or weight < lowest)) lowest = weight;
        }
        if (lowest == 0) break;
        order.count += 1;
        for (weights, &order.places) |weight, *place| {
            if (weight == lowest) place.* = order.count;
        }
        below = lowest;
    }
    return order;
}

/// The lines of a property file: code points, and the fields behind
/// them.
const Listing = struct {
    lines: mem.SplitIterator(u8, .scalar),

    const Line = struct { first: u21, last: u21, fields: [2][]const u8 };

    fn of(text: []const u8) Listing {
        return .{ .lines = mem.splitScalar(u8, text, '\n') };
    }

    fn next(self: *Listing) !?Line {
        while (self.lines.next()) |raw| {
            const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
            if (line.len == 0) continue;
            var fields = mem.splitScalar(u8, line, ';');
            const span = mem.trim(u8, fields.next() orelse continue, " ");
            const dots = mem.indexOf(u8, span, "..");
            var found: Line = .{
                .first = try std.fmt.parseInt(u21, span[0 .. dots orelse span.len], 16),
                .last = undefined,
                .fields = .{ "", "" },
            };
            found.last = if (dots) |at| try std.fmt.parseInt(u21, span[at + 2 ..], 16) else found.first;
            for (&found.fields) |*field| field.* = mem.trim(u8, fields.next() orelse break, " ");
            return found;
        }
        return null;
    }
};

/// Every code point's part in a cluster: 0 for one none of the three
/// files names.
fn clusterParts(arena: mem.Allocator, breaks: []const u8, emoji: []const u8, derived: []const u8) ![]u8 {
    const parts = try arena.alloc(u8, 0x110000);
    @memset(parts, part_other);
    var listing: Listing = .of(breaks);
    while (try listing.next()) |line| {
        const number = for (part_numbers) |known| {
            if (mem.eql(u8, known.name, line.fields[0])) break known.number;
        } else fatal("unknown Grapheme_Cluster_Break {s}", .{line.fields[0]});
        @memset(parts[line.first .. @as(usize, line.last) + 1], number);
    }
    listing = .of(emoji);
    while (try listing.next()) |line| {
        if (!mem.eql(u8, line.fields[0], "Extended_Pictographic")) continue;
        for (parts[line.first .. @as(usize, line.last) + 1], line.first..) |*part, code| {
            if (part.* != part_other) fatal("the pictograph {X} has a break property", .{code});
            part.* = part_pictographic;
        }
    }
    listing = .of(derived);
    while (try listing.next()) |line| {
        if (!mem.eql(u8, line.fields[0], "InCB")) continue;
        const kind = line.fields[1];
        for (parts[line.first .. @as(usize, line.last) + 1], line.first..) |*part, code| {
            if (mem.eql(u8, kind, "Consonant")) {
                if (part.* != part_other) fatal("the consonant {X} has a break property", .{code});
                part.* = part_consonant;
            } else if (mem.eql(u8, kind, "Linker")) {
                if (part.* != part_extend) fatal("the linker {X} is no mark", .{code});
                part.* = part_linker;
            } else if (mem.eql(u8, kind, "Extend")) {
                if (part.* == part_joiner) continue;
                if (part.* != part_extend) fatal("{X} may stand inside a conjunct and is no mark", .{code});
                part.* = part_conjunct_extend;
            } else fatal("unknown Indic_Conjunct_Break {s}", .{kind});
        }
    }
    return parts;
}

/// Where the part changes, as `code << 8 | part`: the Hangul syllables,
/// one of a lead and a vowel and then 27 with a trail, over and over,
/// one `syllables` entry.
fn partStarts(arena: mem.Allocator, parts: []const u8) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    var code: usize = 0;
    while (code < parts.len) {
        const here = parts[code];
        if (here == part_syllable) {
            try starts.append(arena, @as(u32, @intCast(code)) << 8 | part_syllables);
            while (code < parts.len and parts[code] == part_syllable) {
                for (parts[code + 1 ..][0..27], code + 1..) |part, behind| {
                    if (part != part_syllable_trail) fatal("the Hangul syllable {X} has no trail", .{behind});
                }
                code += 28;
            }
            continue;
        }
        if (here == part_syllable_trail) fatal("the Hangul syllable {X} follows none without a trail", .{code});
        try starts.append(arena, @as(u32, @intCast(code)) << 8 | here);
        while (code < parts.len and parts[code] == here) code += 1;
    }
    return starts.items;
}

fn scriptsOf(arena: mem.Allocator, listing: []const u8, aliases: []const u8) !Scripts {
    const Alias = struct { code: [4]u8, name: []const u8 };
    var known: std.ArrayList(Alias) = .empty;
    var lines = mem.splitScalar(u8, aliases, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        var fields = mem.splitScalar(u8, line, ';');
        if (!mem.eql(u8, mem.trim(u8, fields.next() orelse continue, " "), "sc")) continue;
        const code = mem.trim(u8, fields.next() orelse continue, " ");
        const name = mem.trim(u8, fields.next() orelse continue, " ");
        if (code.len != 4) fatal("a script named {s}, not by four letters", .{code});
        try known.append(arena, .{ .code = code[0..4].*, .name = name });
    }

    // Every code point's script as its place in `known`; `none` for those
    // Scripts.txt leaves out.
    const none = 0xFFFF;
    const places = try arena.alloc(u16, 0x110000);
    @memset(places, none);
    const used = try arena.alloc(bool, known.items.len);
    @memset(used, false);
    lines = mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const span = mem.trim(u8, fields.next() orelse continue, " ");
        const name = mem.trim(u8, fields.next() orelse continue, " ");
        const dots = mem.indexOf(u8, span, "..");
        const first = try std.fmt.parseInt(u21, span[0 .. dots orelse span.len], 16);
        const last = if (dots) |at| try std.fmt.parseInt(u21, span[at + 2 ..], 16) else first;
        const place = for (known.items, 0..) |alias, at| {
            if (mem.eql(u8, alias.name, name)) break at;
        } else fatal("Scripts.txt names {s}, which has no four letters", .{name});
        used[place] = true;
        @memset(places[first .. @as(usize, last) + 1], @intCast(place));
    }

    // The numbers: `Zyyy`, `Zinh`, then the others in use by their letters.
    var codes: std.ArrayList([4]u8) = .empty;
    try codes.append(arena, "Zyyy".*);
    try codes.append(arena, "Zinh".*);
    var others: std.ArrayList([4]u8) = .empty;
    for (known.items, used) |alias, in_use| {
        if (!in_use or mem.eql(u8, &alias.code, "Zyyy") or mem.eql(u8, &alias.code, "Zinh")) continue;
        try others.append(arena, alias.code);
    }
    mem.sort([4]u8, others.items, {}, struct {
        fn lessThan(_: void, a: [4]u8, b: [4]u8) bool {
            return mem.order(u8, &a, &b) == .lt;
        }
    }.lessThan);
    try codes.appendSlice(arena, others.items);
    if (codes.items.len > 256) fatal("{d} scripts, more than a byte numbers", .{codes.items.len});
    const numbers = try arena.alloc(u8, known.items.len);
    for (known.items, numbers) |alias, *number| {
        // One not in use keeps 0: no code point reads it.
        number.* = for (codes.items, 0..) |code, at| {
            if (mem.eql(u8, &code, &alias.code)) break @intCast(at);
        } else 0;
    }

    // The code points left out: a stretch of them between two of one
    // script takes it, any other is `Zyyy`.
    const common: u16 = for (known.items, 0..) |alias, at| {
        if (mem.eql(u8, &alias.code, "Zyyy")) break @intCast(at);
    } else fatal("no script Zyyy", .{});
    var code: usize = 0;
    while (code < places.len) {
        if (places[code] != none) {
            code += 1;
            continue;
        }
        var end = code;
        while (end < places.len and places[end] == none) end += 1;
        const before = if (code == 0) none else places[code - 1];
        const after = if (end == places.len) none else places[end];
        @memset(places[code..end], if (before == after and before != none) before else common);
        code = end;
    }

    var starts: std.ArrayList(u32) = .empty;
    var current: u16 = none;
    for (places, 0..) |place, at| {
        if (place == current) continue;
        try starts.append(arena, @as(u32, @intCast(at)) << 8 | numbers[place]);
        current = place;
    }
    return .{ .codes = codes.items, .starts = starts.items };
}

/// `codes` as an array of four letters each, eight to a line.
fn writeCodes(arena: mem.Allocator, out: *std.ArrayList(u8), codes: []const [4]u8) !void {
    try out.appendSlice(arena, "/// The scripts' four letters, a script's at its number.\npub const codes = [_][4]u8{\n");
    for (codes, 0..) |*code, at| {
        if (at % 8 == 0) try out.appendSlice(arena, "   ");
        try out.print(arena, " \"{s}\".*,", .{code});
        if (at % 8 == 7 or at + 1 == codes.len) try out.appendSlice(arena, "\n");
    }
    try out.appendSlice(arena, "};\n");
}

const Range = struct { first: u21, last: u21 };

/// The characters of no width UnicodeData.txt names, as sorted ranges.
fn zeroWidth(arena: mem.Allocator, data: []const u8) ![]Range {
    var codes: std.ArrayList(u21) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const code = try std.fmt.parseInt(u21, fields.next() orelse continue, 16);
        _ = fields.next(); // the name
        const category = fields.next() orelse continue;
        const none = mem.eql(u8, category, "Mn") or mem.eql(u8, category, "Me") or
            (mem.eql(u8, category, "Cf") and code != 0x00AD);
        if (none) try codes.append(arena, code);
    }
    // The Hangul vowels and finals, which join the syllable before them.
    var code: u21 = 0x1160;
    while (code <= 0x11FF) : (code += 1) try codes.append(arena, code);
    code = 0xD7B0;
    while (code <= 0xD7FF) : (code += 1) try codes.append(arena, code);
    mem.sort(u21, codes.items, {}, std.sort.asc(u21));
    return rangesOf(arena, codes.items);
}

/// The wide and full-width characters of EastAsianWidth.txt, without
/// those in `zero`, as sorted ranges.
fn doubleWidth(arena: mem.Allocator, widths: []const u8, zero: []const Range) ![]Range {
    var codes: std.ArrayList(u21) = .empty;
    var lines = mem.splitScalar(u8, widths, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw[0 .. mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const span = mem.trim(u8, fields.next() orelse continue, " ");
        const kind = mem.trim(u8, fields.next() orelse continue, " ");
        if (!mem.eql(u8, kind, "W") and !mem.eql(u8, kind, "F")) continue;
        const dots = mem.indexOf(u8, span, "..");
        const first = try std.fmt.parseInt(u21, span[0 .. dots orelse span.len], 16);
        const last = if (dots) |at| try std.fmt.parseInt(u21, span[at + 2 ..], 16) else first;
        var code = first;
        while (true) : (code += 1) {
            if (!within(zero, code)) try codes.append(arena, code);
            if (code == last) break;
        }
    }
    mem.sort(u21, codes.items, {}, std.sort.asc(u21));
    return rangesOf(arena, codes.items);
}

fn within(ranges: []const Range, code: u21) bool {
    for (ranges) |range| {
        if (code >= range.first and code <= range.last) return true;
    }
    return false;
}

/// Sorted code points, each once, as the runs of neighbours they make.
fn rangesOf(arena: mem.Allocator, codes: []const u21) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    for (codes) |code| {
        if (ranges.items.len != 0) {
            const last = &ranges.items[ranges.items.len - 1];
            if (code == last.last) continue;
            if (code == last.last + 1) {
                last.last = code;
                continue;
            }
        }
        try ranges.append(arena, .{ .first = code, .last = code });
    }
    return ranges.items;
}

/// `ranges` as an array of `.{ first, last }` named `name`, four to a line.
fn writeRanges(arena: mem.Allocator, out: *std.ArrayList(u8), doc: []const u8, name: []const u8, ranges: []const Range) !void {
    try out.print(arena, "/// {s}\npub const {s} = [_][2]u32{{\n", .{ doc, name });
    for (ranges, 0..) |range, at| {
        if (at % 4 == 0) try out.appendSlice(arena, "   ");
        // Five digits each, which every code point in the tables has room
        // in: entries of one width are what zig fmt leaves as they are.
        try out.print(arena, " .{{ 0x{X:0>5}, 0x{X:0>5} }},", .{ range.first, range.last });
        if (at % 4 == 3 or at + 1 == ranges.len) try out.appendSlice(arena, "\n");
    }
    try out.appendSlice(arena, "};\n");
}

/// Every Latin, Greek and Cyrillic letter of the BMP that is another
/// letter with marks, and that letter, sorted.
fn baseLetters(arena: mem.Allocator, data: []const u8) ![]Mapping {
    const Entry = struct { code: u21, name: []const u8, category: []const u8, decomposition: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const code = try std.fmt.parseInt(u21, fields.next() orelse continue, 16);
        const name = fields.next() orelse continue;
        const category = fields.next() orelse continue;
        _ = fields.next(); // the combining class
        _ = fields.next(); // the bidirectional class
        const decomposition = fields.next() orelse continue;
        try by_name.put(arena, name, entries.items.len);
        try entries.append(arena, .{ .code = code, .name = name, .category = category, .decomposition = decomposition });
    }
    var codes: std.AutoHashMapUnmanaged(u21, usize) = .empty;
    for (entries.items, 0..) |entry, index| try codes.put(arena, entry.code, index);
    const isLetter = struct {
        fn of(all: []const Entry, at: ?usize) bool {
            const index = at orelse return false;
            return all[index].category.len != 0 and all[index].category[0] == 'L';
        }
    }.of;

    var mappings: std.ArrayList(Mapping) = .empty;
    for (entries.items, 0..) |entry, index| {
        if (entry.code > 0xFFFF or !isLetter(entries.items, index)) continue;
        if (!mem.startsWith(u8, entry.name, "LATIN ") and !mem.startsWith(u8, entry.name, "GREEK ") and
            !mem.startsWith(u8, entry.name, "CYRILLIC ")) continue;
        var base: ?u21 = null;
        if (entry.decomposition.len != 0) {
            // A tagged decomposition is a compatibility one: no base.
            if (entry.decomposition[0] != '<') {
                const first_text = entry.decomposition[0 .. mem.indexOfScalar(u8, entry.decomposition, ' ') orelse entry.decomposition.len];
                const first = try std.fmt.parseInt(u21, first_text, 16);
                if (isLetter(entries.items, codes.get(first))) base = first;
            }
        } else if (mem.indexOf(u8, entry.name, " WITH ")) |with| {
            const stem = by_name.get(entry.name[0..with]);
            if (isLetter(entries.items, stem)) base = entries.items[stem.?].code;
        }
        if (base) |letter| try mappings.append(arena, .{ .from = entry.code, .to = letter });
    }
    sortMappings(mappings.items);
    return mappings.items;
}

/// One side of `mappings` as a `u16` array named `name`, twelve to a line.
fn writeColumn(arena: mem.Allocator, out: *std.ArrayList(u8), doc: []const u8, name: []const u8, mappings: []const Mapping, comptime side: enum { from, to }) !void {
    try out.print(arena, "/// {s}\npub const {s} = [_]u16{{\n", .{ doc, name });
    for (mappings, 0..) |mapping, at| {
        const value = if (side == .from) mapping.from else mapping.to;
        if (at % 12 == 0) try out.appendSlice(arena, "   ");
        try out.print(arena, " 0x{X:0>4},", .{value});
        if (at % 12 == 11 or at + 1 == mappings.len) try out.appendSlice(arena, "\n");
    }
    try out.appendSlice(arena, "};\n");
}

/// The version CaseFolding.txt's first line names.
fn versionOf(folding: []const u8, path: []const u8) ![]const u8 {
    return versionNamed(folding, "# CaseFolding-", path);
}

/// The version a file's line starting with `prefix` names.
fn versionNamed(text: []const u8, comptime prefix: []const u8, path: []const u8) ![]const u8 {
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (mem.startsWith(u8, line, prefix)) return mem.trim(u8, line[prefix.len..], " .txt");
    }
    fatal("{s}: no version line", .{path});
}

/// CaseFolding.txt's C and S lines, sorted.
fn foldings(arena: mem.Allocator, folding: []const u8) ![]Mapping {
    var mappings: std.ArrayList(Mapping) = .empty;
    var lines = mem.splitScalar(u8, folding, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        const data = mem.trim(u8, line[0 .. mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
        if (data.len == 0) continue;
        var fields = mem.splitScalar(u8, data, ';');
        const from = mem.trim(u8, fields.next() orelse continue, " ");
        const status = mem.trim(u8, fields.next() orelse continue, " ");
        const to = mem.trim(u8, fields.next() orelse continue, " ");
        if (!mem.eql(u8, status, "C") and !mem.eql(u8, status, "S")) continue;
        try mappings.append(arena, .{
            .from = try std.fmt.parseInt(u21, from, 16),
            .to = try std.fmt.parseInt(u21, to, 16),
        });
    }
    sortMappings(mappings.items);
    return mappings.items;
}

/// UnicodeData.txt's simple case mapping in field `field` (12 upper case,
/// 13 lower case), for every character that has one, sorted.
fn caseMappings(arena: mem.Allocator, data: []const u8, field: usize) ![]Mapping {
    var mappings: std.ArrayList(Mapping) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = mem.splitScalar(u8, line, ';');
        const from = fields.next() orelse continue;
        var index: usize = 1;
        var value: []const u8 = "";
        while (fields.next()) |each| : (index += 1) {
            if (index == field) {
                value = each;
                break;
            }
        }
        if (value.len == 0) continue;
        try mappings.append(arena, .{
            .from = try std.fmt.parseInt(u21, from, 16),
            .to = try std.fmt.parseInt(u21, value, 16),
        });
    }
    sortMappings(mappings.items);
    return mappings.items;
}

fn sortMappings(mappings: []Mapping) void {
    std.mem.sort(Mapping, mappings, {}, struct {
        fn lessThan(_: void, a: Mapping, b: Mapping) bool {
            return a.from < b.from;
        }
    }.lessThan);
}

/// The mappings as runs.
fn runsOf(arena: mem.Allocator, all: []const Mapping) ![]Run {
    var runs: std.ArrayList(Run) = .empty;
    var at: usize = 0;
    while (at < all.len) {
        const delta: i32 = @as(i32, all[at].to) - @as(i32, all[at].from);
        var count: usize = 1;
        var stride: u21 = 1;
        if (at + 1 < all.len) {
            const step = all[at + 1].from - all[at].from;
            const next_delta: i32 = @as(i32, all[at + 1].to) - @as(i32, all[at + 1].from);
            if ((step == 1 or step == 2) and next_delta == delta) {
                stride = step;
                count = 2;
                while (at + count < all.len and count < 255) : (count += 1) {
                    const here = all[at + count];
                    if (here.from - all[at + count - 1].from != stride) break;
                    if (@as(i32, here.to) - @as(i32, here.from) != delta) break;
                }
            }
        }
        try runs.append(arena, .{ .first = all[at].from, .count = @intCast(count), .stride = @intCast(stride), .delta = delta });
        at += count;
    }
    return runs.items;
}

fn writeRunType(arena: mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(arena,
        \\pub const Run = packed struct(u64) {
        \\    first: u21,
        \\    count: u8,
        \\    stride: u2,
        \\    delta: i32,
        \\    reserved: u1 = 0,
        \\};
        \\
    );
}

fn writeRuns(arena: mem.Allocator, out: *std.ArrayList(u8), name: []const u8, runs: []const Run) !void {
    try out.print(arena, "pub const {s} = [_]Run{{\n", .{name});
    for (runs) |run| {
        try out.print(arena, "    .{{ .first = 0x{X:0>4}, .count = {d}, .stride = {d}, .delta = {d} }},\n", .{ run.first, run.count, run.stride, run.delta });
    }
    try out.appendSlice(arena, "};\n");
}
