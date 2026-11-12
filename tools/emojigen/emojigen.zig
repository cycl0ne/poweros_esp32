// SPDX-License-Identifier: MPL-2.0
//! emojigen: the emoji list and its names in the disk's languages
//! (`LOCALE:Emoji`), from Unicode's `emoji-test.txt` and the CLDR's
//! annotation files, as scripts/fetch-emoji.sh fetched them.
//!
//! usage: emojigen <emoji-test.txt> <out dir>
//!                 [--language=<name> <annotations.xml>...]...
//!
//! Writes `<out dir>/emoji.list` and, for each language, `<out
//! dir>/<name>.names`, in the forms `sdk/libs/emoji/emoji.zig` describes
//! and reads; what was written is read back with that reader, and a count
//! that does not come out as written fails the build.
//!
//! The list is the file's fully-qualified emoji, in its groups and its
//! order, without the group of components (the tones and hair styles by
//! themselves). An emoji with skin tones in it is no entry of its own: it
//! is the tone of the entry it becomes when the tones are taken out, and
//! only where every person in it has the same tone - the mixed pairs are
//! left out. An entry that did not get all five tones this way has none.
//!
//! A language's names come from its annotation files in the order given:
//! a later file's entry replaces an earlier one's, and an entry that only
//! says "as the parent has it" (`↑↑↑`) leaves it. So a language that
//! inherits is given its parent's files first. The files leave U+FE0F out
//! of their keys, so an emoji is looked up without its own. A keyword
//! that is the name again is dropped.

const std = @import("std");
const sdk = @import("sdk");

const Allocator = std.mem.Allocator;

const FIRST_TONE = 0x1F3FB;
const LAST_TONE = 0x1F3FF;
const VARIATION_SELECTOR = 0xFE0F;
const INHERIT = "↑↑↑";

const Entry = struct {
    /// The emoji as UTF-8, and the same without U+FE0F: what the tones
    /// and the names find it by.
    text: []const u8,
    key: []const u8,
    tones: [sdk.emoji.TONES]?[]const u8 = @splat(null),
    /// The group it is the first of, which its line follows.
    opens: ?[]const u8 = null,
};

const List = struct {
    entries: []Entry,
    groups: u32,
    text: []u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: emojigen <emoji-test.txt> <out dir> [--language=<name> <annotations.xml>...]...\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const list = try makeList(arena, try cwd.readFileAlloc(io, args[1], arena, .unlimited));
    try checkList(list);
    try cwd.createDirPath(io, args[2]);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ args[2], "emoji.list" }), .data = list.text });

    var at: usize = 3;
    while (at < args.len) {
        const prefix = "--language=";
        if (!std.mem.startsWith(u8, args[at], prefix)) {
            std.debug.print("emojigen: {s}: a file before any --language=\n", .{args[at]});
            std.process.exit(2);
        }
        const language = args[at][prefix.len..];
        at += 1;
        var found: Annotations = .empty;
        while (at < args.len and !std.mem.startsWith(u8, args[at], prefix)) : (at += 1) {
            try readAnnotations(arena, &found, try cwd.readFileAlloc(io, args[at], arena, .unlimited));
        }
        const names = try makeNames(arena, list.entries, language, &found);
        try checkNames(names, language);
        const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ language, sdk.emoji.NAMES_SUFFIX });
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ args[2], file }), .data = names });
    }
}

/// The list file made of `emoji-test.txt`.
fn makeList(arena: Allocator, source: []const u8) !List {
    var entries: std.ArrayList(Entry) = .empty;
    var by_key: std.StringHashMapUnmanaged(usize) = .empty;
    var groups: u32 = 0;
    var group: ?[]const u8 = null;
    var opened = false;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const group_prefix = "# group: ";
        if (std.mem.startsWith(u8, line, group_prefix)) {
            const name = std.mem.trim(u8, line[group_prefix.len..], " \r");
            group = if (std.mem.eql(u8, name, "Component")) null else name;
            opened = false;
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        if (hash < semicolon) continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[semicolon + 1 .. hash], " "), "fully-qualified")) continue;
        const name = group orelse continue;

        var text: std.ArrayList(u8) = .empty;
        var key: std.ArrayList(u8) = .empty;
        var tone: ?u32 = null;
        var mixed = false;
        var points = std.mem.tokenizeScalar(u8, line[0..semicolon], ' ');
        while (points.next()) |digits| {
            const point = try std.fmt.parseInt(u21, digits, 16);
            try appendPoint(arena, &text, point);
            if (point >= FIRST_TONE and point <= LAST_TONE) {
                const which = point - FIRST_TONE;
                if (tone) |before| mixed = mixed or before != which;
                tone = which;
            } else if (point != VARIATION_SELECTOR) {
                try appendPoint(arena, &key, point);
            }
        }
        if (tone) |which| {
            if (mixed) continue;
            const entry = &entries.items[by_key.get(key.items) orelse continue];
            if (entry.tones[which] == null) entry.tones[which] = text.items;
            continue;
        }
        if (by_key.contains(key.items)) return error.EmojiListedTwice;
        try by_key.put(arena, key.items, entries.items.len);
        try entries.append(arena, .{ .text = text.items, .key = key.items, .opens = if (opened) null else name });
        if (!opened) groups += 1;
        opened = true;
    }

    var body: std.ArrayList(u8) = .empty;
    for (entries.items) |*entry| {
        if (entry.opens) |name| try body.print(arena, "@{s}\n", .{name});
        try body.appendSlice(arena, entry.text);
        var whole = true;
        for (entry.tones) |one| whole = whole and one != null;
        if (!whole) entry.tones = @splat(null);
        for (entry.tones) |one| try body.print(arena, "\t{s}", .{one orelse break});
        try body.append(arena, '\n');
    }
    const text = try std.fmt.allocPrint(arena, "emoji-list 1 {d} {d}\n{s}", .{ groups, entries.items.len, body.items });
    return .{ .entries = entries.items, .groups = groups, .text = text };
}

fn appendPoint(arena: Allocator, text: *std.ArrayList(u8), point: u21) !void {
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(point, &bytes);
    try text.appendSlice(arena, bytes[0..length]);
}

const Annotation = struct {
    name: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
};

const Annotations = std.StringHashMapUnmanaged(Annotation);

/// The entries of one annotation file into `found`, over what is there.
fn readAnnotations(arena: Allocator, found: *Annotations, xml: []const u8) !void {
    const open = "<annotation ";
    const close = "</annotation>";
    var rest = xml;
    while (std.mem.indexOf(u8, rest, open)) |start| {
        const tag_end = std.mem.indexOfScalarPos(u8, rest, start, '>') orelse return error.BrokenAnnotations;
        const end = std.mem.indexOfPos(u8, rest, tag_end, close) orelse return error.BrokenAnnotations;
        const attributes = rest[start + open.len .. tag_end];
        const content = try unescaped(arena, rest[tag_end + 1 .. end]);
        rest = rest[end + close.len ..];
        if (std.mem.eql(u8, content, INHERIT)) continue;
        const cp = try unescaped(arena, attribute(attributes, "cp") orelse return error.BrokenAnnotations);
        var key: std.ArrayList(u8) = .empty;
        var view = try std.unicode.Utf8View.init(cp);
        var points = view.iterator();
        while (points.nextCodepoint()) |point| {
            if (point != VARIATION_SELECTOR) try appendPoint(arena, &key, point);
        }
        const slot = try found.getOrPut(arena, key.items);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        if (attribute(attributes, "type")) |kind| {
            if (std.mem.eql(u8, kind, "tts")) slot.value_ptr.name = content;
        } else slot.value_ptr.keywords = content;
    }
}

/// The value of attribute `name` in a tag's inside, still escaped.
fn attribute(attributes: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, attributes, at, name)) |found| {
        at = found + name.len;
        if (found != 0 and attributes[found - 1] != ' ') continue;
        if (!std.mem.startsWith(u8, attributes[at..], "=\"")) continue;
        const end = std.mem.indexOfScalarPos(u8, attributes, at + 2, '"') orelse return null;
        return attributes[at + 2 .. end];
    }
    return null;
}

/// XML's text with its entities written out, and with a tab or a line
/// end - which a line of the names file is cut at - made a space.
fn unescaped(arena: Allocator, text: []const u8) ![]const u8 {
    const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    next: while (at < text.len) {
        if (text[at] == '&') {
            for (entities) |entity| {
                if (!std.mem.startsWith(u8, text[at..], entity[0])) continue;
                try out.append(arena, entity[1]);
                at += entity[0].len;
                continue :next;
            }
            if (std.mem.startsWith(u8, text[at..], "&#x")) {
                const end = std.mem.indexOfScalarPos(u8, text, at, ';') orelse return error.BrokenAnnotations;
                try appendPoint(arena, &out, try std.fmt.parseInt(u21, text[at + 3 .. end], 16));
                at = end + 1;
                continue;
            }
            return error.BrokenAnnotations;
        }
        try out.append(arena, switch (text[at]) {
            '\t', '\n', '\r' => ' ',
            else => |byte| byte,
        });
        at += 1;
    }
    return out.items;
}

/// The names file of `language` for the list's entries.
fn makeNames(arena: Allocator, entries: []const Entry, language: []const u8, found: *const Annotations) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var count: u32 = 0;
    for (entries) |entry| {
        const annotation = found.get(entry.key) orelse continue;
        const name = std.mem.trim(u8, annotation.name orelse continue, " ");
        if (name.len == 0) continue;
        count += 1;
        try body.print(arena, "{s}\t{s}", .{ entry.text, name });
        var first = true;
        var words = std.mem.tokenizeScalar(u8, annotation.keywords orelse "", '|');
        while (words.next()) |raw| {
            const word = std.mem.trim(u8, raw, " ");
            if (word.len == 0 or std.mem.eql(u8, word, name)) continue;
            try body.append(arena, if (first) '\t' else '|');
            try body.appendSlice(arena, word);
            first = false;
        }
        try body.append(arena, '\n');
    }
    return std.fmt.allocPrint(arena, "emoji-names 1 {d} {s}\n{s}", .{ count, language, body.items });
}

/// The list read back: as many groups and emoji as it says, each the
/// entry it was made from.
fn checkList(list: List) !void {
    var read = sdk.emoji.List.open(list.text) orelse return error.ListNotRead;
    if (read.groups != list.groups or read.emoji != list.entries.len) return error.ListNotRead;
    var groups: u32 = 0;
    var index: usize = 0;
    while (read.next()) |item| switch (item) {
        .group => groups += 1,
        .emoji => |one| {
            if (index >= list.entries.len) return error.ListNotRead;
            const entry = list.entries[index];
            if (!std.mem.eql(u8, one.text, entry.text)) return error.ListNotRead;
            if (one.hasTones() != (entry.tones[0] != null)) return error.ListNotRead;
            for (entry.tones, 0..) |tone, which| {
                if (!std.mem.eql(u8, one.toned(@intCast(which)), tone orelse entry.text)) return error.ListNotRead;
            }
            index += 1;
        },
    };
    if (groups != list.groups or index != list.entries.len) return error.ListNotRead;
}

/// A names file read back: its language, and as many names as it says.
fn checkNames(text: []const u8, language: []const u8) !void {
    var read = sdk.emoji.Names.open(text) orelse return error.NamesNotRead;
    if (!std.mem.eql(u8, read.language, language)) return error.NamesNotRead;
    var count: u32 = 0;
    while (read.next()) |_| count += 1;
    if (count != read.count) return error.NamesNotRead;
}

const test_list =
    \\# group: Smileys & Emotion
    \\
    \\# subgroup: face-smiling
    \\1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
    \\263A FE0F                                              ; fully-qualified     # ☺️ E0.6 smiling face
    \\263A                                                   ; unqualified         # ☺ E0.6 smiling face
    \\
    \\# group: People & Body
    \\261D FE0F                                              ; fully-qualified     # ☝️ E0.6 index pointing up
    \\261D 1F3FB                                             ; fully-qualified     # ☝🏻 E1.0 index pointing up: light skin tone
    \\261D 1F3FC                                             ; fully-qualified     # ☝🏼 E1.0 index pointing up: medium-light skin tone
    \\261D 1F3FD                                             ; fully-qualified     # ☝🏽 E1.0 index pointing up: medium skin tone
    \\261D 1F3FE                                             ; fully-qualified     # ☝🏾 E1.0 index pointing up: medium-dark skin tone
    \\261D 1F3FF                                             ; fully-qualified     # ☝🏿 E1.0 index pointing up: dark skin tone
    \\1F9D1 200D 1F91D 200D 1F9D1                            ; fully-qualified     # 🧑‍🤝‍🧑 E12.0 people holding hands
    \\1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FB                ; fully-qualified     # 🧑🏻‍🤝‍🧑🏻 E12.0 people holding hands: light skin tone
    \\1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FC                ; fully-qualified     # 🧑🏻‍🤝‍🧑🏼 E12.1 people holding hands: light skin tone, medium-light skin tone
    \\
    \\# group: Component
    \\1F3FB                                                  ; fully-qualified     # 🏻 E1.0 light skin tone
    \\1F9B0                                                  ; fully-qualified     # 🦰 E11.0 red hair
    \\
    \\# group: Flags
    \\1F1E9 1F1EA                                            ; fully-qualified     # 🇩🇪 E0.6 flag: Germany
    \\
;

const test_annotations =
    \\<ldml>
    \\  <annotations>
    \\    <annotation cp="😀">Gesicht | grinsendes Gesicht | lol</annotation>
    \\    <annotation cp="😀" type="tts">grinsendes Gesicht</annotation>
    \\    <annotation cp="☺">Gesicht &amp; mehr | lächeln</annotation>
    \\    <annotation cp="☺" type="tts">lächelndes Gesicht</annotation>
    \\    <annotation cp="☝">nach oben</annotation>
    \\    <annotation cp="🇩🇪" type="tts">Flagge: Deutschland</annotation>
    \\  </annotations>
    \\</ldml>
;

test "the list: groups, order, an emoji's five tones, no components and no mixed pairs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try makeList(arena_state.allocator(), test_list);
    try checkList(list);
    try std.testing.expectEqualStrings("emoji-list 1 3 5\n" ++
        "@Smileys & Emotion\n" ++
        "\u{1F600}\n" ++
        "\u{263A}\u{FE0F}\n" ++
        "@People & Body\n" ++
        "\u{261D}\u{FE0F}\t\u{261D}\u{1F3FB}\t\u{261D}\u{1F3FC}\t\u{261D}\u{1F3FD}\t\u{261D}\u{1F3FE}\t\u{261D}\u{1F3FF}\n" ++
        // One tone of five listed: none.
        "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\n" ++
        "@Flags\n" ++
        "\u{1F1E9}\u{1F1EA}\n", list.text);
}

test "the names: found without U+FE0F, the name's own keyword dropped, a later file over an earlier one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try makeList(arena, test_list);
    var found: Annotations = .empty;
    try readAnnotations(arena, &found, test_annotations);
    try readAnnotations(arena, &found,
        \\<annotation cp="😀" type="tts">↑↑↑</annotation>
        \\<annotation cp="☺" type="tts">Lächeln</annotation>
    );
    const names = try makeNames(arena, list.entries, "deutsch", &found);
    try checkNames(names, "deutsch");
    try std.testing.expectEqualStrings("emoji-names 1 3 deutsch\n" ++
        "\u{1F600}\tgrinsendes Gesicht\tGesicht|lol\n" ++
        "\u{263A}\u{FE0F}\tLächeln\tGesicht & mehr|lächeln\n" ++
        // Keywords without a name: no line. A name without keywords:
        // no third field.
        "\u{1F1E9}\u{1F1EA}\tFlagge: Deutschland\n", names);
}
