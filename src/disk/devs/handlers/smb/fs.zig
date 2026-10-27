// SPDX-License-Identifier: MIT
//! The packets onto SMB: the locks, examining, directory scans, files,
//! changes and watches of a share, one packet at a time, each with the
//! requests it takes.
//!
//! **A lock is a path.** Whatever is locked, open or watched has a `Key`:
//! the object's path in the share, whether it is a directory, and how many
//! locks and watches are on it - and no handle on the server: a handle
//! held open would keep another client from renaming or deleting the
//! directory, and a lock without one has nothing to open again after a
//! new connection. Making a lock asks the server whether the object is
//! there - a CREATE and a CLOSE, compounded into one round trip. Two
//! paths name the same object when they are the same, case aside; an
//! exclusive lock is refused while this handler has another on the
//! object. A rename gives the keys at and below what moved their new
//! paths, so the locks go with it.
//!
//! **Examining** a lock reads its entry from its directory: a CREATE of
//! the directory, a QUERY_DIRECTORY for the one name and a CLOSE, in one
//! round trip, which gives the name as the server spells it as well as
//! what it is now. The root is the volume, named and dated as its node.
//!
//! **A directory scan** (EXAMINE_NEXT) opens the directory once and reads
//! its entries in batches of up to 64 KiB, kept with the lock: the first
//! batch comes in the same round trip as the CREATE. fib_DiskKey counts
//! the entries handed out, so a scan another one interrupted, or one
//! started over, opens the directory again and goes on from there. The
//! handle goes at the end of the directory, or with the lock.
//!
//! **An open file is a handle** on the server, the position kept here:
//! each READ and WRITE says where it is, in pieces of at most 1 MiB (64
//! KiB on the ESP32s, and where the server takes one credit's worth a
//! request) or the server's MaxReadSize and MaxWriteSize. A file is opened sharing
//! everything, so another client's work on it is not refused. FINDINPUT
//! opens it to be read, and its first WRITE opens it again to be written
//! too: a file that is only read never asks for more. FINDINPUT reads
//! the file's first 64 KiB in the same round trip as its CREATE, kept as
//! a piece read ahead (below), so a small file is read, and found to end,
//! without asking again; a file only read is closed without waiting for
//! the CLOSE's answer, which comes before the next request as a piece
//! written behind's does - a small file, one round trip. FINDOUTPUT makes
//! the file or empties it, exclusive, refused while this handler has it
//! locked; FINDUPDATE opens it shared, made when it is not there - one
//! that may not be written is opened to be read, and its writes refused.
//! Its size is what the open said, asked again when a seek is to its end
//! or past it.
//!
//! **Reading ahead**: after a read that follows the one before, or
//! starts the file, the piece after it is asked for at once
//! (`readAhead`) - one READ at a time - and its answer read as it comes,
//! between packets, into one of two buffers of the handler's. The next
//! read takes what it wants from there, waiting for the rest when not
//! all of it has come, and the piece after that is asked for. What was
//! read ahead is kept while the file is open, and let go of when
//! anything is written through this handler and when a new connection
//! is made; where it found the file ending is believed for a second, as
//! the file may grow. Without the buffers nothing is read ahead.
//!
//! **Writing behind**: a WRITE is answered once its last piece has gone,
//! before the server says how it went; that answer is read between
//! packets, or before the next request. What it brings - the disk full,
//! a failure, the connection gone with it - is answered by the file's
//! next WRITE, FLUSH or END, as Linux's cifs and NFS tell it.
//!
//! **Small writes are gathered**: a WRITE smaller than a piece is copied
//! into a buffer of the handler's after the ones before it, and they go
//! as one WRITE, written behind (`sendGathered`) - once the piece is
//! full or a write does not follow on, before any packet but a WRITE, a
//! SEEK and a READ of another file is served, before the file's size is
//! asked, and at the latest when the handler's timer for it runs out, a
//! tenth of a second after the first of them. Until then the data is the
//! handler's alone, as in Linux's page cache. Its failure is answered as
//! a piece written behind's; a lost connection keeps it, to go on the
//! new one. Without the buffer every WRITE goes as it comes.
//!
//! **A change** is one round trip: the object opened, the change set on
//! it (SET_INFO: a name, a deletion, attributes, a date) and the handle
//! closed, compounded. A delete is refused while the object is locked; a
//! rename while it is locked exclusively, or when a directory would move
//! into itself. A rename never replaces what is at the new name.
//!
//! **Protection**: a read-only file has W and D set; A is the server's
//! ARCHIVE bit inverted; R and E are never set. Setting W or D makes the
//! file read-only. **Dates** are LastWriteTime, from UTC into the zone
//! the system clock keeps, and back.
//!
//! **Record locks and notification** are the handler's own
//! (`sdk.dos.record`, `sdk.dos.notify`): a record lock keeps out the
//! record locks of other handles on this machine, and a watcher hears of
//! what changes through this handler - not of another client's changes.
//!
//! **Read-only**: when the startup says so, or the share does not let
//! the user write, every change answers ERROR_DISK_WRITE_PROTECTED and the
//! volume says it is write-protected.
//!
//! **A lost connection is made again** - the connection, the
//! negotiation, the logon and the tree, by the handler's `reconnect` -
//! the next time a packet needs the server, and at once for the packet
//! that found it lost: that one is served again on the new connection,
//! and a READ goes on from the piece it was at. The server's handles went
//! with the old connection, so every open file is opened again by its
//! path and keeps its position; one that is no longer there answers
//! ERROR_OBJECT_NOT_FOUND from then on. A scan starts over from the
//! entries it had handed out. A WRITE, like a READ, goes on from the
//! piece it was at - but a WRITE's last piece, whose answer went with the
//! old connection, is not written again: the file's next WRITE, FLUSH or
//! END fails. CREATE_DIR, DELETE_OBJECT and RENAME_OBJECT are not
//! served again - the server may have done them before the connection
//! went - and answer ERROR_DEVICE_NOT_MOUNTED. While the server cannot be
//! had, a packet that needs it answers ERROR_DEVICE_NOT_MOUNTED; locks
//! and files are still let go of.
//!
//! **Idle**, with anything locked or open, the handler sends an ECHO now
//! and then (`idle`): a connection that died is found, and made again,
//! before a program next asks.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const notify = dos.notify;
const record = dos.record;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DosPacket = dos.DosPacket;
const FileInfoBlock = dos.FileInfoBlock;
const MsgPort = exec.MsgPort;
const wire = @import("wire.zig");
const names = @import("names.zig");
const commands = @import("commands.zig");
const session_area = @import("session.zig");
const Session = session_area.Session;
const Reply = session_area.Reply;
const Path = names.Path;

/// What a packet is answered with.
pub const Answer = struct {
    /// Pointer-wide: a lock goes back in it.
    res1: isize,
    res2: i32,
    /// The packet is kept - a record lock that waits - and answered when
    /// it can be: the handler does not reply it.
    held: bool = false,
};

fn yes() Answer {
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

fn no(err: Error) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = codeOf(err) };
}

fn noCode(code: i32) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = code };
}

fn lockAnswer(lock: *Lock) Answer {
    return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
}

pub const Error = error{
    NotFound,
    DirNotFound,
    WrongType,
    InvalidName,
    InUse,
    Exists,
    NotEmpty,
    ReadProtected,
    /// The object may not be written.
    FileWriteProtected,
    /// Nothing on the volume may be.
    WriteProtected,
    DeleteProtected,
    DiskFull,
    NoMemory,
    SeekError,
    InvalidLock,
    NoMoreEntries,
    NotImplemented,
    /// The connection is gone, or the server answered nonsense.
    NotMounted,
};

pub fn codeOf(err: Error) i32 {
    return switch (err) {
        error.NotFound => dos.ERROR_OBJECT_NOT_FOUND,
        error.DirNotFound => dos.ERROR_DIR_NOT_FOUND,
        error.WrongType => dos.ERROR_OBJECT_WRONG_TYPE,
        error.InvalidName => dos.ERROR_INVALID_COMPONENT_NAME,
        error.InUse => dos.ERROR_OBJECT_IN_USE,
        error.Exists => dos.ERROR_OBJECT_EXISTS,
        error.NotEmpty => dos.ERROR_DIRECTORY_NOT_EMPTY,
        error.ReadProtected => dos.ERROR_READ_PROTECTED,
        error.FileWriteProtected => dos.ERROR_WRITE_PROTECTED,
        error.WriteProtected => dos.ERROR_DISK_WRITE_PROTECTED,
        error.DeleteProtected => dos.ERROR_DELETE_PROTECTED,
        error.DiskFull => dos.ERROR_DISK_FULL,
        error.NoMemory => dos.ERROR_NO_FREE_STORE,
        error.SeekError => dos.ERROR_SEEK_ERROR,
        error.InvalidLock => dos.ERROR_INVALID_LOCK,
        error.NoMoreEntries => dos.ERROR_NO_MORE_ENTRIES,
        error.NotImplemented => dos.ERROR_ACTION_NOT_KNOWN,
        error.NotMounted => dos.ERROR_DEVICE_NOT_MOUNTED,
    };
}

/// The error for a server's status, for an operation that reads.
pub fn errorOf(status: u32) Error {
    return switch (status) {
        smb.STATUS_OBJECT_NAME_NOT_FOUND, smb.STATUS_NO_SUCH_FILE, smb.STATUS_DELETE_PENDING => error.NotFound,
        smb.STATUS_OBJECT_PATH_NOT_FOUND => error.DirNotFound,
        smb.STATUS_OBJECT_NAME_INVALID, smb.STATUS_OBJECT_PATH_INVALID, smb.STATUS_OBJECT_PATH_SYNTAX_BAD => error.InvalidName,
        smb.STATUS_OBJECT_NAME_COLLISION => error.Exists,
        smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => error.ReadProtected,
        smb.STATUS_SHARING_VIOLATION, smb.STATUS_FILE_LOCK_CONFLICT, smb.STATUS_LOCK_NOT_GRANTED => error.InUse,
        smb.STATUS_DISK_FULL, smb.STATUS_QUOTA_EXCEEDED => error.DiskFull,
        smb.STATUS_MEDIA_WRITE_PROTECTED => error.WriteProtected,
        smb.STATUS_FILE_IS_A_DIRECTORY, smb.STATUS_NOT_A_DIRECTORY => error.WrongType,
        smb.STATUS_DIRECTORY_NOT_EMPTY => error.NotEmpty,
        smb.STATUS_CANNOT_DELETE => error.DeleteProtected,
        smb.STATUS_NO_MORE_FILES => error.NoMoreEntries,
        smb.STATUS_INSUFFICIENT_RESOURCES => error.NoMemory,
        smb.STATUS_NOT_SUPPORTED, smb.STATUS_INVALID_DEVICE_REQUEST => error.NotImplemented,
        else => error.NotMounted,
    };
}

/// The error for a server's status, for an operation that writes: a
/// refusal is the object's protection.
pub fn changeErrorOf(status: u32) Error {
    return switch (status) {
        smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => error.FileWriteProtected,
        else => errorOf(status),
    };
}

/// The same, for a delete.
pub fn deleteErrorOf(status: u32) Error {
    return switch (status) {
        smb.STATUS_ACCESS_DENIED, smb.STATUS_NETWORK_ACCESS_DENIED => error.DeleteProtected,
        else => errorOf(status),
    };
}

/// Whether a status says a name of the path is not there.
fn missing(status: u32) bool {
    return status == smb.STATUS_OBJECT_NAME_NOT_FOUND or status == smb.STATUS_OBJECT_PATH_NOT_FOUND;
}

/// An object something is locked, open or watched on. The path is in an
/// allocation of its own, which a rename replaces; the key stays where it
/// is, as the locks, the record locks and the watches point at it.
pub const Key = struct {
    next: ?*Key = null,
    path_bytes: ?[*]u8 = null,
    path_len: usize = 0,
    is_dir: bool = false,
    /// Locks and open files on it, and watches.
    locks: u32 = 0,
    watched: u32 = 0,

    /// The path in the share: the root's is empty.
    pub fn path(key: *const Key) []const u8 {
        const bytes = key.path_bytes orelse return &.{};
        return bytes[0..key.path_len];
    }
};

/// A lock, and an open file.
pub const Lock = extern struct {
    lock: dos.FileLock,
    key: *Key,
    /// An open file's handle on the server.
    file_id: [16]u8 = @splat(0),
    open: bool = false,
    /// An open file that was not there when its handle was made again
    /// on a new connection.
    gone: bool = false,
    /// An open file's handle writes; it has written since it was opened,
    /// and since it was last flushed.
    writable: bool = false,
    modified: bool = false,
    unflushed: bool = false,
    /// What a piece written behind came to, as `@intFromError`, until the
    /// file's next WRITE, FLUSH or END tells it; 0 when nothing failed.
    write_error: u16 = 0,
    /// An open file's position, and its size as last known.
    pos: u64 align(4) = 0,
    size: u64 align(4) = 0,
    /// Where its last read ended: a read from there follows it.
    read_end: u64 align(4) = 0,
    /// A directory scan under way.
    scan: ?*Scan = null,

    pub fn path(lock: *const Lock) []const u8 {
        return lock.key.path();
    }

    fn nextLock(lock: *const Lock) ?*Lock {
        const following = lock.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", following));
    }
};

/// A directory scan: the directory's handle and a batch of its entries.
pub const Scan = struct {
    file_id: [16]u8 = @splat(0),
    open: bool = false,
    /// Entries handed out so far.
    ordinal: usize = 0,
    /// The server said there are no more.
    end: bool = false,
    entries: commands.Entries = .{ .bytes = &.{} },
    batch: [session_area.credit_bytes]u8 = undefined,
};

/// The bytes the share's root is, and what an entry's single-entry query
/// asks for.
const entry_query: u32 = 2048;

/// Seconds from 1601, where a FILETIME counts from, to 1970.
const filetime_epoch: i64 = 11_644_473_600;

/// How long after the share's size was last asked it is asked again,
/// once it has been written to.
const space_seconds = 5;

/// What a CREATE asks for to write a file, besides reading it.
const write_access: u32 = commands.FILE_WRITE_DATA | commands.FILE_APPEND_DATA | commands.FILE_WRITE_ATTRIBUTES;

/// What FINDINPUT reads with its CREATE: a credit's worth, which holds
/// most small files whole - an icon, a script, a prefs file.
const first_bytes: u32 = session_area.credit_bytes;

/// What a change sets on an object: SET_INFO's class and value.
const Setting = union(enum) {
    /// The time last written and the attributes, each left as it is when 0.
    basic: struct { written: u64 = 0, attributes: u32 = 0 },
    disposition,
    /// The new path.
    rename: []const u8,
};

/// A piece of an open file read ahead: `want` bytes from `offset` asked
/// for into buffer `index` as message `id`, `since` seconds on `now`'s
/// clock; once `arrived`, its `data`, and whether the file `end`s there.
/// Nothing without a `lock`.
const ReadAhead = struct {
    lock: ?*Lock = null,
    offset: u64 = 0,
    want: u32 = 0,
    index: u1 = 0,
    id: u64 = 0,
    since: u64 = 0,
    arrived: bool = false,
    data: []const u8 = &.{},
    end: bool = false,
};

pub const FileSystem = struct {
    sys: *ExecBase,
    dl: *DosBase,
    session: *Session,
    /// The handler's port (fl_Task of its locks).
    port: ?*MsgPort = null,
    /// The volume's node (fl_Volume of its locks), its name and its date,
    /// and the device's name, which a watch may name the volume by.
    volume_node: ?*dos.DosList = null,
    volume_name: []const u8 = "",
    volume_date: dos.DateStamp = .{},
    device_name: []const u8 = "",
    /// The zone the system clock keeps, which dates are shown in.
    zone: dos.timezone.Zone = .{},
    locks: ?*Lock = null,
    keys: ?*Key = null,
    /// The volume's record locks and watchers; none without them.
    records: ?*record.Records = null,
    watchers: ?*notify.Watchers = null,
    /// Nothing is written: the startup says so, or the share does not let
    /// the user write.
    read_only: bool = false,
    /// The share's size, as last asked; written to since, and when it was
    /// asked, in seconds on `now`'s clock.
    space: commands.Space = .{},
    space_stale: bool = false,
    space_asked: u64 = 0,
    /// Scratch for paths: the packet's, a rename's new one, and one made
    /// while those are in use - a key's new path, a watch's.
    path: Path = .{},
    target: Path = .{},
    spare: Path = .{},
    /// A batch for looking for a stand-in's name.
    batch: [session_area.credit_bytes]u8 = undefined,
    /// The length of the last batch `listFirst` or `listMore` read.
    batch_length: usize = 0,
    /// The connection is gone.
    lost: bool = false,
    /// Makes the connection again after it was lost - the session, the
    /// logon and the tree - or says it cannot yet: the handler's.
    reconnect: ?*const fn (fs: *FileSystem) bool = null,
    /// Seconds on a clock that only counts up, null without one: the
    /// handler's.
    now: ?*const fn (fs: *FileSystem) ?u64 = null,
    /// Two buffers of `session_area.receive_size` bytes to read ahead
    /// into, none without: the handler's. What was read ahead, and the
    /// READ ahead coming.
    ahead_buffers: ?[2][]u8 = null,
    cached: ReadAhead = .{},
    coming: ReadAhead = .{},
    /// The piece written behind while its answer comes: the file's, its
    /// message id and its length. Nothing without a lock.
    behind: struct { lock: ?*Lock = null, id: u64 = 0, length: u32 = 0 } = .{},
    /// A buffer of `session_area.io_max` bytes to gather small writes in,
    /// none without: the handler's, which sends them when they have
    /// waited long enough. What is gathered: the file's `length` bytes
    /// from `offset`, at `start` in the buffer. Nothing without a lock.
    gather_buffer: ?[]u8 = null,
    gathered: struct { lock: ?*Lock = null, offset: u64 = 0, start: usize = 0, length: usize = 0 } = .{},

    // --- memory ---------------------------------------------------------------

    /// The key for `path`, made if there is none; `is_dir` is what the
    /// server last said the object is.
    fn keyFor(fs: *FileSystem, path: []const u8, is_dir: bool) Error!*Key {
        if (fs.findKey(path)) |key| {
            key.is_dir = is_dir;
            return key;
        }
        const block = fs.sys.AllocVec(@sizeOf(Key), exec.MEMF_CLEAR) orelse return error.NoMemory;
        const key: *Key = @ptrCast(@alignCast(block));
        key.* = .{ .is_dir = is_dir };
        fs.setPath(key, path) catch |err| {
            fs.sys.FreeVec(key);
            return err;
        };
        key.next = fs.keys;
        fs.keys = key;
        return key;
    }

    /// The key for `path`, if there is one.
    fn findKey(fs: *FileSystem, path: []const u8) ?*Key {
        var it = fs.keys;
        while (it) |key| : (it = key.next) if (names.samePath(key.path(), path)) return key;
        return null;
    }

    /// A key given `path`, in an allocation of its own; the old one freed.
    fn setPath(fs: *FileSystem, key: *Key, path: []const u8) Error!void {
        var bytes: ?[*]u8 = null;
        if (path.len > 0) {
            const block = fs.sys.AllocVec(path.len, exec.MEMF_ANY) orelse return error.NoMemory;
            const made: [*]u8 = @ptrCast(block);
            @memcpy(made[0..path.len], path);
            bytes = made;
        }
        if (key.path_bytes) |old| fs.sys.FreeVec(old);
        key.path_bytes = bytes;
        key.path_len = path.len;
    }

    /// A key nothing is locked, open or watched on any more freed.
    fn letGo(fs: *FileSystem, key: *Key) void {
        if (key.locks != 0 or key.watched != 0) return;
        if (fs.keys == key) {
            fs.keys = key.next;
        } else {
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (other.next == key) {
                    other.next = key.next;
                    break;
                }
            }
        }
        if (key.path_bytes) |bytes| fs.sys.FreeVec(bytes);
        fs.sys.FreeVec(key);
    }

    /// A lock on `key`, unless another stands in the way: an exclusive
    /// one, or any for an exclusive lock.
    fn newLock(fs: *FileSystem, key: *Key, access: i32) Error!*Lock {
        const exclusive = access == dos.EXCLUSIVE_LOCK;
        if (fs.otherLock(key, null, !exclusive)) return error.InUse;
        const block = fs.sys.AllocVec(@sizeOf(Lock), exec.MEMF_CLEAR) orelse return error.NoMemory;
        const lock: *Lock = @ptrCast(@alignCast(block));
        lock.* = .{
            .lock = .{
                .link = if (fs.locks) |head| &head.lock else null,
                .key = @intFromPtr(key),
                .access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
                .task = fs.port,
                .volume = fs.volume_node,
            },
            .key = key,
        };
        fs.locks = lock;
        key.locks += 1;
        return lock;
    }

    /// A lock on the object at `path`: its key found or made, and let go
    /// of again when the lock cannot be had.
    fn lockPath(fs: *FileSystem, path: []const u8, is_dir: bool, access: i32) Error!*Lock {
        const key = try fs.keyFor(path, is_dir);
        return fs.newLock(key, access) catch |err| {
            fs.letGo(key);
            return err;
        };
    }

    fn freeLock(fs: *FileSystem, lock: *Lock) void {
        fs.endScan(lock);
        if (fs.cached.lock == lock) fs.cached.lock = null;
        if (fs.coming.lock == lock) fs.coming.lock = null;
        if (fs.behind.lock == lock) fs.behind.lock = null;
        if (fs.gathered.lock == lock) fs.gathered.lock = null;
        // A file's record locks go with its handle.
        if (fs.records) |records| records.release(lock);
        if (fs.locks == lock) {
            fs.locks = lock.nextLock();
        } else {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.lock.link == &lock.lock) {
                    other.lock.link = lock.lock.link;
                    break;
                }
            }
        }
        const key = lock.key;
        fs.sys.FreeVec(lock);
        key.locks -= 1;
        fs.letGo(key);
    }

    /// Whether a lock but `except` is on `key` (with `exclusive_only`, an
    /// exclusive one).
    fn otherLock(fs: *FileSystem, key: *const Key, except: ?*const Lock, exclusive_only: bool) bool {
        var it = fs.locks;
        while (it) |other| : (it = other.nextLock()) {
            if (other == except or other.key != key) continue;
            if (!exclusive_only or other.lock.access == dos.EXCLUSIVE_LOCK) return true;
        }
        return false;
    }

    fn owns(fs: *FileSystem, lock: *Lock) bool {
        var it = fs.locks;
        while (it) |other| : (it = other.nextLock()) if (other == lock) return true;
        return false;
    }

    /// Whether anything on the volume is locked, open or watched: what
    /// keeps it from being dismounted.
    pub fn inUse(fs: *const FileSystem) bool {
        if (fs.locks != null) return true;
        var it = fs.keys;
        while (it) |key| : (it = key.next) if (key.watched != 0) return true;
        return false;
    }

    /// How many locks point at `node` as their volume.
    pub fn locksOn(fs: *FileSystem, node: *dos.DosList) u32 {
        var count: u32 = 0;
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) if (lock.lock.volume == node) {
            count += 1;
        };
        return count;
    }

    /// A lock from a packet: one of ours, or null for the root.
    fn lockArg(fs: *FileSystem, value: isize) Error!?*Lock {
        if (value == 0) return null;
        const lock: *Lock = @ptrFromInt(@as(usize, @bitCast(value)));
        if (!fs.owns(lock)) return error.InvalidLock;
        return lock;
    }

    /// The path a lock from a packet stands for: the root's is empty.
    fn pathArg(fs: *FileSystem, value: isize) Error![]const u8 {
        const lock = try fs.lockArg(value) orelse return "";
        return lock.path();
    }

    /// A packet's name from the directory a lock from it stands for, into
    /// `into`.
    fn resolveArg(fs: *FileSystem, dir: ?*dos.FileLock, name: ?[*:0]const u8, into: *Path) Error!void {
        const base = try fs.pathArg(lockValue(dir));
        try names.resolve(base, span(name orelse return error.InvalidName), into);
    }

    /// An open file from a packet's handle.
    fn fileOf(fs: *FileSystem, fh: ?*dos.FileHandle) Error!*Lock {
        const handle = fh orelse return error.InvalidLock;
        const lock: *Lock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
        if (!fs.owns(lock) or !lock.open) return error.InvalidLock;
        return lock;
    }

    // --- requests -------------------------------------------------------------

    /// The requests sent and their answers in `replies`; a broken
    /// connection is NotMounted from here on.
    fn exchange(fs: *FileSystem, request: *session_area.Request, replies: []Reply) Error!void {
        try fs.settleAhead();
        fs.session.exchange(request, replies) catch {
            fs.lost = true;
            return error.NotMounted;
        };
        try fs.stillThere(request, replies);
    }

    /// One READ sent, its data read straight into `into` when it can be:
    /// as `Session.exchangeRead`, a broken connection NotMounted.
    fn exchangeRead(fs: *FileSystem, request: *session_area.Request, replies: []Reply, into: []u8) Error!?usize {
        try fs.settleAhead();
        const count = fs.session.exchangeRead(request, replies, into) catch {
            fs.lost = true;
            return error.NotMounted;
        };
        try fs.stillThere(request, replies);
        return count;
    }

    /// NotMounted, and the connection lost, when an answer says the
    /// session or the share has gone.
    fn stillThere(fs: *FileSystem, request: *const session_area.Request, replies: []Reply) Error!void {
        for (replies[0..request.count]) |*reply| switch (reply.status()) {
            smb.STATUS_USER_SESSION_DELETED, smb.STATUS_NETWORK_SESSION_EXPIRED, smb.STATUS_NETWORK_NAME_DELETED => {
                fs.lost = true;
                return error.NotMounted;
            },
            else => {},
        };
    }

    /// What `path` is: a CREATE and a CLOSE in one round trip. A path the
    /// server does not know that has a stand-in's name in it is looked
    /// for again with each such name replaced by the one it stands for.
    fn probe(fs: *FileSystem, path: *Path) Error!commands.Object {
        return fs.probeOnce(path) catch |err| {
            if (err != error.NotFound and err != error.DirNotFound) return err;
            if (!try fs.replaceStandIns(path)) return err;
            return fs.probeOnce(path);
        };
    }

    fn probeOnce(fs: *FileSystem, path: *const Path) Error!commands.Object {
        var request = fs.session.begin(.create);
        commands.create(&request, path.slice(), commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, 0);
        request.add(.close);
        commands.close(&request, &session_area.related_file);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return errorOf(replies[0].status());
        return commands.created(&replies[0]) orelse error.NotMounted;
    }

    /// Every name of `path` that has a stand-in's shape and is not on the
    /// server replaced by the one whose stand-in it is: whether any was.
    fn replaceStandIns(fs: *FileSystem, path: *Path) Error!bool {
        var replaced = false;
        var start: usize = 0;
        while (start < path.len) {
            const end = names.nameEnd(path.slice(), start);
            var narrow: [names.name_max]u8 = undefined;
            const latin = narrowed(path.slice()[start..end], &narrow);
            if (latin) |name| if (names.looksStandIn(name)) {
                var found: [2 * names.name_max]u8 = undefined;
                const dir = path.slice()[0..if (start == 0) 0 else start - 2];
                if (try fs.findStandIn(dir, name, &found)) |real| {
                    try path.replace(start, real);
                    replaced = true;
                }
            };
            start = names.nameEnd(path.slice(), start) + 2;
        }
        return replaced;
    }

    /// The name in the directory `dir` whose stand-in is `wanted`, copied
    /// into `into`; null when there is none.
    fn findStandIn(fs: *FileSystem, dir: []const u8, wanted: []const u8, into: *[2 * names.name_max]u8) Error!?[]const u8 {
        var file_id: [16]u8 = undefined;
        try fs.listFirst(dir, &file_id, &fs.batch);
        defer fs.closeHandle(&file_id);
        var entries = fs.batchEntries();
        while (true) {
            while (entries.next()) |entry| {
                if (entry.name.len <= into.len and names.standsFor(entry.name, wanted)) {
                    @memcpy(into[0..entry.name.len], entry.name);
                    return into[0..entry.name.len];
                }
            }
            if (!try fs.listMore(&file_id, &fs.batch)) return null;
            entries = fs.batchEntries();
        }
    }

    fn batchEntries(fs: *FileSystem) commands.Entries {
        return .{ .bytes = fs.batch[0..fs.batch_length] };
    }

    /// The directory `dir` opened and its first batch of entries read
    /// into `into`: CREATE and QUERY_DIRECTORY in one round trip.
    fn listFirst(fs: *FileSystem, dir: []const u8, file_id: *[16]u8, into: *[session_area.credit_bytes]u8) Error!void {
        var request = fs.session.begin(.create);
        commands.create(&request, dir, commands.FILE_LIST_DIRECTORY | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, commands.FILE_DIRECTORY_FILE);
        request.add(.query_directory);
        commands.queryDirectory(&request, &session_area.related_file, commands.FILE_DIRECTORY_INFORMATION, commands.RESTART_SCANS, star, fs.listLength());
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        const object = commands.created(&replies[0]) orelse return errorOf(replies[0].status());
        file_id.* = object.file_id;
        fs.batch_length = 0;
        if (replies[1].status() == smb.STATUS_NO_MORE_FILES) return;
        const out = commands.output(&replies[1]) orelse {
            fs.closeHandle(file_id);
            return errorOf(replies[1].status());
        };
        @memcpy(into[0..out.len], out);
        fs.batch_length = out.len;
    }

    /// The next batch of an open directory's entries: false at its end.
    fn listMore(fs: *FileSystem, file_id: *const [16]u8, into: *[session_area.credit_bytes]u8) Error!bool {
        var request = fs.session.begin(.query_directory);
        commands.queryDirectory(&request, file_id, commands.FILE_DIRECTORY_INFORMATION, 0, star, fs.listLength());
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        fs.batch_length = 0;
        if (replies[0].status() == smb.STATUS_NO_MORE_FILES) return false;
        const out = commands.output(&replies[0]) orelse return errorOf(replies[0].status());
        if (out.len == 0) return false;
        @memcpy(into[0..out.len], out);
        fs.batch_length = out.len;
        return true;
    }

    /// What a QUERY_DIRECTORY asks for: a batch, within what the server
    /// takes.
    fn listLength(fs: *const FileSystem) u32 {
        return @min(session_area.credit_bytes, fs.session.max_transact);
    }

    /// A handle closed, answered or not.
    fn closeHandle(fs: *FileSystem, file_id: *const [16]u8) void {
        var request = fs.session.begin(.close);
        commands.close(&request, file_id);
        var replies = session_area.noReplies();
        fs.exchange(&request, &replies) catch {};
    }

    /// A handle that was only read closed without waiting for the
    /// server's answer, which has nothing to say that matters: it is
    /// taken before the next request, as a piece written behind's is.
    fn closeBehind(fs: *FileSystem, file_id: *const [16]u8) void {
        fs.settleAhead() catch return;
        var request = fs.session.begin(.close);
        commands.close(&request, file_id);
        _ = fs.session.sendAhead(&request, fs.session.receive_buffer) catch {
            fs.lost = true;
        };
    }

    /// The object at `path` opened with `access`, `setting` set on it
    /// and the handle closed, in one round trip: the status of the first
    /// of them that failed, or success.
    fn change(fs: *FileSystem, path: []const u8, access: u32, setting: Setting) Error!u32 {
        var request = fs.session.begin(.create);
        commands.create(&request, path, access | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, 0);
        request.add(.set_info);
        const file = &session_area.related_file;
        switch (setting) {
            .basic => |basic| commands.setBasic(&request, file, basic.written, basic.attributes),
            .disposition => commands.setDisposition(&request, file),
            .rename => |to| commands.setRename(&request, file, to),
        }
        request.add(.close);
        commands.close(&request, file);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return replies[0].status();
        return replies[1].status();
    }

    /// The same at `path`, looked for again with its stand-ins replaced
    /// when the server does not know it.
    fn changeAt(fs: *FileSystem, path: *Path, access: u32, setting: Setting) Error!u32 {
        const status = try fs.change(path.slice(), access, setting);
        if (!missing(status) or !try fs.replaceStandIns(path)) return status;
        return fs.change(path.slice(), access, setting);
    }

    // --- staying connected ----------------------------------------------------

    /// After a lost connection: the connection made again, and every
    /// open file opened again by its path, at its position, as it was
    /// opened - to be written too, or only read. The scans' handles went
    /// with the old connection: each starts over at its next
    /// EXAMINE_NEXT. False while the server cannot be had.
    pub fn recover(fs: *FileSystem) bool {
        if (!fs.lost) return true;
        const reconnect = fs.reconnect orelse return false;
        fs.forgetAhead();
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            const scan = lock.scan orelse continue;
            fs.sys.FreeVec(scan);
            lock.scan = null;
        }
        const connected = reconnect(fs);
        // A piece written behind whose answer went with the connection.
        fs.taken();
        if (!connected) return false;
        fs.lost = false;
        it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            if (!lock.open) continue;
            lock.gone = true;
            const object = fs.openFile(lock.path(), lock.writable, commands.FILE_OPEN) catch {
                if (fs.lost) return false;
                continue;
            };
            lock.file_id = object.file_id;
            lock.size = object.size;
            lock.gone = false;
        }
        return true;
    }

    /// Nothing asked for a while: with anything locked or open, an ECHO,
    /// and a connection found lost made again.
    pub fn idle(fs: *FileSystem) void {
        if (fs.locks == null) return;
        if (!fs.lost) {
            var request = fs.session.begin(.echo);
            request.on_tree = false;
            commands.echo(&request);
            var replies = session_area.noReplies();
            fs.exchange(&request, &replies) catch {};
        }
        if (fs.lost) _ = fs.recover();
    }

    // --- locks ----------------------------------------------------------------

    fn locate(fs: *FileSystem, dir_arg: isize, name: ?[*:0]const u8, access: i32) Error!*Lock {
        const base = try fs.pathArg(dir_arg);
        try names.resolve(base, span(name orelse return error.InvalidName), &fs.path);
        if (fs.path.len == 0) return fs.lockPath("", true, access);
        const object = try fs.probe(&fs.path);
        return fs.lockPath(fs.path.slice(), object.isDir(), access);
    }

    /// A shared lock on the directory `path` is in; the root has none
    /// and answers 0.
    fn lockParent(fs: *FileSystem, path: []const u8) Answer {
        if (path.len == 0) return .{ .res1 = 0, .res2 = 0 };
        const lock = fs.lockPath(path[0..names.parentLength(path)], true, dos.SHARED_LOCK) catch |err| return no(err);
        return lockAnswer(lock);
    }

    /// A shared lock on what `source` is on (null: the root).
    fn copyLock(fs: *FileSystem, source: ?*Lock) Answer {
        const lock = if (source) |held|
            fs.newLock(held.key, dos.SHARED_LOCK) catch |err| return no(err)
        else
            fs.lockPath("", true, dos.SHARED_LOCK) catch |err| return no(err);
        return lockAnswer(lock);
    }

    // --- examine --------------------------------------------------------------

    /// A FileInfoBlock for the root: the volume.
    fn fillRoot(fs: *FileSystem, fib: *FileInfoBlock) void {
        fib.* = .{
            .disk_key = 0,
            .dir_entry_type = dos.ST_ROOT,
            .entry_type = dos.ST_ROOT,
            .date = fs.volume_date,
        };
        const name = fs.volume_name[0..@min(fs.volume_name.len, dos.name_max)];
        @memcpy(fib.file_name[0..name.len], name);
    }

    /// A FileInfoBlock for a directory's entry, `next` the scan's count
    /// after it.
    fn fillEntry(fs: *FileSystem, fib: *FileInfoBlock, entry: *const commands.Entry, next: usize) void {
        const kind: i32 = if (entry.isDir()) dos.ST_USERDIR else dos.ST_FILE;
        const size: u64 = if (entry.isDir()) 0 else entry.size;
        const unit: u64 = if (fs.space.unit_bytes != 0) fs.space.unit_bytes else 512;
        fib.* = .{
            .disk_key = next,
            .dir_entry_type = kind,
            .entry_type = kind,
            .protection = protectionOf(entry.attributes),
            .size = size,
            .num_blocks = (size + unit - 1) / unit,
            .date = dateOf(&fs.zone, entry.written),
        };
        var buffer: [names.name_max]u8 = undefined;
        const name = names.toDos(entry.name, &buffer);
        @memcpy(fib.file_name[0..name.len], name);
    }

    /// The entry of the object at `path`, read from its directory: the
    /// directory's CREATE, a QUERY_DIRECTORY for the one name and a
    /// CLOSE, in one round trip.
    fn examinePath(fs: *FileSystem, path: []const u8, fib: *FileInfoBlock) Error!void {
        if (path.len == 0) return fs.fillRoot(fib);
        const parent = names.parentLength(path);
        const dir = path[0..parent];
        const name = names.lastName(path);
        var request = fs.session.begin(.create);
        commands.create(&request, dir, commands.FILE_LIST_DIRECTORY | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, commands.FILE_DIRECTORY_FILE);
        request.add(.query_directory);
        commands.queryDirectory(&request, &session_area.related_file, commands.FILE_DIRECTORY_INFORMATION, commands.RESTART_SCANS | commands.RETURN_SINGLE_ENTRY, name, entry_query);
        request.add(.close);
        commands.close(&request, &session_area.related_file);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return errorOf(replies[0].status());
        if (replies[1].status() == smb.STATUS_NO_MORE_FILES or replies[1].status() == smb.STATUS_NO_SUCH_FILE) return error.NotFound;
        const out = commands.output(&replies[1]) orelse return errorOf(replies[1].status());
        var entries: commands.Entries = .{ .bytes = out };
        const entry = entries.next() orelse return error.NotFound;
        fs.fillEntry(fib, &entry, 0);
    }

    fn examine(fs: *FileSystem, args: dos.ExamineArgs, next: bool) Error!void {
        const fib = args.fib orelse return error.InvalidLock;
        const lock = try fs.lockArg(@bitCast(@intFromPtr(args.lock)));
        const path: []const u8 = if (lock) |held| held.path() else "";
        if (!next) return fs.examinePath(path, fib);
        // A scan is kept with its lock: there is none without one.
        const held = lock orelse return error.InvalidLock;
        if (!held.key.is_dir) return error.NoMoreEntries;
        return fs.examineNext(held, fib);
    }

    /// The next entry of a directory scan, as the file's header says.
    fn examineNext(fs: *FileSystem, lock: *Lock, fib: *FileInfoBlock) Error!void {
        const wanted: usize = fib.disk_key;
        if (lock.scan) |scan| {
            if (scan.ordinal != wanted) fs.endScan(lock);
        }
        const scan = lock.scan orelse blk: {
            const block = fs.sys.AllocVec(@sizeOf(Scan), exec.MEMF_ANY) orelse return error.NoMemory;
            const made: *Scan = @ptrCast(@alignCast(block));
            made.* = .{};
            lock.scan = made;
            fs.listFirst(lock.path(), &made.file_id, &made.batch) catch |err| {
                fs.endScan(lock);
                return err;
            };
            made.open = true;
            made.entries = .{ .bytes = made.batch[0..fs.batch_length] };
            if (fs.batch_length == 0) made.end = true;
            break :blk made;
        };
        while (true) {
            while (scan.entries.next()) |entry| {
                if (entry.isDots()) continue;
                scan.ordinal += 1;
                if (scan.ordinal <= wanted) continue;
                fs.fillEntry(fib, &entry, scan.ordinal);
                return;
            }
            const more = !scan.end and (fs.listMore(&scan.file_id, &scan.batch) catch |err| {
                fs.endScan(lock);
                return err;
            });
            if (!more) {
                fs.endScan(lock);
                return error.NoMoreEntries;
            }
            scan.entries = .{ .bytes = scan.batch[0..fs.batch_length] };
        }
    }

    /// A lock's scan ended: its directory closed and its batch freed.
    fn endScan(fs: *FileSystem, lock: *Lock) void {
        const scan = lock.scan orelse return;
        if (scan.open and !fs.lost) fs.closeHandle(&scan.file_id);
        fs.sys.FreeVec(scan);
        lock.scan = null;
    }

    // --- files ----------------------------------------------------------------

    /// FINDINPUT, FINDOUTPUT and FINDUPDATE: a file opened as the header
    /// says, and the lock behind it made the handle's.
    fn open(fs: *FileSystem, args: dos.FindArgs, action: dos.ActionCode) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        try fs.resolveArg(args.lock, args.name, &fs.path);
        if (fs.path.len == 0) return error.WrongType;
        const lock = switch (action) {
            .findinput => try fs.openInput(),
            .findoutput => try fs.openOutput(),
            else => try fs.openUpdate(),
        };
        fh.key = lock;
        fh.interactive = false;
    }

    /// FINDINPUT: the file at `fs.path`, there already, opened to be
    /// read, shared - its first piece read in the same round trip.
    fn openInput(fs: *FileSystem) Error!*Lock {
        var first: ReadAhead = .{};
        const object = fs.openToRead(fs.path.slice(), &first) catch |err| blk: {
            if (err != error.NotFound and err != error.DirNotFound) return err;
            if (!try fs.replaceStandIns(&fs.path)) return err;
            break :blk try fs.openToRead(fs.path.slice(), &first);
        };
        const lock = try fs.openLock(&object, false, dos.SHARED_LOCK);
        if (first.arrived) {
            first.lock = lock;
            fs.cached = first;
        }
        return lock;
    }

    /// The file at `path` opened to be read, as `openFile` does, and its
    /// first `first_bytes` read in the same round trip - a CREATE and a
    /// READ of what it opens, compounded - into a buffer read ahead into,
    /// kept in `first` as a piece read ahead: a file no larger is read,
    /// and found to end, without asking again. Without the buffers, the
    /// CREATE alone.
    fn openToRead(fs: *FileSystem, path: []const u8, first: *ReadAhead) Error!commands.Object {
        const buffers = fs.ahead_buffers orelse return fs.openFile(path, false, commands.FILE_OPEN);
        var request = fs.session.begin(.create);
        commands.create(&request, path, commands.FILE_READ_DATA | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, commands.FILE_NON_DIRECTORY_FILE);
        const want: u32 = @intCast(@min(first_bytes, fs.session.pieceMax(fs.session.max_read)));
        request.add(.read);
        commands.read(&request, &session_area.related_file, 0, want);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        const object = commands.created(&replies[0]) orelse return errorOf(replies[0].status());
        const data = commands.readData(&replies[1]) orelse return object;
        // Not into the buffer a READ ahead of another file came into; what
        // was read ahead before is let go of.
        const index: u1 = if (fs.coming.lock != null) fs.coming.index ^ 1 else 0;
        fs.cached.lock = null;
        const count = @min(data.len, want);
        @memcpy(buffers[index][0..count], data[0..count]);
        first.* = .{
            .want = want,
            .index = index,
            .since = fs.clock(),
            .arrived = true,
            .data = buffers[index][0..count],
            .end = count < want or count >= object.size,
        };
        return object;
    }

    /// FINDOUTPUT: the file at `fs.path` made, or emptied, and opened
    /// exclusive - asked only when no lock of this handler is on it.
    fn openOutput(fs: *FileSystem) Error!*Lock {
        if (fs.read_only) return error.WriteProtected;
        _ = try fs.replaceStandIns(&fs.path);
        if (fs.findKey(fs.path.slice())) |key| if (key.locks != 0) return error.InUse;
        const object = try fs.openFile(fs.path.slice(), true, commands.FILE_OVERWRITE_IF);
        const lock = try fs.openLock(&object, true, dos.EXCLUSIVE_LOCK);
        fs.space_stale = true;
        if (object.action == commands.FILE_CREATED) fs.created(fs.path.slice()) else lock.modified = true;
        return lock;
    }

    /// FINDUPDATE: the file at `fs.path` opened shared, made when it is
    /// not there; one that may not be written is opened to be read.
    fn openUpdate(fs: *FileSystem) Error!*Lock {
        _ = try fs.replaceStandIns(&fs.path);
        const path = fs.path.slice();
        if (fs.read_only) {
            const object = fs.openFile(path, false, commands.FILE_OPEN) catch |err|
                return if (err == error.NotFound) error.WriteProtected else err;
            return fs.openLock(&object, false, dos.SHARED_LOCK);
        }
        if (fs.findKey(path)) |key| if (fs.otherLock(key, null, true)) return error.InUse;
        var writable = true;
        const object = fs.openFile(path, true, commands.FILE_OPEN_IF) catch |err| blk: {
            if (err != error.FileWriteProtected and err != error.InUse) return err;
            writable = false;
            break :blk fs.openFile(path, false, commands.FILE_OPEN) catch return err;
        };
        const lock = try fs.openLock(&object, writable, dos.SHARED_LOCK);
        if (object.action == commands.FILE_CREATED) {
            fs.space_stale = true;
            fs.created(path);
        }
        return lock;
    }

    /// The file at `path` opened as `disposition` says: to be read, and
    /// with `writing` to be written too.
    fn openFile(fs: *FileSystem, path: []const u8, writing: bool, disposition: u32) Error!commands.Object {
        var access = commands.FILE_READ_DATA | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE;
        if (writing) access |= write_access;
        var request = fs.session.begin(.create);
        commands.create(&request, path, access, 0, disposition, commands.FILE_NON_DIRECTORY_FILE);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (commands.created(&replies[0])) |object| return object;
        return if (writing) changeErrorOf(replies[0].status()) else errorOf(replies[0].status());
    }

    /// The lock an open file of `fs.path` is behind its handle; the handle
    /// closed again when the lock cannot be had.
    fn openLock(fs: *FileSystem, object: *const commands.Object, writable: bool, access: i32) Error!*Lock {
        const lock = fs.lockPath(fs.path.slice(), false, access) catch |err| {
            fs.closeHandle(&object.file_id);
            return err;
        };
        lock.open = true;
        lock.writable = writable;
        lock.file_id = object.file_id;
        lock.size = object.size;
        return lock;
    }

    /// An open file's handle made one that writes: the file opened again
    /// to be written too, and the handle that only read closed.
    fn makeWritable(fs: *FileSystem, lock: *Lock) Error!void {
        if (fs.read_only) return error.WriteProtected;
        const object = try fs.openFile(lock.path(), true, commands.FILE_OPEN);
        fs.closeHandle(&lock.file_id);
        lock.file_id = object.file_id;
        lock.writable = true;
    }

    /// READ: from the position, what was read ahead first, the rest in
    /// pieces; and when it followed the read before, the piece after it
    /// asked for ahead.
    fn read(fs: *FileSystem, args: dos.IOArgs) Error!usize {
        const lock = try fs.fileOf(args.fh);
        const buffer = args.buffer orelse return 0;
        const length: usize = if (args.length > 0) @intCast(args.length) else 0;
        const following = lock.pos == lock.read_end;
        var recovered = false;
        var done: usize = 0;
        while (done < length) {
            if (lock.gone) return error.NotFound;
            const ahead = fs.fromAhead(lock, buffer[done..length]) catch |err| {
                if (recovered or !fs.lost or !fs.recover()) return err;
                recovered = true;
                continue;
            };
            if (ahead) |count| {
                // Nothing there: the file ends.
                if (count == 0) break;
                done += count;
                lock.pos += count;
                if (lock.pos > lock.size) lock.size = lock.pos;
                continue;
            }
            // The server's limit, which a new connection may change, and
            // the credits there are.
            const piece_max: usize = fs.session.pieceMax(fs.session.max_read);
            const want: u32 = @intCast(@min(length - done, piece_max));
            var request = fs.session.begin(.read);
            commands.read(&request, &lock.file_id, lock.pos, want);
            var replies = session_area.noReplies();
            // Straight into the buffer, or from the answer.
            const streamed = fs.exchangeRead(&request, &replies, buffer[done..length]) catch |err| {
                // Lost on the way: the piece asked for again, once, on
                // the file's handle on a new connection.
                if (recovered or !fs.lost or !fs.recover()) return err;
                recovered = true;
                continue;
            };
            const count = streamed orelse blk: {
                const data = commands.readData(&replies[0]) orelse return errorOf(replies[0].status());
                const count = @min(data.len, length - done);
                @memcpy(buffer[done..][0..count], data[0..count]);
                break :blk count;
            };
            done += count;
            lock.pos += count;
            if (lock.pos > lock.size) lock.size = lock.pos;
            if (count < want) break;
        }
        lock.read_end = lock.pos;
        if (following) fs.readAhead(lock);
        return done;
    }

    // --- reading ahead --------------------------------------------------------

    /// What was read ahead of `lock` from its position copied into
    /// `into`: how much, 0 where the file ends - or null when nothing
    /// read ahead is there. The READ ahead from there is waited for
    /// when it is still coming.
    fn fromAhead(fs: *FileSystem, lock: *Lock, into: []u8) Error!?usize {
        fs.taken();
        var moved = false;
        while (true) {
            const cached = &fs.cached;
            if (cached.lock == lock and lock.pos >= cached.offset and lock.pos - cached.offset <= cached.data.len) {
                const rest = cached.data[@intCast(lock.pos - cached.offset)..];
                if (rest.len > 0 or (cached.end and fs.fresh(cached))) {
                    const count = @min(rest.len, into.len);
                    @memcpy(into[0..count], rest[0..count]);
                    return count;
                }
            }
            if (moved or fs.coming.lock != lock or fs.coming.offset != lock.pos) return null;
            if (!fs.coming.arrived) try fs.settleAhead();
            if (fs.coming.lock != lock or !fs.coming.arrived) return null;
            fs.cached = fs.coming;
            fs.coming.lock = null;
            moved = true;
        }
    }

    /// After a read that followed the one before: the piece after what
    /// was read ahead of `lock`, or after its position, asked for ahead -
    /// not when the file ends before it, as far as is known. A READ ahead
    /// for another file is let be while it is fresh.
    fn readAhead(fs: *FileSystem, lock: *Lock) void {
        const buffers = fs.ahead_buffers orelse return;
        if (fs.lost or lock.gone) return;
        fs.taken();
        const cached = &fs.cached;
        var from = lock.pos;
        if (cached.lock == lock and lock.pos >= cached.offset and lock.pos - cached.offset <= cached.data.len) {
            if (cached.end and fs.fresh(cached)) return;
            from = cached.offset + cached.data.len;
        }
        if (from >= lock.size) return;
        if (fs.coming.lock) |other| {
            if (other == lock and fs.coming.offset == from) return;
            if (other != lock and fs.fresh(&fs.coming)) return;
        }
        // Whatever else was coming taken in, and let go of.
        fs.settleAhead() catch return;
        fs.coming.lock = null;
        const index: u1 = if (cached.lock != null) cached.index ^ 1 else 0;
        const want = fs.session.pieceMax(fs.session.max_read);
        var request = fs.session.begin(.read);
        commands.read(&request, &lock.file_id, from, want);
        const id = fs.session.sendAhead(&request, buffers[index]) catch {
            fs.lost = true;
            return;
        };
        fs.coming = .{ .lock = lock, .offset = from, .want = want, .since = fs.clock(), .index = index, .id = id };
    }

    /// Whether a READ ahead is coming: what `pump` is for. A WRITE's
    /// answer waits on the connection for the next request.
    pub fn reading(fs: *const FileSystem) bool {
        return fs.coming.lock != null and !fs.coming.arrived;
    }

    /// What has come of the READ ahead read, without waiting: the
    /// handler's, between packets. A broken connection is lost.
    pub fn pump(fs: *FileSystem) void {
        if (!fs.reading()) return;
        fs.session.pump() catch {
            fs.lost = true;
        };
        fs.taken();
    }

    /// All of the READ ahead read, waiting for what has not come; a broken
    /// connection NotMounted.
    fn settleAhead(fs: *FileSystem) Error!void {
        if (fs.lost) return error.NotMounted;
        fs.session.settle() catch {
            fs.lost = true;
        };
        fs.taken();
        if (fs.lost) return error.NotMounted;
    }

    /// The answer to the request sent ahead taken from the session once it
    /// has all come: a READ's kept in `coming` while that still wants it,
    /// let go of otherwise; a WRITE's failure kept with its file. A READ
    /// ahead the session no longer has is forgotten, a WRITE behind
    /// failed.
    fn taken(fs: *FileSystem) void {
        const coming = &fs.coming;
        if (fs.session.landed) |landed| {
            fs.session.landed = null;
            if (coming.lock != null and !coming.arrived and landed.id == coming.id) fs.arrived(&landed);
            if (fs.behind.lock != null and landed.id == fs.behind.id) fs.wrote(&landed);
        }
        if (coming.lock != null and !coming.arrived and !fs.session.aheadOf(coming.id)) coming.lock = null;
        // A piece written behind whose answer will not come: the
        // connection went with it.
        if (fs.behind.lock) |lock| if (!fs.session.aheadOf(fs.behind.id)) {
            lock.write_error = @intFromError(error.NotMounted);
            fs.behind.lock = null;
        };
    }

    /// The READ ahead's answer kept, its data no more than was asked
    /// for: where the file ends when it is less. A failed READ is
    /// forgotten; one that says the session or share has gone loses the
    /// connection.
    fn arrived(fs: *FileSystem, landed: *const session_area.Landed) void {
        const coming = &fs.coming;
        const data = landed.data orelse commands.readData(&landed.reply) orelse {
            switch (landed.reply.status()) {
                smb.STATUS_USER_SESSION_DELETED, smb.STATUS_NETWORK_SESSION_EXPIRED, smb.STATUS_NETWORK_NAME_DELETED => fs.lost = true,
                else => {},
            }
            coming.lock = null;
            return;
        };
        coming.data = data[0..@min(data.len, coming.want)];
        coming.end = data.len < coming.want;
        coming.arrived = true;
    }

    /// Everything read ahead let go of, and the READ ahead coming: its
    /// answer is not kept when it comes.
    fn forgetAhead(fs: *FileSystem) void {
        fs.cached.lock = null;
        fs.coming.lock = null;
    }

    /// Whether what was read ahead is young enough to be believed where it
    /// says the file ends: asked for no more than a second ago, on `now`'s
    /// clock - any age without one.
    fn fresh(fs: *FileSystem, ahead: *const ReadAhead) bool {
        const now = fs.now orelse return true;
        const seconds = now(fs) orelse return true;
        return seconds -% ahead.since <= 1;
    }

    /// The seconds on `now`'s clock, 0 without one.
    fn clock(fs: *FileSystem) u64 {
        const now = fs.now orelse return 0;
        return now(fs) orelse 0;
    }

    /// WRITE: the buffer at the position, in pieces; the handle made one
    /// that writes first, if it is not.
    fn write(fs: *FileSystem, args: dos.IOArgs) Error!usize {
        const lock = try fs.fileOf(args.fh);
        const buffer = args.buffer orelse return 0;
        const length: usize = if (args.length > 0) @intCast(args.length) else 0;
        if (length == 0) return 0;
        if (fs.read_only) return error.WriteProtected;
        if (lock.gone) return error.NotFound;
        fs.forgetAhead();
        if (!lock.writable) try fs.makeWritable(lock);
        if (fs.gather_buffer) |into| {
            if (length < @min(into.len, fs.session.pieceMax(fs.session.max_write))) return fs.gather(lock, buffer[0..length], into);
        }
        // A large one after what was gathered.
        fs.sendGathered() catch |err| {
            if (!fs.lost or !fs.recover()) return err;
            try fs.sendGathered();
        };
        var recovered = false;
        var done: usize = 0;
        // The piece of this WRITE whose answer is still coming.
        var behind: usize = 0;
        while (done < length) {
            if (lock.gone) return error.NotFound;
            const piece_max: usize = fs.session.pieceMax(fs.session.max_write);
            const piece: usize = @min(length - done, piece_max);
            var request = fs.session.begin(.write);
            commands.write(&request, &lock.file_id, lock.pos, buffer[done..][0..piece]);
            fs.writeBehind(lock, &request, piece) catch |err| {
                // Lost on the way: the piece written again, once - to the
                // same place, so whatever of it arrived is written over -
                // from the one before it when that one's answer went too.
                if (recovered or !fs.lost or !fs.recover()) return err;
                recovered = true;
                if (behind > 0 and lock.write_error != 0) {
                    lock.write_error = 0;
                    done -= behind;
                    lock.pos -= behind;
                }
                behind = 0;
                continue;
            };
            lock.modified = true;
            lock.unflushed = true;
            fs.space_stale = true;
            behind = piece;
            done += piece;
            lock.pos += piece;
            if (lock.pos > lock.size) lock.size = lock.pos;
        }
        return done;
    }

    /// One piece of a WRITE sent, its answer left to come: signed while
    /// the piece before it may still be going, then sent once that one's
    /// answer is taken - and when that was the file's piece written
    /// behind and it failed, not sent, the failure answered instead.
    fn writeBehind(fs: *FileSystem, lock: *Lock, request: *session_area.Request, length: usize) Error!void {
        const made = try fs.readyBehind(request);
        failedBehind(lock) catch |err| {
            fs.session.withdraw(&made);
            return err;
        };
        try fs.sendBehind(lock, &made, length);
    }

    /// A piece of a WRITE made ready to go (`Session.ready`), then the
    /// answer to the request before it taken; a broken connection
    /// NotMounted.
    ///
    /// It is signed one below the handler's priority, which is the
    /// network stack's (MountShare's): the stack sending the piece before
    /// it then outranks the signing - and the cores' workers that
    /// crypto.library shares a long signature with, which take the
    /// signer's priority. At the stack's priority the four of them held
    /// every core for a while each MiB, and the stack waited.
    fn readyBehind(fs: *FileSystem, request: *const session_area.Request) Error!session_area.Ready {
        if (fs.lost) return error.NotMounted;
        const sys = fs.sys;
        const me = sys.FindTask(null).?;
        const pri = sys.SetTaskPri(me, me.node.pri -| 1);
        const made = fs.session.ready(request);
        _ = sys.SetTaskPri(me, pri);
        const ready = made catch {
            fs.lost = true;
            fs.taken();
            return error.NotMounted;
        };
        try fs.settleAhead();
        return ready;
    }

    /// A piece of `lock` made ready sent, its answer left to come;
    /// whatever was ahead before taken in first.
    fn sendBehind(fs: *FileSystem, lock: *Lock, made: *const session_area.Ready, length: usize) Error!void {
        const id = fs.session.sendReady(made, fs.session.receive_buffer) catch {
            fs.lost = true;
            return error.NotMounted;
        };
        fs.behind = .{ .lock = lock, .id = id, .length = @intCast(length) };
    }

    /// The answer to the piece written behind taken when it has come,
    /// without waiting.
    fn takeWritten(fs: *FileSystem) void {
        if (fs.behind.lock == null or fs.lost) return;
        fs.session.pump() catch {
            fs.lost = true;
        };
        fs.taken();
    }

    /// A small WRITE gathered after the ones before it, into `into`:
    /// what was gathered sent first when this one does not follow on from
    /// it - another file, another place, no room left - and a full piece
    /// sent at once. A failure of a piece written behind is this WRITE's
    /// answer.
    fn gather(fs: *FileSystem, lock: *Lock, data: []const u8, into: []u8) Error!usize {
        fs.takeWritten();
        try failedBehind(lock);
        const piece_max: usize = @min(into.len, fs.session.pieceMax(fs.session.max_write));
        const gathered = &fs.gathered;
        if (gathered.lock) |other| {
            if (other != lock or gathered.offset + gathered.length != lock.pos or gathered.start + gathered.length + data.len > piece_max) {
                fs.sendGathered() catch |err| {
                    if (!fs.lost or !fs.recover()) return err;
                    try fs.sendGathered();
                };
            }
        }
        if (gathered.lock == null) gathered.* = .{ .lock = lock, .offset = lock.pos };
        @memcpy(into[gathered.start + gathered.length ..][0..data.len], data);
        gathered.length += data.len;
        lock.modified = true;
        lock.unflushed = true;
        fs.space_stale = true;
        lock.pos += data.len;
        if (lock.pos > lock.size) lock.size = lock.pos;
        // Full: it goes now - or, when it cannot, with the next try.
        if (gathered.start + gathered.length == piece_max) fs.sendGathered() catch {};
        return data.len;
    }

    /// What was gathered written behind, in as many pieces as the credits
    /// say. Kept when the connection is lost, to go on the next one; let
    /// go of, as the file's failure, when the file was not there again.
    pub fn sendGathered(fs: *FileSystem) Error!void {
        const gathered = &fs.gathered;
        const lock = gathered.lock orelse return;
        const into = fs.gather_buffer.?;
        if (lock.gone) {
            lock.write_error = @intFromError(error.NotFound);
            gathered.lock = null;
            return;
        }
        // The piece sent before, while its answer comes.
        var behind: usize = 0;
        while (gathered.length > 0) {
            const piece: usize = @min(gathered.length, fs.session.pieceMax(fs.session.max_write));
            var request = fs.session.begin(.write);
            commands.write(&request, &lock.file_id, gathered.offset, into[gathered.start..][0..piece]);
            const made = fs.readyBehind(&request) catch |err| {
                // Its answer went with the connection: it goes again on
                // the next one.
                if (behind > 0 and lock.write_error != 0) {
                    lock.write_error = 0;
                    gathered.offset -= behind;
                    gathered.start -= behind;
                    gathered.length += behind;
                }
                return err;
            };
            try fs.sendBehind(lock, &made, piece);
            behind = piece;
            gathered.offset += piece;
            gathered.start += piece;
            gathered.length -= piece;
        }
        gathered.lock = null;
    }

    /// Whether anything is gathered: the handler's timer runs while it is.
    pub fn gathering(fs: *const FileSystem) bool {
        return fs.gathered.lock != null;
    }

    /// What was gathered sent, once its time is up: the handler's, when
    /// its timer runs out. A lost connection is made again for it.
    pub fn sendDue(fs: *FileSystem) void {
        if (fs.gathered.lock == null) return;
        if (fs.lost and !fs.recover()) return;
        fs.sendGathered() catch {};
    }

    /// Whether `pkt` leaves what was gathered waiting: a WRITE, which
    /// sends it itself when it does not follow on; a SEEK, which does when
    /// it asks the size; and a READ of another file - not of the same file
    /// through another handle.
    fn keepsGathered(fs: *FileSystem, pkt: *DosPacket) bool {
        const lock = fs.gathered.lock orelse return true;
        return switch (pkt.getAction()) {
            .write, .seek => true,
            .read => {
                const file = fs.fileOf(pkt.args.io.fh) catch return false;
                return file.key != lock.key;
            },
            else => false,
        };
    }

    /// The answer to a piece written behind: a failure, or fewer bytes
    /// written than sent, kept for the file to tell; one that says the
    /// session or share has gone loses the connection too.
    fn wrote(fs: *FileSystem, landed: *const session_area.Landed) void {
        const lock = fs.behind.lock.?;
        fs.behind.lock = null;
        const count = commands.written(&landed.reply) orelse {
            const status = landed.reply.status();
            switch (status) {
                smb.STATUS_USER_SESSION_DELETED, smb.STATUS_NETWORK_SESSION_EXPIRED, smb.STATUS_NETWORK_NAME_DELETED => fs.lost = true,
                else => {},
            }
            lock.write_error = @intFromError(changeErrorOf(status));
            return;
        };
        if (count < fs.behind.length) lock.write_error = @intFromError(error.DiskFull);
    }

    /// What a piece of `lock` written behind came to, told once.
    fn failedBehind(lock: *Lock) Error!void {
        if (lock.write_error == 0) return;
        const failure: Error = @errorCast(@errorFromInt(lock.write_error));
        lock.write_error = 0;
        return failure;
    }

    /// The open file's size asked again.
    fn askSize(fs: *FileSystem, lock: *Lock) Error!void {
        try fs.sendGathered();
        var request = fs.session.begin(.query_info);
        commands.queryInfo(&request, &lock.file_id, commands.INFO_FILE, commands.FILE_STANDARD_INFORMATION, 24);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        const out = commands.output(&replies[0]) orelse return errorOf(replies[0].status());
        lock.size = commands.standardSize(out) orelse return error.NotMounted;
    }

    /// A position counted from a packet's mode: the start, the position
    /// or the end - asked for again.
    fn positionOf(fs: *FileSystem, lock: *Lock, offset: i64, mode: isize) Error!i128 {
        if (mode == dos.OFFSET_END) try fs.askSize(lock);
        const from: i128 = switch (mode) {
            dos.OFFSET_BEGINNING => 0,
            dos.OFFSET_CURRENT => lock.pos,
            dos.OFFSET_END => lock.size,
            else => return error.SeekError,
        };
        return from + offset;
    }

    /// To a position; the old one. Not before the start or past the end.
    fn seek(fs: *FileSystem, args: dos.SeekArgs) Error!i64 {
        const lock = try fs.fileOf(args.fh);
        if (lock.gone) return error.NotFound;
        const to = try fs.positionOf(lock, args.position, args.mode);
        if (to < 0) return error.SeekError;
        // Past the end as last known: the file may have grown since.
        if (to > lock.size and args.mode != dos.OFFSET_END) try fs.askSize(lock);
        if (to > lock.size) return error.SeekError;
        if (lock.pos > max_position) return error.SeekError;
        const old: i64 = @intCast(lock.pos);
        lock.pos = @intCast(to);
        return old;
    }

    /// SET_FILE_SIZE: the open file cut or grown to a size counted as a
    /// seek counts; the new size. Its handles past it move back to it.
    fn setFileSize(fs: *FileSystem, args: dos.SeekArgs) Error!i64 {
        const lock = try fs.fileOf(args.fh);
        if (fs.read_only) return error.WriteProtected;
        if (lock.gone) return error.NotFound;
        const to = try fs.positionOf(lock, args.position, args.mode);
        if (to < 0 or to > max_position) return error.SeekError;
        fs.forgetAhead();
        if (!lock.writable) try fs.makeWritable(lock);
        const size: u64 = @intCast(to);
        var request = fs.session.begin(.set_info);
        commands.setEndOfFile(&request, &lock.file_id, size);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return changeErrorOf(replies[0].status());
        var it = fs.locks;
        while (it) |other| : (it = other.nextLock()) {
            if (other.key != lock.key or !other.open) continue;
            other.size = size;
            if (other.pos > size) other.pos = size;
        }
        lock.modified = true;
        fs.space_stale = true;
        return @intCast(size);
    }

    /// END: the handle closed on the server, and the lock freed. A file
    /// that was written to is told of, and its directory. A piece written
    /// behind that failed is the answer, the file closed all the same.
    fn close(fs: *FileSystem, args: dos.FileHandleArgs) Error!void {
        const handle = args.fh orelse return error.InvalidLock;
        const lock: *Lock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
        if (!fs.owns(lock)) return error.InvalidLock;
        // What was gathered of it goes first, on a new connection if need
        // be; what cannot go is the file's failure.
        if (fs.gathered.lock == lock) {
            if (fs.lost) _ = fs.recover();
            fs.sendGathered() catch {};
            if (fs.gathered.lock == lock) {
                fs.gathered.lock = null;
                lock.write_error = @intFromError(error.NotMounted);
            }
        }
        if (fs.behind.lock == lock) fs.settleAhead() catch {};
        const failed = failedBehind(lock);
        if (lock.open and !lock.gone and !fs.lost) {
            if (lock.writable) fs.closeHandle(&lock.file_id) else fs.closeBehind(&lock.file_id);
        }
        if (lock.modified) {
            fs.tell(lock.key);
            fs.tellParent(lock.path());
        }
        lock.open = false;
        fs.freeLock(lock);
        handle.key = null;
        return failed;
    }

    /// FLUSH: every open file written to since it was last flushed
    /// flushed on the server - first the answer to the last piece written
    /// behind taken, and a failure of one answered.
    fn flush(fs: *FileSystem) Error!void {
        try fs.settleAhead();
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) try failedBehind(lock);
        it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            if (!lock.open or lock.gone or !lock.unflushed) continue;
            var request = fs.session.begin(.flush);
            commands.flush(&request, &lock.file_id);
            var replies = session_area.noReplies();
            try fs.exchange(&request, &replies);
            if (replies[0].failed()) return changeErrorOf(replies[0].status());
            lock.unflushed = false;
        }
    }

    /// FH_FROM_LOCK: the lock's file opened to be read, and the lock made
    /// the handle's.
    fn fhFromLock(fs: *FileSystem, args: dos.FhFromLockArgs) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const lock = try fs.lockArg(lockValue(args.lock)) orelse return error.InvalidLock;
        if (lock.key.is_dir or lock.open) return error.WrongType;
        const object = try fs.openFile(lock.path(), false, commands.FILE_OPEN);
        lock.open = true;
        lock.writable = false;
        lock.file_id = object.file_id;
        lock.size = object.size;
        lock.pos = 0;
        fh.key = lock;
        fh.interactive = false;
    }

    /// CHANGE_MODE: a lock or a handle made shared or exclusive, if no
    /// other lock stands in the way.
    fn changeMode(fs: *FileSystem, args: dos.ChangeModeArgs) Error!void {
        var lock: *Lock = undefined;
        var exclusive = false;
        switch (args.kind) {
            dos.CHANGE_LOCK => {
                lock = try fs.lockArg(@bitCast(@intFromPtr(args.object))) orelse return error.InvalidLock;
                exclusive = args.mode == dos.EXCLUSIVE_LOCK;
            },
            dos.CHANGE_FH => {
                lock = try fs.fileOf(@ptrCast(@alignCast(args.object)));
                exclusive = args.mode == dos.MODE_NEWFILE;
            },
            else => return error.WrongType,
        }
        if (exclusive and fs.otherLock(lock.key, lock, false)) return error.InUse;
        lock.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
    }

    // --- changes --------------------------------------------------------------

    /// CREATE_DIR: a directory made, and an exclusive lock on it.
    fn createDir(fs: *FileSystem, dir_arg: isize, name: ?[*:0]const u8) Error!*Lock {
        if (fs.read_only) return error.WriteProtected;
        const base = try fs.pathArg(dir_arg);
        try names.resolve(base, span(name orelse return error.InvalidName), &fs.path);
        if (fs.path.len == 0) return error.Exists;
        fs.makeDir() catch |err| {
            if (err != error.DirNotFound or !try fs.replaceStandIns(&fs.path)) return err;
            try fs.makeDir();
        };
        fs.space_stale = true;
        fs.created(fs.path.slice());
        return fs.lockPath(fs.path.slice(), true, dos.EXCLUSIVE_LOCK);
    }

    /// The directory at `fs.path` made: a CREATE and a CLOSE.
    fn makeDir(fs: *FileSystem) Error!void {
        var request = fs.session.begin(.create);
        commands.create(&request, fs.path.slice(), commands.FILE_LIST_DIRECTORY | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_CREATE, commands.FILE_DIRECTORY_FILE);
        request.add(.close);
        commands.close(&request, &session_area.related_file);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return changeErrorOf(replies[0].status());
    }

    /// DELETE_OBJECT: a file, or an empty directory, deleted - unless this
    /// handler has it locked.
    fn delete(fs: *FileSystem, dir_arg: isize, name: ?[*:0]const u8) Error!void {
        if (fs.read_only) return error.WriteProtected;
        const base = try fs.pathArg(dir_arg);
        try names.resolve(base, span(name orelse return error.InvalidName), &fs.path);
        if (fs.path.len == 0) return error.WrongType;
        var status = try fs.deleteAt();
        if (missing(status) and try fs.replaceStandIns(&fs.path)) status = try fs.deleteAt();
        if (smb.isError(status)) return deleteErrorOf(status);
        fs.space_stale = true;
        if (fs.findKey(fs.path.slice())) |key| fs.forsake(key);
        fs.tellParent(fs.path.slice());
    }

    fn deleteAt(fs: *FileSystem) Error!u32 {
        if (fs.findKey(fs.path.slice())) |key| if (key.locks != 0) return error.InUse;
        return fs.change(fs.path.slice(), commands.DELETE, .disposition);
    }

    /// RENAME_OBJECT: an object moved to a new name, never over another;
    /// the locks at and below it go with it.
    fn rename(fs: *FileSystem, args: dos.RenameArgs) Error!void {
        if (fs.read_only) return error.WriteProtected;
        try fs.resolveArg(args.from_lock, args.from_name, &fs.path);
        try fs.resolveArg(args.to_lock, args.to_name, &fs.target);
        if (fs.path.len == 0 or fs.target.len == 0) return error.WrongType;
        var status = try fs.renameAt();
        if (missing(status) and try fs.replaceStandIns(&fs.path)) status = try fs.renameAt();
        if (status == smb.STATUS_OBJECT_PATH_NOT_FOUND and try fs.replaceStandIns(&fs.target)) status = try fs.renameAt();
        const from = fs.path.slice();
        const to = fs.target.slice();
        if (smb.isError(status)) {
            // A directory with a file open below it is not moved.
            if (status == smb.STATUS_ACCESS_DENIED and fs.openWithin(from)) return error.InUse;
            return changeErrorOf(status);
        }
        fs.moveKeys(from, to);
        if (fs.findKey(to)) |key| {
            fs.tell(key);
            fs.forsake(key);
        }
        fs.tellParent(from);
        fs.tellParent(to);
        fs.arrive(to);
    }

    fn renameAt(fs: *FileSystem) Error!u32 {
        const from = fs.path.slice();
        const to = fs.target.slice();
        if (to.len > from.len and names.within(to, from)) return error.InUse;
        if (fs.findKey(from)) |key| if (fs.otherLock(key, null, true)) return error.InUse;
        fs.endScansWithin(from);
        return fs.change(from, commands.DELETE, .{ .rename = to });
    }

    /// The scans of every directory at or below `path` ended: their
    /// handles would keep the server from moving it. Each starts again at
    /// its next EXAMINE_NEXT.
    fn endScansWithin(fs: *FileSystem, path: []const u8) void {
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            if (lock.scan != null and names.within(lock.path(), path)) fs.endScan(lock);
        }
    }

    /// Whether a file at or below `path` is open.
    fn openWithin(fs: *FileSystem, path: []const u8) bool {
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            if (lock.open and names.within(lock.path(), path)) return true;
        }
        return false;
    }

    /// Every key at or below `from` given the path it has below `to` now;
    /// one there is no memory for keeps the old.
    fn moveKeys(fs: *FileSystem, from: []const u8, to: []const u8) void {
        var it = fs.keys;
        while (it) |key| : (it = key.next) {
            const path = key.path();
            if (!names.within(path, from)) continue;
            fs.spare.set(to) catch continue;
            fs.spare.append(path[from.len..]) catch continue;
            fs.setPath(key, fs.spare.slice()) catch {};
        }
    }

    /// SET_PROTECT and SET_DATE: an object's attributes from its
    /// protection, or the time it was last written - now, without a date.
    fn setProperty(fs: *FileSystem, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
        if (fs.read_only) return error.WriteProtected;
        try fs.resolveArg(args.lock, args.name, &fs.path);
        if (fs.path.len == 0) return error.WrongType;
        const value: usize = @bitCast(args.value);
        var setting: Setting = .{ .basic = .{} };
        if (action == .set_protect) {
            const object = try fs.probe(&fs.path);
            setting.basic.attributes = attributesOf(@truncate(value), object.attributes);
        } else {
            var today: dos.DateStamp = .{};
            const given: ?*const dos.DateStamp = @ptrFromInt(value);
            const date = given orelse blk: {
                _ = fs.dl.DateStamp(&today);
                break :blk &today;
            };
            setting.basic.written = filetimeOf(&fs.zone, date.*);
        }
        const status = try fs.changeAt(&fs.path, commands.FILE_WRITE_ATTRIBUTES, setting);
        if (smb.isError(status)) return changeErrorOf(status);
        fs.tellPath(fs.path.slice());
    }

    // --- notification ---------------------------------------------------------

    /// An object changed: its watchers told.
    fn tell(fs: *FileSystem, key: *Key) void {
        if (key.watched == 0) return;
        if (fs.watchers) |watchers| watchers.changed(key);
    }

    /// The object at `path` changed, if it is watched.
    fn tellPath(fs: *FileSystem, path: []const u8) void {
        if (fs.findKey(path)) |key| fs.tell(key);
    }

    /// The directory `path` is in changed.
    fn tellParent(fs: *FileSystem, path: []const u8) void {
        fs.tellPath(path[0..names.parentLength(path)]);
    }

    /// An object gone from where it was - deleted, renamed away: its
    /// watches wait for its name again, and its key is let go of.
    fn forsake(fs: *FileSystem, key: *Key) void {
        if (key.watched == 0) return;
        if (fs.watchers) |watchers| watchers.orphan(key);
        key.watched = 0;
        fs.letGo(key);
    }

    /// An object made at `path`: its directory told, and the watches
    /// waiting for its name.
    fn created(fs: *FileSystem, path: []const u8) void {
        fs.tellParent(path);
        fs.arrive(path);
    }

    /// Something came to be at `path` - made, or renamed there: the
    /// watches waiting for a name ending as it does look for theirs again,
    /// and those that find it are told.
    fn arrive(fs: *FileSystem, path: []const u8) void {
        const watchers = fs.watchers orelse return;
        var buffer: [names.name_max]u8 = undefined;
        const name = names.toDos(names.lastName(path), &buffer);
        watchers.settle(Arrival{ .fs = fs, .name = name }, Arrival.find, true);
    }

    const Arrival = struct {
        fs: *FileSystem,
        name: []const u8,

        fn find(arrival: Arrival, request: *notify.NotifyRequest) ?*anyopaque {
            if (!endsIn(notify.Watchers.pathOf(request), arrival.name)) return null;
            return arrival.fs.watchKey(request);
        }
    };

    /// The key of the object a request names, held for its watch; null
    /// when it is not there, or the request names another volume.
    fn watchKey(fs: *FileSystem, request: *notify.NotifyRequest) ?*Key {
        const named = notify.Watchers.volumeOf(request);
        if (named.len != 0 and !names.same(named, fs.volume_name) and !names.same(named, fs.device_name)) return null;
        const path = &fs.spare;
        names.resolve("", notify.Watchers.pathOf(request), path) catch return null;
        const is_dir = path.len == 0 or (fs.probe(path) catch return null).isDir();
        const key = fs.keyFor(path.slice(), is_dir) catch return null;
        key.watched += 1;
        return key;
    }

    /// ADD_NOTIFY: the request watched on the object its name names, or
    /// on its name until one does.
    fn addNotify(fs: *FileSystem, request: *notify.NotifyRequest) Error!void {
        const watchers = fs.watchers orelse return error.NoMemory;
        const key = fs.watchKey(request);
        if (watchers.add(request, key)) return;
        if (key) |held| {
            held.watched -= 1;
            fs.letGo(held);
        }
        return error.NoMemory;
    }

    /// REMOVE_NOTIFY: the request's watch dropped, and its key let go of.
    fn removeNotify(fs: *FileSystem, request: *notify.NotifyRequest) void {
        const watchers = fs.watchers orelse return;
        const held: ?*Key = @ptrCast(@alignCast(watchers.keyOf(request)));
        if (!watchers.remove(request)) return;
        if (held) |key| {
            key.watched -= 1;
            fs.letGo(key);
        }
    }

    // --- the volume -----------------------------------------------------------

    /// The share's size asked again: the root's CREATE, a QUERY_INFO for
    /// FileFsFullSizeInformation and a CLOSE, in one round trip.
    pub fn askSpace(fs: *FileSystem) Error!void {
        var request = fs.session.begin(.create);
        commands.create(&request, "", commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, commands.FILE_DIRECTORY_FILE);
        request.add(.query_info);
        commands.queryInfo(&request, &session_area.related_file, commands.INFO_FILESYSTEM, commands.FILE_FS_FULL_SIZE_INFORMATION, 32);
        request.add(.close);
        commands.close(&request, &session_area.related_file);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        if (replies[0].failed()) return errorOf(replies[0].status());
        const out = commands.output(&replies[1]) orelse return errorOf(replies[1].status());
        fs.space = commands.Space.of(out) orelse return error.NotMounted;
    }

    /// Between packets: the share's size asked again once it has been
    /// written to, no sooner than `space_seconds` after it was last asked.
    pub fn refresh(fs: *FileSystem) void {
        if (!fs.space_stale or fs.lost) return;
        if (fs.now) |now| if (now(fs)) |at| {
            if (at < fs.space_asked + space_seconds) return;
            fs.space_asked = at;
        };
        fs.space_stale = false;
        fs.askSpace() catch {};
    }

    /// INFO and DISK_INFO, from what was last asked: never the wire while
    /// Info holds the device list.
    fn info(fs: *FileSystem, data: ?*dos.InfoData) Error!void {
        const into = data orelse return error.InvalidLock;
        const free = @min(fs.space.free_units, fs.space.total_units);
        into.* = .{
            .num_soft_errors = 0,
            .unit_number = -1,
            .disk_state = if (fs.read_only) dos.ID_WRITE_PROTECTED else dos.ID_VALIDATED,
            .num_blocks = fs.space.total_units,
            .num_blocks_used = fs.space.total_units - free,
            .bytes_per_block = fs.space.unit_bytes,
            .disk_type = smb.ID_SMB_DISK,
            .volume_node = fs.volume_node,
            .in_use = if (fs.locks != null) -1 else 0,
        };
    }

    /// Every lock and file let go of on the server, for a dismount.
    pub fn releaseAll(fs: *FileSystem) void {
        fs.sendGathered() catch {};
        while (fs.locks) |lock| {
            if (lock.open and !lock.gone and !fs.lost) fs.closeHandle(&lock.file_id);
            fs.freeLock(lock);
        }
    }

    // --- packets --------------------------------------------------------------

    /// A packet answered. One that needs the server and finds the
    /// connection lost has it made again first; one that loses it on the
    /// way is served once more on a new connection - a READ and a WRITE go
    /// on by themselves, from where they were, and what may have been done
    /// already is not done twice.
    pub fn answer(fs: *FileSystem, pkt: *DosPacket) Answer {
        const action = pkt.getAction();
        if (!asksServer(action)) {
            // What was gathered goes first, as it can: a lock is let go
            // of all the same.
            if (!fs.keepsGathered(pkt)) fs.sendGathered() catch {};
            return fs.serve(pkt);
        }
        if (fs.lost and !fs.recover()) return no(error.NotMounted);
        const first = fs.served(pkt);
        if (!fs.lost or !servedAgain(action) or first.res2 != dos.ERROR_DEVICE_NOT_MOUNTED) return first;
        if (!fs.recover()) return first;
        return fs.served(pkt);
    }

    /// A packet that asks the server served after what was gathered has
    /// gone, unless it leaves that waiting.
    fn served(fs: *FileSystem, pkt: *DosPacket) Answer {
        if (!fs.keepsGathered(pkt)) fs.sendGathered() catch |err| return no(err);
        return fs.serve(pkt);
    }

    fn serve(fs: *FileSystem, pkt: *DosPacket) Answer {
        const raw = pkt.args.raw;
        switch (pkt.getAction()) {
            .locate_object => {
                const lock = fs.locate(raw[0], @ptrFromInt(@as(usize, @bitCast(raw[1]))), @truncate(raw[2])) catch |err| return no(err);
                return lockAnswer(lock);
            },
            .free_lock => {
                const lock = fs.lockArg(raw[0]) catch |err| return no(err);
                if (lock) |held| fs.freeLock(held);
                return yes();
            },
            .copy_dir => {
                const source = fs.lockArg(raw[0]) catch |err| return no(err);
                return fs.copyLock(source);
            },
            .parent => {
                const path = fs.pathArg(raw[0]) catch |err| return no(err);
                return fs.lockParent(path);
            },
            .copy_dir_fh => {
                const lock = fs.fileOf(pkt.args.file.fh) catch |err| return no(err);
                return fs.copyLock(lock);
            },
            .parent_fh => {
                const lock = fs.fileOf(pkt.args.file.fh) catch |err| return no(err);
                return fs.lockParent(lock.path());
            },
            .same_lock => {
                const one = fs.pathArg(raw[0]) catch |err| return no(err);
                const two = fs.pathArg(raw[1]) catch |err| return no(err);
                return .{ .res1 = if (names.samePath(one, two)) dos.DOSTRUE else dos.DOSFALSE, .res2 = 0 };
            },
            .examine_object, .examine_next => {
                fs.examine(pkt.args.examine, pkt.getAction() == .examine_next) catch |err| return no(err);
                return yes();
            },
            .examine_fh => {
                const lock = fs.fileOf(pkt.args.examine_fh.fh) catch |err| return no(err);
                const fib = pkt.args.examine_fh.fib orelse return no(error.InvalidLock);
                fs.examinePath(lock.path(), fib) catch |err| return no(err);
                return yes();
            },
            .findinput, .findoutput, .findupdate => {
                fs.open(pkt.args.find, pkt.getAction()) catch |err| return no(err);
                return yes();
            },
            .read => {
                const count = fs.read(pkt.args.io) catch |err| return .{ .res1 = -1, .res2 = codeOf(err) };
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .write => {
                const count = fs.write(pkt.args.io) catch |err| return .{ .res1 = -1, .res2 = codeOf(err) };
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .seek => {
                pkt.args.seek.answer = fs.seek(pkt.args.seek) catch |err| return no(err);
                return yes();
            },
            .set_file_size => {
                pkt.args.seek.answer = fs.setFileSize(pkt.args.seek) catch |err| return no(err);
                return yes();
            },
            .end => {
                fs.close(pkt.args.file) catch |err| return no(err);
                return yes();
            },
            .flush => {
                fs.flush() catch |err| return no(err);
                return yes();
            },
            .lock_record => {
                const lock = fs.fileOf(pkt.args.lock_record.fh) catch |err| return no(err);
                const records = fs.records orelse return no(error.NoMemory);
                return switch (records.lock(pkt, lock.key, lock)) {
                    .granted => yes(),
                    .refused => |code| noCode(code),
                    .waiting => .{ .res1 = 0, .res2 = 0, .held = true },
                };
            },
            .free_record => {
                const lock = fs.fileOf(pkt.args.free_record.fh) catch |err| return no(err);
                const records = fs.records orelse return noCode(dos.ERROR_RECORD_NOT_LOCKED);
                if (!records.unlock(pkt, lock.key, lock)) return noCode(dos.ERROR_RECORD_NOT_LOCKED);
                return yes();
            },
            .fh_from_lock => {
                fs.fhFromLock(pkt.args.fh_from_lock) catch |err| return no(err);
                return yes();
            },
            .change_mode => {
                fs.changeMode(pkt.args.change_mode) catch |err| return no(err);
                return yes();
            },
            .create_dir => {
                const lock = fs.createDir(raw[0], @ptrFromInt(@as(usize, @bitCast(raw[1])))) catch |err| return no(err);
                return lockAnswer(lock);
            },
            .delete_object => {
                fs.delete(raw[0], @ptrFromInt(@as(usize, @bitCast(raw[1])))) catch |err| return no(err);
                return yes();
            },
            .rename_object => {
                fs.rename(pkt.args.rename) catch |err| return no(err);
                return yes();
            },
            .set_protect, .set_date => {
                fs.setProperty(pkt.args.property, pkt.getAction()) catch |err| return no(err);
                return yes();
            },
            .add_notify => {
                const request: ?*notify.NotifyRequest = @ptrFromInt(@as(usize, @bitCast(raw[0])));
                fs.addNotify(request orelse return no(error.NotFound)) catch |err| return no(err);
                return yes();
            },
            .remove_notify => {
                const request: ?*notify.NotifyRequest = @ptrFromInt(@as(usize, @bitCast(raw[0])));
                if (request) |watched| fs.removeNotify(watched);
                return yes();
            },
            .info => {
                _ = fs.lockArg(lockValue(pkt.args.info.lock)) catch |err| return no(err);
                fs.info(pkt.args.info.info) catch |err| return no(err);
                return yes();
            },
            .disk_info => {
                fs.info(@ptrFromInt(@as(usize, @bitCast(raw[0])))) catch |err| return no(err);
                return yes();
            },
            .is_filesystem => return yes(),
            else => return noCode(dos.ERROR_ACTION_NOT_KNOWN),
        }
    }
};

/// The packets that ask the server something: everything else is
/// answered from what the handler holds, the connection there or not.
fn asksServer(action: dos.ActionCode) bool {
    return switch (action) {
        .locate_object,
        .examine_object,
        .examine_next,
        .examine_fh,
        .findinput,
        .findoutput,
        .findupdate,
        .read,
        .write,
        .seek,
        .set_file_size,
        .flush,
        .fh_from_lock,
        .create_dir,
        .delete_object,
        .rename_object,
        .set_protect,
        .set_date,
        .add_notify,
        => true,
        else => false,
    };
}

/// Whether a packet that lost the connection on the way is served again
/// on a new one: not a READ or a WRITE, which go on by themselves, and
/// not what the server may have done before the connection went.
fn servedAgain(action: dos.ActionCode) bool {
    return switch (action) {
        .read, .write, .create_dir, .delete_object, .rename_object => false,
        else => true,
    };
}

/// The furthest position a packet's i64 can say.
const max_position: u64 = 0x7FFF_FFFF_FFFF_FFFF;

/// A lock from a packet's arguments as its raw value.
fn lockValue(lock: ?*dos.FileLock) isize {
    return @bitCast(@intFromPtr(lock));
}

/// A packet's name, its bytes up to the NUL.
fn span(text: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    return text[0..len];
}

/// Whether a dos path's last name is `name`, case aside.
fn endsIn(path: []const u8, name: []const u8) bool {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return names.same(path[start..end], name);
}

/// The `*` a QUERY_DIRECTORY lists everything with.
const star: []const u8 = &.{ '*', 0 };

/// A server's name (UTF-16LE) as Latin-1, or null when it has another
/// character or is too long.
fn narrowed(name: []const u8, into: *[names.name_max]u8) ?[]const u8 {
    const count = name.len / 2;
    if (count > into.len) return null;
    for (0..count) |index| {
        const unit = names.unitAt(name, index);
        if (unit > 0xFF) return null;
        into[index] = @intCast(unit);
    }
    return into[0..count];
}

/// The protection bits for a file's attributes: a read-only file may not
/// be written or deleted, and A is the archive bit inverted.
pub fn protectionOf(attributes: u32) u32 {
    var bits: u32 = dos.FIBF_ARCHIVE;
    if (attributes & commands.ATTR_READONLY != 0) bits |= dos.FIBF_WRITE | dos.FIBF_DELETE;
    if (attributes & commands.ATTR_ARCHIVE != 0) bits &= ~dos.FIBF_ARCHIVE;
    return bits;
}

/// The attributes for protection bits, the others of `current` kept: W
/// or D makes the object read-only, A clear marks it to be archived. A
/// file left with none is ATTR_NORMAL, which stands for none.
pub fn attributesOf(bits: u32, current: u32) u32 {
    var attributes = current & ~(commands.ATTR_READONLY | commands.ATTR_ARCHIVE | commands.ATTR_NORMAL);
    if (bits & (dos.FIBF_WRITE | dos.FIBF_DELETE) != 0) attributes |= commands.ATTR_READONLY;
    if (bits & dos.FIBF_ARCHIVE == 0) attributes |= commands.ATTR_ARCHIVE;
    return if (attributes == 0) commands.ATTR_NORMAL else attributes;
}

/// A FILETIME as a DateStamp in the zone: before 1978 is its start.
pub fn dateOf(zone: *const dos.timezone.Zone, filetime: u64) dos.DateStamp {
    const unix: i64 = @as(i64, @intCast(filetime / 10_000_000)) - filetime_epoch;
    const local = unix + zone.offsetAt(unix) - dos.timezone.datestamp_epoch;
    if (local < 0) return .{};
    const ticks: i64 = @intCast(filetime % 10_000_000 / 200_000);
    return .{
        .days = @intCast(@divTrunc(local, 86400)),
        .minute = @intCast(@divTrunc(@mod(local, 86400), 60)),
        .tick = @intCast(@mod(local, 60) * 50 + ticks),
    };
}

/// A DateStamp in the zone as a FILETIME. The zone's offset is the one
/// at the moment the stamp names, found from a first guess at it.
pub fn filetimeOf(zone: *const dos.timezone.Zone, stamp: dos.DateStamp) u64 {
    const tick: i64 = stamp.tick;
    const local: i64 = @as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(tick, 50) + dos.timezone.datestamp_epoch;
    const guess = local - zone.offsetAt(local);
    const unix = local - zone.offsetAt(guess);
    const seconds: u64 = @intCast(@max(unix + filetime_epoch, 0));
    const fraction: u64 = @intCast(@mod(tick, 50));
    return seconds * 10_000_000 + fraction * 200_000;
}

const testing = @import("std").testing;

test "protection from a file's attributes" {
    try testing.expectEqual(dos.FIBF_ARCHIVE, protectionOf(0));
    try testing.expectEqual(@as(u32, 0), protectionOf(commands.ATTR_ARCHIVE));
    try testing.expectEqual(dos.FIBF_WRITE | dos.FIBF_DELETE, protectionOf(commands.ATTR_READONLY | commands.ATTR_ARCHIVE));
}

test "attributes from protection, and back" {
    // Nothing set on a file: to be archived.
    try testing.expectEqual(commands.ATTR_ARCHIVE, attributesOf(0, commands.ATTR_NORMAL));
    // Archived, nothing else: no attribute left.
    try testing.expectEqual(commands.ATTR_NORMAL, attributesOf(dos.FIBF_ARCHIVE, commands.ATTR_ARCHIVE));
    // D alone makes it read-only; hidden and system are kept.
    const kept = commands.ATTR_HIDDEN | commands.ATTR_SYSTEM;
    try testing.expectEqual(kept | commands.ATTR_READONLY, attributesOf(dos.FIBF_DELETE | dos.FIBF_ARCHIVE, kept | commands.ATTR_ARCHIVE));
    // A directory stays one, and never becomes ATTR_NORMAL.
    try testing.expectEqual(commands.ATTR_DIRECTORY, attributesOf(dos.FIBF_ARCHIVE, commands.ATTR_DIRECTORY | commands.ATTR_ARCHIVE));
    for ([_]u32{ 0, dos.FIBF_ARCHIVE, dos.FIBF_WRITE | dos.FIBF_DELETE, dos.FIBF_WRITE | dos.FIBF_DELETE | dos.FIBF_ARCHIVE }) |bits| {
        try testing.expectEqual(bits, protectionOf(attributesOf(bits, commands.ATTR_NORMAL)));
    }
}

test "a FILETIME as a DateStamp, in UTC and in a zone" {
    const utc: dos.timezone.Zone = .{};
    // 1 January 1978, 00:00:00 UTC.
    const start: u64 = @intCast((dos.timezone.datestamp_epoch + filetime_epoch) * 10_000_000);
    try testing.expect(dateOf(&utc, start).eql(.{ .days = 0, .minute = 0, .tick = 0 }));
    // A day, an hour, a minute and 1.5 seconds later.
    const later = start + (86400 + 3600 + 60) * 10_000_000 + 15_000_000;
    try testing.expect(dateOf(&utc, later).eql(.{ .days = 1, .minute = 61, .tick = 75 }));
    // One hour east of UTC.
    const east: dos.timezone.Zone = .{ .standard = 3600 };
    try testing.expect(dateOf(&east, later).eql(.{ .days = 1, .minute = 121, .tick = 75 }));
    // Before 1978: the start.
    try testing.expect(dateOf(&utc, 0).eql(.{}));
}

test "a DateStamp as a FILETIME, and back" {
    const utc: dos.timezone.Zone = .{};
    const east: dos.timezone.Zone = .{ .standard = 3600 };
    const start: u64 = @intCast((dos.timezone.datestamp_epoch + filetime_epoch) * 10_000_000);
    try testing.expectEqual(start, filetimeOf(&utc, .{}));
    try testing.expectEqual(start + 15_000_000, filetimeOf(&utc, .{ .tick = 75 }));
    // Midnight one hour east of UTC is 23:00 the day before there.
    try testing.expectEqual(start + 23 * 3600 * 10_000_000, filetimeOf(&east, .{ .days = 1 }));
    const stamps = [_]dos.DateStamp{ .{ .days = 17_000, .minute = 754, .tick = 1234 }, .{ .days = 3, .minute = 0, .tick = 49 } };
    for (stamps) |stamp| {
        try testing.expect(dateOf(&utc, filetimeOf(&utc, stamp)).eql(stamp));
        try testing.expect(dateOf(&east, filetimeOf(&east, stamp)).eql(stamp));
    }
}
