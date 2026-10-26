// SPDX-License-Identifier: MIT
//! The index (`.git/index`): what the next commit holds, a file at a
//! time, with what the file looked like when it was put there, so a
//! changed file is told by its size and date before it is hashed again.
//!
//! `DIRC`, the version, how many entries; the entries sorted by path,
//! each ten 32-bit numbers - the change and modification times in
//! seconds and nanoseconds, device, inode, mode, user, group, size - the
//! blob's id, the flags (the stage in bits 12-13, the path's length below
//! them) and the path, padded with NULs to a multiple of eight bytes, at
//! least one. Version 3 adds a second flags word to an entry whose
//! extended bit is set: skip-worktree (0x4000) there marks a file the
//! work tree does not hold, which is not taken for deleted. Extensions - a four-letter name, a length, the
//! bytes - may follow, and the SHA-1 of everything before it ends the
//! file. Version 4, whose paths are cut against the one before, is not
//! read; one is written as version 2.

const _git = @import("_git.zig");
const Id = _git.Id;
const CryptoBase = @import("sdk").interface.crypto.CryptoBase;

pub const header_bytes = 12;

pub const Entry = struct {
    ctime: u32 = 0,
    ctime_ns: u32 = 0,
    mtime: u32 = 0,
    mtime_ns: u32 = 0,
    dev: u32 = 0,
    ino: u32 = 0,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u32,
    id: Id,
    stage: u2 = 0,
    /// The work tree does not hold the file, and is not to.
    skip_worktree: bool = false,
    path: []const u8,
};

/// The extended flags' skip-worktree bit.
const flag_skip_worktree: u16 = 0x4000;

/// An index read in place.
pub const Index = struct {
    bytes: []const u8,
    version: u32,
    count: u32,

    /// The index in `bytes`; null when it is none, or of version 4.
    pub fn open(bytes: []const u8) ?Index {
        if (bytes.len < header_bytes + 20 or !_git.same(bytes[0..4], "DIRC")) return null;
        const version = _git.get32(bytes[4..8]);
        if (version != 2 and version != 3) return null;
        return .{ .bytes = bytes, .version = version, .count = _git.get32(bytes[8..12]) };
    }

    /// Whether its SHA-1, at its end, is right.
    pub fn verify(index: *const Index, cb: *CryptoBase) bool {
        const sum = _git.sha1Of(cb, index.bytes[0 .. index.bytes.len - 20]);
        return _git.same(&sum, index.bytes[index.bytes.len - 20 ..]);
    }

    pub fn entries(index: *const Index) Entries {
        return .{ .index = index, .at = header_bytes };
    }
};

/// An index's entries one at a time; `bad` once one did not fit.
pub const Entries = struct {
    index: *const Index,
    at: usize,
    taken: u32 = 0,
    bad: bool = false,
    /// Where the entry `next` gave last starts in the index's bytes.
    last_at: usize = 0,

    pub fn next(walk: *Entries) ?Entry {
        if (walk.bad or walk.taken == walk.index.count) return null;
        const bytes = walk.index.bytes;
        const end = bytes.len - 20;
        const at = walk.at;
        if (at + 62 > end) return walk.fail();
        const field = struct {
            fn get(from: []const u8, number: usize) u32 {
                return _git.get32(from[number * 4 ..]);
            }
        }.get;
        const fixed = bytes[at..];
        const flags = _git.get16(fixed[60..]);
        var path_at = at + 62;
        var extended: u16 = 0;
        if (flags & 0x4000 != 0) {
            if (walk.index.version < 3 or at + 64 > end) return walk.fail();
            extended = _git.get16(fixed[62..]);
            path_at += 2;
        }
        var path_end = path_at;
        const stated = flags & 0xFFF;
        if (stated < 0xFFF) {
            path_end = path_at + stated;
            if (path_end >= end or bytes[path_end] != 0) return walk.fail();
        } else {
            while (path_end < end and bytes[path_end] != 0) path_end += 1;
            if (path_end == end) return walk.fail();
        }
        // NULs up to the next multiple of eight from the entry's start,
        // at least one.
        const length = path_end - at;
        const padded = (length + 8) & ~@as(usize, 7);
        if (at + padded > end) return walk.fail();
        walk.at = at + padded;
        walk.last_at = at;
        walk.taken += 1;
        return .{
            .ctime = field(fixed, 0),
            .ctime_ns = field(fixed, 1),
            .mtime = field(fixed, 2),
            .mtime_ns = field(fixed, 3),
            .dev = field(fixed, 4),
            .ino = field(fixed, 5),
            .mode = field(fixed, 6),
            .uid = field(fixed, 7),
            .gid = field(fixed, 8),
            .size = field(fixed, 9),
            .id = fixed[40..60].*,
            .stage = @truncate(flags >> 12),
            .skip_worktree = extended & flag_skip_worktree != 0,
            .path = bytes[path_at..path_end],
        };
    }

    fn fail(walk: *Entries) ?Entry {
        walk.bad = true;
        return null;
    }
};

/// The stat fields of the entry at `at` in an index's bytes set from
/// `entry`: its times and its size.
pub fn patchStat(bytes: []u8, at: usize, entry: *const Entry) void {
    _git.put32(bytes[at..][0..4], entry.ctime);
    _git.put32(bytes[at + 4 ..][0..4], entry.ctime_ns);
    _git.put32(bytes[at + 8 ..][0..4], entry.mtime);
    _git.put32(bytes[at + 12 ..][0..4], entry.mtime_ns);
    _git.put32(bytes[at + 36 ..][0..4], entry.size);
}

/// An index written: its head, then each entry in path order, then
/// `finish`. It is of version 2, or 3 when an entry is to carry
/// skip-worktree (`extended`).
pub const Writer = struct {
    emit: _git.Emit,
    extended: bool,

    pub fn start(cb: *CryptoBase, sink: _git.Sink, count: u32, extended: bool) Writer {
        var writer: Writer = .{ .emit = .{ .sink = sink, .sha = _git.Sha1.start(cb) }, .extended = extended };
        writer.emit.put("DIRC");
        writer.emit.be32(if (extended) 3 else 2);
        writer.emit.be32(count);
        return writer;
    }

    pub fn entry(writer: *Writer, given: *const Entry) void {
        const emit = &writer.emit;
        for ([_]u32{ given.ctime, given.ctime_ns, given.mtime, given.mtime_ns, given.dev, given.ino, given.mode, given.uid, given.gid, given.size }) |number| {
            emit.be32(number);
        }
        emit.put(&given.id);
        const stated: u16 = @intCast(@min(given.path.len, 0xFFF));
        const extended = writer.extended and given.skip_worktree;
        emit.be16(@as(u16, given.stage) << 12 | stated | @as(u16, if (extended) 0x4000 else 0));
        if (extended) emit.be16(flag_skip_worktree);
        emit.put(given.path);
        const length = 62 + @as(usize, if (extended) 2 else 0) + given.path.len;
        const padded = (length + 8) & ~@as(usize, 7);
        const zeros = [_]u8{0} ** 8;
        emit.put(zeros[0 .. padded - length]);
    }

    /// The SHA-1 written after the entries: false when the sink failed.
    pub fn finish(writer: *Writer) bool {
        return writer.emit.finish();
    }
};

/// How two entries sort in an index: by path, byte by byte, then stage.
pub fn before(a: *const Entry, b: *const Entry) bool {
    return switch (_git.order(a.path, b.path)) {
        .less => true,
        .greater => false,
        .equal => a.stage < b.stage,
    };
}
