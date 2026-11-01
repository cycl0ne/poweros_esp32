// SPDX-License-Identifier: MIT
//! A manifest: what a tree of files holds, each file's length and the sum
//! of its bytes. One list says what a release package is, what an
//! installed system was given, and what the two differ in - so there is
//! one format, written here and read here, by the build's tools on the
//! host and by `Install` and `Update` on the machine.
//!
//! A settings line, then a line for each drawer and file:
//!
//!     # ... the explanation (`preamble`), passed over as a comment
//!     FORMAT=1 CHIP=rv64sbi BOARD=visionfive2 DRAWERS=48 FILES=511 BYTES=11793248
//!     drawer system/WBStartup
//!     7f3a21b0 5120 system/C/List
//!
//! - **FORMAT** is this file's number (`format_now`). A manifest with a
//!   higher one is refused rather than read as well as can be: a field
//!   whose meaning a reader does not know may be the one that says where
//!   a file goes. A key the reader does not know is passed over, so a
//!   field that only adds to what is there needs no new number.
//! - **CHIP** is the chip the files are built for, and the reason the
//!   header is not optional: every machine's package has the same paths
//!   in it, so without the chip an update would quietly write another
//!   machine's programs and kernel over a working system.
//! - **BOARD** is the board the kernel in it was built for, which only a
//!   package with a kernel says. Two boards share a chip - and share
//!   every path in the package - while their kernels differ in what the
//!   board has and where it is, so the chip alone does not say whether a
//!   kernel belongs on this machine.
//! - **DRAWERS**, **FILES** and **BYTES** are what follows: the lines of
//!   each kind, and the file sizes added up. A reader that counts
//!   something else refuses the manifest, which is what catches a body
//!   that was cut short - a fetch that ended early, a disk that filled.
//!   Without that check the missing lines read as "the build dropped
//!   these files", and an update would delete them.
//!
//! A path is relative, with `/` between its parts, and in a package it
//! begins with the half it is in (`install.zig`: `system/`, `boot/`). An
//! absolute path, a device name, `.`, `..` and control characters are
//! refused: the lines come from a server over the network, and they name
//! files a machine is about to write.
//!
//! **The order is the format's, not a convenience.** Entries are sorted by
//! path, letters as if upper case, which is how the file systems compare
//! names - so two manifests are compared by walking both at once, with
//! nothing held in memory but the two lines in hand. A reader refuses a
//! line that is not after the one before it, and refuses a path twice.
//! Sorted this way a drawer comes before everything in it (`/` sorts
//! below the letters and digits), so the entries are also the order to
//! make them in; what is deleted is walked backwards.
//!
//! Nothing here reads a file or sums one: a CRC-32 comes from the host's
//! own code on one side and compression.library on the other, and this
//! writes down and reads back what they answer. Whether two manifests are
//! the same package is their text compared, which is why the lines are
//! sorted and the preamble is fixed.

const Chip = @import("../../hardware/hardware.zig").Chip;
const prefs = @import("../prefs/prefs.zig");
const style = @import("../prefs/style.zig");

/// The format this writes, and the highest it reads.
pub const format_now: u32 = 1;

/// What a manifest may not say.
pub const Error = error{
    /// Its first line with words in it is not a settings line with
    /// FORMAT and CHIP in it.
    NotManifest,
    /// FORMAT says a number past `format_now`: written by a newer system.
    Format,
    /// A settings line whose key is known and whose value is not a value
    /// for it, or a chip with no such name.
    BadHeader,
    /// A line that is neither a drawer nor a file.
    BadLine,
    /// A path a manifest may not name.
    BadPath,
    /// A path that is not after the one in front of it, or one that is in
    /// the manifest twice.
    OutOfOrder,
    /// The last line has no end, or there is less than the header says:
    /// what was read is part of a manifest, not one.
    Truncated,
    /// More entries than the header says, or sizes that add up to
    /// something else.
    Counts,
};

/// What is wrong, as a line to print.
pub fn why(err: Error) [*:0]const u8 {
    return switch (err) {
        error.NotManifest => "not a manifest: its first line says no FORMAT and no CHIP",
        error.Format => "written by a newer system: its FORMAT is one this cannot read",
        error.BadHeader => "its first line has a setting with no value of that kind",
        error.BadLine => "a line is neither a drawer nor a file",
        error.BadPath => "a line names a path a manifest may not name",
        error.OutOfOrder => "a path is not after the one in front of it, or is in it twice",
        error.Truncated => "it ends in the middle: less than its first line says",
        error.Counts => "it holds more than its first line says",
    };
}

/// A drawer, or a file with its sum and its length.
pub const Kind = enum { drawer, file };

/// The word a drawer's line begins with.
pub const drawer_word = "drawer";

/// One line: a drawer to make, or a file with the CRC-32 of its bytes and
/// how many there are. `path` is in the manifest's own text, which the
/// caller keeps while it uses the entry.
pub const Entry = struct {
    kind: Kind,
    path: []const u8,
    /// The CRC-32 of the file's bytes; 0 for a drawer.
    crc: u32 = 0,
    /// The file's length; 0 for a drawer.
    size: u64 = 0,
};

/// What a manifest holds, which its first line says and a reader counts
/// again as it goes.
pub const Counts = struct {
    drawers: u32 = 0,
    files: u32 = 0,
    /// The files' lengths, added up.
    bytes: u64 = 0,

    /// `entry` counted.
    pub fn add(counts: *Counts, entry: Entry) void {
        switch (entry.kind) {
            .drawer => counts.drawers += 1,
            .file => {
                counts.files += 1;
                counts.bytes += entry.size;
            },
        }
    }

    pub fn same(counts: Counts, other: Counts) bool {
        return counts.drawers == other.drawers and counts.files == other.files and counts.bytes == other.bytes;
    }
};

/// The settings line: what the manifest is, and what follows it.
pub const Header = struct {
    /// The chip the files in it are built for.
    chip: Chip,
    /// The board the kernel in it was built for, empty where the manifest
    /// names none (`max_board`, `boardOk`). It is in the manifest's own
    /// text, as a path is.
    board: []const u8 = &.{},
    /// The lines that follow, which a reader checks against what it reads.
    counts: Counts = .{},
    /// The format the manifest was written in; `format_now` in one this
    /// writes.
    format: u32 = format_now,
};

/// The manifest read a line at a time. `init` takes the settings line and
/// `next` each entry after it; the counts are checked when the last line
/// is read, so a loop over `next` has looked at the whole manifest by the
/// time it ends:
///
///     var reader = try manifest.Reader.init(text);
///     while (try reader.next()) |entry| { ... }
pub const Reader = struct {
    header: Header,
    /// What has been read so far; `header.counts` when `next` has
    /// answered null.
    seen: Counts = .{},
    lines: prefs.Lines,
    /// The path of the line before, to keep the order.
    previous: []const u8 = &.{},
    ended: bool = false,

    /// The settings line read; `Reader` or what is wrong with it.
    pub fn init(text: []const u8) Error!Reader {
        // A manifest's last line ends like every other: one that does not
        // is a file that stops in the middle.
        if (text.len != 0 and text[text.len - 1] != '\n') return error.Truncated;
        var lines: prefs.Lines = .{ .text = text };
        const first = while (lines.next()) |line| {
            const words = trim(line.text);
            if (hasWords(words)) break words;
        } else return error.NotManifest;
        var format: ?u32 = null;
        var chip: ?Chip = null;
        var board: []const u8 = &.{};
        var counts: Counts = .{};
        var pairs: Pairs = .{ .text = first };
        while (pairs.next()) |pair| {
            if (style.same(pair.key, "FORMAT")) {
                format = @intCast(decimal(pair.value, 0xFFFF_FFFF) orelse return error.BadHeader);
            } else if (style.same(pair.key, "CHIP")) {
                chip = chipNamed(pair.value) orelse return error.BadHeader;
            } else if (style.same(pair.key, "BOARD")) {
                if (!boardOk(pair.value)) return error.BadHeader;
                board = pair.value;
            } else if (style.same(pair.key, "DRAWERS")) {
                counts.drawers = @intCast(decimal(pair.value, 0xFFFF_FFFF) orelse return error.BadHeader);
            } else if (style.same(pair.key, "FILES")) {
                counts.files = @intCast(decimal(pair.value, 0xFFFF_FFFF) orelse return error.BadHeader);
            } else if (style.same(pair.key, "BYTES")) {
                counts.bytes = decimal(pair.value, ~@as(u64, 0)) orelse return error.BadHeader;
            }
            // Any other key is a field a later format added: passed over.
        }
        if (format == null or chip == null) return error.NotManifest;
        if (format.? > format_now) return error.Format;
        return .{ .header = .{ .format = format.?, .chip = chip.?, .board = board, .counts = counts }, .lines = lines };
    }

    /// The next entry, null once the last line is read - and then only if
    /// what was read is what the settings line said.
    pub fn next(reader: *Reader) Error!?Entry {
        if (reader.ended) return null;
        while (reader.lines.next()) |line| {
            const text = trim(line.text);
            if (!hasWords(text)) continue;
            const entry = try entryOf(text);
            if (orderPaths(reader.previous, entry.path) != .before) return error.OutOfOrder;
            reader.previous = entry.path;
            reader.seen.add(entry);
            if (reader.seen.files > reader.header.counts.files or
                reader.seen.drawers > reader.header.counts.drawers or
                reader.seen.bytes > reader.header.counts.bytes) return error.Counts;
            return entry;
        }
        reader.ended = true;
        if (!reader.seen.same(reader.header.counts)) return error.Truncated;
        return null;
    }
};

/// One line as an entry.
fn entryOf(text: []const u8) Error!Entry {
    var words: Words = .{ .text = text };
    const first = words.next() orelse return error.BadLine;
    if (style.same(first, "DRAWER")) {
        const path = words.rest() orelse return error.BadLine;
        if (!pathOk(path)) return error.BadPath;
        return .{ .kind = .drawer, .path = path };
    }
    const crc = hex8(first) orelse return error.BadLine;
    const size = decimal(words.next() orelse return error.BadLine, ~@as(u64, 0)) orelse return error.BadLine;
    const path = words.rest() orelse return error.BadLine;
    if (!pathOk(path)) return error.BadPath;
    return .{ .kind = .file, .path = path, .crc = crc, .size = size };
}

// --- writing ----------------------------------------------------------------

/// The bytes `headerLine` writes at most, newline included: every field
/// at its longest, the board's name among them.
pub const max_header: usize = 160;

/// `header` written as the settings line into `into` (`max_header` bytes
/// will do): how many bytes, newline included.
pub fn headerLine(header: Header, into: []u8) usize {
    var at: usize = 0;
    put(into, &at, "FORMAT=");
    at += number(header.format, into[at..]);
    put(into, &at, " CHIP=");
    put(into, &at, @tagName(header.chip));
    if (header.board.len != 0) {
        put(into, &at, " BOARD=");
        put(into, &at, header.board);
    }
    put(into, &at, " DRAWERS=");
    at += number(header.counts.drawers, into[at..]);
    put(into, &at, " FILES=");
    at += number(header.counts.files, into[at..]);
    put(into, &at, " BYTES=");
    at += number(header.counts.bytes, into[at..]);
    put(into, &at, "\n");
    return at;
}

/// The bytes `entryLine` writes for `entry`, newline included.
pub fn entryLength(entry: Entry) usize {
    return switch (entry.kind) {
        .drawer => drawer_word.len + 1 + entry.path.len + 1,
        .file => 8 + 1 + digits(entry.size) + 1 + entry.path.len + 1,
    };
}

/// `entry` written as its line into `into` (`entryLength(entry)` bytes):
/// how many bytes, newline included.
pub fn entryLine(entry: Entry, into: []u8) usize {
    var at: usize = 0;
    switch (entry.kind) {
        .drawer => {
            put(into, &at, drawer_word);
            put(into, &at, " ");
        },
        .file => {
            var hex: [8]u8 = undefined;
            writeHex8(entry.crc, &hex);
            put(into, &at, &hex);
            put(into, &at, " ");
            at += number(entry.size, into[at..]);
            put(into, &at, " ");
        },
    }
    put(into, &at, entry.path);
    put(into, &at, "\n");
    return at;
}

/// What a manifest says of itself, before its settings line. Every line a
/// comment, so a reader passes over it; the same bytes in every manifest,
/// so that two manifests of one package are the same text.
pub const preamble =
    \\# The files this holds, their lengths and the CRC-32 of each - the
    \\# list a system is installed from and brought up to date against.
    \\# A line for each: `drawer <path>`, or `<crc-32> <length> <path>`,
    \\# sorted by path. The first line that is not a comment says what
    \\# format this is, which chip and board the files are for, and how
    \\# many lines and bytes follow.
    \\
;

// --- paths ------------------------------------------------------------------

/// Where one path stands against another.
pub const Order = enum { before, same, after };

/// Whether `a` comes before `b`, letters as if upper case: the order a
/// manifest's lines are in, and the order the file systems compare names
/// in.
pub fn orderPaths(a: []const u8, b: []const u8) Order {
    const shared = if (a.len < b.len) a.len else b.len;
    for (a[0..shared], b[0..shared]) |one, other| {
        const first = style.upper(one);
        const second = style.upper(other);
        if (first != second) return if (first < second) .before else .after;
    }
    if (a.len == b.len) return .same;
    return if (a.len < b.len) .before else .after;
}

/// Whether two paths name one file.
pub fn samePath(a: []const u8, b: []const u8) bool {
    return orderPaths(a, b) == .same;
}

/// The longest path a manifest may name, as long as a path anywhere.
pub const max_board: usize = 31;

/// Whether `name` may be a BOARD: letters, digits, `_` and `-`, at least
/// one and no more than `max_board`. It names a directory in a package on
/// a server and is printed where a machine says what it is installing,
/// and it is checked here so that neither has to.
pub fn boardOk(name: []const u8) bool {
    if (name.len == 0 or name.len > max_board) return false;
    for (name) |byte| {
        const letter = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
        const digit = byte >= '0' and byte <= '9';
        if (!letter and !digit and byte != '_' and byte != '-') return false;
    }
    return true;
}

pub const max_path: usize = 1024;

/// Whether `path` is one a manifest may name: relative, its parts
/// separated by single `/`, none of them `.` or `..`, no device name, no
/// pattern character, no control character, and not beginning with `#`. The lines come over a network and name files
/// about to be written, so a path that could reach out of the tree is not
/// read as well as can be - it is refused.
pub fn pathOk(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path) return false;
    if (path[0] == '/' or path[path.len - 1] == '/') return false;
    // A line that begins with one is the explanation, not an entry, so a
    // path that begins with one could not be read back.
    if (path[0] == '#') return false;
    var part: usize = 0;
    for (path, 0..) |c, at| {
        switch (c) {
            '/' => {
                if (part == 0) return false;
                if (dots(path[at - part .. at])) return false;
                part = 0;
                continue;
            },
            ':', '\\', '*', '?', '"', '|' => return false,
            0...31, 127 => return false,
            else => part += 1,
        }
    }
    return !dots(path[path.len - part ..]);
}

/// Whether a part of a path is `.` or `..`, which name another drawer.
fn dots(part: []const u8) bool {
    return (part.len == 1 or part.len == 2) and part[0] == '.' and (part.len == 1 or part[1] == '.');
}

// --- lines and numbers ------------------------------------------------------

/// A line without what is around its words: the carriage return a file
/// that went through another system keeps, and blanks at either end.
fn trim(text: []const u8) []const u8 {
    var first: usize = 0;
    var last: usize = text.len;
    while (last > first and blank(text[last - 1])) last -= 1;
    while (first < last and blank(text[first])) first += 1;
    return text[first..last];
}

fn blank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Whether a line holds anything but a comment.
fn hasWords(text: []const u8) bool {
    return text.len != 0 and text[0] != '#';
}

/// The words of a line, blanks between them; `rest` takes everything left
/// as one, which is how a path with blanks in it is read.
const Words = struct {
    text: []const u8,
    at: usize = 0,

    fn next(words: *Words) ?[]const u8 {
        while (words.at < words.text.len and blank(words.text[words.at])) words.at += 1;
        if (words.at >= words.text.len) return null;
        const first = words.at;
        while (words.at < words.text.len and !blank(words.text[words.at])) words.at += 1;
        return words.text[first..words.at];
    }

    fn rest(words: *Words) ?[]const u8 {
        while (words.at < words.text.len and blank(words.text[words.at])) words.at += 1;
        if (words.at >= words.text.len) return null;
        const left = words.text[words.at..];
        words.at = words.text.len;
        return left;
    }
};

/// The settings line's `KEY=value` words. A value is a word: a manifest's
/// settings never have blanks in them, so there is nothing to quote.
const Pairs = struct {
    text: []const u8,
    words: Words = undefined,
    started: bool = false,

    const Pair = struct { key: []const u8, value: []const u8 };

    fn next(pairs: *Pairs) ?Pair {
        if (!pairs.started) {
            pairs.words = .{ .text = pairs.text };
            pairs.started = true;
        }
        const word = pairs.words.next() orelse return null;
        for (word, 0..) |c, at| {
            if (c == '=') return .{ .key = word[0..at], .value = word[at + 1 ..] };
        }
        return .{ .key = word, .value = &.{} };
    }
};

/// A chip by the name the header writes, which is the name in the SDK.
fn chipNamed(text: []const u8) ?Chip {
    inline for (@typeInfo(Chip).@"enum".fields) |field| {
        if (sameFolded(text, field.name)) return @field(Chip, field.name);
    }
    return null;
}

/// Whether two texts are one name, whatever the case of their letters.
/// `style.same` wants the name it is given already in upper case, which
/// the chips' are not.
fn sameFolded(text: []const u8, name: []const u8) bool {
    if (text.len != name.len) return false;
    for (text, name) |one, other| {
        if (style.upper(one) != style.upper(other)) return false;
    }
    return true;
}

/// All of `text` as a number, up to `limit`; null for anything else,
/// an empty text and one that goes past it.
fn decimal(text: []const u8, limit: u64) ?u64 {
    if (text.len == 0 or text.len > 20) return null;
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (value > (limit - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return value;
}

/// Eight hex digits as a number, either case; null for anything else.
fn hex8(text: []const u8) ?u32 {
    if (text.len != 8) return null;
    var value: u32 = 0;
    for (text) |c| {
        const digit: u32 = switch (style.upper(c)) {
            '0'...'9' => c - '0',
            'A'...'F' => style.upper(c) - 'A' + 10,
            else => return null,
        };
        value = value << 4 | digit;
    }
    return value;
}

/// `value` as eight hex digits, lower case.
fn writeHex8(value: u32, into: *[8]u8) void {
    var left = value;
    var at: usize = 8;
    while (at > 0) {
        at -= 1;
        const digit: u8 = @intCast(left & 0xF);
        into[at] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        left >>= 4;
    }
}

/// The digits `number` writes for `value`.
fn digits(value: u64) usize {
    var count: usize = 1;
    var left = value;
    while (left >= 10) : (left /= 10) count += 1;
    return count;
}

/// `value` in decimal digits into `into`; how many.
fn number(value: u64, into: []u8) usize {
    const count = digits(value);
    var left = value;
    var at = count;
    while (at > 0) {
        at -= 1;
        into[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
    }
    return count;
}

fn put(into: []u8, at: *usize, text: []const u8) void {
    @memcpy(into[at.*..][0..text.len], text);
    at.* += text.len;
}
