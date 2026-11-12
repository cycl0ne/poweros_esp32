// SPDX-License-Identifier: MIT
//! What the Emoji window shows, without the window: the emoji of
//! `LOCALE:Emoji` in a book, the ones a search finds, the ones used last
//! with the file they are kept in, and where the cells of the grid are.
//!
//! **The book** is the list file's emoji in its order, each with its name
//! and the words it is found by, and the groups as runs of that order.
//! Nothing is copied: an entry's text, name and words are slices of the
//! two files, which stay in memory for as long as the book is used.
//!
//! **A search** is the words typed, a space between them. An emoji is
//! found when each word is part of its name or of one of the words it is
//! found by, upper and lower case being the same.
//!
//! **The ones used last** are kept the newest first, each once, and
//! written with the skin tone chosen:
//!
//!     emoji-used 1 <tone>
//!     <emoji>
//!     ...
//!
//! `<tone>` is 0 for none, 1 the lightest to 5 the darkest. An emoji is
//! written as the list has it, without a tone; one the list no longer
//! has is passed by when the file is read.

const sdk = @import("sdk");
const emoji = sdk.emoji;
const utf8 = sdk.utility.utf8;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The groups the book holds; a list with more has the rest in the last.
pub const MOST_GROUPS = 15;
/// How many of the emoji used last are kept.
pub const MOST_USED = 40;
/// The words of a search, and the letters of each, that count.
pub const MOST_WORDS = 4;
pub const MOST_LETTERS = 24;

/// Where the ones used last are in force, and where they are kept.
pub const USED_ENV = "ENV:Sys/emoji.used";
pub const USED_ENVARC = "ENVARC:Sys/emoji.used";
/// The most the file is long.
pub const USED_ROOM = 24 + MOST_USED * 48;

const USED_WORD = "emoji-used";
const USED_FORM = 1;

/// An emoji of the book.
pub const Entry = struct {
    emoji: emoji.Emoji,
    /// What it is called, and the words it is found by besides (`|`
    /// between them); empty without a name in the language.
    name: []const u8 = "",
    keywords: []const u8 = "",
};

/// A group: `count` entries of the book from `first` on.
pub const Group = struct {
    name: []const u8 = "",
    first: u32 = 0,
    count: u32 = 0,
};

pub const Book = struct {
    /// Room for the entries, the caller's: as many as the list says it
    /// holds (`emoji.List.emoji`). `count` of them are filled.
    entries: []Entry,
    count: u32 = 0,
    groups: [MOST_GROUPS]Group = @splat(.{}),
    group_count: u32 = 0,

    /// The list in `bytes` taken in; false when it is no list. Emoji
    /// past the room there is are left out.
    pub fn read(book: *Book, bytes: []const u8) bool {
        var list = emoji.List.open(bytes) orelse return false;
        book.count = 0;
        book.group_count = 0;
        while (list.next()) |item| switch (item) {
            .group => |title| {
                if (book.group_count == MOST_GROUPS) continue;
                book.groups[book.group_count] = .{ .name = title, .first = book.count };
                book.group_count += 1;
            },
            .emoji => |one| {
                if (book.count == book.entries.len) break;
                // An emoji before any group's line is in a group without
                // a name.
                if (book.group_count == 0) {
                    book.groups[0] = .{};
                    book.group_count = 1;
                }
                book.entries[book.count] = .{ .emoji = one };
                book.count += 1;
                book.groups[book.group_count - 1].count += 1;
            },
        };
        return true;
    }

    /// The names in `bytes` given to the entries that have none yet; how
    /// many were. The names are in the list's order, so each is looked
    /// for from the one before on.
    pub fn name(book: *Book, bytes: []const u8) u32 {
        var names = emoji.Names.open(bytes) orelse return 0;
        var given: u32 = 0;
        var from: u32 = 0;
        while (names.next()) |one| {
            var at = from;
            while (at < book.count and !same(book.entries[at].emoji.text, one.emoji)) at += 1;
            if (at == book.count) continue;
            from = at + 1;
            const entry = &book.entries[at];
            if (entry.name.len != 0) continue;
            entry.name = one.name;
            entry.keywords = one.keywords;
            given += 1;
        }
        return given;
    }

    /// The entry whose emoji is `text`, or null.
    pub fn find(book: *const Book, text: []const u8) ?u32 {
        for (book.entries[0..book.count], 0..) |*entry, at| {
            if (same(entry.emoji.text, text)) return @intCast(at);
        }
        return null;
    }

    /// The entries of group `which` into `into`; how many.
    pub fn group(book: *const Book, which: u32, into: []u32) u32 {
        if (which >= book.group_count) return 0;
        const run = book.groups[which];
        const count: u32 = @intCast(@min(run.count, into.len));
        for (into[0..count], 0..) |*slot, at| slot.* = run.first + @as(u32, @intCast(at));
        return count;
    }

    /// The entries `query` finds into `into`, in the book's order; how
    /// many.
    pub fn search(book: *const Book, ub: *UtilityBase, query: *const Query, into: []u32) u32 {
        var count: u32 = 0;
        for (book.entries[0..book.count], 0..) |*entry, at| {
            if (count == into.len) break;
            if (!query.finds(ub, entry)) continue;
            into[count] = @intCast(at);
            count += 1;
        }
        return count;
    }
};

/// The words of a search, in lower case.
pub const Query = struct {
    words: [MOST_WORDS][MOST_LETTERS]u32 = undefined,
    lengths: [MOST_WORDS]u32 = @splat(0),
    count: u32 = 0,

    /// The words of `text`, spaces between them. Words past
    /// `MOST_WORDS` and letters past `MOST_LETTERS` do not count.
    pub fn init(ub: *UtilityBase, text: []const u8) Query {
        var query: Query = .{};
        var at: usize = 0;
        var open = false;
        while (at < text.len) {
            const got = utf8.read(text[at..]);
            at += got.length;
            if (got.char == ' ') {
                open = false;
                continue;
            }
            if (!open) {
                if (query.count == MOST_WORDS) break;
                query.count += 1;
                open = true;
            }
            const word = query.count - 1;
            if (query.lengths[word] == MOST_LETTERS) continue;
            query.words[word][query.lengths[word]] = lower(ub, got.char);
            query.lengths[word] += 1;
        }
        return query;
    }

    /// Whether nothing is asked for.
    pub fn empty(query: *const Query) bool {
        return query.count == 0;
    }

    /// Whether every word is part of `entry`'s name or of the words it
    /// is found by. No words find nothing.
    pub fn finds(query: *const Query, ub: *UtilityBase, entry: *const Entry) bool {
        if (query.count == 0) return false;
        for (query.words[0..query.count], query.lengths[0..query.count]) |*word, length| {
            const letters = word[0..length];
            if (!holds(ub, entry.name, letters) and !holds(ub, entry.keywords, letters)) return false;
        }
        return true;
    }
};

/// The emoji used last, the newest first, and the skin tone chosen.
pub const Used = struct {
    /// Entries of the book.
    items: [MOST_USED]u32 = undefined,
    count: u32 = 0,
    /// 0 the lightest to `emoji.TONES - 1`, or null for none.
    tone: ?u32 = null,

    /// `entry` put first; false when it was first already.
    pub fn use(used: *Used, entry: u32) bool {
        if (used.count != 0 and used.items[0] == entry) return false;
        var at: u32 = 0;
        while (at < used.count and used.items[at] != entry) at += 1;
        // Not among them: the oldest goes when there is no room.
        if (at == used.count) {
            if (used.count < MOST_USED) used.count += 1;
            at = used.count - 1;
        }
        while (at > 0) : (at -= 1) used.items[at] = used.items[at - 1];
        used.items[0] = entry;
        return true;
    }

    /// The file in `bytes` taken in, its emoji looked up in `book`;
    /// false, and nothing changed, when it is no such file.
    pub fn read(used: *Used, book: *const Book, bytes: []const u8) bool {
        var lines = emoji.Fields{ .rest = bytes, .between = '\n' };
        var head = emoji.Fields{ .rest = lines.next() orelse return false, .between = ' ' };
        if (!same(head.next() orelse return false, USED_WORD)) return false;
        if ((digit(head.next() orelse return false) orelse return false) != USED_FORM) return false;
        const tone = digit(head.next() orelse return false) orelse return false;
        if (tone > emoji.TONES) return false;
        used.tone = if (tone == 0) null else tone - 1;
        used.count = 0;
        while (lines.next()) |text| {
            if (used.count == MOST_USED) break;
            if (text.len == 0) continue;
            const entry = book.find(text) orelse continue;
            if (among(used.items[0..used.count], entry)) continue;
            used.items[used.count] = entry;
            used.count += 1;
        }
        return true;
    }

    /// The file written into `into`; how many bytes. What does not fit
    /// is left out.
    pub fn write(used: *const Used, book: *const Book, into: []u8) usize {
        var at: usize = 0;
        const tone: u8 = if (used.tone) |which| @intCast(which + 1) else 0;
        const head = USED_WORD ++ " 1 ";
        if (into.len < head.len + 2) return 0;
        @memcpy(into[0..head.len], head);
        into[head.len] = '0' + tone;
        into[head.len + 1] = '\n';
        at = head.len + 2;
        for (used.items[0..used.count]) |entry| {
            const text = book.entries[entry].emoji.text;
            if (at + text.len + 1 > into.len) break;
            @memcpy(into[at .. at + text.len], text);
            into[at + text.len] = '\n';
            at += text.len + 1;
        }
        return at;
    }
};

/// The grid: square cells in rows from the top left of a box.
pub const Grid = struct {
    /// A cell's side in pixels.
    cell: u32,
    /// Cells across, at least one.
    columns: u32,
    /// Whole rows the box shows, at least one.
    rows: u32,
    /// Rows the box shows any part of.
    drawn: u32,

    pub fn init(width: u32, height: u32, cell: u32) Grid {
        const side = @max(cell, 1);
        return .{
            .cell = side,
            .columns = @max(width / side, 1),
            .rows = @max(height / side, 1),
            .drawn = @max((height + side - 1) / side, 1),
        };
    }

    /// The rows `count` cells make.
    pub fn lines(grid: *const Grid, count: u32) u32 {
        return (count + grid.columns - 1) / grid.columns;
    }

    /// The highest row that can be the top one with `count` cells.
    pub fn lastTop(grid: *const Grid, count: u32) u32 {
        const all = grid.lines(count);
        return if (all > grid.rows) all - grid.rows else 0;
    }

    /// The cell at a place in the box, row `top` being the first shown;
    /// null beside the columns, outside the box and past the last of
    /// `count` cells.
    pub fn at(grid: *const Grid, x: i32, y: i32, top: u32, count: u32) ?u32 {
        if (x < 0 or y < 0) return null;
        const column = @as(u32, @intCast(x)) / grid.cell;
        const row = @as(u32, @intCast(y)) / grid.cell;
        if (column >= grid.columns or row >= grid.drawn) return null;
        const which = (top + row) * grid.columns + column;
        return if (which < count) which else null;
    }

    /// Where cell `which` is in the box, or null when its row is not
    /// shown.
    pub fn place(grid: *const Grid, which: u32, top: u32) ?Place {
        const row = which / grid.columns;
        if (row < top or row - top >= grid.drawn) return null;
        return .{
            .x = @intCast((which % grid.columns) * grid.cell),
            .y = @intCast((row - top) * grid.cell),
        };
    }
};

/// A cell's top left corner.
pub const Place = struct { x: i32, y: i32 };

/// The lower case of a character: the letters of ASCII here, the rest by
/// utility.library.
fn lower(ub: *UtilityBase, char: u32) u32 {
    if (char < 0x80) return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
    return ub.ToLower(char);
}

/// Whether `text` holds `letters`, lower case characters, anywhere in
/// it, its own taken in lower case.
fn holds(ub: *UtilityBase, text: []const u8, letters: []const u32) bool {
    if (letters.len == 0) return true;
    var start: usize = 0;
    while (start < text.len) {
        const first = utf8.read(text[start..]);
        if (lower(ub, first.char) == letters[0]) {
            var at = start + first.length;
            var matched: usize = 1;
            while (matched < letters.len and at < text.len) : (matched += 1) {
                const got = utf8.read(text[at..]);
                if (lower(ub, got.char) != letters[matched]) break;
                at += got.length;
            }
            if (matched == letters.len) return true;
        }
        start += first.length;
    }
    return false;
}

fn same(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |one, other| {
        if (one != other) return false;
    }
    return true;
}

fn among(items: []const u32, entry: u32) bool {
    for (items) |item| {
        if (item == entry) return true;
    }
    return false;
}

/// One decimal digit's value, or null for anything else.
fn digit(text: []const u8) ?u32 {
    if (text.len != 1 or text[0] < '0' or text[0] > '9') return null;
    return text[0] - '0';
}
