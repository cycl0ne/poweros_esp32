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

const usage = "usage: foldgen posfs <CaseFolding.txt> <out.zig> | foldgen case|base <CaseFolding.txt> <UnicodeData.txt> <out.zig> | foldgen width <UnicodeData.txt> <EastAsianWidth.txt> <out.zig> | foldgen class <CaseFolding.txt> <UnicodeData.txt> <out.zig>";

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
        try writeStarts(arena, &out, starts);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = out.items });
        return;
    }
    fatal(usage, .{});
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

/// `starts` as a `u32` array, eight to a line.
fn writeStarts(arena: mem.Allocator, out: *std.ArrayList(u8), starts: []const u32) !void {
    try out.appendSlice(arena, "/// Where the class changes: `code << 8 | class`, sorted.\npub const starts = [_]u32{\n");
    for (starts, 0..) |start, at| {
        if (at % 8 == 0) try out.appendSlice(arena, "   ");
        try out.print(arena, " 0x{X:0>8},", .{start});
        if (at % 8 == 7 or at + 1 == starts.len) try out.appendSlice(arena, "\n");
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
