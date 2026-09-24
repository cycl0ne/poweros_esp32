// SPDX-License-Identifier: MPL-2.0
//! The file system on the log: the tree, the locks and the packets, over
//! `volume.zig`. `FileSystem(Media)` is generic over the medium, as the
//! volume is, so all of this is tested on the host against memory that
//! behaves like flash.
//!
//! The packets, their arguments and their answers are RAM:'s
//! (src/rom/handler/ram, docs/ram.md) - a program cannot tell the two
//! apart - and so are the lock rules, the name walking and the error codes.
//! What is different is underneath:
//!
//! - **The tree is in memory, the bytes are on the medium.** Mounting
//!   replays the log into nodes; a file's data stays where it was written
//!   and the node keeps a list of extents pointing at it. Reading a file is
//!   a copy out of the mapped medium.
//! - **Nothing is changed in place.** Every create, write, rename, delete
//!   and SetProtection appends a record; the newest one about a thing wins.
//! - **Inodes** number the objects and are never reused, so a lock or a
//!   FileInfoBlock from before cannot come to mean a different object.
//! - **The collector** frees a sector when the volume runs short: what is
//!   still live in it is appended again at the head, and the sector is
//!   forgotten so the next segment erases it.
//!
//! The medium must offer what volume.zig asks for, plus `now()` for the
//! date on a new file.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const flashfs = dos.flashfs;
const volume = @import("volume.zig");
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const DosPacket = dos.DosPacket;
const MsgPort = exec.MsgPort;

const max_name = flashfs.max_name;
const max_comment = flashfs.max_comment;

/// Buckets for looking a node up by its inode while the log is replayed.
const bucket_count = 256;

/// The collector runs when fewer than this many sectors hold no segment, so
/// there is always room to write what moving costs.
const free_floor = 3;

pub const Error = error{
    NotFound,
    WrongType,
    InvalidName,
    InUse,
    Exists,
    NotEmpty,
    DeleteProtected,
    NoMemory,
    DiskFull,
    SeekError,
    InvalidLock,
    NoMoreEntries,
    CommentTooBig,
    /// The medium said no, or what is on it doesn't make sense.
    MediumFailed,
};

/// The dos error a file system error answers with.
pub fn codeOf(e: Error) i32 {
    return errorCode(e);
}

fn errorCode(e: Error) i32 {
    return switch (e) {
        error.NotFound => dos.ERROR_OBJECT_NOT_FOUND,
        error.WrongType => dos.ERROR_OBJECT_WRONG_TYPE,
        error.InvalidName => dos.ERROR_INVALID_COMPONENT_NAME,
        error.InUse => dos.ERROR_OBJECT_IN_USE,
        error.Exists => dos.ERROR_OBJECT_EXISTS,
        error.NotEmpty => dos.ERROR_DIRECTORY_NOT_EMPTY,
        error.DeleteProtected => dos.ERROR_DELETE_PROTECTED,
        error.NoMemory => dos.ERROR_NO_FREE_STORE,
        error.DiskFull => dos.ERROR_DISK_FULL,
        error.SeekError => dos.ERROR_SEEK_ERROR,
        error.InvalidLock => dos.ERROR_INVALID_LOCK,
        error.NoMoreEntries => dos.ERROR_NO_MORE_ENTRIES,
        error.CommentTooBig => dos.ERROR_COMMENT_TOO_BIG,
        error.MediumFailed => dos.ERROR_NOT_A_DOS_DISK,
    };
}

/// What the volume can go wrong with, as a file system error.
fn fromVolume(e: volume.Error) Error {
    return switch (e) {
        error.NoMemory => error.NoMemory,
        error.MediumFull => error.DiskFull,
        else => error.MediumFailed,
    };
}

/// dp_Res1 and dp_Res2 for a packet.
pub const Answer = struct { res1: isize, res2: i32 };

fn yes() Answer {
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

fn no(e: Error) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = errorCode(e) };
}

/// For READ, WRITE and SEEK, which answer -1 on failure.
fn minusOne(e: Error) Answer {
    return .{ .res1 = -1, .res2 = errorCode(e) };
}

fn ptrArg(value: isize) usize {
    return @bitCast(value);
}

fn lockValue(l: ?*FileLock) isize {
    return @bitCast(@intFromPtr(l));
}

/// ToUpper as utility.library has it (Latin-1), so names compare the same
/// way here as in RAM:, without the library the tests don't have.
fn upper(c: u8) u8 {
    return switch (c) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        else => c,
    };
}

fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (upper(x) != upper(y)) return false;
    }
    return true;
}

/// A name a new entry may have.
fn validName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == ':') return error.InvalidName;
}

/// A piece of a file that is somewhere on the medium: `length` bytes at
/// file offset `offset`, lying at `at`. Extents never overlap and are kept
/// in order.
const Extent = struct {
    next: ?*Extent = null,
    offset: u64 align(4) = 0,
    length: u32 = 0,
    at: u32 = 0,
};

/// A file or directory, as RAM:'s node, plus what the log needs.
const Node = struct {
    /// The next entry in the directory, and the next node in the bucket.
    next: ?*Node = null,
    hash_next: ?*Node = null,
    parent: ?*Node = null,
    children: ?*Node = null,
    extents: ?*Extent = null,
    /// Its number on the medium; never reused.
    inode: u32 = 0,
    /// ST_ROOT, ST_USERDIR or ST_FILE.
    kind: i32 = 0,
    size: u64 align(4) = 0,
    protection: u32 = 0,
    date: dos.DateStamp = .{},
    /// Counts entries leaving the directory, so EXAMINE_NEXT notices.
    delcount: u32 = 0,
    /// Where its newest meta record is, and how long it is, so the
    /// collector knows what to move and what is dead weight.
    meta_at: u32 = 0,
    meta_size: u32 = 0,
    /// user << 16 | group
    owner: u32 = 0,
    comment: [max_comment:0]u8 = @splat(0),
    name: [max_name:0]u8 = @splat(0),

    fn isDir(n: *const Node) bool {
        return n.kind > 0;
    }

    fn nameSlice(n: *const Node) []const u8 {
        return std.mem.sliceTo(&n.name, 0);
    }

    fn commentSlice(n: *const Node) []const u8 {
        return std.mem.sliceTo(&n.comment, 0);
    }
};

/// A lock: the FileLock first, then where an open file is, as RAM:'s.
const DiskLock = extern struct {
    lock: FileLock,
    pos: u64 align(4) = 0,
    modified: bool = false,
    delcount: u32 = 0,

    fn node(l: *const DiskLock) *Node {
        return @ptrFromInt(l.lock.key);
    }

    fn nextLock(l: *const DiskLock) ?*DiskLock {
        const n = l.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", n));
    }
};

/// Where a path ends: the directory and the last part ("": that directory).
const Place = struct { dir: *Node, name: [max_name:0]u8 };

pub fn FileSystem(comptime Media: type) type {
    return struct {
        const Fs = @This();
        const Volume = volume.Volume(Media);

        media: *Media,
        vol: Volume,
        /// The handler's port (fl_Task of its locks).
        port: ?*MsgPort = null,
        /// The volume's DosList node (fl_Volume of its locks).
        volume_node: ?*dos.DosList = null,
        root: *Node = undefined,
        locks: ?*DiskLock = null,
        buckets: []?*Node = &.{},
        next_inode: u32 = flashfs.root_inode + 1,
        /// Set while a collection runs: what it appends must not start
        /// another one, which is what `free_floor` keeps room for.
        collecting: bool = false,
        /// de_NumBuffers, as the mountlist gave it. Nothing here keeps
        /// buffers - the medium is read through its mapping - but
        /// ACTION_MORE_CACHE has to answer with something, and this is the
        /// truth about what was asked for.
        buffers: u32 = 0,

        pub fn init(media: *Media, port: ?*MsgPort) Fs {
            return .{ .media = media, .vol = Volume.init(media), .port = port };
        }

        pub fn deinit(fs: *Fs) void {
            var lock = fs.locks;
            while (lock) |l| {
                const following = l.nextLock();
                fs.free(l);
                lock = following;
            }
            fs.locks = null;
            if (fs.buckets.len != 0) {
                for (fs.buckets) |head| {
                    var n = head;
                    while (n) |it| {
                        const following = it.hash_next;
                        fs.freeNode(it);
                        n = following;
                    }
                }
                fs.media.free(std.mem.sliceAsBytes(fs.buckets));
                fs.buckets = &.{};
            }
            fs.vol.deinit();
        }

        // --- memory -------------------------------------------------------

        fn alloc(fs: *Fs, comptime T: type) ?*T {
            const block = fs.media.alloc(@sizeOf(T)) orelse return null;
            return @ptrCast(@alignCast(block.ptr));
        }

        fn free(fs: *Fs, p: anytype) void {
            const bytes: [*]u8 = @ptrCast(p);
            fs.media.free(bytes[0..@sizeOf(@TypeOf(p.*))]);
        }

        fn freeNode(fs: *Fs, n: *Node) void {
            var e = n.extents;
            while (e) |it| {
                const following = it.next;
                fs.free(it);
                e = following;
            }
            fs.free(n);
        }

        // --- the node table -----------------------------------------------

        fn takeBuckets(fs: *Fs) Error!void {
            if (fs.buckets.len != 0) {
                @memset(fs.buckets, null);
                return;
            }
            const block = fs.media.alloc(bucket_count * @sizeOf(?*Node)) orelse return error.NoMemory;
            fs.buckets = @alignCast(std.mem.bytesAsSlice(?*Node, block));
            @memset(fs.buckets, null);
        }

        fn byInode(fs: *Fs, inode: u32) ?*Node {
            var n = fs.buckets[inode % bucket_count];
            while (n) |it| : (n = it.hash_next) {
                if (it.inode == inode) return it;
            }
            return null;
        }

        fn remember(fs: *Fs, n: *Node) void {
            const bucket = &fs.buckets[n.inode % bucket_count];
            n.hash_next = bucket.*;
            bucket.* = n;
        }

        fn forget(fs: *Fs, n: *Node) void {
            const bucket = &fs.buckets[n.inode % bucket_count];
            if (bucket.* == n) {
                bucket.* = n.hash_next;
                return;
            }
            var it = bucket.*;
            while (it) |x| : (it = x.hash_next) {
                if (x.hash_next == n) {
                    x.hash_next = n.hash_next;
                    return;
                }
            }
        }

        /// A node with nothing in it yet, in the table.
        fn newNode(fs: *Fs, inode: u32) Error!*Node {
            const n = fs.alloc(Node) orelse return error.NoMemory;
            n.* = .{ .inode = inode };
            fs.remember(n);
            if (inode >= fs.next_inode) fs.next_inode = inode + 1;
            return n;
        }

        fn makeRoot(fs: *Fs) Error!void {
            const root = try fs.newNode(flashfs.root_inode);
            root.kind = dos.ST_ROOT;
            root.date = fs.vol.super.created;
            const label = fs.vol.name();
            @memcpy(root.name[0..label.len], label);
            root.parent = null;
            fs.root = root;
        }

        // --- mounting and formatting ---------------------------------------

        /// A volume that is already there: its superblock, then its log
        /// replayed into the tree.
        pub fn mount(fs: *Fs) Error!void {
            fs.vol.mount() catch |e| return fromVolume(e);
            try fs.takeBuckets();
            try fs.makeRoot();
            fs.vol.replay(fs, applyRecord) catch |e| return fromVolume(e);
            try fs.settle();
        }

        /// A fresh volume: a superblock and an empty root.
        pub fn format(fs: *Fs, label: []const u8) Error!void {
            fs.vol.format(label, fs.media.now()) catch |e| return fromVolume(e);
            try fs.takeBuckets();
            try fs.makeRoot();
        }

        /// ACTION_FORMAT on a volume that is already mounted: everything on
        /// it goes. Refused while anything is locked, as a format must be.
        pub fn reformat(fs: *Fs, label: []const u8) Error!void {
            if (fs.locks != null) return error.InUse;
            for (fs.buckets) |head| {
                var n = head;
                while (n) |it| {
                    const following = it.hash_next;
                    fs.freeNode(it);
                    n = following;
                }
            }
            @memset(fs.buckets, null);
            fs.next_inode = flashfs.root_inode + 1;
            try fs.format(label);
        }

        /// Replay puts every node in the table as it meets it, parents
        /// included, so a directory can be filled in before its own meta
        /// record turns up. This hangs them where they belong once every
        /// record has been seen, and drops what never got a meta record (a
        /// parent that was killed, or a half-written creation).
        fn settle(fs: *Fs) Error!void {
            for (fs.buckets) |head| {
                var n = head;
                while (n) |it| {
                    const following = it.hash_next;
                    if (it.kind == 0) {
                        fs.unhang(it);
                        fs.forget(it);
                        fs.freeNode(it);
                    }
                    n = following;
                }
            }
        }

        /// One record from the log into the tree. It answers how many of
        /// the record's bytes still say something, which is what the
        /// collector goes by.
        fn applyRecord(fs: *Fs, vol: *Volume, r: volume.Record) volume.Error!u32 {
            const applied = switch (r.kind) {
                .meta => fs.replayMeta(vol, r),
                .data => fs.replayData(vol, r),
                .trunc => fs.replayTrunc(vol, r),
                .kill => fs.replayKill(vol, r),
                else => return 0,
            };
            return applied catch |e| asVolume(e);
        }

        fn asVolume(e: Error) volume.Error {
            return switch (e) {
                error.NoMemory => error.NoMemory,
                else => error.ReadFailed,
            };
        }

        fn replayMeta(fs: *Fs, vol: *Volume, r: volume.Record) Error!u32 {
            var meta: flashfs.Meta = undefined;
            if (r.length < @sizeOf(flashfs.Meta)) return 0;
            if (!vol.readAt(r.at, std.mem.asBytes(&meta))) return error.MediumFailed;
            if (meta.inode == 0 or meta.name_len > max_name or meta.comment_len > max_comment) return 0;
            const n = fs.byInode(meta.inode) orelse try fs.newNode(meta.inode);
            if (n.meta_at != 0) vol.kill(n.meta_at, n.meta_size);
            n.kind = meta.kind;
            n.protection = meta.protection;
            n.date = meta.date;
            n.owner = @as(u32, meta.owner_uid) << 16 | meta.owner_gid;
            n.meta_at = r.at;
            n.meta_size = r.size;
            @memset(&n.name, 0);
            @memset(&n.comment, 0);
            if (!vol.readAt(r.at + @sizeOf(flashfs.Meta), n.name[0..meta.name_len])) return error.MediumFailed;
            if (!vol.readAt(r.at + @sizeOf(flashfs.Meta) + meta.name_len, n.comment[0..meta.comment_len])) {
                return error.MediumFailed;
            }
            // The parent may not have had its own record yet.
            const parent = if (meta.parent == n.inode) null else fs.byInode(meta.parent) orelse try fs.newNode(meta.parent);
            fs.unhang(n);
            n.parent = parent;
            if (parent) |p| {
                n.next = p.children;
                p.children = n;
            }
            return r.size;
        }

        fn replayData(fs: *Fs, vol: *Volume, r: volume.Record) Error!u32 {
            var data: flashfs.Data = undefined;
            if (r.length < @sizeOf(flashfs.Data)) return 0;
            if (!vol.readAt(r.at, std.mem.asBytes(&data))) return error.MediumFailed;
            const length = r.length - @sizeOf(flashfs.Data);
            if (length == 0) return 0;
            const n = fs.byInode(data.inode) orelse try fs.newNode(data.inode);
            try fs.place(n, data.offset, length, r.at + @sizeOf(flashfs.Data));
            if (data.offset + length > n.size) n.size = data.offset + length;
            // The bytes count; the header is counted with them.
            return r.size;
        }

        fn replayTrunc(fs: *Fs, vol: *Volume, r: volume.Record) Error!u32 {
            var trunc: flashfs.Trunc = undefined;
            if (r.length < @sizeOf(flashfs.Trunc)) return 0;
            if (!vol.readAt(r.at, std.mem.asBytes(&trunc))) return error.MediumFailed;
            const n = fs.byInode(trunc.inode) orelse try fs.newNode(trunc.inode);
            fs.cutTo(n, trunc.size);
            n.size = trunc.size;
            return r.size;
        }

        fn replayKill(fs: *Fs, vol: *Volume, r: volume.Record) Error!u32 {
            var gone: flashfs.Kill = undefined;
            if (r.length < @sizeOf(flashfs.Kill)) return 0;
            if (!vol.readAt(r.at, std.mem.asBytes(&gone))) return error.MediumFailed;
            const n = fs.byInode(gone.inode) orelse return r.size;
            if (n.meta_at != 0) vol.kill(n.meta_at, n.meta_size);
            fs.cutTo(n, 0);
            fs.unhang(n);
            fs.forget(n);
            fs.freeNode(n);
            return r.size;
        }

        /// Out of its directory, if it is in one.
        fn unhang(fs: *Fs, n: *Node) void {
            _ = fs;
            const parent = n.parent orelse return;
            if (parent.children == n) {
                parent.children = n.next;
            } else {
                var c = parent.children;
                while (c) |it| : (c = it.next) {
                    if (it.next == n) {
                        it.next = n.next;
                        break;
                    }
                }
            }
            n.parent = null;
            n.next = null;
        }

        // --- extents -------------------------------------------------------

        /// `length` bytes of the file at `offset` now live at `at`. What was
        /// there before stops counting.
        fn place(fs: *Fs, n: *Node, offset: u64, length: u32, at: u32) Error!void {
            const end = offset + length;
            var prev: ?*Extent = null;
            var it = n.extents;
            while (it) |e| {
                const e_end = e.offset + e.length;
                if (e_end <= offset) {
                    prev = e;
                    it = e.next;
                    continue;
                }
                if (e.offset >= end) break;
                // They overlap. What is left of the old one keeps its place.
                const front = if (e.offset < offset) offset - e.offset else 0;
                const back = if (e_end > end) e_end - end else 0;
                fs.vol.kill(e.at, @intCast(e.length - front - back));
                if (front != 0 and back != 0) {
                    // The new piece is inside the old one: split it.
                    const tail = fs.alloc(Extent) orelse return error.NoMemory;
                    tail.* = .{
                        .next = e.next,
                        .offset = end,
                        .length = @intCast(back),
                        .at = @intCast(e.at + (end - e.offset)),
                    };
                    e.length = @intCast(front);
                    e.next = tail;
                    // The new piece goes between the two halves.
                    prev = e;
                    it = tail;
                    break;
                }
                if (front != 0) {
                    e.length = @intCast(front);
                    prev = e;
                    it = e.next;
                    continue;
                }
                if (back != 0) {
                    e.at = @intCast(e.at + (end - e.offset));
                    e.length = @intCast(back);
                    e.offset = end;
                    it = e;
                    break;
                }
                // Gone entirely.
                const following = e.next;
                if (prev) |p| p.next = following else n.extents = following;
                fs.free(e);
                it = following;
            }
            const fresh = fs.alloc(Extent) orelse return error.NoMemory;
            fresh.* = .{ .next = it, .offset = offset, .length = length, .at = at };
            if (prev) |p| p.next = fresh else n.extents = fresh;
            fs.joinWithNext(n, fresh);
            if (prev) |p| fs.joinWithNext(n, p);
        }

        /// Two extents that follow each other in the file and on the medium
        /// become one, so a file written from start to end ends up with a
        /// single extent.
        fn joinWithNext(fs: *Fs, n: *Node, e: *Extent) void {
            _ = n;
            const following = e.next orelse return;
            if (e.offset + e.length != following.offset) return;
            if (e.at + e.length != following.at) return;
            e.length += following.length;
            e.next = following.next;
            fs.free(following);
        }

        /// The extent holding a file offset, if one does.
        fn extentAt(n: *Node, offset: u64) ?*Extent {
            var it = n.extents;
            while (it) |e| : (it = e.next) {
                if (offset < e.offset) return null;
                if (offset < e.offset + e.length) return e;
            }
            return null;
        }

        /// Where the next extent after a file offset begins.
        fn gapEnd(n: *Node, offset: u64) ?u64 {
            var it = n.extents;
            while (it) |e| : (it = e.next) {
                if (e.offset > offset) return e.offset;
            }
            return null;
        }

        /// Everything past `size` is gone; what stays keeps its place.
        fn cutTo(fs: *Fs, n: *Node, size: u64) void {
            var prev: ?*Extent = null;
            var it = n.extents;
            while (it) |e| {
                const following = e.next;
                if (e.offset >= size) {
                    fs.vol.kill(e.at, e.length);
                    if (prev) |p| p.next = following else n.extents = following;
                    fs.free(e);
                } else if (e.offset + e.length > size) {
                    const cut: u32 = @intCast(e.offset + e.length - size);
                    fs.vol.kill(e.at, cut);
                    e.length -= cut;
                    prev = e;
                } else {
                    prev = e;
                }
                it = following;
            }
        }

        // --- appending ------------------------------------------------------

        /// A record at the head, with a collection first if the volume is
        /// running out of sectors, and one more try if it still says no.
        fn append(fs: *Fs, kind: flashfs.Kind, fixed: []const u8, tail: []const u8, more: []const u8) Error!u32 {
            if (!fs.collecting and fs.vol.freeSegments() < free_floor) try fs.collect();
            if (fs.vol.append(kind, fixed, tail, more)) |at| return at else |e| {
                if (e != error.MediumFull) return fromVolume(e);
            }
            // A collection appends what it moves, and must not start
            // another one: that is what the floor of free sectors is for.
            if (fs.collecting) return error.DiskFull;
            try fs.collect();
            return fs.vol.append(kind, fixed, tail, more) catch |e| fromVolume(e);
        }

        /// Everything about an object but its bytes, written down again.
        fn writeMeta(fs: *Fs, n: *Node) Error!void {
            const name = n.nameSlice();
            const comment = n.commentSlice();
            const meta: flashfs.Meta = .{
                .inode = n.inode,
                .parent = if (n.parent) |p| p.inode else n.inode,
                .kind = n.kind,
                .protection = n.protection,
                .date = n.date,
                .owner_uid = @truncate(n.owner >> 16),
                .owner_gid = @truncate(n.owner),
                .name_len = @intCast(name.len),
                .comment_len = @intCast(comment.len),
            };
            const was_at = n.meta_at;
            const was_size = n.meta_size;
            const at = try fs.append(.meta, flashfs.bytesOf(&meta), name, comment);
            if (was_at != 0) fs.vol.kill(was_at, was_size);
            n.meta_at = at;
            n.meta_size = @intCast(flashfs.recordSize(@sizeOf(flashfs.Meta) + name.len + comment.len));
        }

        /// The most bytes one data record can carry.
        fn maxChunk(fs: *Fs) u32 {
            const room = fs.vol.sector_size - @sizeOf(flashfs.SegmentHeader) - @sizeOf(flashfs.RecordHeader);
            return room - @sizeOf(flashfs.Data);
        }

        fn writeKill(fs: *Fs, n: *Node) Error!void {
            const gone: flashfs.Kill = .{ .inode = n.inode };
            _ = try fs.append(.kill, flashfs.bytesOf(&gone), "", "");
            if (n.meta_at != 0) fs.vol.kill(n.meta_at, n.meta_size);
        }

        fn writeTrunc(fs: *Fs, n: *Node, size: u64) Error!void {
            const trunc: flashfs.Trunc = .{ .inode = n.inode, .size = size };
            _ = try fs.append(.trunc, flashfs.bytesOf(&trunc), "", "");
        }

        // --- the collector ---------------------------------------------------

        /// One sector back: what is still live in it goes to the head, and
        /// the sector is forgotten so the next segment erases it. Always
        /// the oldest segment, so the records that only speak of what came
        /// before them - a truncation, a deletion - can be dropped instead
        /// of moved, which would put them after what they preceded
        /// (volume.zig says more).
        fn collect(fs: *Fs) Error!void {
            if (fs.collecting) return error.DiskFull;
            const sector = fs.vol.oldest() orelse return error.DiskFull;
            if (sector == fs.vol.head) return error.DiskFull;
            fs.collecting = true;
            defer fs.collecting = false;
            const from = sector * fs.vol.sector_size;
            const to = from + fs.vol.sector_size;

            // The bytes of files that live in this sector, written again.
            // Writing one replaces the extent it came from, so the list is
            // walked from the start each time.
            for (fs.buckets) |head| {
                var node = head;
                while (node) |n| : (node = n.hash_next) {
                    while (firstIn(n, from, to)) |extent| {
                        try fs.moveExtent(n, extent.offset, extent.length, extent.at);
                    }
                    if (n.meta_at >= from and n.meta_at < to) try fs.writeMeta(n);
                }
            }
            fs.vol.forget(sector) catch |e| return fromVolume(e);
        }

        /// The first of a file's extents that lies in a range of the
        /// medium, as values: the extent itself may be replaced by moving
        /// it.
        fn firstIn(n: *Node, from: u32, to: u32) ?Extent {
            var it = n.extents;
            while (it) |e| : (it = e.next) {
                if (e.at >= from and e.at < to) return .{ .offset = e.offset, .length = e.length, .at = e.at };
            }
            return null;
        }

        /// Bytes read from where they are and appended at the head, in
        /// pieces a record can hold.
        fn moveExtent(fs: *Fs, n: *Node, offset: u64, length: u32, at: u32) Error!void {
            const buffer = fs.media.alloc(@min(length, fs.maxChunk())) orelse return error.NoMemory;
            defer fs.media.free(buffer);
            var done: u32 = 0;
            while (done < length) {
                const piece: u32 = @min(@as(u32, @intCast(buffer.len)), length - done);
                if (!fs.vol.readAt(at + done, buffer[0..piece])) return error.MediumFailed;
                const data: flashfs.Data = .{ .inode = n.inode, .offset = offset + done };
                const put = try fs.append(.data, flashfs.bytesOf(&data), buffer[0..piece], "");
                try fs.place(n, offset + done, piece, put + @sizeOf(flashfs.Data));
                done += piece;
            }
        }

        // --- locks -----------------------------------------------------------

        fn owns(fs: *Fs, l: *DiskLock) bool {
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x == l) return true;
            }
            return false;
        }

        /// A lock from a packet: one of ours, or null for the root.
        fn lockArg(fs: *Fs, value: isize) Error!?*DiskLock {
            if (value == 0) return null;
            const l: *DiskLock = @ptrFromInt(ptrArg(value));
            if (!fs.owns(l)) return error.InvalidLock;
            return l;
        }

        /// The directory a lock from a packet stands for (null: the root).
        fn dirOf(fs: *Fs, value: isize) Error!*Node {
            const l = try fs.lockArg(value) orelse return fs.root;
            return l.node();
        }

        fn isLocked(fs: *Fs, n: *Node) bool {
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x.node() == n) return true;
            }
            return false;
        }

        /// A new lock on a node: shared locks go together, an exclusive one
        /// wants the node to itself.
        fn getLock(fs: *Fs, n: *Node, access: i32) Error!*DiskLock {
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x.node() == n and (access == dos.EXCLUSIVE_LOCK or x.lock.access == dos.EXCLUSIVE_LOCK)) return error.InUse;
            }
            const l = fs.alloc(DiskLock) orelse return error.NoMemory;
            l.* = .{ .lock = .{
                .link = if (fs.locks) |head| &head.lock else null,
                .key = @intFromPtr(n),
                .access = if (access == dos.EXCLUSIVE_LOCK) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
                .task = fs.port,
                .volume = fs.volume_node,
            } };
            fs.locks = l;
            return l;
        }

        fn freeLock(fs: *Fs, l: *DiskLock) void {
            if (fs.locks == l) {
                fs.locks = l.nextLock();
            } else {
                var it = fs.locks;
                while (it) |x| : (it = x.nextLock()) {
                    if (x.lock.link == &l.lock) {
                        x.lock.link = l.lock.link;
                        break;
                    }
                }
            }
            fs.free(l);
        }

        /// Whether a lock but `l` is on the node (with `exclusive_only`, an
        /// exclusive one).
        fn otherLock(fs: *Fs, n: *Node, l: ?*DiskLock, exclusive_only: bool) bool {
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x == l or x.node() != n) continue;
                if (!exclusive_only or x.lock.access == dos.EXCLUSIVE_LOCK) return true;
            }
            return false;
        }

        // --- names -----------------------------------------------------------

        fn child(fs: *Fs, dir: *Node, name: []const u8) Error!?*Node {
            _ = fs;
            if (!dir.isDir()) return error.WrongType;
            var c = dir.children;
            while (c) |it| : (c = it.next) {
                if (sameName(it.nameSlice(), name)) return it;
            }
            return null;
        }

        /// A path's last part, checked for length.
        fn component(part: []const u8) Error![max_name:0]u8 {
            if (part.len > max_name) return error.InvalidName;
            var name: [max_name:0]u8 = @splat(0);
            @memcpy(name[0..part.len], part);
            return name;
        }

        /// Drop the device, walk the directories from
        /// `start` ("" goes up), and leave the last part.
        fn findDir(fs: *Fs, start: *Node, path: [*:0]const u8) Error!Place {
            var s = std.mem.span(path);
            if (std.mem.indexOfScalar(u8, s, ':')) |colon| s = s[colon + 1 ..];
            var dir = start;
            var parts = std.mem.splitScalar(u8, s, '/');
            var part = parts.first();
            while (parts.next()) |following| : (part = following) {
                if (part.len == 0) {
                    dir = dir.parent orelse return error.NotFound;
                    continue;
                }
                const name = try component(part);
                dir = try fs.child(dir, std.mem.sliceTo(&name, 0)) orelse return error.NotFound;
                if (!dir.isDir()) return error.WrongType;
            }
            return .{ .dir = dir, .name = try component(part) };
        }

        /// The node a path names, from the directory a lock stands for.
        fn locate(fs: *Fs, dir_arg: isize, path: [*:0]const u8) Error!*Node {
            const spot = try fs.findDir(try fs.dirOf(dir_arg), path);
            if (spot.name[0] == 0) return spot.dir;
            return try fs.child(spot.dir, std.mem.sliceTo(&spot.name, 0)) orelse error.NotFound;
        }

        /// A new file or directory, written down and locked.
        fn create(fs: *Fs, dir_arg: isize, path: [*:0]const u8, kind: i32, access: i32) Error!*DiskLock {
            const spot = try fs.findDir(try fs.dirOf(dir_arg), path);
            const name = std.mem.sliceTo(&spot.name, 0);
            try validName(name);
            if (try fs.child(spot.dir, name) != null) return error.Exists;
            const n = try fs.newNode(fs.next_inode);
            n.kind = kind;
            n.date = fs.media.now();
            n.name = spot.name;
            n.parent = spot.dir;
            n.next = spot.dir.children;
            spot.dir.children = n;
            errdefer {
                fs.unhang(n);
                fs.forget(n);
                fs.freeNode(n);
            }
            try fs.writeMeta(n);
            const l = try fs.getLock(n, access);
            spot.dir.date = n.date;
            fs.writeMeta(spot.dir) catch {};
            l.modified = true;
            return l;
        }

        fn delete(fs: *Fs, dir_arg: isize, path: [*:0]const u8) Error!void {
            const n = try fs.locate(dir_arg, path);
            if (n == fs.root) return error.WrongType;
            if (n.isDir() and n.children != null) return error.NotEmpty;
            if (n.protection & dos.FIBF_DELETE != 0) return error.DeleteProtected;
            if (fs.isLocked(n)) return error.InUse;
            try fs.writeKill(n);
            const parent = n.parent;
            fs.unhang(n);
            fs.cutTo(n, 0);
            fs.forget(n);
            fs.freeNode(n);
            if (parent) |p| {
                p.delcount +%= 1;
                p.date = fs.media.now();
                fs.writeMeta(p) catch {};
            }
        }

        // --- files -------------------------------------------------------------

        fn fileOf(fs: *Fs, fh: ?*FileHandle) Error!*DiskLock {
            const handle = fh orelse return error.InvalidLock;
            const l: *DiskLock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
            if (!fs.owns(l)) return error.InvalidLock;
            return l;
        }

        /// FINDINPUT (an existing file, shared), FINDOUTPUT (a new or
        /// emptied file, exclusive), FINDUPDATE (an existing or new file,
        /// shared), as RAM: has them.
        fn open(fs: *Fs, args: dos.FindArgs, action: dos.ActionCode) Error!void {
            const fh = args.fh orelse return error.InvalidLock;
            const dir_arg: isize = @bitCast(@intFromPtr(args.lock));
            const path = args.name orelse return error.InvalidName;
            const l: *DiskLock = switch (action) {
                .findinput => blk: {
                    const n = try fs.locate(dir_arg, path);
                    if (n.isDir()) return error.WrongType;
                    break :blk try fs.getLock(n, dos.SHARED_LOCK);
                },
                .findoutput => if (fs.locate(dir_arg, path)) |n| blk: {
                    if (n.isDir()) return error.WrongType;
                    const l = try fs.getLock(n, dos.EXCLUSIVE_LOCK);
                    errdefer fs.freeLock(l);
                    try fs.writeTrunc(n, 0);
                    fs.cutTo(n, 0);
                    n.size = 0;
                    l.modified = true;
                    break :blk l;
                } else |e| blk: {
                    if (e != error.NotFound) return e;
                    break :blk try fs.create(dir_arg, path, dos.ST_FILE, dos.EXCLUSIVE_LOCK);
                },
                else => if (fs.locate(dir_arg, path)) |n| blk: {
                    if (n.isDir()) return error.WrongType;
                    break :blk try fs.getLock(n, dos.SHARED_LOCK);
                } else |e| blk: {
                    if (e != error.NotFound) return e;
                    break :blk try fs.create(dir_arg, path, dos.ST_FILE, dos.SHARED_LOCK);
                },
            };
            fh.key = l;
            fh.interactive = false;
        }

        fn read(fs: *Fs, args: dos.IOArgs) Error!usize {
            const l = try fs.fileOf(args.fh);
            const n = l.node();
            const buf = args.buffer orelse return 0;
            const len: usize = if (args.length > 0) @intCast(args.length) else 0;
            var done: usize = 0;
            while (done < len and l.pos < n.size) {
                const want: usize = @intCast(@min(@as(u64, len - done), n.size - l.pos));
                if (extentAt(n, l.pos)) |e| {
                    const off: u32 = @intCast(l.pos - e.offset);
                    const count = @min(want, e.length - off);
                    if (!fs.vol.readAt(e.at + off, buf[done..][0..count])) return error.MediumFailed;
                    done += count;
                    l.pos += count;
                } else {
                    // A hole: bytes never written read as zero.
                    const until = gapEnd(n, l.pos) orelse n.size;
                    const count: usize = @intCast(@min(@as(u64, want), until - l.pos));
                    @memset(buf[done..][0..count], 0);
                    done += count;
                    l.pos += count;
                }
            }
            return done;
        }

        fn write(fs: *Fs, args: dos.IOArgs) Error!usize {
            const l = try fs.fileOf(args.fh);
            const n = l.node();
            const buf = args.buffer orelse return 0;
            const len: usize = if (args.length > 0) @intCast(args.length) else 0;
            var done: usize = 0;
            defer if (done > 0) {
                l.modified = true;
            };
            const chunk = fs.maxChunk();
            while (done < len) {
                const piece: u32 = @intCast(@min(len - done, chunk));
                const data: flashfs.Data = .{ .inode = n.inode, .offset = l.pos };
                const at = try fs.append(.data, flashfs.bytesOf(&data), buf[done..][0..piece], "");
                try fs.place(n, l.pos, piece, at + @sizeOf(flashfs.Data));
                done += piece;
                l.pos += piece;
                if (l.pos > n.size) n.size = l.pos;
            }
            return done;
        }

        /// To a position from the beginning, the current position or the
        /// end; the old position. Not before the start or past the end.
        fn seek(fs: *Fs, args: dos.SeekArgs) Error!u64 {
            const l = try fs.fileOf(args.fh);
            const size: i64 = @intCast(l.node().size);
            const from: i64 = switch (args.mode) {
                dos.OFFSET_BEGINNING => 0,
                dos.OFFSET_CURRENT => @intCast(l.pos),
                dos.OFFSET_END => size,
                else => return error.SeekError,
            };
            const target = from + args.position;
            if (target < 0 or target > size) return error.SeekError;
            const old = l.pos;
            l.pos = @intCast(target);
            return old;
        }

        /// END: the file dated if written to, its lock freed, and what is
        /// still in the head buffer put on the medium.
        fn close(fs: *Fs, args: dos.FileHandleArgs) Error!void {
            const l = try fs.fileOf(args.fh);
            const n = l.node();
            if (l.modified) {
                n.date = fs.media.now();
                try fs.writeMeta(n);
            }
            fs.freeLock(l);
            args.fh.?.key = null;
            fs.vol.flush() catch |e| return fromVolume(e);
        }

        /// SET_FILE_SIZE: the file cut or grown; handles past the new end
        /// move back to it. The new size.
        fn setFileSize(fs: *Fs, args: dos.SeekArgs) Error!u64 {
            const l = try fs.fileOf(args.fh);
            const n = l.node();
            const from: i64 = switch (args.mode) {
                dos.OFFSET_BEGINNING => 0,
                dos.OFFSET_CURRENT => @intCast(l.pos),
                dos.OFFSET_END => @intCast(n.size),
                else => return error.SeekError,
            };
            const target = from + args.position;
            if (target < 0) return error.SeekError;
            const size: u64 = @intCast(target);
            try fs.writeTrunc(n, size);
            fs.cutTo(n, size);
            n.size = size;
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x.node() != n) continue;
                if (x.pos > size) x.pos = size;
            }
            l.modified = true;
            return size;
        }

        /// FH_FROM_LOCK: the lock on a file becomes the handle's.
        fn fhFromLock(fs: *Fs, args: dos.FhFromLockArgs) Error!void {
            const fh = args.fh orelse return error.InvalidLock;
            const l = try fs.lockArg(lockValue(args.lock)) orelse return error.InvalidLock;
            if (l.node().isDir()) return error.WrongType;
            l.pos = 0;
            fh.key = l;
            fh.interactive = false;
        }

        /// CHANGE_MODE, as RAM:'s.
        fn changeMode(fs: *Fs, args: dos.ChangeModeArgs) Error!void {
            var l: *DiskLock = undefined;
            var exclusive = false;
            switch (args.kind) {
                dos.CHANGE_LOCK => {
                    l = try fs.lockArg(@bitCast(@intFromPtr(args.object))) orelse return error.InvalidLock;
                    exclusive = args.mode == dos.EXCLUSIVE_LOCK;
                },
                dos.CHANGE_FH => {
                    l = try fs.fileOf(@ptrCast(@alignCast(args.object)));
                    exclusive = args.mode == dos.MODE_NEWFILE;
                },
                else => return error.WrongType,
            }
            if (exclusive and fs.otherLock(l.node(), l, false)) return error.InUse;
            l.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
        }

        // --- examine ------------------------------------------------------------

        fn fill(fs: *Fs, fib: *FileInfoBlock, n: *Node) void {
            fib.* = .{
                .disk_key = n.inode,
                .dir_entry_type = n.kind,
                .entry_type = n.kind,
                .protection = n.protection,
                .size = n.size,
                .num_blocks = (n.size + fs.vol.sector_size - 1) / fs.vol.sector_size,
                .date = n.date,
            };
            const name = n.nameSlice();
            @memcpy(fib.file_name[0..name.len], name);
            const comment = n.commentSlice();
            @memcpy(fib.comment[0..comment.len], comment);
            fib.owner_uid = @truncate(n.owner >> 16);
            fib.owner_gid = @truncate(n.owner);
        }

        /// EXAMINE_FH: the open file's own entry.
        fn examineFile(fs: *Fs, args: dos.ExamineFHArgs) Error!void {
            const l = try fs.fileOf(args.fh);
            fs.fill(args.fib orelse return error.InvalidLock, l.node());
        }

        fn contains(dir: *Node, n: *Node) bool {
            var c = dir.children;
            while (c) |it| : (c = it.next) {
                if (it == n) return true;
            }
            return false;
        }

        /// EXAMINE_OBJECT (`next` false) and EXAMINE_NEXT, as RAM:'s: the
        /// FileInfoBlock carries the entry it last gave in fib_DiskKey, and
        /// the walk starts again if that entry has gone.
        fn examine(fs: *Fs, args: dos.ExamineArgs, next: bool) Error!void {
            const l = try fs.lockArg(@bitCast(@intFromPtr(args.lock)));
            const n = if (l) |it| it.node() else fs.root;
            const fib = args.fib orelse return error.InvalidLock;
            if (!next) {
                if (l) |it| it.delcount = n.delcount;
                fs.fill(fib, n);
                return;
            }
            if (!n.isDir()) return error.NoMoreEntries;
            var from: ?*Node = if (fib.disk_key == n.inode) n else fs.byInode(@truncate(fib.disk_key));
            if (from != n) {
                const changed = if (l) |it| it.delcount != n.delcount else true;
                if (from == null or (changed and !contains(n, from.?))) from = n;
            }
            if (l) |it| it.delcount = n.delcount;
            const entry = (if (from == n) n.children else from.?.next) orelse return error.NoMoreEntries;
            fs.fill(fib, entry);
        }

        // --- changing -------------------------------------------------------------

        /// RENAME_OBJECT, as RAM:'s.
        fn rename(fs: *Fs, args: dos.RenameArgs) Error!void {
            const from = try fs.locate(lockValue(args.from_lock), args.from_name orelse return error.InvalidName);
            if (from == fs.root) return error.WrongType;
            const spot = try fs.findDir(try fs.dirOf(lockValue(args.to_lock)), args.to_name orelse return error.InvalidName);
            if (!spot.dir.isDir()) return error.WrongType;
            const name = std.mem.sliceTo(&spot.name, 0);
            try validName(name);
            if (try fs.child(spot.dir, name)) |there| {
                if (there != from) return error.Exists;
            }
            var up: ?*Node = spot.dir;
            while (up) |it| : (up = it.parent) {
                if (it == from) return error.InUse;
            }
            if (fs.otherLock(from, null, true)) return error.InUse;
            const old_parent = from.parent;
            fs.unhang(from);
            from.parent = spot.dir;
            from.next = spot.dir.children;
            spot.dir.children = from;
            from.name = spot.name;
            try fs.writeMeta(from);
            if (old_parent) |p| p.delcount +%= 1;
            spot.dir.date = fs.media.now();
            fs.writeMeta(spot.dir) catch {};
        }

        /// SET_PROTECT, SET_COMMENT, SET_DATE and SET_OWNER on (lock, name).
        fn setProperty(fs: *Fs, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
            const n = try fs.locate(lockValue(args.lock), args.name orelse return error.InvalidName);
            if (n == fs.root) return error.WrongType;
            const bits: u32 = @truncate(ptrArg(args.value));
            switch (action) {
                .set_protect => n.protection = bits,
                .set_owner => n.owner = bits,
                .set_date => {
                    const date: ?*const dos.DateStamp = @ptrFromInt(ptrArg(args.value));
                    n.date = if (date) |d| d.* else fs.media.now();
                },
                else => {
                    const text: ?[*:0]const u8 = @ptrFromInt(ptrArg(args.value));
                    const s: []const u8 = if (text) |t| std.mem.span(t) else "";
                    if (s.len > max_comment) return error.CommentTooBig;
                    @memset(&n.comment, 0);
                    @memcpy(n.comment[0..s.len], s);
                },
            }
            try fs.writeMeta(n);
        }

        /// INFO and DISK_INFO: the volume's sectors, and how many of them
        /// hold a segment.
        fn info(fs: *Fs, data: ?*dos.InfoData) Error!void {
            const d = data orelse return error.InvalidLock;
            const total = fs.vol.sectors - 1;
            d.* = .{
                .num_soft_errors = 0,
                .unit_number = 0,
                .disk_state = dos.ID_VALIDATED,
                .num_blocks = total,
                .num_blocks_used = total - fs.vol.freeSegments(),
                .bytes_per_block = fs.vol.sector_size,
                .disk_type = flashfs.ID_FLASHFS_DISK,
                .volume_node = fs.volume_node,
                .in_use = if (fs.locks != null) -1 else 0,
            };
        }

        // --- packets ----------------------------------------------------------------

        /// The answer to one packet (all but STARTUP, which the process
        /// takes). The same set RAM: answers, with the same meanings.
        ///
        /// What changes the tree reaches the medium before the packet is
        /// answered; a file's bytes wait in the head buffer until it is
        /// closed or flushed. A flush gives up the
        /// rest of a page, which is why a write does not do one.
        pub fn answer(fs: *Fs, pkt: *DosPacket) Answer {
            const result = fs.respond(pkt);
            switch (pkt.getAction()) {
                .create_dir,
                .delete_object,
                .rename_object,
                .set_protect,
                .set_comment,
                .set_date,
                .set_owner,
                .set_file_size,
                .findoutput,
                .end,
                .flush,
                .format,
                => fs.vol.flush() catch {},
                else => {},
            }
            return result;
        }

        fn respond(fs: *Fs, pkt: *DosPacket) Answer {
            const a = pkt.args.raw;
            switch (pkt.getAction()) {
                .locate_object => {
                    const n = fs.locate(a[0], @ptrFromInt(ptrArg(a[1]))) catch |e| return no(e);
                    const l = fs.getLock(n, @truncate(a[2])) catch |e| return no(e);
                    return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
                },
                .free_lock => {
                    const l = fs.lockArg(a[0]) catch |e| return no(e);
                    if (l) |it| fs.freeLock(it);
                    return yes();
                },
                .copy_dir, .parent => {
                    const n = fs.dirOf(a[0]) catch |e| return no(e);
                    const target = if (pkt.getAction() == .parent) n.parent orelse return .{ .res1 = 0, .res2 = 0 } else n;
                    const l = fs.getLock(target, dos.SHARED_LOCK) catch |e| return no(e);
                    return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
                },
                .same_lock => {
                    const n1 = fs.dirOf(a[0]) catch |e| return no(e);
                    const n2 = fs.dirOf(a[1]) catch |e| return no(e);
                    return .{ .res1 = if (n1 == n2) dos.DOSTRUE else dos.DOSFALSE, .res2 = 0 };
                },
                .create_dir => {
                    const l = fs.create(a[0], @ptrFromInt(ptrArg(a[1])), dos.ST_USERDIR, dos.EXCLUSIVE_LOCK) catch |e| return no(e);
                    return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
                },
                .delete_object => {
                    fs.delete(a[0], @ptrFromInt(ptrArg(a[1]))) catch |e| return no(e);
                    return yes();
                },
                .findinput, .findoutput, .findupdate => {
                    fs.open(pkt.args.find, pkt.getAction()) catch |e| return no(e);
                    return yes();
                },
                .read => {
                    const count = fs.read(pkt.args.io) catch |e| return minusOne(e);
                    return .{ .res1 = @intCast(count), .res2 = 0 };
                },
                .write => {
                    const count = fs.write(pkt.args.io) catch |e| return minusOne(e);
                    return .{ .res1 = @intCast(count), .res2 = 0 };
                },
                .seek => {
                    const old = fs.seek(pkt.args.seek) catch |e| return minusOne(e);
                    return .{ .res1 = @intCast(old), .res2 = 0 };
                },
                .end => {
                    fs.close(pkt.args.file) catch |e| return no(e);
                    return yes();
                },
                .examine_object, .examine_next => {
                    fs.examine(pkt.args.examine, pkt.getAction() == .examine_next) catch |e| return no(e);
                    return yes();
                },
                .examine_fh => {
                    fs.examineFile(pkt.args.examine_fh) catch |e| return no(e);
                    return yes();
                },
                .rename_object => {
                    fs.rename(pkt.args.rename) catch |e| return no(e);
                    return yes();
                },
                .set_protect, .set_comment, .set_date, .set_owner => {
                    fs.setProperty(pkt.args.property, pkt.getAction()) catch |e| return no(e);
                    return yes();
                },
                .set_file_size => {
                    const size = fs.setFileSize(pkt.args.seek) catch |e| return minusOne(e);
                    return .{ .res1 = @intCast(size), .res2 = 0 };
                },
                .parent_fh, .copy_dir_fh => {
                    const l = fs.fileOf(pkt.args.file.fh) catch |e| return no(e);
                    const n = l.node();
                    const target = if (pkt.getAction() == .parent_fh) n.parent orelse return .{ .res1 = 0, .res2 = 0 } else n;
                    const got = fs.getLock(target, dos.SHARED_LOCK) catch |e| return no(e);
                    return .{ .res1 = @bitCast(@intFromPtr(got)), .res2 = 0 };
                },
                .fh_from_lock => {
                    fs.fhFromLock(pkt.args.fh_from_lock) catch |e| return no(e);
                    return yes();
                },
                .change_mode => {
                    fs.changeMode(pkt.args.change_mode) catch |e| return no(e);
                    return yes();
                },
                .info => {
                    _ = fs.lockArg(lockValue(pkt.args.info.lock)) catch |e| return no(e);
                    fs.info(pkt.args.info.info) catch |e| return no(e);
                    return yes();
                },
                .disk_info => {
                    fs.info(@ptrFromInt(ptrArg(a[0]))) catch |e| return no(e);
                    return yes();
                },
                .flush => {
                    fs.vol.flush() catch |e| return no(fromVolume(e));
                    return yes();
                },
                .format => {
                    const label: ?[*:0]const u8 = @ptrFromInt(ptrArg(a[0]));
                    fs.reformat(if (label) |l| std.mem.span(l) else "Empty") catch |e| return no(e);
                    return yes();
                },
                .more_cache => {
                    // The medium is read through its mapping, so there are
                    // no buffers to add to: it answers with the number the
                    // mountlist gave it and keeps it.
                    return .{ .res1 = @intCast(fs.buffers), .res2 = 0 };
                },
                .is_filesystem => return yes(),
                .die => return no(error.InUse), // it stays, as RAM: does
                else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
            }
        }
    };
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;
const MemMedia = @import("memmedia.zig").MemMedia;

const TestFs = FileSystem(MemMedia);

const test_sectors = 24;
const test_sector = 512;
const test_page = 64;

fn send(fs: *TestFs, action: dos.ActionCode, args: [4]isize) Answer {
    var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
    return fs.answer(&pkt);
}

fn sendArgs(fs: *TestFs, action: dos.ActionCode, args: dos.PacketArgs) Answer {
    var pkt = DosPacket.init(action, args);
    return fs.answer(&pkt);
}

/// A file written from nothing: its contents, through the packets a
/// program's Open/Write/Close send.
fn writeFile(fs: *TestFs, name: [*:0]const u8, text: []const u8) !void {
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = name } }).res1);
    const count = sendArgs(fs, .write, .{ .io = .{
        .fh = &fh,
        .buffer = @constCast(text.ptr),
        .length = @intCast(text.len),
    } });
    try testing.expectEqual(@as(isize, @intCast(text.len)), count.res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .end, .{ .file = .{ .fh = &fh } }).res1);
}

/// What a file holds, read back through the packets.
fn readFile(fs: *TestFs, name: [*:0]const u8, into: []u8) !usize {
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = name } }).res1);
    const count = sendArgs(fs, .read, .{ .io = .{ .fh = &fh, .buffer = into.ptr, .length = @intCast(into.len) } });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .end, .{ .file = .{ .fh = &fh } }).res1);
    if (count.res1 < 0) return error.ReadFailed;
    return @intCast(count.res1);
}

test "a formatted volume has an empty root" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .examine_object, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
    try testing.expectEqualStrings("System", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);
    try testing.expectEqual(dos.DOSFALSE, sendArgs(&fs, .examine_next, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
    fs.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a file written comes back after mounting again" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    const made = send(&fs, .create_dir, .{ 0, @bitCast(@intFromPtr("dir")), dos.EXCLUSIVE_LOCK, 0 });
    try testing.expect(made.res1 != 0);
    _ = send(&fs, .free_lock, .{ made.res1, 0, 0, 0 });
    try writeFile(&fs, "dir/hello", "one two three");
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    var buffer: [32]u8 = undefined;
    const count = try readFile(&again, "dir/hello", &buffer);
    try testing.expectEqualStrings("one two three", buffer[0..count]);
    // And the directory is where it was.
    var fib: FileInfoBlock = undefined;
    const lock = send(&again, .locate_object, .{ 0, @bitCast(@intFromPtr("dir")), dos.SHARED_LOCK, 0 });
    try testing.expect(lock.res1 != 0);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&again, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
    try testing.expectEqualStrings("dir", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&again, .examine_next, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
    try testing.expectEqualStrings("hello", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(@as(u64, 13), fib.size);
    _ = send(&again, .free_lock, .{ lock.res1, 0, 0, 0 });
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "writing over the middle of a file wins, and survives mounting" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "f", "aaaaaaaaaa");

    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .findupdate, .{ .find = .{ .fh = &fh, .lock = null, .name = "f" } }).res1);
    try testing.expectEqual(@as(isize, 0), sendArgs(&fs, .seek, .{ .seek = .{ .fh = &fh, .position = 3, .mode = dos.OFFSET_BEGINNING } }).res1);
    const written = sendArgs(&fs, .write, .{ .io = .{ .fh = &fh, .buffer = @constCast(@as([]const u8, "bbbb").ptr), .length = 4 } });
    try testing.expectEqual(@as(isize, 4), written.res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .end, .{ .file = .{ .fh = &fh } }).res1);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    var buffer: [32]u8 = undefined;
    const count = try readFile(&again, "f", &buffer);
    try testing.expectEqualStrings("aaabbbbaaa", buffer[0..count]);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "cutting a file and growing it again reads zeros" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "f", "0123456789");

    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .findupdate, .{ .find = .{ .fh = &fh, .lock = null, .name = "f" } }).res1);
    try testing.expectEqual(@as(isize, 4), sendArgs(&fs, .set_file_size, .{ .seek = .{ .fh = &fh, .position = 4, .mode = dos.OFFSET_BEGINNING } }).res1);
    try testing.expectEqual(@as(isize, 10), sendArgs(&fs, .set_file_size, .{ .seek = .{ .fh = &fh, .position = 10, .mode = dos.OFFSET_BEGINNING } }).res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .end, .{ .file = .{ .fh = &fh } }).res1);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    var buffer: [32]u8 = undefined;
    const count = try readFile(&again, "f", &buffer);
    try testing.expectEqual(@as(usize, 10), count);
    try testing.expectEqualStrings("0123\x00\x00\x00\x00\x00\x00", buffer[0..count]);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a file longer than one record comes back whole" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    var text: [1500]u8 = undefined;
    for (&text, 0..) |*c, i| c.* = @intCast('0' + i % 10);
    try writeFile(&fs, "big", &text);
    var buffer: [2048]u8 = undefined;
    try testing.expectEqual(@as(usize, text.len), try readFile(&fs, "big", &buffer));
    try testing.expectEqualSlices(u8, &text, buffer[0..text.len]);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    const count = try readFile(&again, "big", &buffer);
    try testing.expectEqual(@as(usize, text.len), count);
    try testing.expectEqualSlices(u8, &text, buffer[0..count]);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "the real geometry: a file of records that each fill a sector" {
    // 4 KiB sectors and 256-byte pages, as flash.device reports them: a
    // data record is then exactly as long as a segment's room, which is the
    // case the smaller test geometry never hits.
    const sector: u32 = 4096;
    const store = try testing.allocator.alloc(u8, 12 * sector);
    defer testing.allocator.free(store);
    var media = MemMedia.init(store, sector, 256);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    const text = try testing.allocator.alloc(u8, 9604);
    defer testing.allocator.free(text);
    for (text, 0..) |*c, i| c.* = @intCast('0' + i % 10);
    try writeFile(&fs, "type", text);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    const buffer = try testing.allocator.alloc(u8, text.len + 16);
    defer testing.allocator.free(buffer);
    const count = try readFile(&again, "type", buffer);
    try testing.expectEqual(text.len, count);
    try testing.expectEqualSlices(u8, text, buffer[0..count]);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a deleted file stays deleted" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "gone", "bytes");
    try writeFile(&fs, "stays", "bytes");
    try testing.expectEqual(dos.DOSTRUE, send(&fs, .delete_object, .{ 0, @bitCast(@intFromPtr("gone")), 0, 0 }).res1);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    const lock = send(&again, .locate_object, .{ 0, @bitCast(@intFromPtr("gone")), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.DOSFALSE, lock.res1);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, lock.res2);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try readFile(&again, "stays", &buffer));
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "protection and a comment come back" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "f", "x");
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .set_protect, .{ .property = .{
        .lock = null,
        .name = "f",
        .value = dos.FIBF_PURE,
    } }).res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .set_comment, .{ .property = .{
        .lock = null,
        .name = "f",
        .value = @bitCast(@intFromPtr("a note")),
    } }).res1);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    const lock = send(&again, .locate_object, .{ 0, @bitCast(@intFromPtr("f")), dos.SHARED_LOCK, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&again, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
    try testing.expectEqual(@as(u32, dos.FIBF_PURE), fib.protection);
    try testing.expectEqualStrings("a note", std.mem.sliceTo(&fib.comment, 0));
    _ = send(&again, .free_lock, .{ lock.res1, 0, 0, 0 });
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "the power going mid-write leaves what was there before" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "first", "safe");
    // The power goes part-way through the next file.
    media.budget = 40;
    writeFile(&fs, "second", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch {};
    media.budget = null;
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("safe", buffer[0..try readFile(&again, "first", &buffer)]);
    // And the volume takes writes again.
    try writeFile(&again, "third", "later");
    again.deinit();

    var third = TestFs.init(&media, null);
    try third.mount();
    try testing.expectEqualStrings("safe", buffer[0..try readFile(&third, "first", &buffer)]);
    try testing.expectEqualStrings("later", buffer[0..try readFile(&third, "third", &buffer)]);
    third.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "the collector keeps a file whole while the same one is rewritten" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    try writeFile(&fs, "keep", "the one that has to survive");

    // Far more than the volume holds, so the collector has to run.
    var text: [200]u8 = undefined;
    var round: u32 = 0;
    while (round < 40) : (round += 1) {
        @memset(&text, @intCast('a' + round % 26));
        try writeFile(&fs, "churn", &text);
    }
    try testing.expect(media.erases > 1);
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("the one that has to survive", buffer[0..try readFile(&fs, "keep", &buffer)]);
    fs.deinit();

    var again = TestFs.init(&media, null);
    try again.mount();
    try testing.expectEqualStrings("the one that has to survive", buffer[0..try readFile(&again, "keep", &buffer)]);
    const count = try readFile(&again, "churn", &buffer);
    try testing.expectEqual(@as(usize, 200), count);
    try testing.expectEqual(text[0], buffer[0]);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}

test "a full volume says so instead of losing data" {
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    var text: [400]u8 = undefined;
    @memset(&text, 'z');
    var made: u32 = 0;
    var full = false;
    while (made < 60 and !full) : (made += 1) {
        var name: [16]u8 = undefined;
        const called = std.fmt.bufPrintZ(&name, "f{d}", .{made}) catch unreachable;
        // Straight through the packets, so a refusal is an answer and not
        // a failed expectation.
        var fh: FileHandle = .{};
        const opened = sendArgs(&fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = called.ptr } });
        if (opened.res1 == dos.DOSFALSE) {
            full = true;
            try testing.expectEqual(dos.ERROR_DISK_FULL, opened.res2);
            break;
        }
        const count = sendArgs(&fs, .write, .{ .io = .{ .fh = &fh, .buffer = &text, .length = text.len } });
        _ = sendArgs(&fs, .end, .{ .file = .{ .fh = &fh } });
        if (count.res1 != text.len) {
            full = true;
            try testing.expectEqual(dos.ERROR_DISK_FULL, count.res2);
        }
    }
    try testing.expect(full);
    // What was written before it filled up is still readable.
    var buffer: [512]u8 = undefined;
    try testing.expectEqual(@as(usize, 400), try readFile(&fs, "f0", &buffer));
    fs.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}
