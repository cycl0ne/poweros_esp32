// SPDX-License-Identifier: MPL-2.0
//! The RAM: handler: a file system in memory. A ROM module of its own ("ram-handler"), which dos's
//! init makes a system segment; its "RAM" device node starts it on first
//! use. At startup it adds the volume "Ram Disk" and sets the device node's
//! port.
//!
//! It keeps a tree of nodes (a directory's entries in a list, new
//! ones first, looked up by name in any case), file data in 1K blocks, and
//! locks that are a FileLock with the handler's fields after it (fl_Key is
//! the node). Shared locks go together, an exclusive one wants the node to
//! itself; COPY_DIR and PARENT give shared locks. Names are walked from the
//! lock's directory after the device ("RAM:") is dropped: "a/b", "/" for
//! the parent, "" for the directory itself.
//!
//! It answers LOCATE_OBJECT, FREE_LOCK, COPY_DIR, PARENT, SAME_LOCK,
//! CREATE_DIR, DELETE_OBJECT, RENAME_OBJECT, SET_PROTECT, SET_COMMENT,
//! SET_DATE, SET_OWNER, FINDINPUT, FINDOUTPUT, FINDUPDATE, READ, WRITE,
//! SEEK, SET_FILE_SIZE, END, PARENT_FH, COPY_DIR_FH, FH_FROM_LOCK,
//! CHANGE_MODE, EXAMINE_OBJECT, EXAMINE_NEXT, EXAMINE_FH, INFO, DISK_INFO,
//! IS_FILESYSTEM and FLUSH (not EXAMINE_ALL: dos does ExAll through
//! EXAMINE_OBJECT/NEXT);
//! DIE is refused (it never ends); the rest are ERROR_ACTION_NOT_KNOWN.
//! Packets about an open file carry its FileHandle, whose key is the lock.
//!
//! Names are C strings, and a path part over 30 characters is
//! ERROR_INVALID_COMPONENT_NAME; the root is ST_ROOT; deleting the root is
//! ERROR_OBJECT_WRONG_TYPE; FINDOUTPUT empties an existing file in place
//! and keeps its protection; an empty file has no data block; a failed
//! data block is ERROR_DISK_FULL; SAME_LOCK answers DOSTRUE; the property
//! packets are (lock, name, value); SET_OWNER is answered; a null date for
//! SET_DATE is now; SET_FILE_SIZE moves the handles past the new end back
//! to it; INFO counts free memory as free space and refuses a bad lock
//! with ERROR_INVALID_LOCK; a name with ':' is refused. No hard or soft
//! links, notification or record locks yet.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosLib = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DosPacket = dos.DosPacket;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const MsgPort = exec.MsgPort;

pub const HANDLER_NAME = "ram-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 0;
const BUILD_DATE = "15.9.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The volume's name, and the root's.
pub const VOLUME_NAME = "Ram Disk";
const block_size = 1024;
/// The longest name of a file or directory.
const max_name = 30;
/// The longest comment.
const max_comment = 79;

/// A piece of a file's data.
const Block = struct {
    next: ?*Block,
    data: [block_size]u8,
};

/// A file or directory.
const Node = struct {
    /// The next entry in the directory.
    next: ?*Node = null,
    parent: ?*Node = null,
    /// A directory's entries, the newest first.
    children: ?*Node = null,
    /// A file's data; null while it is empty.
    data: ?*Block = null,
    /// ST_ROOT, ST_USERDIR or ST_FILE.
    kind: i32,
    size: u64 align(4) = 0,
    protection: u32 = 0,
    date: dos.DateStamp = .{},
    /// Counts entries leaving the directory, so EXAMINE_NEXT notices.
    delcount: u32 = 0,
    /// Its comment, only when it has one.
    comment: ?[*:0]u8 = null,
    /// user << 16 | group
    owner: u32 = 0,
    name: [max_name:0]u8 = @splat(0),

    fn isDir(n: *const Node) bool {
        return n.kind > 0;
    }

    fn nameZ(n: *const Node) [*:0]const u8 {
        return &n.name;
    }
};

/// A lock: the FileLock first, then where an open
/// file is. An open file's FileHandle keeps it as its key.
const RamLock = extern struct {
    lock: FileLock,
    /// The block holding `pos`, and its number, to go on from.
    block: ?*Block = null,
    block_index: u64 align(4) = 0,
    /// The position in an open file.
    pos: u64 align(4) = 0,
    /// Written to: END dates the file.
    modified: bool = false,
    /// The directory's delcount at the last EXAMINE.
    delcount: u32 = 0,

    fn node(l: *const RamLock) *Node {
        return @ptrFromInt(l.lock.key);
    }

    /// The next lock on the disk's list. Every RamLock comes from AllocVec,
    /// so its FileLock is as aligned as the RamLock.
    fn nextLock(l: *const RamLock) ?*RamLock {
        const n = l.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", n));
    }
};

const Error = error{
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
};

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

/// A name a new entry may have: not empty, no control
/// characters, no ':'.
fn validName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == ':') return error.InvalidName;
}

/// A path's last part, checked for length.
fn component(part: []const u8) Error![max_name:0]u8 {
    if (part.len > max_name) return error.InvalidName;
    var name: [max_name:0]u8 = @splat(0);
    @memcpy(name[0..part.len], part);
    return name;
}

/// Where a path ends: the directory and the last part ("": that directory).
const Place = struct { dir: *Node, name: [max_name:0]u8 };

/// The disk: its tree and its locks. The handler process has one; the
/// tests make their own.
pub const RamDisk = struct {
    sys: *ExecBase,
    dl: *DosLib,
    ub: *UtilityBase,
    /// The handler's port (fl_Task of its locks).
    port: ?*MsgPort,
    /// The volume's DosList node (fl_Volume of its locks).
    volume: ?*dos.DosList = null,
    root: *Node,
    /// The locks, through their fl_Link.
    locks: ?*RamLock = null,
    /// The data blocks there are, for INFO.
    blocks: u64 align(4) = 0,

    pub fn init(sys: *ExecBase, dl: *DosLib, ub: *UtilityBase, port: ?*MsgPort) Error!RamDisk {
        var disk: RamDisk = .{ .sys = sys, .dl = dl, .ub = ub, .port = port, .root = undefined };
        const root = disk.alloc(Node) orelse return error.NoMemory;
        root.* = .{ .kind = dos.ST_ROOT, .date = disk.now() };
        @memcpy(root.name[0..VOLUME_NAME.len], VOLUME_NAME);
        disk.root = root;
        return disk;
    }

    /// Frees the locks and the tree (the tests; the handler never ends).
    pub fn deinit(disk: *RamDisk) void {
        while (disk.locks) |l| {
            disk.locks = l.nextLock();
            disk.free(l);
        }
        disk.freeTree(disk.root);
    }

    fn alloc(disk: *RamDisk, comptime T: type) ?*T {
        const mem = disk.sys.AllocVec(@sizeOf(T), exec.MEMF_CLEAR) orelse return null;
        return @ptrCast(@alignCast(mem));
    }

    fn free(disk: *RamDisk, p: anytype) void {
        disk.sys.FreeVec(@ptrCast(p));
    }

    fn now(disk: *RamDisk) dos.DateStamp {
        var ds: dos.DateStamp = .{};
        _ = disk.dl.DateStamp(&ds);
        return ds;
    }

    fn freeData(disk: *RamDisk, n: *Node) void {
        var b = n.data;
        while (b) |it| {
            b = it.next;
            disk.free(it);
            disk.blocks -= 1;
        }
        n.data = null;
        n.size = 0;
    }

    /// A node, its data and its comment.
    fn freeNode(disk: *RamDisk, n: *Node) void {
        disk.freeData(n);
        if (n.comment) |c| disk.free(c);
        disk.free(n);
    }

    fn freeTree(disk: *RamDisk, n: *Node) void {
        var c = n.children;
        while (c) |it| {
            c = it.next;
            disk.freeTree(it);
        }
        disk.freeNode(n);
    }

    // --- locks ---

    fn owns(disk: *RamDisk, l: *RamLock) bool {
        var it = disk.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x == l) return true;
        }
        return false;
    }

    /// A lock from a packet: one of ours, or null for the root.
    fn lockArg(disk: *RamDisk, value: isize) Error!?*RamLock {
        if (value == 0) return null;
        const l: *RamLock = @ptrFromInt(ptrArg(value));
        if (!disk.owns(l)) return error.InvalidLock;
        return l;
    }

    /// The directory a lock from a packet stands for (null: the root).
    fn dirOf(disk: *RamDisk, value: isize) Error!*Node {
        const l = try disk.lockArg(value) orelse return disk.root;
        return l.node();
    }

    fn isLocked(disk: *RamDisk, n: *Node) bool {
        var it = disk.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.node() == n) return true;
        }
        return false;
    }

    /// A new lock on a node: shared locks go together, an exclusive one
    /// wants the node to itself.
    fn getLock(disk: *RamDisk, n: *Node, access: i32) Error!*RamLock {
        var it = disk.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.node() == n and (access == dos.EXCLUSIVE_LOCK or x.lock.access == dos.EXCLUSIVE_LOCK)) return error.InUse;
        }
        const l = disk.alloc(RamLock) orelse return error.NoMemory;
        l.* = .{ .lock = .{
            .link = if (disk.locks) |head| &head.lock else null,
            .key = @intFromPtr(n),
            .access = if (access == dos.EXCLUSIVE_LOCK) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
            .task = disk.port,
            .volume = disk.volume,
        } };
        disk.locks = l;
        return l;
    }

    fn freeLock(disk: *RamDisk, l: *RamLock) void {
        if (disk.locks == l) {
            disk.locks = l.nextLock();
        } else {
            var it = disk.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x.lock.link == &l.lock) {
                    x.lock.link = l.lock.link;
                    break;
                }
            }
        }
        disk.free(l);
    }

    // --- names ---

    fn child(disk: *RamDisk, dir: *Node, name: [*:0]const u8) Error!?*Node {
        if (!dir.isDir()) return error.WrongType;
        var c = dir.children;
        while (c) |it| : (c = it.next) {
            if (disk.ub.Stricmp(it.nameZ(), name) == 0) return it;
        }
        return null;
    }

    /// Drop the device, walk the directories from `start`
    /// ("" goes up), and leave the last part.
    fn findDir(disk: *RamDisk, start: *Node, path: [*:0]const u8) Error!Place {
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
            dir = try disk.child(dir, &name) orelse return error.NotFound;
            if (!dir.isDir()) return error.WrongType;
        }
        return .{ .dir = dir, .name = try component(part) };
    }

    /// The node a path names, from the directory a lock stands for.
    fn locate(disk: *RamDisk, dir_arg: isize, path: [*:0]const u8) Error!*Node {
        const place = try disk.findDir(try disk.dirOf(dir_arg), path);
        if (place.name[0] == 0) return place.dir;
        return try disk.child(place.dir, &place.name) orelse error.NotFound;
    }

    /// A new file or directory, locked.
    fn create(disk: *RamDisk, dir_arg: isize, path: [*:0]const u8, kind: i32, access: i32) Error!*RamLock {
        const place = try disk.findDir(try disk.dirOf(dir_arg), path);
        const name = std.mem.sliceTo(&place.name, 0);
        try validName(name);
        if (try disk.child(place.dir, &place.name) != null) return error.Exists;
        const n = disk.alloc(Node) orelse return error.NoMemory;
        n.* = .{ .kind = kind, .parent = place.dir, .next = place.dir.children, .date = disk.now(), .name = place.name };
        const l = disk.getLock(n, access) catch |e| {
            disk.free(n);
            return e;
        };
        place.dir.children = n;
        place.dir.date = n.date;
        l.modified = true;
        return l;
    }

    fn unlink(disk: *RamDisk, n: *Node) void {
        const parent = n.parent.?;
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
        parent.delcount +%= 1;
        parent.date = disk.now();
    }

    fn delete(disk: *RamDisk, dir_arg: isize, path: [*:0]const u8) Error!void {
        const n = try disk.locate(dir_arg, path);
        if (n == disk.root) return error.WrongType;
        if (n.isDir() and n.children != null) return error.NotEmpty;
        if (n.protection & dos.FIBF_DELETE != 0) return error.DeleteProtected;
        if (disk.isLocked(n)) return error.InUse;
        disk.unlink(n);
        disk.freeNode(n);
    }

    // --- files ---

    fn fileOf(disk: *RamDisk, fh: ?*FileHandle) Error!*RamLock {
        const handle = fh orelse return error.InvalidLock;
        const l: *RamLock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
        if (!disk.owns(l)) return error.InvalidLock;
        return l;
    }

    /// FINDINPUT (an existing file, shared), FINDOUTPUT (a new or emptied
    /// file, exclusive), FINDUPDATE (an existing or new file, shared).
    fn open(disk: *RamDisk, args: dos.FindArgs, action: dos.ActionCode) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const dir_arg: isize = @bitCast(@intFromPtr(args.lock));
        const path = args.name orelse return error.InvalidName;
        const l: *RamLock = switch (action) {
            .findinput => blk: {
                const n = try disk.locate(dir_arg, path);
                if (n.isDir()) return error.WrongType;
                break :blk try disk.getLock(n, dos.SHARED_LOCK);
            },
            .findoutput => if (disk.locate(dir_arg, path)) |n| blk: {
                if (n.isDir()) return error.WrongType;
                const l = try disk.getLock(n, dos.EXCLUSIVE_LOCK);
                disk.freeData(n);
                l.modified = true;
                break :blk l;
            } else |e| blk: {
                if (e != error.NotFound) return e;
                break :blk try disk.create(dir_arg, path, dos.ST_FILE, dos.EXCLUSIVE_LOCK);
            },
            else => if (disk.locate(dir_arg, path)) |n| blk: {
                if (n.isDir()) return error.WrongType;
                break :blk try disk.getLock(n, dos.SHARED_LOCK);
            } else |e| blk: {
                if (e != error.NotFound) return e;
                break :blk try disk.create(dir_arg, path, dos.ST_FILE, dos.SHARED_LOCK);
            },
        };
        fh.key = l;
        fh.interactive = false;
    }

    /// The block holding `pos` (the one after the last with `grow`).
    fn blockAt(disk: *RamDisk, l: *RamLock, n: *Node, pos: u64, grow: bool) Error!?*Block {
        const index = pos / block_size;
        var b: ?*Block = n.data;
        var i: u64 = 0;
        if (l.block) |cached| {
            if (l.block_index <= index) {
                b = cached;
                i = l.block_index;
            }
        }
        var cur = b orelse blk: {
            if (!grow or index != 0) return null;
            const first = disk.alloc(Block) orelse return error.DiskFull;
            n.data = first;
            disk.blocks += 1;
            break :blk first;
        };
        while (i < index) : (i += 1) {
            cur = cur.next orelse blk: {
                if (!grow or i + 1 != index) return null;
                const more = disk.alloc(Block) orelse return error.DiskFull;
                cur.next = more;
                disk.blocks += 1;
                break :blk more;
            };
        }
        l.block = cur;
        l.block_index = index;
        return cur;
    }

    fn read(disk: *RamDisk, args: dos.IOArgs) Error!usize {
        const l = try disk.fileOf(args.fh);
        const n = l.node();
        const buf = args.buffer orelse return 0;
        const len: usize = if (args.length > 0) @intCast(args.length) else 0;
        var done: usize = 0;
        while (done < len and l.pos < n.size) {
            const b = try disk.blockAt(l, n, l.pos, false) orelse break;
            const off: usize = @intCast(l.pos % block_size);
            const count: usize = @intCast(@min(@as(u64, len - done), block_size - off, n.size - l.pos));
            @memcpy(buf[done..][0..count], b.data[off..][0..count]);
            done += count;
            l.pos += count;
        }
        return done;
    }

    fn write(disk: *RamDisk, args: dos.IOArgs) Error!usize {
        const l = try disk.fileOf(args.fh);
        const n = l.node();
        const buf = args.buffer orelse return 0;
        const len: usize = if (args.length > 0) @intCast(args.length) else 0;
        var done: usize = 0;
        defer if (done > 0) {
            l.modified = true;
        };
        while (done < len) {
            const b = try disk.blockAt(l, n, l.pos, true) orelse return error.DiskFull;
            const off: usize = @intCast(l.pos % block_size);
            const count = @min(len - done, block_size - off);
            @memcpy(b.data[off..][0..count], buf[done..][0..count]);
            done += count;
            l.pos += count;
            if (l.pos > n.size) n.size = l.pos;
        }
        return done;
    }

    /// To a position from the beginning, the current position or the end;
    /// the old position. Not before the start or past the end.
    fn seek(disk: *RamDisk, args: dos.SeekArgs) Error!u64 {
        const l = try disk.fileOf(args.fh);
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

    /// END: the file dated if written to, and its lock freed.
    fn close(disk: *RamDisk, args: dos.FileHandleArgs) Error!void {
        const l = try disk.fileOf(args.fh);
        if (l.modified) l.node().date = disk.now();
        disk.freeLock(l);
        args.fh.?.key = null;
    }

    // --- examine ---

    fn fill(fib: *FileInfoBlock, n: *Node) void {
        fib.* = .{
            .disk_key = @intFromPtr(n),
            .dir_entry_type = n.kind,
            .entry_type = n.kind,
            .protection = n.protection,
            .size = n.size,
            .num_blocks = n.size / block_size + 1,
            .date = n.date,
        };
        const name = std.mem.sliceTo(&n.name, 0);
        @memcpy(fib.file_name[0..name.len], name);
        if (n.comment) |c| {
            const text = std.mem.span(c);
            @memcpy(fib.comment[0..text.len], text);
        }
        fib.owner_uid = @truncate(n.owner >> 16);
        fib.owner_gid = @truncate(n.owner);
    }

    /// EXAMINE_FH: the open file's own entry.
    fn examineFile(disk: *RamDisk, args: dos.ExamineFHArgs) Error!void {
        const l = try disk.fileOf(args.fh);
        fill(args.fib orelse return error.InvalidLock, l.node());
    }

    fn contains(dir: *Node, n: *Node) bool {
        var c = dir.children;
        while (c) |it| : (c = it.next) {
            if (it == n) return true;
        }
        return false;
    }

    /// EXAMINE_OBJECT (`next` false) fills in the lock's own object;
    /// EXAMINE_NEXT the directory's entry after the one in the FIB, from
    /// the first again if that one has gone.
    fn examine(disk: *RamDisk, args: dos.ExamineArgs, next: bool) Error!void {
        const l = try disk.lockArg(@bitCast(@intFromPtr(args.lock)));
        const n = if (l) |it| it.node() else disk.root;
        const fib = args.fib orelse return error.InvalidLock;
        if (!next) {
            if (l) |it| it.delcount = n.delcount;
            fill(fib, n);
            return;
        }
        if (!n.isDir()) return error.NoMoreEntries;
        var from: ?*Node = @ptrFromInt(fib.disk_key);
        if (from != n) {
            const changed = if (l) |it| it.delcount != n.delcount else true;
            if (from == null or (changed and !contains(n, from.?))) from = n;
        }
        if (l) |it| it.delcount = n.delcount;
        const entry = (if (from == n) n.children else from.?.next) orelse return error.NoMoreEntries;
        fill(fib, entry);
    }

    // --- changing ---

    /// Whether a lock but `l` is on the node (with `exclusive_only`, an
    /// exclusive one).
    fn otherLock(disk: *RamDisk, n: *Node, l: ?*RamLock, exclusive_only: bool) bool {
        var it = disk.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x == l or x.node() != n) continue;
            if (!exclusive_only or x.lock.access == dos.EXCLUSIVE_LOCK) return true;
        }
        return false;
    }

    /// RENAME_OBJECT: not the root, into a directory,
    /// a valid name that isn't there (but its own in another case), not a
    /// directory into itself, not while locked exclusively.
    fn rename(disk: *RamDisk, args: dos.RenameArgs) Error!void {
        const from = try disk.locate(lockValue(args.from_lock), args.from_name orelse return error.InvalidName);
        if (from == disk.root) return error.WrongType;
        const place = try disk.findDir(try disk.dirOf(lockValue(args.to_lock)), args.to_name orelse return error.InvalidName);
        if (!place.dir.isDir()) return error.WrongType;
        try validName(std.mem.sliceTo(&place.name, 0));
        if (try disk.child(place.dir, &place.name)) |there| {
            if (there != from) return error.Exists;
        }
        var up: ?*Node = place.dir;
        while (up) |it| : (up = it.parent) {
            if (it == from) return error.InUse;
        }
        if (disk.otherLock(from, null, true)) return error.InUse;
        disk.unlink(from);
        from.parent = place.dir;
        from.next = place.dir.children;
        place.dir.children = from;
        from.name = place.name;
        place.dir.date = disk.now();
    }

    /// SET_PROTECT, SET_COMMENT, SET_DATE and SET_OWNER on (lock, name).
    fn setProperty(disk: *RamDisk, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
        const n = try disk.locate(lockValue(args.lock), args.name orelse return error.InvalidName);
        if (n == disk.root) return error.WrongType;
        const bits: u32 = @truncate(ptrArg(args.value));
        switch (action) {
            .set_protect => n.protection = bits,
            .set_owner => n.owner = bits,
            .set_date => {
                const date: ?*const dos.DateStamp = @ptrFromInt(ptrArg(args.value));
                n.date = if (date) |d| d.* else disk.now();
            },
            else => try disk.setComment(n, @ptrFromInt(ptrArg(args.value))),
        }
    }

    /// A copy of the comment, or none for "".
    fn setComment(disk: *RamDisk, n: *Node, text: ?[*:0]const u8) Error!void {
        const s: []const u8 = if (text) |t| std.mem.span(t) else "";
        if (s.len > max_comment) return error.CommentTooBig;
        var copy: ?[*:0]u8 = null;
        if (s.len > 0) {
            const mem = disk.sys.AllocVec(s.len + 1, exec.MEMF_ANY) orelse return error.NoMemory;
            const p: [*]u8 = @ptrCast(mem);
            @memcpy(p[0..s.len], s);
            p[s.len] = 0;
            copy = @ptrCast(p);
        }
        if (n.comment) |old| disk.free(old);
        n.comment = copy;
    }

    /// Blocks for `size` bytes, the new ones zeroed (and the unused end of
    /// the last one, which may hold old data).
    fn growTo(disk: *RamDisk, n: *Node, size: u64) Error!void {
        var count: u64 = 0;
        var last: ?*Block = null;
        var b = n.data;
        while (b) |it| : (b = it.next) {
            count += 1;
            last = it;
        }
        if (last) |it| {
            const start = (count - 1) * block_size;
            const used: usize = if (n.size > start) @intCast(n.size - start) else 0;
            @memset(it.data[used..], 0);
        }
        const needed = (size + block_size - 1) / block_size;
        while (count < needed) : (count += 1) {
            const more = disk.alloc(Block) orelse return error.DiskFull;
            if (last) |it| it.next = more else n.data = more;
            last = more;
            disk.blocks += 1;
        }
    }

    /// Only the blocks `size` bytes need stay.
    fn cutTo(disk: *RamDisk, n: *Node, size: u64) void {
        const keep = (size + block_size - 1) / block_size;
        if (keep == 0) return disk.freeData(n);
        var b = n.data;
        var i: u64 = 1;
        while (b) |it| : (i += 1) {
            if (i == keep) {
                var rest = it.next;
                it.next = null;
                while (rest) |r| {
                    rest = r.next;
                    disk.free(r);
                    disk.blocks -= 1;
                }
                return;
            }
            b = it.next;
        }
    }

    /// SET_FILE_SIZE: the file cut or grown to the size the offset and mode
    /// give; handles past the new end move back to it. The new size.
    fn setFileSize(disk: *RamDisk, args: dos.SeekArgs) Error!u64 {
        const l = try disk.fileOf(args.fh);
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
        if (size > n.size) try disk.growTo(n, size) else disk.cutTo(n, size);
        n.size = size;
        var it = disk.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.node() != n) continue;
            x.block = null;
            x.block_index = 0;
            if (x.pos > size) x.pos = size;
        }
        l.modified = true;
        return size;
    }

    /// FH_FROM_LOCK: the lock on a file becomes the handle's, at the start.
    fn fhFromLock(disk: *RamDisk, args: dos.FhFromLockArgs) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const l = try disk.lockArg(lockValue(args.lock)) orelse return error.InvalidLock;
        if (l.node().isDir()) return error.WrongType;
        l.pos = 0;
        l.block = null;
        l.block_index = 0;
        fh.key = l;
        fh.interactive = false;
    }

    /// CHANGE_MODE: a lock (CHANGE_LOCK: EXCLUSIVE_LOCK or shared) or an
    /// open file (CHANGE_FH: MODE_NEWFILE exclusive, else shared) to
    /// another access; exclusive only without other locks.
    fn changeMode(disk: *RamDisk, args: dos.ChangeModeArgs) Error!void {
        var l: *RamLock = undefined;
        var exclusive = false;
        switch (args.kind) {
            dos.CHANGE_LOCK => {
                l = try disk.lockArg(@bitCast(@intFromPtr(args.object))) orelse return error.InvalidLock;
                exclusive = args.mode == dos.EXCLUSIVE_LOCK;
            },
            dos.CHANGE_FH => {
                l = try disk.fileOf(@ptrCast(@alignCast(args.object)));
                exclusive = args.mode == dos.MODE_NEWFILE;
            },
            else => return error.WrongType,
        }
        if (exclusive and disk.otherLock(l.node(), l, false)) return error.InUse;
        l.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
    }

    /// INFO and DISK_INFO: RAM:'s InfoData. It grows as long as memory
    /// lasts, so free memory is its free space.
    fn info(disk: *RamDisk, data: ?*dos.InfoData) Error!void {
        const d = data orelse return error.InvalidLock;
        const free_blocks: u64 = disk.sys.AvailMem(exec.MEMF_ANY) / block_size;
        d.* = .{
            .num_soft_errors = 0,
            .unit_number = -1,
            .disk_state = dos.ID_VALIDATED,
            .num_blocks = disk.blocks + free_blocks,
            .num_blocks_used = disk.blocks,
            .bytes_per_block = block_size,
            .disk_type = dos.ID_DOS_DISK,
            .volume_node = disk.volume,
            .in_use = if (disk.locks != null) -1 else 0,
        };
    }

    // --- packets ---

    /// The answer to one packet (all but STARTUP, which the process takes).
    pub fn answer(disk: *RamDisk, pkt: *DosPacket) Answer {
        const a = pkt.args.raw;
        switch (pkt.getAction()) {
            .locate_object => {
                const n = disk.locate(a[0], @ptrFromInt(ptrArg(a[1]))) catch |e| return no(e);
                const l = disk.getLock(n, @truncate(a[2])) catch |e| return no(e);
                return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
            },
            .free_lock => {
                const l = disk.lockArg(a[0]) catch |e| return no(e);
                if (l) |it| disk.freeLock(it);
                return yes();
            },
            .copy_dir, .parent => {
                const n = disk.dirOf(a[0]) catch |e| return no(e);
                const target = if (pkt.getAction() == .parent) n.parent orelse return .{ .res1 = 0, .res2 = 0 } else n;
                const l = disk.getLock(target, dos.SHARED_LOCK) catch |e| return no(e);
                return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
            },
            .same_lock => {
                const n1 = disk.dirOf(a[0]) catch |e| return no(e);
                const n2 = disk.dirOf(a[1]) catch |e| return no(e);
                return .{ .res1 = if (n1 == n2) dos.DOSTRUE else dos.DOSFALSE, .res2 = 0 };
            },
            .create_dir => {
                const l = disk.create(a[0], @ptrFromInt(ptrArg(a[1])), dos.ST_USERDIR, dos.EXCLUSIVE_LOCK) catch |e| return no(e);
                return .{ .res1 = @bitCast(@intFromPtr(l)), .res2 = 0 };
            },
            .delete_object => {
                disk.delete(a[0], @ptrFromInt(ptrArg(a[1]))) catch |e| return no(e);
                return yes();
            },
            .findinput, .findoutput, .findupdate => {
                disk.open(pkt.args.find, pkt.getAction()) catch |e| return no(e);
                return yes();
            },
            .read => {
                const count = disk.read(pkt.args.io) catch |e| return minusOne(e);
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .write => {
                const count = disk.write(pkt.args.io) catch |e| return minusOne(e);
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .seek => {
                const old = disk.seek(pkt.args.seek) catch |e| return minusOne(e);
                return .{ .res1 = @intCast(old), .res2 = 0 };
            },
            .end => {
                disk.close(pkt.args.file) catch |e| return no(e);
                return yes();
            },
            .examine_object, .examine_next => {
                disk.examine(pkt.args.examine, pkt.getAction() == .examine_next) catch |e| return no(e);
                return yes();
            },
            .examine_fh => {
                disk.examineFile(pkt.args.examine_fh) catch |e| return no(e);
                return yes();
            },
            .rename_object => {
                disk.rename(pkt.args.rename) catch |e| return no(e);
                return yes();
            },
            .set_protect, .set_comment, .set_date, .set_owner => {
                disk.setProperty(pkt.args.property, pkt.getAction()) catch |e| return no(e);
                return yes();
            },
            .set_file_size => {
                const size = disk.setFileSize(pkt.args.seek) catch |e| return minusOne(e);
                return .{ .res1 = @intCast(size), .res2 = 0 };
            },
            .parent_fh, .copy_dir_fh => {
                const l = disk.fileOf(pkt.args.file.fh) catch |e| return no(e);
                const n = l.node();
                const target = if (pkt.getAction() == .parent_fh) n.parent orelse return .{ .res1 = 0, .res2 = 0 } else n;
                const got = disk.getLock(target, dos.SHARED_LOCK) catch |e| return no(e);
                return .{ .res1 = @bitCast(@intFromPtr(got)), .res2 = 0 };
            },
            .fh_from_lock => {
                disk.fhFromLock(pkt.args.fh_from_lock) catch |e| return no(e);
                return yes();
            },
            .change_mode => {
                disk.changeMode(pkt.args.change_mode) catch |e| return no(e);
                return yes();
            },
            .info => {
                _ = disk.lockArg(lockValue(pkt.args.info.lock)) catch |e| return no(e);
                disk.info(pkt.args.info.info) catch |e| return no(e);
                return yes();
            },
            .disk_info => {
                disk.info(@ptrFromInt(ptrArg(a[0]))) catch |e| return no(e);
                return yes();
            },
            .is_filesystem, .flush => return yes(),
            .die => return no(error.InUse), // it stays
            else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
        }
    }
};

/// The handler process: ACTION_STARTUP first (the disk, the volume "Ram
/// Disk", the device node's port), then packets for good.
pub fn ramHandler(sb: *ExecBase) callconv(.c) void {
    const dl: *DosLib = @ptrCast(sb.OpenLibrary(dos.DOSNAME, 0) orelse return);
    const ub: *UtilityBase = @ptrCast(sb.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return);
    const me: *dos.Process = @fieldParentPtr("task", sb.FindTask(null).?);
    const startup = dl.WaitPkt() orelse return;
    var disk = RamDisk.init(sb, dl, ub, &me.msg_port) catch {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
        return;
    };
    const volume = dl.MakeDosEntry(VOLUME_NAME, dos.DLT_VOLUME) orelse {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
        return;
    };
    volume.task = &me.msg_port;
    volume.misc.volume.disk_type = dos.ID_DOS_DISK;
    _ = dl.DateStamp(&volume.misc.volume.volume_date);
    if (!dl.AddDosEntry(volume)) {
        dl.FreeDosEntry(volume);
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_OBJECT_EXISTS);
        return;
    }
    disk.volume = volume;
    const device: ?*dos.DosList = @ptrFromInt(ptrArg(startup.args.raw[2]));
    if (device) |d| d.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);
    while (dl.WaitPkt()) |pkt| {
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
    }
}

export const ram_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &ram_handler_tag.resident,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = -121,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..], // past the NUL: a C string
    },
    .handler = &ramHandler,
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const kdos = @import("../../libs/dos/dos.zig");
const kexec = @import("../../libs/exec/exec.zig");

fn diskFor(db: *kdos.DosBase) !RamDisk {
    return RamDisk.init(db.sys_base, kdos.testBase(db), db.utility_base, null);
}

fn arg(p: anytype) isize {
    return @bitCast(@intFromPtr(p));
}

fn send(disk: *RamDisk, action: dos.ActionCode, args: [4]isize) Answer {
    var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
    return disk.answer(&pkt);
}

/// A lock from an answer, or a test failure.
fn lockOf(reply: Answer) !isize {
    try testing.expect(reply.res1 != 0);
    return reply.res1;
}

test "the ROM tag: a handler's, which InitCode and InitResident leave alone" {
    const tag = &ram_handler_tag;
    try testing.expectEqual(&tag.resident, tag.resident.match_tag);
    try testing.expectEqual(exec.NodeType.handler, tag.resident.type);
    try testing.expectEqual(@as(u8, 0), tag.resident.flags);
    try testing.expect(tag.resident.init == null);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(tag.resident.name));
}

test "RAM: directories: create, locate, locks, parent, delete, names" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    var disk = try diskFor(db);

    const made = try lockOf(send(&disk, .create_dir, .{ 0, arg("RAM:dir"), 0, 0 }));
    const busy = send(&disk, .locate_object, .{ 0, arg("RAM:dir"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, busy.res2); // CreateDir's lock is exclusive
    try testing.expectEqual(yes(), send(&disk, .free_lock, .{ made, 0, 0, 0 }));

    const dir = try lockOf(send(&disk, .locate_object, .{ 0, arg("ram:DIR"), dos.SHARED_LOCK, 0 }));
    const again = try lockOf(send(&disk, .locate_object, .{ 0, arg("RAM:dir"), dos.SHARED_LOCK, 0 }));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(&disk, .locate_object, .{ 0, arg("RAM:dir"), dos.EXCLUSIVE_LOCK, 0 }).res2);
    const copy = try lockOf(send(&disk, .copy_dir, .{ dir, 0, 0, 0 }));
    try testing.expectEqual(dos.DOSTRUE, send(&disk, .same_lock, .{ dir, copy, 0, 0 }).res1);
    const root = try lockOf(send(&disk, .parent, .{ dir, 0, 0, 0 }));
    try testing.expectEqual(dos.DOSFALSE, send(&disk, .same_lock, .{ dir, root, 0, 0 }).res1);
    try testing.expectEqual(Answer{ .res1 = 0, .res2 = 0 }, send(&disk, .parent, .{ root, 0, 0, 0 }));

    const sub = try lockOf(send(&disk, .create_dir, .{ dir, arg("sub"), 0, 0 })); // relative to dir
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(&disk, .copy_dir, .{ sub, 0, 0, 0 }).res2); // exclusive
    _ = send(&disk, .free_lock, .{ sub, 0, 0, 0 });
    const up = try lockOf(send(&disk, .locate_object, .{ 0, arg("RAM:dir/sub//"), dos.SHARED_LOCK, 0 }));
    try testing.expectEqual(dos.DOSTRUE, send(&disk, .same_lock, .{ up, dir, 0, 0 }).res1); // sub, up, the dir itself
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, send(&disk, .create_dir, .{ 0, arg("RAM:dir"), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, send(&disk, .locate_object, .{ 0, arg("RAM:none/x"), dos.SHARED_LOCK, 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, send(&disk, .create_dir, .{ 0, arg("RAM:" ++ "n" ** 31), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, send(&disk, .create_dir, .{ 0, arg("RAM:dir/"), 0, 0 }).res2);

    try testing.expectEqual(dos.ERROR_DIRECTORY_NOT_EMPTY, send(&disk, .delete_object, .{ 0, arg("RAM:dir"), 0, 0 }).res2);
    try testing.expectEqual(yes(), send(&disk, .delete_object, .{ 0, arg("RAM:dir/sub"), 0, 0 }));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(&disk, .delete_object, .{ 0, arg("RAM:dir"), 0, 0 }).res2);
    for ([_]isize{ dir, again, copy, root, up }) |l| _ = send(&disk, .free_lock, .{ l, 0, 0, 0 });
    try testing.expectEqual(yes(), send(&disk, .delete_object, .{ 0, arg("RAM:dir"), 0, 0 }));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, send(&disk, .delete_object, .{ 0, arg("RAM:dir"), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, send(&disk, .delete_object, .{ 0, arg("RAM:"), 0, 0 }).res2);
    var stray: FileLock = .{};
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, send(&disk, .free_lock, .{ arg(&stray), 0, 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, send(&disk, .format, .{ 0, 0, 0, 0 }).res2);

    disk.deinit();
    try kdos.testTearDown(db);
}

test "RAM: files: write across blocks, seek, read back, open modes" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    var disk = try diskFor(db);
    var pattern: [3000]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i % 251);
    var back: [5000]u8 = undefined;

    var out: FileHandle = .{};
    try testing.expectEqual(yes(), send(&disk, .findoutput, .{ arg(&out), 0, arg("RAM:f"), 0 }));
    try testing.expect(out.key != null);
    try testing.expectEqual(Answer{ .res1 = 3000, .res2 = 0 }, send(&disk, .write, .{ arg(&out), arg(&pattern), 3000, 0 }));
    var in: FileHandle = .{};
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(&disk, .findinput, .{ arg(&in), 0, arg("RAM:f"), 0 }).res2);
    try testing.expectEqual(Answer{ .res1 = 3000, .res2 = 0 }, send(&disk, .seek, .{ arg(&out), 0, dos.OFFSET_BEGINNING, 0 }));
    try testing.expectEqual(Answer{ .res1 = 3000, .res2 = 0 }, send(&disk, .read, .{ arg(&out), arg(&back), 5000, 0 }));
    try testing.expectEqualSlices(u8, &pattern, back[0..3000]);
    try testing.expectEqual(Answer{ .res1 = 0, .res2 = 0 }, send(&disk, .read, .{ arg(&out), arg(&back), 10, 0 })); // at the end
    _ = send(&disk, .seek, .{ arg(&out), -10, dos.OFFSET_END, 0 });
    try testing.expectEqual(Answer{ .res1 = 10, .res2 = 0 }, send(&disk, .read, .{ arg(&out), arg(&back), 20, 0 }));
    try testing.expectEqualSlices(u8, pattern[2990..], back[0..10]);
    try testing.expectEqual(Answer{ .res1 = -1, .res2 = dos.ERROR_SEEK_ERROR }, send(&disk, .seek, .{ arg(&out), 1, dos.OFFSET_END, 0 }));
    try testing.expectEqual(Answer{ .res1 = -1, .res2 = dos.ERROR_SEEK_ERROR }, send(&disk, .seek, .{ arg(&out), 0, 7, 0 }));
    try testing.expectEqual(yes(), send(&disk, .end, .{ arg(&out), 0, 0, 0 }));
    try testing.expect(out.key == null);

    try testing.expectEqual(yes(), send(&disk, .findinput, .{ arg(&in), 0, arg("RAM:F"), 0 }));
    var in2: FileHandle = .{};
    try testing.expectEqual(yes(), send(&disk, .findinput, .{ arg(&in2), 0, arg("RAM:f"), 0 })); // shared
    try testing.expectEqual(Answer{ .res1 = 3000, .res2 = 0 }, send(&disk, .read, .{ arg(&in2), arg(&back), 5000, 0 }));
    _ = send(&disk, .end, .{ arg(&in), 0, 0, 0 });
    _ = send(&disk, .end, .{ arg(&in2), 0, 0, 0 });

    try testing.expectEqual(yes(), send(&disk, .findoutput, .{ arg(&out), 0, arg("RAM:f"), 0 })); // emptied
    try testing.expectEqual(Answer{ .res1 = 0, .res2 = 0 }, send(&disk, .read, .{ arg(&out), arg(&back), 10, 0 }));
    _ = send(&disk, .end, .{ arg(&out), 0, 0, 0 });

    var up: FileHandle = .{};
    try testing.expectEqual(yes(), send(&disk, .findupdate, .{ arg(&up), 0, arg("RAM:new"), 0 })); // made
    try testing.expectEqual(Answer{ .res1 = 5, .res2 = 0 }, send(&disk, .write, .{ arg(&up), arg("hello"), 5, 0 }));
    _ = send(&disk, .end, .{ arg(&up), 0, 0, 0 });
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, send(&disk, .findinput, .{ arg(&in), 0, arg("RAM:missing"), 0 }).res2);
    _ = try lockOf(send(&disk, .create_dir, .{ 0, arg("RAM:d"), 0, 0 }));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, send(&disk, .findinput, .{ arg(&in), 0, arg("RAM:d"), 0 }).res2);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, send(&disk, .findoutput, .{ arg(&in), 0, arg("RAM:d"), 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, send(&disk, .read, .{ arg(&in), arg(&back), 1, 0 }).res2);

    disk.deinit();
    try kdos.testTearDown(db);
}

test "RAM: examine: the object, the entries, a delete in between" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    var disk = try diskFor(db);
    var fib: FileInfoBlock = .{};

    try testing.expectEqual(yes(), send(&disk, .examine_object, .{ 0, arg(&fib), 0, 0 }));
    try testing.expectEqualStrings(VOLUME_NAME, std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);

    const made = try lockOf(send(&disk, .create_dir, .{ 0, arg("RAM:d"), 0, 0 }));
    _ = send(&disk, .free_lock, .{ made, 0, 0, 0 });
    for ([_][*:0]const u8{ "RAM:d/a", "RAM:d/b", "RAM:d/c" }) |name| {
        var fh: FileHandle = .{};
        try testing.expectEqual(yes(), send(&disk, .findoutput, .{ arg(&fh), 0, arg(name), 0 }));
        _ = send(&disk, .write, .{ arg(&fh), arg("xyz"), 3, 0 });
        _ = send(&disk, .end, .{ arg(&fh), 0, 0, 0 });
    }
    const dir = try lockOf(send(&disk, .locate_object, .{ 0, arg("RAM:d"), dos.SHARED_LOCK, 0 }));
    try testing.expectEqual(yes(), send(&disk, .examine_object, .{ dir, arg(&fib), 0, 0 }));
    try testing.expectEqualStrings("d", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ST_USERDIR, fib.dir_entry_type);
    try testing.expectEqual(yes(), send(&disk, .examine_next, .{ dir, arg(&fib), 0, 0 }));
    try testing.expectEqualStrings("c", std.mem.sliceTo(&fib.file_name, 0)); // the newest first
    try testing.expectEqual(dos.ST_FILE, fib.entry_type);
    try testing.expectEqual(@as(u64, 3), fib.size);
    try testing.expectEqual(yes(), send(&disk, .delete_object, .{ 0, arg("RAM:d/c"), 0, 0 })); // the one in the FIB
    try testing.expectEqual(yes(), send(&disk, .examine_next, .{ dir, arg(&fib), 0, 0 }));
    try testing.expectEqualStrings("b", std.mem.sliceTo(&fib.file_name, 0)); // from the first again
    try testing.expectEqual(yes(), send(&disk, .examine_next, .{ dir, arg(&fib), 0, 0 }));
    try testing.expectEqualStrings("a", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, send(&disk, .examine_next, .{ dir, arg(&fib), 0, 0 }).res2);
    _ = send(&disk, .free_lock, .{ dir, 0, 0, 0 });

    disk.deinit();
    try kdos.testTearDown(db);
}
