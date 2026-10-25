// SPDX-License-Identifier: MIT
//! The packets onto SMB: the locks, examining, directory scans and files
//! of a share, one packet at a time, each with the requests it takes.
//!
//! **A lock is a path.** It holds its object's path in the share and
//! whether it is a directory, and no handle on the server: a handle held
//! open would keep another client from renaming or deleting the
//! directory, and a lock without one has nothing to open again after a
//! new connection. Making a lock asks the server whether the object is
//! there - a CREATE and a CLOSE, compounded into one round trip. Two
//! locks are on the same object when their paths are the same, case
//! aside; an exclusive lock is refused while this handler has another on
//! the object, as on a disk.
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
//! each READ says where it reads, in pieces of at most 64 KiB or the
//! server's MaxReadSize. A file is opened sharing everything, so another
//! client's work on it is not refused. Its size is what the open said,
//! asked again when a seek is to its end or past it.
//!
//! **Writing comes later**: until it does, every packet that would
//! change the share answers ERROR_DISK_WRITE_PROTECTED, and the volume
//! says it is write-protected.
//!
//! **Protection**: a read-only file has W and D set; A is the server's
//! ARCHIVE bit inverted, as on a FAT volume; R and E are never set.
//! **Dates** are LastWriteTime, from UTC into the zone the system clock
//! keeps.
//!
//! **A broken connection** answers ERROR_DEVICE_NOT_MOUNTED for every
//! packet that needs the server; locks and files are still let go of.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const ExecBase = sdk.interface.exec.ExecBase;
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
};

fn yes() Answer {
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

fn no(err: Error) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = codeOf(err) };
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

/// A lock, and an open file: its path follows it in the same allocation.
pub const Lock = extern struct {
    lock: dos.FileLock,
    /// An open file's handle on the server.
    file_id: [16]u8 = @splat(0),
    open: bool = false,
    is_dir: bool = false,
    /// An open file's position, and its size as last known.
    pos: u64 align(4) = 0,
    size: u64 align(4) = 0,
    /// A directory scan under way.
    scan: ?*Scan = null,
    /// The path's length in bytes.
    path_len: u32 = 0,

    pub fn path(lock: *Lock) []u8 {
        const bytes: [*]u8 = @ptrCast(lock);
        return bytes[@sizeOf(Lock)..][0..lock.path_len];
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
    batch: [session_area.io_max]u8 = undefined,
};

/// The bytes the share's root is, and what an entry's single-entry query
/// asks for.
const entry_query: u32 = 2048;

/// Seconds from 1601, where a FILETIME counts from, to 1970.
const filetime_epoch: i64 = 11_644_473_600;

pub const FileSystem = struct {
    sys: *ExecBase,
    session: *Session,
    /// The handler's port (fl_Task of its locks).
    port: ?*MsgPort = null,
    /// The volume's node (fl_Volume of its locks), its name and its date.
    volume_node: ?*dos.DosList = null,
    volume_name: []const u8 = "",
    volume_date: dos.DateStamp = .{},
    /// The zone the system clock keeps, which dates are shown in.
    zone: dos.timezone.Zone = .{},
    locks: ?*Lock = null,
    /// The share's size, as last asked.
    space: commands.Space = .{},
    /// Scratch for paths, and a batch for looking for a stand-in's name.
    path: Path = .{},
    batch: [session_area.io_max]u8 = undefined,
    /// The length of the last batch `listFirst` or `listMore` read.
    batch_length: usize = 0,
    /// The connection is gone.
    lost: bool = false,

    // --- memory ---------------------------------------------------------------

    fn newLock(fs: *FileSystem, path: []const u8, is_dir: bool, access: i32) Error!*Lock {
        if (access == dos.EXCLUSIVE_LOCK or fs.exclusiveOn(path)) {
            if (fs.lockedAt(path)) return error.InUse;
        }
        const block = fs.sys.AllocVec(@sizeOf(Lock) + path.len, exec.MEMF_CLEAR) orelse return error.NoMemory;
        const lock: *Lock = @ptrCast(@alignCast(block));
        lock.* = .{
            .lock = .{
                .link = if (fs.locks) |head| &head.lock else null,
                .key = names.keyOf(path),
                .access = if (access == dos.EXCLUSIVE_LOCK) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
                .task = fs.port,
                .volume = fs.volume_node,
            },
            .is_dir = is_dir,
            .path_len = @intCast(path.len),
        };
        @memcpy(lock.path(), path);
        fs.locks = lock;
        return lock;
    }

    fn freeLock(fs: *FileSystem, lock: *Lock) void {
        fs.endScan(lock);
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
        fs.sys.FreeVec(lock);
    }

    /// Whether a lock of this handler is on `path`.
    fn lockedAt(fs: *FileSystem, path: []const u8) bool {
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) if (names.samePath(lock.path(), path)) return true;
        return false;
    }

    /// Whether an exclusive lock of this handler is on `path`.
    fn exclusiveOn(fs: *FileSystem, path: []const u8) bool {
        var it = fs.locks;
        while (it) |lock| : (it = lock.nextLock()) {
            if (lock.lock.access == dos.EXCLUSIVE_LOCK and names.samePath(lock.path(), path)) return true;
        }
        return false;
    }

    fn owns(fs: *FileSystem, lock: *Lock) bool {
        var it = fs.locks;
        while (it) |other| : (it = other.nextLock()) if (other == lock) return true;
        return false;
    }

    /// Whether anything on the volume is locked or open.
    pub fn inUse(fs: *const FileSystem) bool {
        return fs.locks != null;
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
        if (fs.lost) return error.NotMounted;
        fs.session.exchange(request, replies) catch {
            fs.lost = true;
            return error.NotMounted;
        };
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
    fn listFirst(fs: *FileSystem, dir: []const u8, file_id: *[16]u8, into: *[session_area.io_max]u8) Error!void {
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
    fn listMore(fs: *FileSystem, file_id: *const [16]u8, into: *[session_area.io_max]u8) Error!bool {
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
        return @min(session_area.io_max, fs.session.max_transact);
    }

    /// A handle closed, answered or not.
    fn closeHandle(fs: *FileSystem, file_id: *const [16]u8) void {
        var request = fs.session.begin(.close);
        commands.close(&request, file_id);
        var replies = session_area.noReplies();
        fs.exchange(&request, &replies) catch {};
    }

    // --- locks ----------------------------------------------------------------

    fn locate(fs: *FileSystem, dir_arg: isize, name: ?[*:0]const u8, access: i32) Error!*Lock {
        const base = try fs.pathArg(dir_arg);
        try names.resolve(base, span(name orelse return error.InvalidName), &fs.path);
        if (fs.path.len == 0) return fs.newLock("", true, access);
        const object = try fs.probe(&fs.path);
        return fs.newLock(fs.path.slice(), object.isDir(), access);
    }

    /// A shared lock on the directory `path` is in; the root has none
    /// and answers 0.
    fn lockParent(fs: *FileSystem, path: []const u8) Answer {
        if (path.len == 0) return .{ .res1 = 0, .res2 = 0 };
        const lock = fs.newLock(path[0..names.parentLength(path)], true, dos.SHARED_LOCK) catch |err| return no(err);
        return lockAnswer(lock);
    }

    /// A shared lock on what `source` is on (null: the root).
    fn copyLock(fs: *FileSystem, source: ?*Lock) Answer {
        const path: []const u8 = if (source) |held| held.path() else "";
        const is_dir = if (source) |held| held.is_dir else true;
        const lock = fs.newLock(path, is_dir, dos.SHARED_LOCK) catch |err| return no(err);
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
        if (!held.is_dir) return error.NoMoreEntries;
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

    /// FINDINPUT: an existing file opened to be read.
    fn open(fs: *FileSystem, args: dos.FindArgs) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const base = try fs.pathArg(@bitCast(@intFromPtr(args.lock)));
        try names.resolve(base, span(args.name orelse return error.InvalidName), &fs.path);
        if (fs.path.len == 0) return error.WrongType;
        const object = fs.openFile(&fs.path) catch |err| blk: {
            if (err != error.NotFound and err != error.DirNotFound) return err;
            if (!try fs.replaceStandIns(&fs.path)) return err;
            break :blk try fs.openFile(&fs.path);
        };
        const lock = fs.newLock(fs.path.slice(), false, dos.SHARED_LOCK) catch |err| {
            fs.closeHandle(&object.file_id);
            return err;
        };
        lock.open = true;
        lock.file_id = object.file_id;
        lock.size = object.size;
        fh.key = lock;
        fh.interactive = false;
    }

    /// The file at `path` opened to be read.
    fn openFile(fs: *FileSystem, path: *const Path) Error!commands.Object {
        var request = fs.session.begin(.create);
        commands.create(&request, path.slice(), commands.FILE_READ_DATA | commands.FILE_READ_ATTRIBUTES | commands.SYNCHRONIZE, 0, commands.FILE_OPEN, commands.FILE_NON_DIRECTORY_FILE);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        return commands.created(&replies[0]) orelse errorOf(replies[0].status());
    }

    fn read(fs: *FileSystem, args: dos.IOArgs) Error!usize {
        const lock = try fs.fileOf(args.fh);
        const buffer = args.buffer orelse return 0;
        const length: usize = if (args.length > 0) @intCast(args.length) else 0;
        const piece_max: usize = @min(session_area.io_max, fs.session.max_read);
        var done: usize = 0;
        while (done < length) {
            const want: u32 = @intCast(@min(length - done, piece_max));
            var request = fs.session.begin(.read);
            commands.read(&request, &lock.file_id, lock.pos, want);
            var replies = session_area.noReplies();
            try fs.exchange(&request, &replies);
            const data = commands.readData(&replies[0]) orelse return errorOf(replies[0].status());
            const count = @min(data.len, length - done);
            @memcpy(buffer[done..][0..count], data[0..count]);
            done += count;
            lock.pos += count;
            if (lock.pos > lock.size) lock.size = lock.pos;
            if (count < want) break;
        }
        return done;
    }

    /// The open file's size asked again.
    fn askSize(fs: *FileSystem, lock: *Lock) Error!void {
        var request = fs.session.begin(.query_info);
        commands.queryInfo(&request, &lock.file_id, commands.INFO_FILE, commands.FILE_STANDARD_INFORMATION, 24);
        var replies = session_area.noReplies();
        try fs.exchange(&request, &replies);
        const out = commands.output(&replies[0]) orelse return errorOf(replies[0].status());
        lock.size = commands.standardSize(out) orelse return error.NotMounted;
    }

    /// To a position; the old one. Not before the start or past the end.
    fn seek(fs: *FileSystem, args: dos.SeekArgs) Error!i64 {
        const lock = try fs.fileOf(args.fh);
        if (args.mode == dos.OFFSET_END) try fs.askSize(lock);
        const from: i128 = switch (args.mode) {
            dos.OFFSET_BEGINNING => 0,
            dos.OFFSET_CURRENT => lock.pos,
            dos.OFFSET_END => lock.size,
            else => return error.SeekError,
        };
        const to = from + args.position;
        if (to < 0) return error.SeekError;
        // Past the end as last known: the file may have grown since.
        if (to > lock.size and args.mode != dos.OFFSET_END) try fs.askSize(lock);
        if (to > lock.size) return error.SeekError;
        if (lock.pos > max_position) return error.SeekError;
        const old: i64 = @intCast(lock.pos);
        lock.pos = @intCast(to);
        return old;
    }

    /// END: the handle closed on the server, and the lock freed.
    fn close(fs: *FileSystem, args: dos.FileHandleArgs) Error!void {
        const handle = args.fh orelse return error.InvalidLock;
        const lock: *Lock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
        if (!fs.owns(lock)) return error.InvalidLock;
        if (lock.open and !fs.lost) fs.closeHandle(&lock.file_id);
        lock.open = false;
        fs.freeLock(lock);
        handle.key = null;
    }

    /// FH_FROM_LOCK: the lock's file opened, and the lock made the
    /// handle's.
    fn fhFromLock(fs: *FileSystem, args: dos.FhFromLockArgs) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const lock = try fs.lockArg(@bitCast(@intFromPtr(args.lock))) orelse return error.InvalidLock;
        if (lock.is_dir or lock.open) return error.WrongType;
        try fs.path.set(lock.path());
        const object = try fs.openFile(&fs.path);
        lock.open = true;
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
        if (exclusive) {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other != lock and names.samePath(other.path(), lock.path())) return error.InUse;
            }
        }
        lock.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
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

    /// INFO and DISK_INFO, from what was last asked: never the wire while
    /// Info holds the device list.
    fn info(fs: *FileSystem, data: ?*dos.InfoData) Error!void {
        const into = data orelse return error.InvalidLock;
        const free = @min(fs.space.free_units, fs.space.total_units);
        into.* = .{
            .num_soft_errors = 0,
            .unit_number = -1,
            .disk_state = dos.ID_WRITE_PROTECTED,
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
        while (fs.locks) |lock| {
            if (lock.open and !fs.lost) fs.closeHandle(&lock.file_id);
            fs.freeLock(lock);
        }
    }

    // --- packets --------------------------------------------------------------

    pub fn answer(fs: *FileSystem, pkt: *DosPacket) Answer {
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
                const copy = fs.newLock(lock.path(), false, dos.SHARED_LOCK) catch |err| return no(err);
                return lockAnswer(copy);
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
            .findinput => {
                fs.open(pkt.args.find) catch |err| return no(err);
                return yes();
            },
            .read => {
                const count = fs.read(pkt.args.io) catch |err| return .{ .res1 = -1, .res2 = codeOf(err) };
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .seek => {
                pkt.args.seek.answer = fs.seek(pkt.args.seek) catch |err| return no(err);
                return yes();
            },
            .end => {
                fs.close(pkt.args.file) catch |err| return no(err);
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
            .info => {
                _ = fs.lockArg(@bitCast(@intFromPtr(pkt.args.info.lock))) catch |err| return no(err);
                fs.info(pkt.args.info.info) catch |err| return no(err);
                return yes();
            },
            .disk_info => {
                fs.info(@ptrFromInt(@as(usize, @bitCast(raw[0])))) catch |err| return no(err);
                return yes();
            },
            .flush => return yes(),
            .is_filesystem => return yes(),
            .findoutput,
            .findupdate,
            .write,
            .set_file_size,
            .create_dir,
            .delete_object,
            .rename_object,
            .rename_disk,
            .set_protect,
            .set_date,
            .make_link,
            => return no(error.WriteProtected),
            else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
        }
    }
};

/// The furthest position a packet's i64 can say.
const max_position: u64 = 0x7FFF_FFFF_FFFF_FFFF;

/// A packet's name, its bytes up to the NUL.
fn span(text: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    return text[0..len];
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

const testing = @import("std").testing;

test "protection from a file's attributes" {
    try testing.expectEqual(dos.FIBF_ARCHIVE, protectionOf(0));
    try testing.expectEqual(@as(u32, 0), protectionOf(commands.ATTR_ARCHIVE));
    try testing.expectEqual(dos.FIBF_WRITE | dos.FIBF_DELETE, protectionOf(commands.ATTR_READONLY | commands.ATTR_ARCHIVE));
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
