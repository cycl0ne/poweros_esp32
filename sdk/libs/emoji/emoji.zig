// SPDX-License-Identifier: MIT
//! The emoji a program offers to choose from, and what they are called:
//! the files of `LOCALE:Emoji` and how they are read.
//!
//! Two kinds of file, both UTF-8 text with a line feed after each line
//! and a tab between a line's fields:
//!
//! `LOCALE:Emoji/emoji.list` - every emoji, in the groups and the order
//! they are shown in.
//!
//!     emoji-list 1 <groups> <emoji>
//!     @<a group's name>
//!     <emoji>
//!     <emoji> <tab> <light> <tab> <medium-light> <tab> <medium> <tab> <medium-dark> <tab> <dark>
//!
//! The first line says how many groups and how many emoji follow. A line
//! starting with `@` opens a group, whose emoji are the lines up to the
//! next one. An emoji that is drawn in the skin tones has the five of
//! them after it, each written out whole: a program picks the field and
//! needs no rule for how a tone goes into a sequence. Where an emoji shows
//! several people, the five are the ones with all of them in one tone.
//!
//! `LOCALE:Emoji/<language>.names` - what the emoji are called in a
//! language, named as the locale names it (`deutsch`, `english`).
//!
//!     emoji-names 1 <names> <language>
//!     <emoji> <tab> <name> <tab> <keyword>|<keyword>|...
//!
//! One line for each emoji of the list that has a name in that language,
//! in the list's order; the keywords are further words it is found by,
//! and the field is missing where there are none. An emoji in a skin tone
//! goes by the name of the one without.
//!
//! A program reads a file into memory whole and walks it with `List` or
//! `Names`, which hand out slices of that memory and allocate nothing:
//!
//!     var list = emoji.List.open(bytes) orelse return; // not a list
//!     while (list.next()) |item| switch (item) {
//!         .group => |name| ...,
//!         .emoji => |one| ..., // one.text, one.toned(tone)
//!     };
//!
//! A file that does not start with its first line is refused; a line
//! further down that is not as described is passed by.

/// The list, and the drawer the names are in.
pub const LIST_FILE = "LOCALE:Emoji/emoji.list";
pub const DRAWER = "LOCALE:Emoji";
/// What a names file's name ends with, after the language.
pub const NAMES_SUFFIX = ".names";

/// The skin tones an emoji is listed in, the lightest first.
pub const TONES = 5;

const LIST_WORD = "emoji-list";
const NAMES_WORD = "emoji-names";
/// The form both files are in, the number after the first word.
const FORM = 1;

/// An emoji of the list.
pub const Emoji = struct {
    /// Its characters, as UTF-8.
    text: []const u8,
    /// The same in each skin tone, the lightest first; all empty for an
    /// emoji that has none.
    tones: [TONES][]const u8 = @splat(""),

    /// Whether it is drawn in the skin tones.
    pub fn hasTones(emoji: *const Emoji) bool {
        return emoji.tones[0].len != 0;
    }

    /// Its characters in skin tone `tone` (0 the lightest, `TONES - 1`
    /// the darkest), or as it is for null, for a tone there is none of
    /// and for an emoji without tones.
    pub fn toned(emoji: *const Emoji, tone: ?u32) []const u8 {
        const which = tone orelse return emoji.text;
        if (which >= TONES or emoji.tones[which].len == 0) return emoji.text;
        return emoji.tones[which];
    }
};

/// A line of the list: a group that begins, or an emoji of the group
/// begun last.
pub const Item = union(enum) {
    group: []const u8,
    emoji: Emoji,
};

/// The list file, walked from its start.
pub const List = struct {
    /// How many groups and emoji the file says it holds - what a program
    /// sizes its own tables by. `next` hands out what is there, which a
    /// damaged file may have less or more of.
    groups: u32,
    emoji: u32,
    rest: []const u8,

    /// The list in `bytes`, a whole file, or null when it is no list in
    /// this form.
    pub fn open(bytes: []const u8) ?List {
        var rest = bytes;
        var fields = Fields{ .rest = line(&rest) orelse return null, .between = ' ' };
        if (!same(fields.next() orelse return null, LIST_WORD)) return null;
        if ((number(fields.next() orelse return null) orelse return null) != FORM) return null;
        const groups = number(fields.next() orelse return null) orelse return null;
        const count = number(fields.next() orelse return null) orelse return null;
        return .{ .groups = groups, .emoji = count, .rest = rest };
    }

    /// The next line, or null at the end.
    pub fn next(list: *List) ?Item {
        while (line(&list.rest)) |text| {
            if (text.len == 0) continue;
            if (text[0] == '@') return .{ .group = text[1..] };
            var fields = Fields{ .rest = text, .between = '\t' };
            var found = Emoji{ .text = fields.next() orelse continue };
            if (found.text.len == 0) continue;
            var tones: [TONES][]const u8 = undefined;
            var have: u32 = 0;
            while (have < TONES) : (have += 1) {
                tones[have] = fields.next() orelse break;
                if (tones[have].len == 0) break;
            }
            if (have == TONES) found.tones = tones;
            return .{ .emoji = found };
        }
        return null;
    }
};

/// What an emoji is called.
pub const Name = struct {
    /// The emoji, as the list has it.
    emoji: []const u8,
    name: []const u8,
    /// The words it is found by besides, `|` between them; empty for
    /// none. `words` walks them.
    keywords: []const u8,

    pub fn words(name: *const Name) Fields {
        return .{ .rest = name.keywords, .between = '|' };
    }
};

/// A names file, walked from its start.
pub const Names = struct {
    /// How many names the file says it holds.
    count: u32,
    /// The language they are in, as the file says.
    language: []const u8,
    rest: []const u8,

    /// The names in `bytes`, a whole file, or null when it is no names
    /// file in this form.
    pub fn open(bytes: []const u8) ?Names {
        var rest = bytes;
        var fields = Fields{ .rest = line(&rest) orelse return null, .between = ' ' };
        if (!same(fields.next() orelse return null, NAMES_WORD)) return null;
        if ((number(fields.next() orelse return null) orelse return null) != FORM) return null;
        const count = number(fields.next() orelse return null) orelse return null;
        const language = fields.next() orelse return null;
        return .{ .count = count, .language = language, .rest = rest };
    }

    /// The next name, or null at the end.
    pub fn next(names: *Names) ?Name {
        while (line(&names.rest)) |text| {
            var fields = Fields{ .rest = text, .between = '\t' };
            const emoji = fields.next() orelse continue;
            const name = fields.next() orelse continue;
            if (emoji.len == 0 or name.len == 0) continue;
            return .{ .emoji = emoji, .name = name, .keywords = fields.next() orelse "" };
        }
        return null;
    }
};

/// The fields of a line, or the words of a `Name`'s keywords, one after
/// the other.
pub const Fields = struct {
    rest: ?[]const u8,
    between: u8,

    /// The next one, which may be empty, or null after the last.
    pub fn next(fields: *Fields) ?[]const u8 {
        const rest = fields.rest orelse return null;
        for (rest, 0..) |byte, at| {
            if (byte != fields.between) continue;
            fields.rest = rest[at + 1 ..];
            return rest[0..at];
        }
        fields.rest = null;
        return rest;
    }
};

/// The path of the names in `language` (`deutsch`), written into `buffer`
/// with its NUL, or null when it has not the room.
pub fn namesPath(buffer: []u8, language: []const u8) ?[*:0]const u8 {
    const parts = [_][]const u8{ DRAWER, "/", language, NAMES_SUFFIX };
    var length: usize = 0;
    for (parts) |part| {
        if (length + part.len >= buffer.len) return null;
        @memcpy(buffer[length .. length + part.len], part);
        length += part.len;
    }
    buffer[length] = 0;
    return @ptrCast(buffer.ptr);
}

/// The line `rest` starts with, without its line feed, `rest` moved past
/// it; null when nothing is left.
fn line(rest: *[]const u8) ?[]const u8 {
    const text = rest.*;
    if (text.len == 0) return null;
    for (text, 0..) |byte, at| {
        if (byte != '\n') continue;
        rest.* = text[at + 1 ..];
        return text[0..at];
    }
    rest.* = text[text.len..];
    return text;
}

fn same(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |one, other| {
        if (one != other) return false;
    }
    return true;
}

/// A decimal number of up to nine digits, or null for anything else.
fn number(digits: []const u8) ?u32 {
    if (digits.len == 0 or digits.len > 9) return null;
    var value: u32 = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return null;
        value = value * 10 + (digit - '0');
    }
    return value;
}
