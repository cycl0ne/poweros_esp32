// SPDX-License-Identifier: MIT
//! catcomp: a program's strings, from its catalog descriptor (`.cd`), as
//! the Zig module the program is built with, and a translation (`.ct`) as
//! the catalog file locale.library reads.
//!
//!   catcomp strings <file.cd> <name.catalog> <out.zig>
//!   catcomp catalog <file.cd> <file.ct> <name.catalog> <out.catalog>
//!
//! A descriptor, UTF-8 text:
//!
//!   ; a comment
//!   #version 1           the version a catalog must have (OC_Version)
//!   #language english    the language of the strings here (the default)
//!   MSG_HELLO (1//)      a string's name, then (number/least/most)
//!   Hello, %s!\n         its text, on the next line
//!   MSG_FILES (//40)     no number: one past the one before (0 first)
//!   %ld files in \
//!   %s                   a line ending in `\` goes on with the next
//!
//! A translation:
//!
//!   ## version $VER: c/test/locale.catalog 1.0 (29.10.2026)
//!   ## language deutsch
//!   ## codeset 106
//!   MSG_HELLO
//!   Hallo, %s!\n
//!   ; a comment, the English for one, say
//!
//! A string's text takes C's escapes - `\n \t \r \a \b \f \v \e` (escape)
//! `\c` (CSI) `\\ \" \'`, `\xHH`, `\ooo` - and its least and most bound its
//! length in characters in every translation. A translation may leave a
//! string out, or leave its text empty: the one built in is used.
//!
//! What it checks: every name in a translation is in the descriptor, none
//! twice; each translation takes the same values, of the same sizes, as
//! the string built in - by place (`%2$s`) or in order; its version is the
//! descriptor's; it is UTF-8.
//!
//! The module: `catalog_name`, `catalog_version`, `builtin_language`, the
//! names as `Id`, and `builtin(id)`, each string as it is built in - in
//! Latin-1, the system's code set, a character it lacks as `?`. The
//! catalog: an IFF FORM CTLG with FVER, LANG, CSET (106: the strings are
//! UTF-8, and the library converts them as it reads) and STRS, the strings
//! sorted by number.

const std = @import("std");
const mem = std.mem;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("catcomp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();
    const usage = "usage: catcomp strings <file.cd> <name.catalog> <out.zig>\n       catcomp catalog <file.cd> <file.ct> <name.catalog> <out.catalog>";
    if (args.len < 2) fatal("{s}", .{usage});
    var problem: Problem = .{};
    if (mem.eql(u8, args[1], "strings") and args.len == 5) {
        const cd_text = try cwd.readFileAlloc(io, args[2], arena, .unlimited);
        const descriptor = readDescriptor(arena, cd_text, &problem) catch fatal("{s}:{d}: {s}", .{ args[2], problem.line, problem.text });
        const module = try writeModule(arena, &descriptor, args[3], std.fs.path.basename(args[2]));
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = module });
        return;
    }
    if (mem.eql(u8, args[1], "catalog") and args.len == 6) {
        const cd_text = try cwd.readFileAlloc(io, args[2], arena, .unlimited);
        const descriptor = readDescriptor(arena, cd_text, &problem) catch fatal("{s}:{d}: {s}", .{ args[2], problem.line, problem.text });
        const ct_text = try cwd.readFileAlloc(io, args[3], arena, .unlimited);
        const translation = readTranslation(arena, ct_text, &descriptor, &problem) catch fatal("{s}:{d}: {s}", .{ args[3], problem.line, problem.text });
        const catalog = try writeCatalog(arena, &translation);
        try cwd.writeFile(io, .{ .sub_path = args[5], .data = catalog });
        return;
    }
    fatal("{s}", .{usage});
}

/// What is wrong, and on which line.
pub const Problem = struct {
    line: usize = 0,
    text: []const u8 = "",

    fn at(problem: *Problem, line: usize, text: []const u8) error{Bad} {
        problem.* = .{ .line = line, .text = text };
        return error.Bad;
    }
};

pub const Message = struct {
    name: []const u8,
    id: i32,
    least: ?usize = null,
    most: ?usize = null,
    /// UTF-8, the escapes undone.
    text: []const u8,
};

pub const Descriptor = struct {
    version: u32 = 0,
    language: []const u8 = "english",
    messages: []const Message,

    fn find(descriptor: *const Descriptor, name: []const u8) ?*const Message {
        for (descriptor.messages) |*message| {
            if (mem.eql(u8, message.name, name)) return message;
        }
        return null;
    }
};

pub const Translated = struct { id: i32, text: []const u8 };

pub const Translation = struct {
    version_string: []const u8,
    language: []const u8,
    strings: []const Translated,
};

/// The lines of a file, a line ending in `\` joined with the next; each
/// with the number of its first line.
const Lines = struct {
    text: []const u8,
    at: usize = 0,
    number: usize = 0,

    fn next(lines: *Lines, gpa: mem.Allocator) !?struct { text: []const u8, number: usize } {
        if (lines.at >= lines.text.len) return null;
        var joined: std.ArrayList(u8) = .empty;
        const first = lines.number + 1;
        while (lines.at < lines.text.len) {
            var end = lines.at;
            while (end < lines.text.len and lines.text[end] != '\n') end += 1;
            var line = lines.text[lines.at..end];
            lines.at = end + 1;
            lines.number += 1;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > 0 and line[line.len - 1] == '\\' and !escapedBackslash(line)) {
                try joined.appendSlice(gpa, line[0 .. line.len - 1]);
                continue;
            }
            try joined.appendSlice(gpa, line);
            break;
        }
        return .{ .text = joined.items, .number = first };
    }

    /// Whether the `\` the line ends in is the second of a `\\`.
    fn escapedBackslash(line: []const u8) bool {
        var count: usize = 0;
        var at = line.len;
        while (at > 0 and line[at - 1] == '\\') : (at -= 1) count += 1;
        return count % 2 == 0;
    }
};

pub fn readDescriptor(gpa: mem.Allocator, text: []const u8, problem: *Problem) !Descriptor {
    if (!std.unicode.utf8ValidateSlice(text)) return problem.at(0, "not UTF-8");
    var descriptor: Descriptor = .{ .messages = &.{} };
    var messages: std.ArrayList(Message) = .empty;
    var lines = Lines{ .text = text };
    var next_id: i32 = 0;
    while (try lines.next(gpa)) |line| {
        const words = mem.trim(u8, line.text, " \t");
        if (words.len == 0 or words[0] == ';') continue;
        if (words[0] == '#') {
            const directive = mem.trim(u8, words[1..], " \t");
            if (mem.startsWith(u8, directive, "version")) {
                descriptor.version = std.fmt.parseInt(u32, mem.trim(u8, directive[7..], " \t"), 10) catch return problem.at(line.number, "#version takes a number");
            } else if (mem.startsWith(u8, directive, "language")) {
                descriptor.language = mem.trim(u8, directive[8..], " \t");
            } else return problem.at(line.number, "an unknown directive");
            continue;
        }
        const open = mem.indexOfScalar(u8, words, '(') orelse return problem.at(line.number, "a name without (number/least/most)");
        const close = mem.lastIndexOfScalar(u8, words, ')') orelse return problem.at(line.number, "a ( not closed");
        const name = mem.trim(u8, words[0..open], " \t");
        if (!std.zig.isValidId(name)) return problem.at(line.number, "a name that is no identifier");
        var fields = mem.splitScalar(u8, words[open + 1 .. close], '/');
        const id_text = mem.trim(u8, fields.next() orelse "", " \t");
        const least_text = mem.trim(u8, fields.next() orelse "", " \t");
        const most_text = mem.trim(u8, fields.next() orelse "", " \t");
        const id = if (id_text.len == 0) next_id else std.fmt.parseInt(i32, id_text, 0) catch return problem.at(line.number, "a number that is none");
        next_id = id + 1;
        const least = if (least_text.len == 0) null else std.fmt.parseInt(usize, least_text, 10) catch return problem.at(line.number, "a least that is no number");
        const most = if (most_text.len == 0) null else std.fmt.parseInt(usize, most_text, 10) catch return problem.at(line.number, "a most that is no number");
        for (messages.items) |message| {
            if (mem.eql(u8, message.name, name)) return problem.at(line.number, "a name given twice");
            if (message.id == id) return problem.at(line.number, "a number given twice");
        }
        const string_line = (try lines.next(gpa)) orelse return problem.at(line.number, "a name without its text");
        const string = unescape(gpa, string_line.text) catch return problem.at(string_line.number, "an escape that is none");
        if (!fits(string, least, most)) return problem.at(string_line.number, "a text outside its least and most");
        _ = signature(gpa, string) catch return problem.at(string_line.number, "a value both by place and in order");
        try messages.append(gpa, .{ .name = name, .id = id, .least = least, .most = most, .text = string });
    }
    descriptor.messages = messages.items;
    return descriptor;
}

pub fn readTranslation(gpa: mem.Allocator, text: []const u8, descriptor: *const Descriptor, problem: *Problem) !Translation {
    if (!std.unicode.utf8ValidateSlice(text)) return problem.at(0, "not UTF-8");
    var translation: Translation = .{ .version_string = "", .language = "", .strings = &.{} };
    var strings: std.ArrayList(Translated) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var lines = Lines{ .text = text };
    while (try lines.next(gpa)) |line| {
        const words = mem.trim(u8, line.text, " \t");
        if (words.len == 0 or words[0] == ';') continue;
        if (mem.startsWith(u8, words, "##")) {
            const directive = mem.trim(u8, words[2..], " \t");
            if (mem.startsWith(u8, directive, "version")) {
                translation.version_string = mem.trim(u8, directive[7..], " \t");
            } else if (mem.startsWith(u8, directive, "language")) {
                translation.language = mem.trim(u8, directive[8..], " \t");
            } else if (mem.startsWith(u8, directive, "codeset")) {
                const set = std.fmt.parseInt(u32, mem.trim(u8, directive[7..], " \t"), 10) catch return problem.at(line.number, "## codeset takes a number");
                if (set != 0 and set != 106) return problem.at(line.number, "a translation is UTF-8: ## codeset 106");
            } else return problem.at(line.number, "an unknown directive");
            continue;
        }
        const message = descriptor.find(words) orelse return problem.at(line.number, "a name the descriptor does not have");
        for (seen.items) |name| {
            if (mem.eql(u8, name, words)) return problem.at(line.number, "a name given twice");
        }
        try seen.append(gpa, message.name);
        const string_line = (try lines.next(gpa)) orelse return problem.at(line.number, "a name without its text");
        const string = unescape(gpa, string_line.text) catch return problem.at(string_line.number, "an escape that is none");
        if (string.len == 0) continue;
        if (!fits(string, message.least, message.most)) return problem.at(string_line.number, "a text outside its least and most");
        const want = signature(gpa, message.text) catch unreachable;
        const got = signature(gpa, string) catch return problem.at(string_line.number, "a value both by place and in order");
        if (!mem.eql(u8, want, got)) return problem.at(string_line.number, "values not those of the string built in");
        try strings.append(gpa, .{ .id = message.id, .text = string });
    }
    if (translation.language.len == 0) return problem.at(0, "no ## language");
    if (translation.version_string.len == 0) return problem.at(0, "no ## version");
    if (versionOf(translation.version_string) != descriptor.version) return problem.at(0, "a version that is not the descriptor's #version");
    mem.sort(Translated, strings.items, {}, struct {
        fn less(_: void, a: Translated, b: Translated) bool {
            return a.id < b.id;
        }
    }.less);
    translation.strings = strings.items;
    return translation;
}

/// The version in `$VER: name v.r (date)`.
fn versionOf(string: []const u8) u32 {
    var words = mem.tokenizeAny(u8, string, " \t");
    while (words.next()) |word| {
        if (word.len == 0 or word[0] < '0' or word[0] > '9') continue;
        const dot = mem.indexOfScalar(u8, word, '.') orelse word.len;
        return std.fmt.parseInt(u32, word[0..dot], 10) catch continue;
    }
    return 0;
}

fn fits(text: []const u8, least: ?usize, most: ?usize) bool {
    const count = std.unicode.utf8CountCodepoints(text) catch return false;
    if (least) |bound| if (count < bound) return false;
    if (most) |bound| if (count > bound) return false;
    return true;
}

fn unescape(gpa: mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const c = text[at];
        at += 1;
        if (c != '\\') {
            try out.append(gpa, c);
            continue;
        }
        if (at >= text.len) return error.Escape;
        const e = text[at];
        at += 1;
        const byte: u8 = switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0C,
            'v' => 0x0B,
            'e' => 0x1B,
            'c' => 0x9B,
            '\\', '"', '\'' => e,
            'x' => hex: {
                var value: u8 = 0;
                var count: usize = 0;
                while (count < 2 and at < text.len) : (count += 1) {
                    const digit = std.fmt.charToDigit(text[at], 16) catch break;
                    value = value * 16 + digit;
                    at += 1;
                }
                if (count == 0) return error.Escape;
                break :hex value;
            },
            '0'...'7' => octal: {
                var value: u16 = e - '0';
                var count: usize = 1;
                while (count < 3 and at < text.len and text[at] >= '0' and text[at] <= '7') : (count += 1) {
                    value = value * 8 + (text[at] - '0');
                    at += 1;
                }
                if (value > 0xFF) return error.Escape;
                break :octal @intCast(value);
            },
            else => return error.Escape,
        };
        try out.append(gpa, byte);
    }
    return out.items;
}

/// The values a format takes, by place: each value's size - `4`, `8`,
/// `z` or `p` for a pointer - in the order of the places. A value no
/// conversion names is `-`.
pub fn signature(gpa: mem.Allocator, format: []const u8) ![]const u8 {
    var sizes: std.ArrayList(u8) = .empty;
    var by_place = false;
    var in_order = false;
    var sequence: usize = 0;
    var at: usize = 0;
    while (at < format.len) : (at += 1) {
        if (format[at] != '%') continue;
        at += 1;
        const place_start = at;
        while (at < format.len and format[at] >= '0' and format[at] <= '9') at += 1;
        var index: ?usize = null;
        if (at < format.len and format[at] == '$' and at > place_start) {
            index = (std.fmt.parseInt(usize, format[place_start..at], 10) catch return error.Place) -| 1;
            at += 1;
        } else at = place_start;
        while (at < format.len and (format[at] == '-' or format[at] == '.' or (format[at] >= '0' and format[at] <= '9'))) at += 1;
        var size: u8 = '4';
        if (at < format.len and format[at] == 'l') {
            size = '8';
            at += 1;
        } else if (at < format.len and format[at] == 'z') {
            size = 'z';
            at += 1;
        }
        if (at >= format.len) break;
        switch (format[at]) {
            'd', 'D', 'u', 'U', 'x', 'X', 'c' => {},
            's' => size = 'p',
            else => continue,
        }
        if (index != null) by_place = true else in_order = true;
        if (by_place and in_order) return error.Place;
        const place = index orelse sequence;
        sequence += 1;
        while (sizes.items.len <= place) try sizes.append(gpa, '-');
        sizes.items[place] = size;
    }
    return sizes.items;
}

/// UTF-8 as Latin-1, a character it lacks as `?`.
fn toLatin1(gpa: mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const view = try std.unicode.Utf8View.init(text);
    var points = view.iterator();
    while (points.nextCodepoint()) |point| try out.append(gpa, if (point <= 0xFF) @intCast(point) else '?');
    return out.items;
}

pub fn writeModule(gpa: mem.Allocator, descriptor: *const Descriptor, catalog_name: []const u8, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, try std.fmt.allocPrint(gpa,
        \\// SPDX-License-Identifier: MIT
        \\//! The strings of {s}, made by catcomp from {s}: do not edit.
        \\
        \\/// The catalog's name, for OpenCatalogA.
        \\pub const catalog_name = "{s}";
        \\/// The version a catalog must have (OC_Version).
        \\pub const catalog_version = {d};
        \\/// The language of the strings built in (OC_BuiltInLanguage).
        \\pub const builtin_language = "{s}";
        \\
        \\/// Each string's number, by its name.
        \\pub const Id = enum(i32) {{
        \\
    , .{ catalog_name, source, catalog_name, descriptor.version, descriptor.language }));
    for (descriptor.messages) |message| {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "    {s} = {d},\n", .{ message.name, message.id }));
    }
    try out.appendSlice(gpa,
        \\};
        \\
        \\/// Each string as it is built in.
        \\pub fn builtin(comptime id: Id) [:0]const u8 {
        \\    return switch (id) {
        \\
    );
    for (descriptor.messages) |message| {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "        .{s} => \"", .{message.name}));
        for (try toLatin1(gpa, message.text)) |byte| {
            if (byte >= 0x20 and byte < 0x7F and byte != '"' and byte != '\\') {
                try out.append(gpa, byte);
            } else {
                try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "\\x{x:0>2}", .{byte}));
            }
        }
        try out.appendSlice(gpa, "\",\n");
    }
    try out.appendSlice(gpa,
        \\    };
        \\}
        \\
    );
    return out.items;
}

pub fn writeCatalog(gpa: mem.Allocator, translation: *const Translation) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(gpa, "CTLG");
    try chunk(gpa, &body, "FVER", &.{ translation.version_string, "\x00" });
    try chunk(gpa, &body, "LANG", &.{ translation.language, "\x00" });
    var set: [32]u8 = @splat(0);
    mem.writeInt(u32, set[0..4], 106, .big);
    try chunk(gpa, &body, "CSET", &.{&set});
    var strings: std.ArrayList(u8) = .empty;
    for (translation.strings) |string| {
        var head: [8]u8 = undefined;
        mem.writeInt(i32, head[0..4], string.id, .big);
        mem.writeInt(u32, head[4..8], @intCast(string.text.len + 1), .big);
        try strings.appendSlice(gpa, &head);
        try strings.appendSlice(gpa, string.text);
        try strings.append(gpa, 0);
        while (strings.items.len % 4 != 0) try strings.append(gpa, 0);
    }
    try chunk(gpa, &body, "STRS", &.{strings.items});
    var file: std.ArrayList(u8) = .empty;
    var head: [8]u8 = undefined;
    @memcpy(head[0..4], "FORM");
    mem.writeInt(u32, head[4..8], @intCast(body.items.len), .big);
    try file.appendSlice(gpa, &head);
    try file.appendSlice(gpa, body.items);
    return file.items;
}

fn chunk(gpa: mem.Allocator, into: *std.ArrayList(u8), id: *const [4]u8, parts: []const []const u8) !void {
    var length: usize = 0;
    for (parts) |part| length += part.len;
    var head: [8]u8 = undefined;
    @memcpy(head[0..4], id);
    mem.writeInt(u32, head[4..8], @intCast(length), .big);
    try into.appendSlice(gpa, &head);
    for (parts) |part| try into.appendSlice(gpa, part);
    if (length % 2 != 0) try into.append(gpa, 0);
}

// --- tests (host: zig build test in sdk/) ------------------------------------

const testing = std.testing;

const sample_cd =
    \\; The test program's strings.
    \\#version 2
    \\MSG_HELLO (1//)
    \\Hello, %s!\n
    \\MSG_FILES (//)
    \\%ld files in \
    \\%s
    \\MSG_SHORT (10/1/5)
    \\Short
    \\MSG_TAB (//)
    \\a\tb\x41\101\\
    \\
;

test "a descriptor: numbers counted on, lines joined, escapes undone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    const descriptor = try readDescriptor(arena.allocator(), sample_cd, &problem);
    try testing.expectEqual(@as(u32, 2), descriptor.version);
    try testing.expectEqualStrings("english", descriptor.language);
    try testing.expectEqual(@as(usize, 4), descriptor.messages.len);
    try testing.expectEqual(@as(i32, 1), descriptor.messages[0].id);
    try testing.expectEqualStrings("Hello, %s!\n", descriptor.messages[0].text);
    try testing.expectEqual(@as(i32, 2), descriptor.messages[1].id);
    try testing.expectEqualStrings("%ld files in %s", descriptor.messages[1].text);
    try testing.expectEqual(@as(i32, 10), descriptor.messages[2].id);
    try testing.expectEqual(@as(?usize, 5), descriptor.messages[2].most);
    try testing.expectEqual(@as(i32, 11), descriptor.messages[3].id);
    try testing.expectEqualStrings("a\tbAA\\", descriptor.messages[3].text);

    const module = try writeModule(arena.allocator(), &descriptor, "c/test/locale.catalog", "locale.cd");
    try testing.expect(mem.indexOf(u8, module, "pub const catalog_version = 2;") != null);
    try testing.expect(mem.indexOf(u8, module, "    MSG_FILES = 2,\n") != null);
    try testing.expect(mem.indexOf(u8, module, ".MSG_HELLO => \"Hello, %s!\\x0a\",") != null);
    try testing.expect(mem.indexOf(u8, module, ".MSG_TAB => \"a\\x09bAA\\x5c\",") != null);
}

test "a translation: checked against the descriptor, written as a CTLG file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var problem: Problem = .{};
    const descriptor = try readDescriptor(gpa, sample_cd, &problem);
    const ct =
        \\## version $VER: c/test/locale.catalog 2.1 (29.10.2026)
        \\## language deutsch
        \\## codeset 106
        \\MSG_FILES
        \\%2$s hat %1$ld Dateien
        \\MSG_HELLO
        \\Grüß dich, %s!\n
        \\MSG_SHORT
        \\
        \\
    ;
    const translation = try readTranslation(gpa, ct, &descriptor, &problem);
    try testing.expectEqualStrings("deutsch", translation.language);
    // Sorted by number; the empty one left out.
    try testing.expectEqual(@as(usize, 2), translation.strings.len);
    try testing.expectEqual(@as(i32, 1), translation.strings[0].id);
    try testing.expectEqualStrings("Gr\xC3\xBC\xC3\x9F dich, %s!\n", translation.strings[0].text);

    const file = try writeCatalog(gpa, &translation);
    try testing.expectEqualStrings("FORM", file[0..4]);
    try testing.expectEqual(@as(u32, @intCast(file.len - 8)), mem.readInt(u32, file[4..8], .big));
    try testing.expectEqualStrings("CTLGFVER", file[8..16]);
    const strs = mem.indexOf(u8, file, "STRS").?;
    try testing.expectEqual(@as(i32, 1), mem.readInt(i32, file[strs + 8 ..][0..4], .big));
    try testing.expectEqual(@as(u32, 18), mem.readInt(u32, file[strs + 12 ..][0..4], .big));
    try testing.expectEqual(@as(usize, 0), (file.len - strs - 8) % 4);

    // What is refused.
    const wrong_values = "## version $VER: x 2.0\n## language deutsch\nMSG_HELLO\nHallo, %ld!\n";
    try testing.expectError(error.Bad, readTranslation(gpa, wrong_values, &descriptor, &problem));
    try testing.expectEqualStrings("values not those of the string built in", problem.text);
    const unknown = "## version $VER: x 2.0\n## language deutsch\nMSG_NONE\nnichts\n";
    try testing.expectError(error.Bad, readTranslation(gpa, unknown, &descriptor, &problem));
    const old = "## version $VER: x 1.0\n## language deutsch\n";
    try testing.expectError(error.Bad, readTranslation(gpa, old, &descriptor, &problem));
    try testing.expectEqualStrings("a version that is not the descriptor's #version", problem.text);
    const too_long = "## version $VER: x 2.0\n## language deutsch\nMSG_SHORT\nZu lang hier\n";
    try testing.expectError(error.Bad, readTranslation(gpa, too_long, &descriptor, &problem));
    try testing.expectError(error.Bad, readDescriptor(gpa, "MSG_A (1//)\none\nMSG_B (1//)\ntwo\n", &problem));
    try testing.expectEqualStrings("a number given twice", problem.text);
}

test "a format's values: by place or in order, never both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try testing.expectEqualStrings("p84", try signature(gpa, "%s %ld %-5d %% %zx"[0..12]));
    try testing.expectEqualStrings("p84z", try signature(gpa, "%s %ld %-5d %% %zx"));
    try testing.expectEqualStrings("p8", try signature(gpa, "%2$ld %1$s"));
    try testing.expectError(error.Place, signature(gpa, "%2$s %d"));
}
