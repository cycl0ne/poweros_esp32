// SPDX-License-Identifier: MIT
//! The modules of a directory, found by the tag in each file: what a
//! library that opens modules of its own keeps of `LIBS:codecs/`.
//!
//! A library like audiocodec.library or media.library is given a kind of
//! sound or a kind of container and has to find the module that does it.
//! It could hold a table of every kind there is and the file each lives
//! in, but then a kind is a row in the library and a module the library
//! was not built with cannot be reached at all. Instead each module says
//! in its own ROM tag what it does - `acodec.ResidentACodec`,
//! `mcontainer.ResidentMContainer`, `vcodec.ResidentVCodec` - and the
//! library reads those tags.
//!
//! **Nothing is loaded for that.** A tag is read out of the file with
//! `loadfile`, which follows the load file's segments and relocates
//! nothing, so looking through a directory of modules costs the reads and
//! no code runs. A file whose name, date and size are what they were when
//! its tag was last read keeps what that tag said.
//!
//! The caller owns the storage and the locking: it hands in the table to
//! fill and the one it has, which **must not be the same storage**.

const dos = @import("dos.zig");
const loadfile = @import("loadfile.zig");
const interface_dos = @import("../../interface/dos.zig");
const DosBase = interface_dos.DosBase;

/// The longest name a module is opened by, its directory in front:
/// "codecs/vorbis.acodec" and room over.
pub const NAME_BYTES = 40;

/// The most words after a tag's magic that are read.
pub const MOST_WORDS = 4;

/// A module found in the directory: the name it is opened by, what its
/// file was when the tag was read, and the tag's words.
pub const Found = struct {
    /// "<prefix><file>", NUL-terminated: what `OpenLibrary` is given.
    name: [NAME_BYTES]u8 = @splat(0),
    date: dos.DateStamp = .{},
    size: u64 = 0,
    version: u8 = 0,
    /// From the tag's ID string ("dts.acodec 1.0 (date)"); 0 without one.
    revision: u16 = 0,
    /// The words after the magic, as many as `Kind.words` asked for; the
    /// rest 0. What they mean is the asking library's: the kinds it does,
    /// a chip or software kind, a priority.
    words: [MOST_WORDS]u32 = @splat(0),

    /// Word `n`, or 0 past what was asked for.
    pub fn word(found: *const Found, n: usize) u32 {
        return if (n < MOST_WORDS) found.words[n] else 0;
    }
};

/// What is being looked for.
pub const Kind = struct {
    /// Where they are, as dos is given it: "LIBS:codecs".
    dir: [*:0]const u8,
    /// What a module is opened by, before its file's name: "codecs/".
    prefix: []const u8,
    /// What its file ends in, lower case: ".acodec". The other kinds of
    /// module in the same directory are told apart by this.
    suffix: []const u8,
    /// The word after the library tag that says the tag is one of these.
    magic: u32,
    /// How many words after the magic to read, up to `MOST_WORDS`.
    words: u8,
};

/// The modules of `kind`'s directory into `into`: how many there are.
///
/// A file ending in `kind.suffix` whose name, date and size are what
/// `was` has for it keeps what it says and is not read again; any other
/// has its tag read, and is left out when the file holds no tag of this
/// kind, is named otherwise than its file, or does not fit `into`. Files
/// come in the order the directory gives them, at most `into.len` of
/// them.
///
/// `into` and `was` must be different storage. 0 when the directory
/// cannot be read, which is how a disk with no modules at all answers.
pub fn scan(dl: *DosBase, kind: Kind, into: []Found, was: []const Found) u32 {
    var count: u32 = 0;
    const dir = dl.Lock(kind.dir, dos.SHARED_LOCK) orelse return 0;
    defer dl.UnLock(dir);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return 0;
    while (dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        const file = fileName(&fib);
        if (!endsWith(file, kind.suffix)) continue;
        if (count >= into.len) break;
        const slot = &into[count];
        if (!nameOf(slot, kind.prefix, file)) continue;
        if (known(was, &slot.name, fib.date, fib.size)) |found| {
            slot.* = found;
        } else {
            if (!readFile(dl, kind, slot, file)) continue;
            slot.date = fib.date;
            slot.size = fib.size;
        }
        count += 1;
    }
    return count;
}

/// A load file's tag into `found`: false when the file holds no library
/// tag of this kind, or one named otherwise than `file` - ramlib would
/// not load it by that name. `found.name` is left as it is.
pub fn readTag(source: loadfile.Source, kind: Kind, found: *Found, file: []const u8) bool {
    const at = loadfile.findResident(source) orelse return false;
    var tag: loadfile.LibraryTag = .{};
    if (!loadfile.readLibrary(source, at, &tag)) return false;
    var length: usize = 0;
    while (tag.name[length] != 0) length += 1;
    if (!sameText(tag.name[0..length], file)) return false;
    const magic = loadfile.readWord(source, at, tag.after) orelse return false;
    if (magic != kind.magic) return false;
    const wanted = @min(kind.words, MOST_WORDS);
    found.words = @splat(0);
    for (0..wanted) |n| {
        found.words[n] = loadfile.readWord(source, at, tag.after + 4 + @as(u32, @intCast(n)) * 4) orelse return false;
    }
    found.version = tag.version;
    found.revision = tag.revision;
    return true;
}

/// The module of that name `was` has, if its file is as it was then.
pub fn known(was: []const Found, name: *const [NAME_BYTES]u8, date: dos.DateStamp, size: u64) ?Found {
    for (was) |found| {
        if (!sameName(&found.name, name)) continue;
        if (found.date.eql(date) and found.size == size) return found;
        return null;
    }
    return null;
}

// --- the file's own -----------------------------------------------------------------

/// A file read through dos, for `loadfile`'s reader.
const DosFile = struct {
    dl: *DosBase,
    file: *dos.FileHandle,

    fn readAt(context: *anyopaque, offset: u32, into: []u8) bool {
        const self: *DosFile = @ptrCast(@alignCast(context));
        if (self.dl.Seek(self.file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
        const got = self.dl.Read(self.file, into.ptr, @intCast(into.len));
        return got == @as(isize, @intCast(into.len));
    }
};

fn readFile(dl: *DosBase, kind: Kind, found: *Found, file: []const u8) bool {
    var path: [96]u8 = @splat(0);
    const dir = nulText(kind.dir);
    if (dir.len + 1 + file.len + 1 > path.len) return false;
    @memcpy(path[0..dir.len], dir);
    path[dir.len] = '/';
    @memcpy(path[dir.len + 1 ..][0..file.len], file);
    const handle = dl.Open(@ptrCast(&path), dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(handle);
    var reader = DosFile{ .dl = dl, .file = handle };
    return readTag(.{ .context = &reader, .readAt = DosFile.readAt }, kind, found, file);
}

fn fileName(fib: *const dos.FileInfoBlock) []const u8 {
    var length: usize = 0;
    while (length < fib.file_name.len and fib.file_name[length] != 0) length += 1;
    return fib.file_name[0..length];
}

/// "<prefix><file>" into `found.name`; false when it does not fit. What
/// was in `found` is cleared.
fn nameOf(found: *Found, prefix: []const u8, file: []const u8) bool {
    found.* = .{};
    if (prefix.len + file.len + 1 > found.name.len) return false;
    @memcpy(found.name[0..prefix.len], prefix);
    @memcpy(found.name[prefix.len..][0..file.len], file);
    return true;
}

fn endsWith(file: []const u8, suffix: []const u8) bool {
    if (file.len < suffix.len) return false;
    for (file[file.len - suffix.len ..], suffix) |a, b| {
        if (lower(a) != b) return false;
    }
    return true;
}

fn sameName(a: *const [NAME_BYTES]u8, b: *const [NAME_BYTES]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn sameText(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn nulText(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
