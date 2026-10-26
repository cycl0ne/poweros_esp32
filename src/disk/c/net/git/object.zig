// SPDX-License-Identifier: MIT
//! git's objects: a type and a body, the id the SHA-1 of `<type>
//! <size>\0` and the body. A commit, a tree and a tag are taken apart
//! here; a blob is its bytes.
//!
//! A commit's body is header lines - `tree`, `parent` as often as it has
//! parents, `author`, `committer`, and others this reading passes over -
//! an empty line and the message. A tree's is entries one after another:
//! the mode in octal, a space, the name, a NUL and the 20 bytes of the
//! id. A tag's is lines like a commit's: `object`, `type`, `tag`,
//! `tagger`.

const _git = @import("_git.zig");
const Id = _git.Id;
const CryptoBase = @import("sdk").interface.crypto.CryptoBase;

/// An object's type, as a pack's entries number them; 6 and 7 are a
/// pack's deltas, which are no objects of their own.
pub const Type = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,

    pub fn name(kind: Type) []const u8 {
        return switch (kind) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            .ofs_delta => "ofs-delta",
            .ref_delta => "ref-delta",
        };
    }
};

/// The type a pack entry's three bits say; null for 0 and 5.
pub fn typeOfBits(bits: u3) ?Type {
    return switch (bits) {
        1, 2, 3, 4, 6, 7 => @enumFromInt(bits),
        else => null,
    };
}

/// The type an object's header names; null for none of the four.
pub fn typeOfName(text: []const u8) ?Type {
    inline for (.{ Type.commit, Type.tree, Type.blob, Type.tag }) |kind| {
        if (_git.same(text, kind.name())) return kind;
    }
    return null;
}

/// `<type> <size>\0`, into `into`.
pub fn header(kind: Type, size: u64, into: *[32]u8) []const u8 {
    var out: _git.Out = .{ .into = into };
    out.put(kind.name());
    out.byte(' ');
    out.decimal(size);
    out.byte(0);
    return out.written();
}

/// The id of an object of `kind` with `body`.
pub fn idOfObject(cb: *CryptoBase, kind: Type, body: []const u8) Id {
    var head: [32]u8 = undefined;
    var sha = _git.Sha1.start(cb);
    sha.update(header(kind, body.len, &head));
    sha.update(body);
    return sha.finish();
}

/// A loose object's inflated bytes taken apart: its type and where its
/// body starts; null when the header is not one.
pub fn parseHeader(bytes: []const u8) ?struct { kind: Type, size: u64, body_at: usize } {
    var space: usize = 0;
    while (space < bytes.len and bytes[space] != ' ') space += 1;
    if (space == bytes.len) return null;
    const kind = typeOfName(bytes[0..space]) orelse return null;
    var at = space + 1;
    var size: u64 = 0;
    var digits: usize = 0;
    while (at < bytes.len and bytes[at] != 0) : (at += 1) {
        const char = bytes[at];
        if (char < '0' or char > '9' or digits == 19) return null;
        size = size * 10 + (char - '0');
        digits += 1;
    }
    if (at == bytes.len or digits == 0) return null;
    return .{ .kind = kind, .size = size, .body_at = at + 1 };
}

// --- people and times -----------------------------------------------------

/// `Name <email> 1761403600 +0100`, an author's, committer's or
/// tagger's line after its keyword.
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    /// Seconds since 1970, UTC.
    time: i64,
    /// The zone's offset from UTC, in minutes.
    offset: i32,
};

pub fn parseSignature(text: []const u8) ?Signature {
    var open: usize = 0;
    while (open < text.len and text[open] != '<') open += 1;
    if (open == text.len) return null;
    var close = open;
    while (close < text.len and text[close] != '>') close += 1;
    if (close == text.len) return null;
    var name = text[0..open];
    while (name.len > 0 and name[name.len - 1] == ' ') name = name[0 .. name.len - 1];
    var at = close + 1;
    while (at < text.len and text[at] == ' ') at += 1;
    var time: i64 = 0;
    var digits: usize = 0;
    while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) {
        if (digits == 18) return null;
        time = time * 10 + (text[at] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    while (at < text.len and text[at] == ' ') at += 1;
    var offset: i32 = 0;
    if (at + 5 <= text.len and (text[at] == '+' or text[at] == '-')) {
        for (text[at + 1 .. at + 5]) |char| {
            if (char < '0' or char > '9') return null;
        }
        const hours: i32 = (text[at + 1] - '0') * 10 + (text[at + 2] - '0');
        const minutes: i32 = (text[at + 3] - '0') * 10 + (text[at + 4] - '0');
        offset = hours * 60 + minutes;
        if (text[at] == '-') offset = -offset;
    }
    return .{ .name = name, .email = text[open + 1 .. close], .time = time, .offset = offset };
}

// --- commits ----------------------------------------------------------------

pub const Commit = struct {
    tree: Id,
    parent_count: usize,
    /// The `parent` lines, one after another, 48 bytes each.
    parent_lines: []const u8,
    author: Signature,
    committer: Signature,
    /// From the line after the empty one to the end.
    message: []const u8,

    pub fn parent(commit: *const Commit, index: usize) Id {
        return _git.idOf(commit.parent_lines[index * 48 + 7 ..]).?;
    }

    /// The message's first line.
    pub fn subject(commit: *const Commit) []const u8 {
        var end: usize = 0;
        while (end < commit.message.len and commit.message[end] != '\n') end += 1;
        return commit.message[0..end];
    }
};

/// The lines of a commit's or tag's head, up to the empty line.
const HeadLines = struct {
    body: []const u8,
    at: usize = 0,
    /// Where the message starts, once the empty line has been passed.
    message_at: ?usize = null,

    fn next(lines: *HeadLines) ?struct { key: []const u8, value: []const u8, start: usize } {
        if (lines.message_at != null or lines.at >= lines.body.len) return null;
        const start = lines.at;
        var end = start;
        while (end < lines.body.len and lines.body[end] != '\n') end += 1;
        lines.at = end + 1;
        if (end == start) {
            lines.message_at = @min(lines.at, lines.body.len);
            return null;
        }
        const text = lines.body[start..end];
        var space: usize = 0;
        while (space < text.len and text[space] != ' ') space += 1;
        const value = if (space < text.len) text[space + 1 ..] else text[text.len..];
        return .{ .key = text[0..space], .value = value, .start = start };
    }
};

pub fn parseCommit(body: []const u8) ?Commit {
    var lines: HeadLines = .{ .body = body };
    var tree: ?Id = null;
    var author: ?Signature = null;
    var committer: ?Signature = null;
    var parents_start: usize = 0;
    var parent_count: usize = 0;
    while (lines.next()) |field| {
        if (_git.same(field.key, "tree")) {
            if (tree != null or field.value.len != 40) return null;
            tree = _git.idOf(field.value) orelse return null;
        } else if (_git.same(field.key, "parent")) {
            if (field.value.len != 40 or _git.idOf(field.value) == null) return null;
            // The parents follow one another, right after the tree.
            if (parent_count == 0) parents_start = field.start else if (field.start != parents_start + parent_count * 48) return null;
            parent_count += 1;
        } else if (_git.same(field.key, "author")) {
            author = parseSignature(field.value) orelse return null;
        } else if (_git.same(field.key, "committer")) {
            committer = parseSignature(field.value) orelse return null;
        }
    }
    return .{
        .tree = tree orelse return null,
        .parent_count = parent_count,
        .parent_lines = body[parents_start..][0 .. parent_count * 48],
        .author = author orelse return null,
        .committer = committer orelse return null,
        .message = body[lines.message_at orelse body.len ..],
    };
}

// --- trees ------------------------------------------------------------------

/// The modes git gives a tree's entries.
pub const mode_tree: u32 = 0o040000;
pub const mode_file: u32 = 0o100644;
pub const mode_executable: u32 = 0o100755;
pub const mode_link: u32 = 0o120000;
pub const mode_gitlink: u32 = 0o160000;

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    id: Id,

    pub fn isTree(entry: TreeEntry) bool {
        return entry.mode == mode_tree;
    }
};

/// A tree's entries one at a time; `bad` once one was not an entry.
pub const TreeEntries = struct {
    body: []const u8,
    at: usize = 0,
    bad: bool = false,

    pub fn next(entries: *TreeEntries) ?TreeEntry {
        if (entries.bad or entries.at >= entries.body.len) return null;
        const body = entries.body;
        var at = entries.at;
        var mode: u32 = 0;
        var digits: usize = 0;
        while (at < body.len and body[at] != ' ') : (at += 1) {
            const char = body[at];
            if (char < '0' or char > '7' or digits == 7) return entries.fail();
            mode = mode * 8 + (char - '0');
            digits += 1;
        }
        if (at == body.len or digits == 0) return entries.fail();
        const name_start = at + 1;
        var name_end = name_start;
        while (name_end < body.len and body[name_end] != 0) name_end += 1;
        if (name_end == name_start or name_end + 21 > body.len) return entries.fail();
        entries.at = name_end + 21;
        return .{ .mode = mode, .name = body[name_start..name_end], .id = body[name_end + 1 ..][0..20].* };
    }

    fn fail(entries: *TreeEntries) ?TreeEntry {
        entries.bad = true;
        return null;
    }
};

/// One entry of a tree, written as a tree holds it.
pub fn putTreeEntry(out: *_git.Out, mode: u32, name: []const u8, id: *const Id) void {
    var digits: [7]u8 = undefined;
    var count: usize = 0;
    var rest = mode;
    while (true) {
        digits[digits.len - 1 - count] = '0' + @as(u8, @intCast(rest & 7));
        count += 1;
        rest >>= 3;
        if (rest == 0) break;
    }
    out.put(digits[digits.len - count ..]);
    out.byte(' ');
    out.put(name);
    out.byte(0);
    out.put(id);
}

// --- tags -------------------------------------------------------------------

pub const Tag = struct {
    object: Id,
    kind: Type,
    name: []const u8,
    tagger: ?Signature,
    message: []const u8,
};

pub fn parseTag(body: []const u8) ?Tag {
    var lines: HeadLines = .{ .body = body };
    var object: ?Id = null;
    var kind: ?Type = null;
    var name: ?[]const u8 = null;
    var tagger: ?Signature = null;
    while (lines.next()) |field| {
        if (_git.same(field.key, "object")) {
            if (field.value.len != 40) return null;
            object = _git.idOf(field.value) orelse return null;
        } else if (_git.same(field.key, "type")) {
            kind = typeOfName(field.value) orelse return null;
        } else if (_git.same(field.key, "tag")) {
            name = field.value;
        } else if (_git.same(field.key, "tagger")) {
            tagger = parseSignature(field.value);
        }
    }
    return .{
        .object = object orelse return null,
        .kind = kind orelse return null,
        .name = name orelse return null,
        .tagger = tagger,
        .message = body[lines.message_at orelse body.len ..],
    };
}
