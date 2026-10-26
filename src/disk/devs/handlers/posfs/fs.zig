// SPDX-License-Identifier: MPL-2.0
//! posfs's packets: locks, names, files and the answers dos gets, over
//! the volume core. The core calls no library, so all of this runs in
//! the host tests, on the test media, as it runs in the handler.
//!
//! The packets mean what they mean for RAM: and flashfs - the arguments,
//! the answers, the lock rules, the error codes. On top:
//!
//! - **Every change is durable in the order it was answered.** A packet
//!   that changes the volume puts its record in the journal and replies
//!   (`objects.change`); the journal goes to the medium with one barrier
//!   for the changes of a moment (`writeJournal`, which the handler calls
//!   shortly after the first change waits), and at ACTION_FLUSH. A cut
//!   loses only the newest changes, never one without those after it. A
//!   write to a file counts as a change when the file is closed or
//!   flushed, and then all of it at once.
//! - **The protection bits are kept to**: a file with r set is not read,
//!   one with w set not written, one with d set not deleted, and
//!   MODE_NEWFILE on a file with w or d set is refused. The others are
//!   dos's and the shell's.
//! - **A lock knows the name it came through** - its directory and the
//!   name's position - for Examine, ParentDir, and so that a name in use is
//!   not deleted from under it.
//! - **ExNext** goes through a directory in position order and keeps its
//!   place in fib_DiskKey (the next position), so entries that come and go
//!   meanwhile neither repeat an entry nor stop the walk. **EXAMINE_ALL**
//!   walks the same way, its place in eac_LastKey, and packs its records
//!   with the SDK's `exall.pack`.
//! - **Links.** A soft link is an object that holds a path. A name that
//!   meets one before its last part, or at its end for a lock or an open,
//!   is answered ERROR_IS_SOFT_LINK, and READ_LINK gives dos the name with
//!   the link resolved; the other packets act on the link itself. A hard
//!   link is another name for a file, with the same object behind both:
//!   the object goes when its last name does. A directory and a soft link
//!   take none.
//!
//! - **A medium that goes** (`retire`) takes the volume's memory with it,
//!   unwritten - the changes the journal had not written yet too. Its
//!   locks are parked: they answer ERROR_DEVICE_NOT_MOUNTED until the
//!   same volume is back (`revive`), and then name what they named,
//!   since an object's id is never given to another. Its handles are
//!   lost with what they had not committed, and good only for END.
//!
//! - **Recycled** (recycled.zig), while the volume has it on: a delete
//!   of an object's last name moves the name there, and only a delete
//!   there (for good) or a rename out of it (an undelete) changes what it
//!   holds - anything else in it, and Recycled itself, is
//!   ERROR_WRITE_PROTECTED. The oldest that nothing uses go first: past
//!   the volume table's limits, and on a full volume once checkpoints have
//!   made no room. A file with much data goes as a job (an orphan) whose
//!   blocks come free between packets.
//!
//! - **Snapshots** (snapshots.zig) are read under `.snapshots/<name>/`
//!   in the root, a directory no listing of the root shows and no name
//!   there may take: a lock and an object say which snapshot they are
//!   seen in (`view`, 0 for the live volume), and every read follows that
//!   snapshot's tree. Nothing in a snapshot, nor `.snapshots` itself, is
//!   changed: those packets answer ERROR_DISK_WRITE_PROTECTED.
//!
//! - **posfs's own packets** (`posfs.packets`): INFO, SETTINGS, the
//!   snapshot actions (MAKE_SNAPSHOT, DELETE_SNAPSHOT, ROLLBACK), the
//!   Recycled actions (UNDELETE, EMPTY_RECYCLED, ORIGIN) and CHECK, a
//!   check in slices of about 50 ms over the newest checkpoint, which the
//!   check pins while the volume goes on changing.
//!
//! The process (posfs.zig) gives what needs the system: the watchers, the
//! record locks and ExAll's matcher. Without them ADD_NOTIFY and
//! LOCK_RECORD are refused, and EXAMINE_ALL is left to dos.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const posfs = dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;
const notify = dos.notify;
const record = dos.record;
const media = @import("media.zig");
const volume = @import("volume.zig");
const checkpoint = @import("checkpoint.zig");
const journal = @import("journal.zig");
const space = @import("space.zig");
const objects = @import("objects.zig");
const dirs = @import("dirs.zig");
const files = @import("files.zig");
const recycled = @import("recycled.zig");
const snapshots = @import("snapshots.zig");
const btree = @import("btree.zig");
const check = @import("check.zig");
const packets = posfs.packets;
const Volume = volume.Volume;
const Error = volume.Error;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const DosPacket = dos.DosPacket;
const MsgPort = exec.MsgPort;
const Inode = layout.Inode;

/// The medium as the file system takes it, and what a format is asked
/// for: for the process and for tools/mkfs, which import this file.
pub const Device = media.Device;
pub const FormatOptions = checkpoint.Options;
/// The check, for tools/posfsck.
pub const Report = check.Report;
pub const Totals = check.Totals;

/// The dos error a posfs error answers with.
pub fn codeOf(err: Error) i32 {
    return switch (err) {
        error.NoMemory => dos.ERROR_NO_FREE_STORE,
        error.Io, error.Corrupt, error.NotPosfs => dos.ERROR_NOT_A_DOS_DISK,
        error.BadChecksum => dos.ERROR_BAD_CHECKSUM,
        error.DiskFull => dos.ERROR_DISK_FULL,
        error.ReadOnly => dos.ERROR_DISK_WRITE_PROTECTED,
        error.NotFound => dos.ERROR_OBJECT_NOT_FOUND,
        error.Exists => dos.ERROR_OBJECT_EXISTS,
        error.InUse => dos.ERROR_OBJECT_IN_USE,
        error.NotEmpty => dos.ERROR_DIRECTORY_NOT_EMPTY,
        error.WrongType => dos.ERROR_OBJECT_WRONG_TYPE,
        error.BadName => dos.ERROR_INVALID_COMPONENT_NAME,
        error.DeleteProtected => dos.ERROR_DELETE_PROTECTED,
        error.WriteProtected => dos.ERROR_WRITE_PROTECTED,
        error.ReadProtected => dos.ERROR_READ_PROTECTED,
        error.CommentTooBig => dos.ERROR_COMMENT_TOO_BIG,
        error.InvalidArgument => dos.ERROR_INVALID_ARGUMENT,
        error.LineTooLong => dos.ERROR_LINE_TOO_LONG,
        error.IsSoftLink => dos.ERROR_IS_SOFT_LINK,
        error.TooManyLevels => dos.ERROR_TOO_MANY_LEVELS,
        error.BufferOverflow => dos.ERROR_BUFFER_OVERFLOW,
        error.NotImplemented => dos.ERROR_NOT_IMPLEMENTED,
        error.InvalidLock => dos.ERROR_INVALID_LOCK,
        error.NotMounted => dos.ERROR_DEVICE_NOT_MOUNTED,
        error.SeekError => dos.ERROR_SEEK_ERROR,
        error.NoMoreEntries => dos.ERROR_NO_MORE_ENTRIES,
        error.DirNotFound => dos.ERROR_DIR_NOT_FOUND,
    };
}

/// dp_Res1 and dp_Res2 for a packet; `held` for one answered later (a
/// record lock that waits), which must not be replied now.
pub const Answer = struct { res1: isize, res2: i32, held: bool = false };

fn yes() Answer {
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

fn no(err: Error) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = codeOf(err) };
}

fn noCode(code: i32) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = code };
}

/// READ and WRITE answer -1 on failure.
fn minusOne(err: Error) Answer {
    return .{ .res1 = -1, .res2 = codeOf(err) };
}

fn ptrArg(value: isize) usize {
    return @bitCast(value);
}

fn lockValue(lock: ?*FileLock) isize {
    return @bitCast(@intFromPtr(lock));
}

/// The bytes of a C string from a packet.
fn span(text: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    return text[0..len];
}

/// An object as a lock or a walk has it: what it is, and the name it
/// came through (none for the root).
const Object = struct {
    oid: u64,
    parent: u64 = 0,
    pos: u64 = 0,
    entry_type: i32,
    /// The snapshot it is seen in, by id: 0 for the live volume.
    view: u32 = 0,

    fn isDir(object: Object) bool {
        return objects.isDir(object.entry_type);
    }

    /// Whether it may be changed: not in a snapshot, and not
    /// `.snapshots` itself.
    fn writable(object: Object) Error!void {
        if (object.view != 0 or object.oid == snapshots.dir_oid) return error.ReadOnly;
    }

    /// Whether it is Recycled or in it: what only a delete and a rename
    /// out change.
    fn inRecycled(object: Object) bool {
        return object.oid == posfs.recycled_oid or object.parent == posfs.recycled_oid;
    }
};

const root_object: Object = .{ .oid = posfs.root_oid, .entry_type = dos.ST_ROOT };

/// `.snapshots`, in the live root at a position no name has.
const snapshots_object: Object = .{ .oid = snapshots.dir_oid, .parent = posfs.root_oid, .pos = 1 << 40, .entry_type = dos.ST_USERDIR };

/// A snapshot's root: `.snapshots/<name>`, the root of the snapshot `id`.
fn snapshotRoot(id: u32) Object {
    return .{ .oid = posfs.root_oid, .parent = snapshots.dir_oid, .pos = id, .entry_type = dos.ST_USERDIR, .view = id };
}

/// A lock: the FileLock first, then the object and, for an open file, its
/// place and what all its handles share.
const Lock = extern struct {
    lock: FileLock,
    oid: u64 align(4),
    parent: u64 align(4),
    pos: u64 align(4),
    file_pos: u64 align(4) = 0,
    open: ?*Open = null,
    entry_type: i32,
    /// The snapshot the object is seen in (0: the live volume).
    view: u32 = 0,
    /// A handle's: opened as a new file, or written through.
    modified: bool = false,
    /// A handle whose medium went: good for nothing but END.
    lost: bool = false,

    fn object(lock: *const Lock) Object {
        return .{ .oid = lock.oid, .parent = lock.parent, .pos = lock.pos, .entry_type = lock.entry_type, .view = lock.view };
    }

    fn nextLock(lock: *const Lock) ?*Lock {
        const link = lock.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", link));
    }
};

/// A file open through one handle or more: their overlay, once one of
/// them writes.
const Open = struct {
    oid: u64,
    /// The snapshot the file is read from (0: the live volume).
    view: u32 = 0,
    handles: u32 = 0,
    writing: bool = false,
    overlay: files.Overlay = undefined,
    next: ?*Open = null,
};

/// Where a path ends: the directory, and the last part as dos gave it
/// (empty: the directory itself).
const Place = struct { dir: Object, name: []const u8 };

/// Where a new name goes: its directory, the name as posfs keeps it, and
/// the position it takes.
const Spot = struct { dir: Object, name: []const u8, pos: u64 };

/// An entry of a directory, and the position a walk goes on from.
const Next = struct { object: Object, next: u64 };

/// The key an object is watched and record-locked by.
fn keyOf(oid: u64) *anyopaque {
    return @ptrFromInt(@as(usize, @truncate(oid)));
}

/// ExAll's two tests of an entry, which take utility.library: whether its
/// name matches the caller's pattern (from ParsePatternNoCase), and
/// whether the caller's hook takes its record.
pub const Matcher = struct {
    context: *anyopaque,
    matches: *const fn (context: *anyopaque, pattern: [*:0]const u8, name: [*:0]const u8) bool,
    takes: *const fn (context: *anyopaque, hook: *sdk.utility.Hook, level: i32, record: *dos.ExAllData) bool,
};

pub const FileSystem = struct {
    vol: Volume,
    /// The handler's port (fl_Task of its locks).
    port: ?*MsgPort = null,
    /// The volume's DosList node (fl_Volume of its locks).
    volume_node: ?*dos.DosList = null,
    locks: ?*Lock = null,
    opens: ?*Open = null,
    /// The locks of volumes no longer in the drive (`retire`), each with
    /// its volume node in fl_Volume.
    parked: ?*Lock = null,
    /// The device's name, which a watch may be named on beside the
    /// volume's.
    device_name: []const u8 = "",
    /// Notification, record locks and ExAll's tests, when the handler
    /// gives them.
    watchers: ?*notify.Watchers = null,
    records: ?*record.Records = null,
    matcher: ?*const Matcher = null,
    /// The check under way (ACTION_POSFS_CHECK), the cursor its slices
    /// carry, when the last one came, and how long one works.
    checking: ?*check.Check = null,
    check_serial: u32 = 0,
    check_touched: u64 = 0,
    check_slice: u64 = 50_000,
    /// An orphan waits for its job, and how many blocks of data make a
    /// file go as one - and a step of the job.
    orphans: bool = false,
    job_blocks: u64 = recycled.job_blocks,

    pub fn init(dev: media.Device) FileSystem {
        return .{ .vol = .{ .dev = dev, .make_room = makeRoomFor } };
    }

    /// Every lock and open file let go, and the volume's memory freed;
    /// what was not committed is lost.
    pub fn deinit(fs: *FileSystem) void {
        fs.dropAll();
        var lock = fs.parked;
        while (lock) |it| {
            const following = it.nextLock();
            fs.freeMemory(it);
            lock = following;
        }
        fs.parked = null;
        fs.vol.release();
    }

    fn dropAll(fs: *FileSystem) void {
        fs.endCheck();
        var lock = fs.locks;
        while (lock) |it| {
            const following = it.nextLock();
            if (fs.records) |records| records.release(it);
            fs.freeMemory(it);
            lock = following;
        }
        fs.locks = null;
        var open = fs.opens;
        while (open) |it| {
            const following = it.next;
            if (it.writing) files.discard(&fs.vol, &it.overlay);
            fs.freeMemory(it);
            open = following;
        }
        fs.opens = null;
    }

    fn create(fs: *FileSystem, comptime T: type) Error!*T {
        const bytes = try fs.vol.alloc(@sizeOf(T));
        return @ptrCast(@alignCast(bytes.ptr));
    }

    fn freeMemory(fs: *FileSystem, item: anytype) void {
        const bytes: [*]u8 = @ptrCast(item);
        fs.vol.free(bytes[0..@sizeOf(@TypeOf(item.*))]);
    }

    // --- the volume -------------------------------------------------------------

    pub fn mount(fs: *FileSystem) Error!void {
        fs.dropAll();
        fs.orphans = false;
        try checkpoint.mount(&fs.vol);
        fs.orphans = try recycled.hasOrphans(&fs.vol);
        fs.settleWatches();
    }

    /// The medium has gone, or another is in: what the volume held in
    /// memory dropped unwritten - it belongs to a medium no longer there.
    /// Every lock is parked with its volume node, every handle lost with
    /// what it had not committed, and every watch waits for its name on
    /// the next volume.
    pub fn retire(fs: *FileSystem) void {
        fs.endCheck();
        var open = fs.opens;
        while (open) |it| {
            const following = it.next;
            if (it.writing) files.forget(&fs.vol, &it.overlay);
            fs.freeMemory(it);
            open = following;
        }
        fs.opens = null;
        var lock = fs.locks;
        while (lock) |it| {
            const following = it.nextLock();
            if (it.open != null) {
                if (fs.records) |records| records.release(it);
                it.open = null;
                it.lost = true;
            }
            it.lock.link = if (fs.parked) |head| &head.lock else null;
            fs.parked = it;
            lock = following;
        }
        fs.locks = null;
        if (fs.watchers) |watchers| watchers.orphanAll();
        fs.orphans = false;
        fs.vol.release();
    }

    /// The volume of `node` is back in the drive: its parked locks work
    /// again. Lost handles stay parked until their END.
    pub fn revive(fs: *FileSystem, node: *dos.DosList) void {
        var kept: ?*Lock = null;
        var lock = fs.parked;
        while (lock) |it| {
            const following = it.nextLock();
            if (it.lock.volume == node and !it.lost) {
                it.lock.link = if (fs.locks) |head| &head.lock else null;
                fs.locks = it;
            } else {
                it.lock.link = if (kept) |head| &head.lock else null;
                kept = it;
            }
            lock = following;
        }
        fs.parked = kept;
    }

    /// How many parked locks point at `node`: while any do, the node stays
    /// on the device list.
    pub fn locksOn(fs: *const FileSystem, node: *dos.DosList) u32 {
        var count: u32 = 0;
        var it = fs.parked;
        while (it) |x| : (it = x.nextLock()) {
            if (x.lock.volume == node) count += 1;
        }
        return count;
    }

    /// A parked lock from a packet taken off and freed: true if `value`
    /// was one.
    fn unpark(fs: *FileSystem, value: usize) bool {
        if (value == 0) return false;
        var previous: ?*Lock = null;
        var it = fs.parked;
        while (it) |x| : (it = x.nextLock()) {
            if (@intFromPtr(x) == value) {
                const following = x.nextLock();
                if (previous) |before| {
                    before.lock.link = if (following) |next| &next.lock else null;
                } else fs.parked = following;
                fs.freeMemory(x);
                return true;
            }
            previous = x;
        }
        return false;
    }

    fn isParked(fs: *const FileSystem, lock: *Lock) bool {
        var it = fs.parked;
        while (it) |x| : (it = x.nextLock()) {
            if (x == lock) return true;
        }
        return false;
    }

    /// A fresh volume over the medium, its name as dos gives it (Latin-1,
    /// or UTF-8 already). A mounted volume stays as it is when the
    /// options are refused.
    pub fn format(fs: *FileSystem, options: checkpoint.Options) Error!void {
        var buffer: [posfs.max_name]u8 = undefined;
        const utf8 = fold.fromDos(options.name, &buffer) orelse return error.BadName;
        if (utf8.len == 0 or utf8.len > posfs.max_volume_name or !fold.acceptable(utf8)) return error.BadName;
        var given = options;
        given.name = utf8;
        fs.dropAll();
        // The new volume's objects take the old ones' ids again: every
        // watch waits for its name anew.
        if (fs.watchers) |watchers| watchers.orphanAll();
        fs.orphans = false;
        try checkpoint.format(&fs.vol, given);
        fs.settleWatches();
    }

    /// The volume put away: what files hold committed, a clean checkpoint.
    pub fn unmount(fs: *FileSystem) Error!void {
        try fs.flush();
        fs.dropAll();
        try checkpoint.unmount(&fs.vol);
    }

    /// The volume as it is in memory checked whole, its data too with
    /// `data`: what tools/posfsck runs.
    pub fn checkWhole(fs: *FileSystem, data: bool, report: *Report) Error!Totals {
        return check.checkWhole(&fs.vol, data, report);
    }

    pub fn volumeName(fs: *const FileSystem) []const u8 {
        return fs.vol.voltab.volumeName();
    }

    /// Whether a file is open with changes not committed, or to be
    /// written: what INHIBIT is refused for.
    pub fn writing(fs: *const FileSystem) bool {
        var open = fs.opens;
        while (open) |it| : (open = it.next) {
            if (it.writing) return true;
        }
        return false;
    }

    /// Everything written made durable: every file's changes committed,
    /// and the journal written.
    pub fn flush(fs: *FileSystem) Error!void {
        var open = fs.opens;
        while (open) |it| : (open = it.next) {
            if (it.writing) try files.commit(&fs.vol, &it.overlay);
        }
        try fs.writeJournal();
    }

    /// Whether answered changes wait in the journal's memory: what the
    /// handler's journal timer is started for.
    pub fn journalWaits(fs: *const FileSystem) bool {
        const vol = &fs.vol;
        return !vol.read_only and !vol.failed and journal.hasPending(vol);
    }

    /// The changes answered since the journal was last written, written
    /// and made durable together.
    pub fn writeJournal(fs: *FileSystem) Error!void {
        if (!fs.journalWaits()) return;
        try journal.flush(&fs.vol);
    }

    /// Whether changes wait for a checkpoint, an orphan for its job, or a
    /// check for its next slice: what an idle handler is woken for.
    pub fn pending(fs: *const FileSystem) bool {
        return fs.checking != null or fs.jobsWait() or fs.changesWait();
    }

    fn jobsWait(fs: *const FileSystem) bool {
        return fs.orphans and !fs.vol.read_only and !fs.vol.failed;
    }

    fn changesWait(fs: *const FileSystem) bool {
        const vol = &fs.vol;
        if (vol.read_only or vol.failed) return false;
        if (vol.voltab_dirty) return true;
        if (!vol.session_started) return false;
        return vol.dirty_count != 0 or vol.journal.records != 0;
    }

    /// What an idle handler does: a check no slice came for in a while
    /// ended, a slice's time of the orphans' jobs, and a checkpoint when
    /// changes wait.
    pub fn idle(fs: *FileSystem) Error!void {
        if (fs.checking != null and fs.vol.now() -% fs.check_touched > check_timeout) fs.endCheck();
        if (fs.jobsWait()) try fs.trimOrphans(fs.vol.now() + fs.check_slice);
        if (!fs.changesWait()) return;
        try checkpoint.write(&fs.vol, 0);
    }

    /// Whether a lock or a handle is on the volume: what a format is
    /// refused for.
    pub fn inUse(fs: *const FileSystem) bool {
        return fs.locks != null or fs.opens != null;
    }

    /// ACTION_RENAME_DISK: the volume table's name, committed by two
    /// checkpoints.
    pub fn relabel(fs: *FileSystem, name: []const u8) Error!void {
        const vol = &fs.vol;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        var buffer: [posfs.max_name]u8 = undefined;
        const utf8 = fold.fromDos(name, &buffer) orelse return error.BadName;
        if (utf8.len == 0 or utf8.len > posfs.max_volume_name or !fold.acceptable(utf8)) return error.BadName;
        const table = vol.voltab;
        @memset(&table.name, 0);
        @memcpy(table.name[0..utf8.len], utf8);
        table.name_len = @intCast(utf8.len);
        vol.voltab_dirty = true;
        try checkpoint.write(vol, 0);
        try checkpoint.write(vol, 0);
    }

    // --- locks ------------------------------------------------------------------

    fn owns(fs: *const FileSystem, lock: *Lock) bool {
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x == lock) return true;
        }
        return false;
    }

    /// A lock from a packet: one of ours, or null for the root. One of a
    /// volume not in the drive is NotMounted.
    fn lockArg(fs: *FileSystem, value: isize) Error!?*Lock {
        if (value == 0) return null;
        const lock: *Lock = @ptrFromInt(ptrArg(value));
        if (!fs.owns(lock)) return if (fs.isParked(lock)) error.NotMounted else error.InvalidLock;
        return lock;
    }

    /// What a lock from a packet stands for (null: the root).
    fn objectOf(fs: *FileSystem, value: isize) Error!Object {
        const lock = try fs.lockArg(value) orelse return root_object;
        return lock.object();
    }

    /// A new lock on an object: shared locks go together, an exclusive one
    /// wants the object to itself.
    fn getLock(fs: *FileSystem, object: Object, access: i32) Error!*Lock {
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.oid == object.oid and x.view == object.view and (access == dos.EXCLUSIVE_LOCK or x.lock.access == dos.EXCLUSIVE_LOCK)) return error.InUse;
        }
        const lock = try fs.create(Lock);
        lock.* = .{
            .lock = .{
                .link = if (fs.locks) |head| &head.lock else null,
                .key = @truncate(object.oid),
                .access = if (access == dos.EXCLUSIVE_LOCK) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
                .task = fs.port,
                .volume = fs.volume_node,
            },
            .oid = object.oid,
            .parent = object.parent,
            .pos = object.pos,
            .entry_type = object.entry_type,
            .view = object.view,
        };
        fs.locks = lock;
        return lock;
    }

    fn freeLock(fs: *FileSystem, lock: *Lock) void {
        if (fs.locks == lock) {
            fs.locks = lock.nextLock();
        } else {
            var it = fs.locks;
            while (it) |x| : (it = x.nextLock()) {
                if (x.lock.link == &lock.lock) {
                    x.lock.link = lock.lock.link;
                    break;
                }
            }
        }
        fs.freeMemory(lock);
    }

    /// Whether a lock but `except` is on the live object (with
    /// `exclusive_only`, an exclusive one).
    fn otherLock(fs: *const FileSystem, oid: u64, except: ?*Lock, exclusive_only: bool) bool {
        return fs.otherLockIn(0, oid, except, exclusive_only);
    }

    /// Whether a lock but `except` is on the object as `view` has it.
    fn otherLockIn(fs: *const FileSystem, view: u32, oid: u64, except: ?*Lock, exclusive_only: bool) bool {
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x == except or x.oid != oid or x.view != view) continue;
            if (!exclusive_only or x.lock.access == dos.EXCLUSIVE_LOCK) return true;
        }
        return false;
    }

    /// Whether a lock came through the live name at (`parent`, `pos`).
    fn nameInUse(fs: *const FileSystem, parent: u64, pos: u64) bool {
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.parent == parent and x.pos == pos and x.oid != posfs.root_oid and x.view == 0) return true;
        }
        return false;
    }

    /// Whether a lock is on something in the snapshot `id`.
    fn viewInUse(fs: *const FileSystem, id: u32) bool {
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.view == id) return true;
        }
        return false;
    }

    // --- names ------------------------------------------------------------------

    /// The tree `view` reads: the live one, or a snapshot's, kept in
    /// `held`.
    fn viewTree(fs: *FileSystem, view: u32, held: *btree.Tree) Error!*const btree.Tree {
        if (view == 0) return &fs.vol.obj;
        const snapshot = snapshots.byId(&fs.vol, view) orelse return error.NotFound;
        held.* = snapshots.treeOf(snapshot);
        return held;
    }

    /// The inode of `oid` as `view` has it, which must be there.
    fn inodeIn(fs: *FileSystem, view: u32, oid: u64) Error!Inode {
        var held: btree.Tree = undefined;
        return try objects.inodeIn(&fs.vol, try fs.viewTree(view, &held), oid) orelse error.NotFound;
    }

    /// The object a name in a directory stands for: in `.snapshots` a
    /// snapshot's root, and `.snapshots` in the live root.
    fn child(fs: *FileSystem, dir: Object, name: []const u8) Error!?Object {
        if (!dir.isDir()) return error.WrongType;
        if (name.len > posfs.max_name) return error.BadName;
        if (dir.oid == snapshots.dir_oid) {
            const index = snapshots.findDos(&fs.vol, name) orelse return null;
            return snapshotRoot(snapshots.all(&fs.vol)[index].id);
        }
        if (dir.oid == posfs.root_oid and dir.view == 0 and fold.sameLatin1(name, posfs.snapshots_name)) return snapshots_object;
        var held: btree.Tree = undefined;
        const tree = try fs.viewTree(dir.view, &held);
        const entry = try dirs.lookupDosIn(&fs.vol, tree, dir.oid, name) orelse return null;
        return .{ .oid = entry.oid, .parent = dir.oid, .pos = entry.pos, .entry_type = entry.entry_type, .view = dir.view };
    }

    /// The directory an object is in, as an object of its own: a
    /// snapshot's root is in `.snapshots`, and that in the live root.
    fn parentOf(fs: *FileSystem, object: Object) Error!?Object {
        if (object.oid == posfs.root_oid) return if (object.view != 0) snapshots_object else null;
        if (object.oid == snapshots.dir_oid) return root_object;
        const dir = object.parent;
        if (dir == posfs.root_oid) return if (object.view != 0) snapshotRoot(object.view) else root_object;
        const node = try fs.inodeIn(object.view, dir);
        return .{ .oid = dir, .parent = node.parent, .pos = node.pos, .entry_type = node.entry_type, .view = object.view };
    }

    /// Drop the device, walk the directories from `start` (an empty part
    /// goes up), and leave the last part.
    fn findDir(fs: *FileSystem, start: Object, path: []const u8) Error!Place {
        var rest = path;
        for (path, 0..) |char, index| {
            if (char == ':') rest = path[index + 1 ..];
        }
        var dir = start;
        while (true) {
            var cut: usize = 0;
            while (cut < rest.len and rest[cut] != '/') cut += 1;
            if (cut == rest.len) return .{ .dir = dir, .name = rest };
            const part = rest[0..cut];
            rest = rest[cut + 1 ..];
            if (part.len == 0) {
                dir = try fs.parentOf(dir) orelse return error.NotFound;
                continue;
            }
            const next = try fs.child(dir, part) orelse return error.NotFound;
            if (next.entry_type == dos.ST_SOFTLINK) return error.IsSoftLink;
            if (!next.isDir()) return error.WrongType;
            dir = next;
        }
    }

    /// The object a path names, from the directory a lock stands for.
    fn locate(fs: *FileSystem, dir_arg: isize, path: []const u8) Error!Object {
        const place = try fs.findDir(try fs.objectOf(dir_arg), path);
        if (place.name.len == 0) return place.dir;
        return try fs.child(place.dir, place.name) orelse error.NotFound;
    }

    /// The path of an object from the root, `/` between the names, for
    /// the watchers.
    fn pathOf(fs: *FileSystem, object: Object, into: []u8) Error![]const u8 {
        var end = into.len;
        var at = object;
        var shown: [posfs.max_name]u8 = undefined;
        var steps: u32 = 0;
        while (at.oid != posfs.root_oid) : (steps += 1) {
            if (steps > 256) return error.Corrupt;
            const entry = try dirs.at(&fs.vol, at.parent, at.pos) orelse return error.NotFound;
            const name = fold.toDos(entry.name, &shown);
            const need = name.len + @intFromBool(end != into.len);
            if (need > end) return error.BufferOverflow;
            if (end != into.len) {
                end -= 1;
                into[end] = '/';
            }
            end -= name.len;
            @memcpy(into[end..][0..name.len], name);
            at = try fs.parentOf(at) orelse break;
        }
        return into[end..];
    }

    // --- notification -------------------------------------------------------------

    fn changed(fs: *FileSystem, oid: u64) void {
        if (fs.watchers) |watchers| watchers.changed(keyOf(oid));
    }

    fn orphaned(fs: *FileSystem, oid: u64) void {
        if (fs.watchers) |watchers| watchers.orphan(keyOf(oid));
    }

    /// An object come to be where it is: the watchers of its name take it.
    fn appeared(fs: *FileSystem, object: Object, tell: bool) void {
        const watchers = fs.watchers orelse return;
        var buffer: [dos.path_max]u8 = undefined;
        const path = fs.pathOf(object, &buffer) catch return;
        watchers.adopt(keyOf(object.oid), path, tell);
    }

    fn addNotify(fs: *FileSystem, request: *notify.NotifyRequest) Error!void {
        const watchers = fs.watchers orelse return error.NoMemory;
        if (!watchers.add(request, fs.watchedKey(request))) return error.NoMemory;
    }

    /// Whether a request is about this volume: named on the device, on
    /// the volume's name, or on neither.
    fn watchedHere(fs: *FileSystem, request: *const notify.NotifyRequest) bool {
        const named = notify.Watchers.volumeOf(request);
        if (named.len == 0) return true;
        var buffer: [posfs.max_name]u8 = undefined;
        const utf8 = fold.fromDos(named, &buffer) orelse return false;
        if (fold.same(utf8, fs.volumeName())) return true;
        var device: [posfs.max_name]u8 = undefined;
        const device_utf8 = fold.fromDos(fs.device_name, &device) orelse return false;
        return fold.same(utf8, device_utf8);
    }

    /// The key of the object a request names on this volume, if it is
    /// there.
    fn watchedKey(fs: *FileSystem, request: *notify.NotifyRequest) ?*anyopaque {
        if (!fs.vol.mounted or !fs.watchedHere(request)) return null;
        const object = fs.locate(0, notify.Watchers.pathOf(request)) catch return null;
        // A snapshot never changes.
        if (object.view != 0) return null;
        return keyOf(object.oid);
    }

    /// A volume mounted or made: every watch waiting for its name looks
    /// for it here, and those that find it are told.
    fn settleWatches(fs: *FileSystem) void {
        const watchers = fs.watchers orelse return;
        watchers.settle(fs, watchedKey, true);
    }

    // --- making and deleting ---------------------------------------------------------

    /// Where a new name at `path` goes, the name kept in `buffer`: in a
    /// directory, free, not one the root keeps, and on a volume that can
    /// be written and has room.
    fn newName(fs: *FileSystem, dir_arg: isize, path: []const u8, buffer: *[posfs.max_name]u8) Error!Spot {
        const vol = &fs.vol;
        const place = try fs.findDir(try fs.objectOf(dir_arg), path);
        if (!place.dir.isDir()) return error.WrongType;
        try place.dir.writable();
        const name = try dirs.fromDos(place.name, buffer);
        if (place.dir.oid == posfs.root_oid and dirs.reservedInRoot(name)) return error.BadName;
        if (try dirs.lookupDos(vol, place.dir.oid, place.name) != null) return error.Exists;
        if (try dirs.lookup(vol, place.dir.oid, name) != null) return error.Exists;
        if (place.dir.inRecycled()) return error.WriteProtected;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        try files.room(vol);
        const pos = try dirs.freePosition(vol, place.dir.oid, name, null);
        return .{ .dir = place.dir, .name = name, .pos = pos };
    }

    /// A new file, directory or soft link at `path`, its record durable.
    fn make(fs: *FileSystem, dir_arg: isize, path: []const u8, entry_type: i32, target: []const u8) Error!Object {
        const vol = &fs.vol;
        var buffer: [posfs.max_name]u8 = undefined;
        const spot = try fs.newName(dir_arg, path, &buffer);
        const oid = vol.next_oid;
        const head: layout.CreateRecord = .{
            .oid = oid,
            .parent = spot.dir.oid,
            .pos = spot.pos,
            .time = vol.now(),
            .entry_type = entry_type,
            .fold = layout.fold_1,
            .name_len = @intCast(spot.name.len),
            .link_len = @intCast(target.len),
        };
        var payload: [@sizeOf(layout.CreateRecord) + posfs.max_name + posfs.max_link]u8 = undefined;
        var len: usize = @sizeOf(layout.CreateRecord);
        @memcpy(payload[0..len], layout.bytesOf(&head));
        @memcpy(payload[len..][0..spot.name.len], spot.name);
        len += spot.name.len;
        @memcpy(payload[len..][0..target.len], target);
        len += target.len;
        try objects.change(vol, .create, payload[0..len]);
        return .{ .oid = oid, .parent = spot.dir.oid, .pos = spot.pos, .entry_type = entry_type };
    }

    /// MAKE_LINK: at `name`, a soft link holding the path `dest` points
    /// at, or another name for the file `dest` locks.
    fn makeLink(fs: *FileSystem, args: dos.MakeLinkArgs) Error!void {
        const vol = &fs.vol;
        const dir_arg = lockValue(args.lock);
        const path = span(args.name orelse return error.BadName);
        switch (args.kind) {
            dos.LINK_SOFT => {
                const given: ?[*:0]const u8 = @ptrFromInt(args.dest);
                const latin = span(given orelse return error.BadName);
                if (latin.len == 0) return error.BadName;
                var stored: [posfs.max_link]u8 = undefined;
                const target = fold.fromDos(latin, &stored) orelse return error.LineTooLong;
                const object = try fs.make(dir_arg, path, dos.ST_SOFTLINK, target);
                fs.appeared(object, true);
                fs.changed(object.parent);
            },
            dos.LINK_HARD => {
                const lock = try fs.lockArg(@bitCast(args.dest)) orelse return error.InvalidLock;
                try lock.object().writable();
                if (lock.entry_type != dos.ST_FILE) return error.WrongType;
                if (lock.object().inRecycled()) return error.WriteProtected;
                const node = try objects.needInode(vol, lock.oid);
                if (node.nlink == 0xFFFF_FFFF) return error.InvalidArgument;
                var buffer: [posfs.max_name]u8 = undefined;
                const spot = try fs.newName(dir_arg, path, &buffer);
                const head: layout.LinkRecord = .{
                    .oid = lock.oid,
                    .parent = spot.dir.oid,
                    .pos = spot.pos,
                    .time = vol.now(),
                    .name_len = @intCast(spot.name.len),
                };
                var payload: [@sizeOf(layout.LinkRecord) + posfs.max_name]u8 = undefined;
                @memcpy(payload[0..@sizeOf(layout.LinkRecord)], layout.bytesOf(&head));
                @memcpy(payload[@sizeOf(layout.LinkRecord)..][0..spot.name.len], spot.name);
                try objects.change(vol, .link, payload[0 .. @sizeOf(layout.LinkRecord) + spot.name.len]);
                fs.appeared(.{ .oid = lock.oid, .parent = spot.dir.oid, .pos = spot.pos, .entry_type = dos.ST_FILE }, true);
                fs.changed(spot.dir.oid);
            },
            else => return error.InvalidArgument,
        }
    }

    /// READ_LINK: the name `path` from `lock` with its first soft link
    /// resolved - the link's target, what of `path` came after the link
    /// behind it, and before it, for a target with no device part of its
    /// own, the directories `path` went through to the link, so that the
    /// answer is again a name from `lock`. Its length; BufferOverflow when
    /// it and its NUL do not fit, WrongType when `path` meets no soft link.
    fn readLink(fs: *FileSystem, args: dos.ReadLinkArgs) Error!usize {
        const path = span(args.path orelse return error.BadName);
        const buffer = args.buffer orelse return error.InvalidArgument;
        const room: usize = if (args.size > 0) @intCast(args.size) else 0;
        var start: usize = 0;
        for (path, 0..) |char, index| {
            if (char == ':') start = index + 1;
        }
        var dir = try fs.objectOf(lockValue(args.lock));
        var at = start;
        while (true) {
            var cut = at;
            while (cut < path.len and path[cut] != '/') cut += 1;
            const part = path[at..cut];
            const last = cut == path.len;
            if (part.len == 0) {
                if (last) return error.WrongType;
                dir = try fs.parentOf(dir) orelse return error.NotFound;
            } else {
                const next = try fs.child(dir, part) orelse return error.NotFound;
                if (next.entry_type == dos.ST_SOFTLINK) {
                    const after = if (last) "" else path[cut + 1 ..];
                    return fs.resolved(next, path[start..at], after, buffer[0..room]);
                }
                if (last or !next.isDir()) return error.WrongType;
                dir = next;
            }
            at = cut + 1;
        }
    }

    /// `before`, the target of the soft link `link` and `after`, joined
    /// in `into` with a NUL behind: `before` left off when the target has
    /// a colon - a device, or the root - and a `/` before `after` unless
    /// the target ends in one or in a colon.
    fn resolved(fs: *FileSystem, link: Object, before: []const u8, after: []const u8, into: []u8) Error!usize {
        var stored: [posfs.max_link]u8 = undefined;
        var held: btree.Tree = undefined;
        const stored_len = try objects.linkTargetIn(&fs.vol, try fs.viewTree(link.view, &held), link.oid, &stored);
        if (stored_len == 0 or stored_len > stored.len) return error.Corrupt;
        const target = stored[0..stored_len];
        var own_device = false;
        for (target) |char| {
            if (char == ':') own_device = true;
        }
        var len: usize = 0;
        if (!own_device) {
            if (before.len > into.len) return error.BufferOverflow;
            @memcpy(into[0..before.len], before);
            len = before.len;
        }
        len += pathToDos(target, into[len..]) orelse return error.BufferOverflow;
        if (after.len != 0) {
            const ends = into[len - 1];
            if (ends != '/' and ends != ':') {
                if (len == into.len) return error.BufferOverflow;
                into[len] = '/';
                len += 1;
            }
            if (after.len > into.len - len) return error.BufferOverflow;
            @memcpy(into[len..][0..after.len], after);
            len += after.len;
        }
        if (len == into.len) return error.BufferOverflow;
        into[len] = 0;
        return len;
    }

    /// DELETE_OBJECT: the name gone - into Recycled when the volume has it
    /// on and it was the object's last, else for good.
    fn delete(fs: *FileSystem, dir_arg: isize, path: []const u8) Error!void {
        const vol = &fs.vol;
        const object = try fs.locate(dir_arg, path);
        try object.writable();
        if (object.oid == posfs.root_oid) return error.WrongType;
        if (object.oid == posfs.recycled_oid) return error.WriteProtected;
        const node = try objects.needInode(vol, object.oid);
        if (object.isDir() and try dirs.hasEntries(vol, object.oid)) return error.NotEmpty;
        if (node.protection & dos.FIBF_DELETE != 0) return error.DeleteProtected;
        if (fs.nameInUse(object.parent, object.pos)) return error.InUse;
        if (node.nlink <= 1 and fs.otherLock(object.oid, null, false)) return error.InUse;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        if (fs.goesToRecycled(object, &node)) return fs.recycle(object);
        try fs.unlink(object, &node);
    }

    /// A name gone for good, and with the last its object - at once, or
    /// as a job when its data is much.
    fn unlink(fs: *FileSystem, object: Object, node: *const Inode) Error!void {
        const vol = &fs.vol;
        const job = node.nlink <= 1 and node.entry_type == dos.ST_FILE and node.blocks > fs.job_blocks;
        const head: layout.UnlinkRecord = .{
            .parent = object.parent,
            .pos = object.pos,
            .oid = object.oid,
            .time = vol.now(),
            .mode = if (job) layout.unlink_job else layout.unlink_now,
        };
        try objects.change(vol, .unlink, layout.bytesOf(&head));
        if (job) fs.orphans = true;
        fs.changed(object.oid);
        fs.orphaned(object.oid);
        fs.changed(object.parent);
    }

    fn rename(fs: *FileSystem, args: dos.RenameArgs) Error!void {
        const from = try fs.locate(lockValue(args.from_lock), span(args.from_name orelse return error.BadName));
        if (from.oid == posfs.root_oid) return error.WrongType;
        const place = try fs.findDir(try fs.objectOf(lockValue(args.to_lock)), span(args.to_name orelse return error.BadName));
        if (!place.dir.isDir()) return error.WrongType;
        var buffer: [posfs.max_name]u8 = undefined;
        try fs.moveTo(from, place.dir, try dirs.fromDos(place.name, &buffer));
    }

    /// A name moved to `name` (UTF-8) in `dir`: a rename, and out of
    /// Recycled an undelete. Into Recycled, within it, and of Recycled
    /// itself it is refused.
    fn moveTo(fs: *FileSystem, from: Object, dir: Object, name: []const u8) Error!void {
        const vol = &fs.vol;
        try from.writable();
        try dir.writable();
        if (from.oid == posfs.root_oid) return error.WrongType;
        if (from.oid == posfs.recycled_oid or dir.inRecycled()) return error.WriteProtected;
        if (!dir.isDir()) return error.WrongType;
        if (dir.oid == posfs.root_oid and dirs.reservedInRoot(name)) return error.BadName;
        if (try dirs.lookup(vol, dir.oid, name)) |there| {
            if (there.oid != from.oid) return error.Exists;
        }
        if (from.isDir() and try objects.within(vol, dir.oid, from.oid)) return error.InUse;
        if (fs.otherLock(from.oid, null, true)) return error.InUse;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        const leaving: ?u64 = if (dir.oid == from.parent) from.pos else null;
        const to_pos = try dirs.freePosition(vol, dir.oid, name, leaving);
        const head: layout.RenameRecord = .{
            .from_parent = from.parent,
            .from_pos = from.pos,
            .to_parent = dir.oid,
            .to_pos = to_pos,
            .oid = from.oid,
            .time = vol.now(),
            .name_len = @intCast(name.len),
        };
        var payload: [@sizeOf(layout.RenameRecord) + posfs.max_name]u8 = undefined;
        @memcpy(payload[0..@sizeOf(layout.RenameRecord)], layout.bytesOf(&head));
        @memcpy(payload[@sizeOf(layout.RenameRecord)..][0..name.len], name);
        fs.changed(from.oid);
        fs.orphaned(from.oid);
        try objects.change(vol, .rename, payload[0 .. @sizeOf(layout.RenameRecord) + name.len]);
        // The locks that came through the old name now come through the new.
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.parent == from.parent and x.pos == from.pos and x.oid == from.oid) {
                x.parent = dir.oid;
                x.pos = to_pos;
            }
        }
        const moved: Object = .{ .oid = from.oid, .parent = dir.oid, .pos = to_pos, .entry_type = from.entry_type };
        fs.appeared(moved, true);
        fs.changed(from.parent);
        if (dir.oid != from.parent) fs.changed(dir.oid);
    }

    /// SET_PROTECT, SET_COMMENT, SET_DATE and SET_OWNER on (lock, name).
    fn setProperty(fs: *FileSystem, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
        const vol = &fs.vol;
        const object = try fs.locate(lockValue(args.lock), span(args.name orelse return error.BadName));
        try object.writable();
        if (object.oid == posfs.root_oid) return error.WrongType;
        if (object.inRecycled()) return error.WriteProtected;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        const bits: u32 = @truncate(ptrArg(args.value));
        var head: layout.SetAttrRecord = .{ .oid = object.oid, .time = vol.now() };
        var text_buffer: [posfs.max_name]u8 = undefined;
        var text: []const u8 = "";
        switch (action) {
            .set_protect => {
                head.mask = layout.ATTR_PROTECTION;
                head.protection = bits;
            },
            .set_owner => {
                head.mask = layout.ATTR_OWNER;
                head.owner_uid = bits >> 16;
                head.owner_gid = bits & 0xFFFF;
            },
            .set_date => {
                head.mask = layout.ATTR_DATE;
                const date: ?*const dos.DateStamp = @ptrFromInt(ptrArg(args.value));
                head.date = if (date) |stamp| layout.microsOf(stamp.*) else head.time;
            },
            else => {
                head.mask = layout.ATTR_COMMENT;
                const given: ?[*:0]const u8 = @ptrFromInt(ptrArg(args.value));
                const latin = if (given) |it| span(it) else "";
                if (latin.len > posfs.max_comment) return error.CommentTooBig;
                text = fold.fromDos(latin, &text_buffer) orelse return error.CommentTooBig;
                if (text.len > posfs.max_comment) return error.CommentTooBig;
                head.comment_len = @intCast(text.len);
            },
        }
        var payload: [@sizeOf(layout.SetAttrRecord) + posfs.max_comment]u8 = undefined;
        @memcpy(payload[0..@sizeOf(layout.SetAttrRecord)], layout.bytesOf(&head));
        @memcpy(payload[@sizeOf(layout.SetAttrRecord)..][0..text.len], text);
        try objects.change(vol, .set_attr, payload[0 .. @sizeOf(layout.SetAttrRecord) + text.len]);
        fs.changed(object.oid);
    }

    // --- Recycled ------------------------------------------------------------------

    /// Whether a delete moves the name into Recycled: Recycled is on, the
    /// name is its object's last and not in Recycled already, and the
    /// object is not more than Recycled may hold on its own.
    fn goesToRecycled(fs: *FileSystem, object: Object, node: *const Inode) bool {
        const vol = &fs.vol;
        if (!recycled.on(vol) or object.parent == posfs.recycled_oid or node.nlink > 1) return false;
        const most = vol.voltab.recycled_max_bytes;
        return most == 0 or node.blocks << vol.block_shift <= most;
    }

    /// A delete that moves the name into Recycled, and Recycled kept to
    /// its limits after.
    fn recycle(fs: *FileSystem, object: Object) Error!void {
        const vol = &fs.vol;
        const entry = try dirs.at(vol, object.parent, object.pos) orelse return error.NotFound;
        var original: [posfs.max_name]u8 = undefined;
        const original_len = entry.name.len;
        @memcpy(original[0..original_len], entry.name);
        var buffer: [posfs.max_name]u8 = undefined;
        const spot = try recycled.place(vol, original[0..original_len], &buffer);
        const totals = try recycled.stats(vol);
        const head: layout.RecycleRecord = .{
            .parent = object.parent,
            .pos = object.pos,
            .oid = object.oid,
            .time = vol.now(),
            .new_pos = spot.pos,
            .rseq = totals.next_rseq,
            .name_len = @intCast(spot.name.len),
        };
        var payload: [@sizeOf(layout.RecycleRecord) + posfs.max_name]u8 = undefined;
        @memcpy(payload[0..@sizeOf(layout.RecycleRecord)], layout.bytesOf(&head));
        @memcpy(payload[@sizeOf(layout.RecycleRecord)..][0..spot.name.len], spot.name);
        fs.changed(object.oid);
        fs.orphaned(object.oid);
        try objects.change(vol, .recycle, payload[0 .. @sizeOf(layout.RecycleRecord) + spot.name.len]);
        fs.appeared(.{ .oid = object.oid, .parent = posfs.recycled_oid, .pos = spot.pos, .entry_type = object.entry_type }, true);
        fs.changed(object.parent);
        fs.changed(posfs.recycled_oid);
        try fs.keepLimits();
    }

    /// The oldest object in Recycled that nothing uses deleted for good:
    /// the blocks its data took, null when there is none.
    fn purgeOldest(fs: *FileSystem) Error!?u64 {
        const vol = &fs.vol;
        var key = recycled.queueKey(0);
        while (try recycled.nextQueued(vol, &key)) |oid| {
            const node = try objects.inode(vol, oid) orelse return error.Corrupt;
            if (node.parent != posfs.recycled_oid) return error.Corrupt;
            if (fs.otherLock(oid, null, false) or fs.nameInUse(posfs.recycled_oid, node.pos)) continue;
            try fs.unlink(.{ .oid = oid, .parent = posfs.recycled_oid, .pos = node.pos, .entry_type = node.entry_type }, &node);
            return node.blocks;
        }
        return null;
    }

    /// Recycled kept to the volume table's limits: its oldest that nothing
    /// uses deleted while it holds more.
    fn keepLimits(fs: *FileSystem) Error!void {
        const vol = &fs.vol;
        if (!recycled.on(vol)) return;
        const table = vol.voltab;
        while (true) {
            const totals = try recycled.stats(vol);
            const too_many = table.recycled_max_count != 0 and totals.count > table.recycled_max_count;
            const too_big = table.recycled_max_bytes != 0 and totals.bytes > table.recycled_max_bytes;
            if (!too_many and !too_big) return;
            _ = try fs.purgeOldest() orelse return;
        }
    }

    /// The volume full, and checkpoints made no room: Recycled's oldest
    /// deleted, the orphans' data given up, and two checkpoints to make it
    /// free. False when there was nothing to give up.
    fn makeRoom(fs: *FileSystem) Error!bool {
        const vol = &fs.vol;
        var gave = false;
        if (recycled.on(vol)) {
            // Enough at once that a full volume does not checkpoint for
            // every block.
            const share: u64 = @min(vol.block_count / 64, recycled.job_blocks);
            const goal: u64 = @max(share, 16);
            var freed: u64 = 0;
            while (freed < goal) {
                freed += try fs.purgeOldest() orelse break;
                gave = true;
            }
        }
        if (fs.orphans) {
            try fs.trimOrphans(null);
            gave = true;
        }
        if (!gave) return false;
        try checkpoint.write(vol, 0);
        try checkpoint.write(vol, 0);
        return true;
    }

    /// The orphans' data given up a step at a time until the clock reaches
    /// `until` - all of it with null - each object gone with its last.
    fn trimOrphans(fs: *FileSystem, until: ?u64) Error!void {
        const vol = &fs.vol;
        try checkpoint.startSession(vol);
        while (try recycled.trimOrphan(vol, fs.job_blocks)) {
            if (checkpoint.due(vol)) try checkpoint.write(vol, 0);
            if (until) |limit| {
                if (vol.now() >= limit) return;
            }
        }
        fs.orphans = false;
    }

    /// The directory `oid` as an object of its own, when it is there and
    /// not in Recycled.
    fn dirObject(fs: *FileSystem, oid: u64) Error!?Object {
        if (oid == posfs.root_oid) return root_object;
        const node = try objects.inode(&fs.vol, oid) orelse return null;
        if (!objects.isDir(node.entry_type)) return null;
        const object: Object = .{ .oid = oid, .parent = node.parent, .pos = node.pos, .entry_type = node.entry_type };
        return if (object.inRecycled()) null else object;
    }

    /// ACTION_POSFS_UNDELETE: an object in Recycled given back - where it
    /// came from, or to the path `to`: into the directory it names (or one
    /// it ends in `/` or `:` after) under its old name, else under the name
    /// it ends in.
    fn undelete(fs: *FileSystem, args: *const packets.UndeleteArgs) Error!void {
        const vol = &fs.vol;
        const given = try takeStruct(packets.UndeleteArgs, args);
        if (!recycled.on(vol)) return error.NotFound;
        const entry = try dirs.lookupDos(vol, posfs.recycled_oid, span(given.name orelse return error.BadName)) orelse return error.NotFound;
        const object: Object = .{ .oid = entry.oid, .parent = posfs.recycled_oid, .pos = entry.pos, .entry_type = entry.entry_type };
        var old_name: [posfs.max_name]u8 = undefined;
        const from = try recycled.origin(vol, object.oid, &old_name);
        var buffer: [posfs.max_name]u8 = undefined;
        var name = from.name;
        var dir: Object = undefined;
        if (given.to) |text| {
            const place = try fs.findDir(root_object, span(text));
            dir = place.dir;
            if (place.name.len != 0) {
                const there = try fs.child(place.dir, place.name);
                if (there != null and there.?.isDir()) {
                    dir = there.?;
                } else name = try dirs.fromDos(place.name, &buffer);
            }
        } else dir = try fs.dirObject(from.parent) orelse return error.DirNotFound;
        try fs.moveTo(object, dir, name);
    }

    /// ACTION_POSFS_EMPTY_RECYCLED: everything in Recycled deleted for
    /// good, the oldest first; InUse when something used stays.
    fn emptyRecycled(fs: *FileSystem) Error!void {
        const vol = &fs.vol;
        if (!recycled.on(vol)) return error.NotFound;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        while (try fs.purgeOldest()) |_| {}
        if ((try recycled.stats(vol)).count != 0) return error.InUse;
    }

    /// ACTION_POSFS_ORIGIN: where an object in Recycled was deleted from -
    /// the path from the root - and when. The time is given when the
    /// directory it was in has gone since (DirNotFound).
    fn originOf(fs: *FileSystem, args: *packets.OriginArgs) Error!void {
        const vol = &fs.vol;
        const given = try takeStruct(packets.OriginArgs, args);
        if (!recycled.on(vol)) return error.NotFound;
        const entry = try dirs.lookupDos(vol, posfs.recycled_oid, span(given.name orelse return error.BadName)) orelse return error.NotFound;
        var old_name: [posfs.max_name]u8 = undefined;
        const from = try recycled.origin(vol, entry.oid, &old_name);
        var reply = given;
        reply.deleted = from.deleted;
        try giveStruct(packets.OriginArgs, args, &reply);
        const into = given.path orelse return error.InvalidArgument;
        var dir: Object = root_object;
        if (from.parent != posfs.root_oid) {
            const node = try objects.inode(vol, from.parent) orelse return error.DirNotFound;
            if (!objects.isDir(node.entry_type)) return error.DirNotFound;
            dir = .{ .oid = from.parent, .parent = node.parent, .pos = node.pos, .entry_type = node.entry_type };
        }
        var buffer: [dos.path_max]u8 = undefined;
        const path = try fs.pathOf(dir, &buffer);
        var shown: [posfs.max_name]u8 = undefined;
        const name = fold.toDos(from.name, &shown);
        const between = @intFromBool(path.len != 0);
        if (path.len + between + name.len + 1 > given.path_size) return error.BufferOverflow;
        @memcpy(into[0..path.len], path);
        if (between != 0) into[path.len] = '/';
        @memcpy(into[path.len + between ..][0..name.len], name);
        into[path.len + between + name.len] = 0;
    }

    // --- files ------------------------------------------------------------------

    fn fileOf(fs: *FileSystem, fh: ?*FileHandle) Error!*Lock {
        const handle = fh orelse return error.InvalidLock;
        const lock: *Lock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
        if (!fs.owns(lock) or lock.open == null) return error.InvalidLock;
        return lock;
    }

    /// The file `oid` open as `view` has it.
    fn openOf(fs: *FileSystem, view: u32, oid: u64) ?*Open {
        var it = fs.opens;
        while (it) |x| : (it = x.next) {
            if (x.oid == oid and x.view == view) return x;
        }
        return null;
    }

    /// The lock becomes a handle's: the file's shared state found or made.
    fn attach(fs: *FileSystem, lock: *Lock) Error!void {
        const open = fs.openOf(lock.view, lock.oid) orelse blk: {
            const made = try fs.create(Open);
            made.* = .{ .oid = lock.oid, .view = lock.view, .next = fs.opens };
            fs.opens = made;
            break :blk made;
        };
        open.handles += 1;
        lock.open = open;
        lock.file_pos = 0;
    }

    /// The handle's file's overlay, made when it first writes.
    fn overlayOf(fs: *FileSystem, lock: *Lock) Error!*files.Overlay {
        const open = lock.open.?;
        if (!open.writing) {
            try lock.object().writable();
            if (lock.object().inRecycled()) return error.WriteProtected;
            if (fs.vol.read_only or fs.vol.failed) return error.ReadOnly;
            const node = try objects.needInode(&fs.vol, open.oid);
            open.overlay = files.begin(open.oid, &node);
            open.writing = true;
        }
        return &open.overlay;
    }

    /// A handle's file let go of: what it held committed when it was the
    /// last one, and its share freed.
    fn detach(fs: *FileSystem, lock: *Lock) Error!void {
        const open = lock.open orelse return;
        lock.open = null;
        open.handles -= 1;
        var result: Error!void = {};
        if (open.writing) result = files.commit(&fs.vol, &open.overlay);
        if (open.handles != 0) return result;
        if (open.writing) files.discard(&fs.vol, &open.overlay);
        if (fs.opens == open) {
            fs.opens = open.next;
        } else {
            var it = fs.opens;
            while (it) |x| : (it = x.next) {
                if (x.next == open) {
                    x.next = open.next;
                    break;
                }
            }
        }
        fs.freeMemory(open);
        return result;
    }

    /// The size of an open file as its handles see it.
    fn sizeOf(fs: *FileSystem, lock: *Lock) Error!u64 {
        const open = lock.open.?;
        if (open.writing) return open.overlay.size;
        return (try fs.inodeIn(lock.view, lock.oid)).size;
    }

    /// FINDINPUT (an existing file, shared), FINDOUTPUT (a new or emptied
    /// file, exclusive), FINDUPDATE (an existing or new file, shared).
    fn find(fs: *FileSystem, args: dos.FindArgs, action: dos.ActionCode) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const dir_arg = lockValue(args.lock);
        const path = span(args.name orelse return error.BadName);
        var made = false;
        const lock: *Lock = switch (action) {
            .findinput => blk: {
                const object = try fs.locate(dir_arg, path);
                try fileObject(object);
                break :blk try fs.getLock(object, dos.SHARED_LOCK);
            },
            .findoutput => if (fs.locate(dir_arg, path)) |object| blk: {
                try fileObject(object);
                try object.writable();
                if (object.inRecycled()) return error.WriteProtected;
                const node = try objects.needInode(&fs.vol, object.oid);
                if (node.protection & dos.FIBF_WRITE != 0) return error.WriteProtected;
                if (node.protection & dos.FIBF_DELETE != 0) return error.DeleteProtected;
                if (fs.vol.read_only or fs.vol.failed) return error.ReadOnly;
                break :blk try fs.getLock(object, dos.EXCLUSIVE_LOCK);
            } else |err| blk: {
                if (err != error.NotFound) return err;
                made = true;
                break :blk try fs.getLock(try fs.make(dir_arg, path, dos.ST_FILE, ""), dos.EXCLUSIVE_LOCK);
            },
            else => if (fs.locate(dir_arg, path)) |object| blk: {
                try fileObject(object);
                try object.writable();
                if (object.inRecycled()) return error.WriteProtected;
                break :blk try fs.getLock(object, dos.SHARED_LOCK);
            } else |err| blk: {
                if (err != error.NotFound) return err;
                made = true;
                break :blk try fs.getLock(try fs.make(dir_arg, path, dos.ST_FILE, ""), dos.SHARED_LOCK);
            },
        };
        errdefer fs.freeLock(lock);
        try fs.attach(lock);
        if (action == .findoutput) {
            const overlay = fs.overlayOf(lock) catch |err| {
                fs.detach(lock) catch {};
                return err;
            };
            if (!made) try files.truncateAll(&fs.vol, overlay);
            overlay.modified = true;
            lock.modified = true;
        }
        if (made) fs.appeared(lock.object(), false);
        fh.key = lock;
        fh.interactive = false;
    }

    fn fileObject(object: Object) Error!void {
        if (object.entry_type == dos.ST_SOFTLINK) return error.IsSoftLink;
        if (object.isDir()) return error.WrongType;
    }

    fn read(fs: *FileSystem, args: dos.IOArgs) Error!usize {
        const lock = try fs.fileOf(args.fh);
        const buffer = args.buffer orelse return 0;
        const len: usize = if (args.length > 0) @intCast(args.length) else 0;
        var held: btree.Tree = undefined;
        const tree = try fs.viewTree(lock.view, &held);
        const node = try objects.inodeIn(&fs.vol, tree, lock.oid) orelse return error.NotFound;
        if (node.protection & dos.FIBF_READ != 0) return error.ReadProtected;
        const open = lock.open.?;
        const size = if (open.writing) open.overlay.size else node.size;
        if (lock.file_pos >= size) return 0;
        const count: usize = @intCast(@min(@as(u64, len), size - lock.file_pos));
        if (open.writing) {
            try files.readThrough(&fs.vol, &open.overlay, &node, lock.file_pos, buffer[0..count]);
        } else try files.readCommitted(&fs.vol, tree, lock.oid, &node, lock.file_pos, buffer[0..count]);
        lock.file_pos += count;
        return count;
    }

    /// The bytes written; fewer than asked for, with the reason in
    /// `failed`, when the volume filled or failed on the way.
    fn write(fs: *FileSystem, args: dos.IOArgs, failed: *?Error) Error!usize {
        const lock = try fs.fileOf(args.fh);
        const buffer = args.buffer orelse return 0;
        const len: usize = if (args.length > 0) @intCast(args.length) else 0;
        try lock.object().writable();
        const node = try objects.needInode(&fs.vol, lock.oid);
        if (node.protection & dos.FIBF_WRITE != 0) return error.WriteProtected;
        if (len == 0) return 0;
        const overlay = try fs.overlayOf(lock);
        const count = try files.write(&fs.vol, overlay, &node, lock.file_pos, buffer[0..len], failed);
        lock.file_pos += count;
        lock.modified = true;
        return count;
    }

    /// To a position from the beginning, the current position or the end;
    /// the old position. Not before the start or past the end.
    fn seek(fs: *FileSystem, args: dos.SeekArgs) Error!u64 {
        const lock = try fs.fileOf(args.fh);
        const size: i64 = @intCast(try fs.sizeOf(lock));
        const from: i64 = switch (args.mode) {
            dos.OFFSET_BEGINNING => 0,
            dos.OFFSET_CURRENT => @intCast(lock.file_pos),
            dos.OFFSET_END => size,
            else => return error.SeekError,
        };
        const sum = @addWithOverflow(from, args.position);
        if (sum[1] != 0) return error.SeekError;
        if (sum[0] < 0 or sum[0] > size) return error.SeekError;
        const old = lock.file_pos;
        lock.file_pos = @intCast(sum[0]);
        return old;
    }

    /// END: what the handle wrote committed (when it is the file's last
    /// handle, everything), and the handle let go.
    fn close(fs: *FileSystem, args: dos.FileHandleArgs) Error!void {
        const lock = try fs.fileOf(args.fh);
        const written = lock.modified;
        const object = lock.object();
        if (fs.records) |records| records.release(lock);
        const result = fs.detach(lock);
        fs.freeLock(lock);
        args.fh.?.key = null;
        try result;
        if (written) {
            fs.changed(object.oid);
            fs.changed(object.parent);
        }
    }

    /// SET_FILE_SIZE: the file cut or grown; handles past the new end move
    /// back to it. The new size.
    fn setFileSize(fs: *FileSystem, args: dos.SeekArgs) Error!u64 {
        const lock = try fs.fileOf(args.fh);
        try lock.object().writable();
        const node = try objects.needInode(&fs.vol, lock.oid);
        if (node.protection & dos.FIBF_WRITE != 0) return error.WriteProtected;
        const current = try fs.sizeOf(lock);
        const from: i64 = switch (args.mode) {
            dos.OFFSET_BEGINNING => 0,
            dos.OFFSET_CURRENT => @intCast(lock.file_pos),
            dos.OFFSET_END => @intCast(current),
            else => return error.SeekError,
        };
        const sum = @addWithOverflow(from, args.position);
        if (sum[1] != 0 or sum[0] < 0) return error.SeekError;
        const size: u64 = @intCast(sum[0]);
        const overlay = try fs.overlayOf(lock);
        try files.setSize(&fs.vol, overlay, &node, size);
        var it = fs.locks;
        while (it) |x| : (it = x.nextLock()) {
            if (x.oid == lock.oid and x.open != null and x.file_pos > size) x.file_pos = size;
        }
        lock.modified = true;
        return size;
    }

    fn fhFromLock(fs: *FileSystem, args: dos.FhFromLockArgs) Error!void {
        const fh = args.fh orelse return error.InvalidLock;
        const lock = try fs.lockArg(lockValue(args.lock)) orelse return error.InvalidLock;
        try fileObject(lock.object());
        if (lock.open != null) return error.InvalidLock;
        try fs.attach(lock);
        fh.key = lock;
        fh.interactive = false;
    }

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
        if (exclusive and fs.otherLockIn(lock.view, lock.oid, lock, false)) return error.InUse;
        lock.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
    }

    // --- examine ------------------------------------------------------------------

    /// A FileInfoBlock for an object: its inode, the name it came through
    /// (the volume's for the root), and what an open file holds besides.
    /// `.snapshots` and a snapshot's root are directories that are neither
    /// written nor deleted, a root with the snapshot's name and the time
    /// it was made.
    fn fill(fs: *FileSystem, fib: *FileInfoBlock, object: Object) Error!void {
        const vol = &fs.vol;
        const fixed = dos.FIBF_WRITE | dos.FIBF_DELETE;
        var shown: [posfs.max_name]u8 = undefined;
        if (object.oid == snapshots.dir_oid) {
            const made = snapshots.all(vol);
            const time = if (made.len != 0) made[made.len - 1].created else (try objects.needInode(vol, posfs.root_oid)).mtime;
            fib.* = .{
                .dir_entry_type = dos.ST_USERDIR,
                .entry_type = dos.ST_USERDIR,
                .protection = fixed,
                .date = layout.stampOf(time),
            };
            @memcpy(fib.file_name[0..posfs.snapshots_name.len], posfs.snapshots_name);
            return;
        }
        var held: btree.Tree = undefined;
        const tree = try fs.viewTree(object.view, &held);
        const node = try objects.inodeIn(vol, tree, object.oid) orelse return error.NotFound;
        var size = node.size;
        if (fs.openOf(object.view, object.oid)) |open| {
            if (open.writing) size = open.overlay.size;
        }
        fib.* = .{
            .dir_entry_type = node.entry_type,
            .entry_type = node.entry_type,
            .protection = node.protection,
            .size = if (objects.isDir(node.entry_type)) 0 else size,
            .num_blocks = if (node.blocks != 0) node.blocks else (size + vol.block_size - 1) / vol.block_size,
            .date = layout.stampOf(node.mtime),
            .owner_uid = @truncate(node.owner_uid),
            .owner_gid = @truncate(node.owner_gid),
        };
        var name: []const u8 = undefined;
        if (object.oid == posfs.root_oid and object.view != 0) {
            const snapshot = snapshots.byId(vol, object.view) orelse return error.NotFound;
            name = fold.toDos(snapshots.nameOf(snapshot), &shown);
            fib.dir_entry_type = dos.ST_USERDIR;
            fib.entry_type = dos.ST_USERDIR;
            fib.protection |= fixed;
            fib.date = layout.stampOf(snapshot.created);
        } else if (object.oid == posfs.root_oid) {
            name = fold.toDos(fs.volumeName(), &shown);
        } else {
            const entry = try dirs.atIn(vol, tree, object.parent, object.pos) orelse return error.NotFound;
            // A lock kept while its volume was away may come back to a
            // name that is another object's now.
            if (entry.oid != object.oid) return error.NotFound;
            name = fold.toDos(entry.name, &shown);
        }
        @memcpy(fib.file_name[0..name.len], name);
        var text: [posfs.max_comment]u8 = undefined;
        const note = try objects.commentIn(vol, tree, object.oid, &text);
        var latin: [posfs.max_comment]u8 = undefined;
        const comment_shown = latinOf(note, &latin);
        @memcpy(fib.comment[0..comment_shown.len], comment_shown);
    }

    /// EXAMINE_OBJECT (`next` false) and EXAMINE_NEXT: the FileInfoBlock
    /// keeps the position the walk goes on from in fib_DiskKey.
    fn examine(fs: *FileSystem, args: dos.ExamineArgs, next: bool) Error!void {
        const object = try fs.objectOf(lockValue(args.lock));
        const fib = args.fib orelse return error.InvalidLock;
        if (!next) {
            try fs.fill(fib, object);
            fib.disk_key = 0;
            return;
        }
        if (!object.isDir()) return error.NoMoreEntries;
        const found = try fs.entryFrom(object, fib.disk_key) orelse return error.NoMoreEntries;
        try fs.fill(fib, found.object);
        fib.disk_key = @intCast(found.next);
    }

    /// The first entry of the directory `dir` at position `from` or after
    /// it: in `.snapshots` the snapshots, by id.
    fn entryFrom(fs: *FileSystem, dir: Object, from: u64) Error!?Next {
        if (dir.oid == snapshots.dir_oid) {
            for (snapshots.all(&fs.vol)) |*snapshot| {
                if (snapshot.id >= from) return .{ .object = snapshotRoot(snapshot.id), .next = @as(u64, snapshot.id) + 1 };
            }
            return null;
        }
        var held: btree.Tree = undefined;
        const tree = try fs.viewTree(dir.view, &held);
        const entry = try dirs.followingIn(&fs.vol, tree, dir.oid, from) orelse return null;
        const object: Object = .{ .oid = entry.oid, .parent = dir.oid, .pos = entry.pos, .entry_type = entry.entry_type, .view = dir.view };
        return .{ .object = object, .next = entry.pos + 1 };
    }

    fn examineFile(fs: *FileSystem, args: dos.ExamineFHArgs) Error!void {
        const lock = try fs.fileOf(args.fh);
        try fs.fill(args.fib orelse return error.InvalidLock, lock.object());
    }

    /// EXAMINE_ALL: as many of a directory's entries as the buffer holds,
    /// from the position in `control.last_key` on, packed at `level`.
    /// True while more come, the place to go on from in last_key;
    /// NoMoreEntries at the end, and BufferOverflow when not even one
    /// record fits, each with last_key 0 again. An entry the pattern or
    /// the hook leaves out takes no room.
    fn examineAll(fs: *FileSystem, args: dos.ExAllArgs, level: i32, matcher: *const Matcher) Error!bool {
        const control = args.control orelse return error.InvalidArgument;
        control.entries = 0;
        const object = try fs.objectOf(lockValue(args.lock));
        if (!object.isDir()) return error.WrongType;
        const buffer = args.buffer orelse return error.InvalidArgument;
        const room: usize = if (args.size > 0) @intCast(args.size) else 0;
        var fib: FileInfoBlock = .{};
        var pos: usize = 0;
        var last: ?*dos.ExAllData = null;
        var from: u64 = control.last_key;
        while (try fs.entryFrom(object, from)) |found| {
            from = found.next;
            try fs.fill(&fib, found.object);
            if (control.match_string) |pattern| {
                if (!matcher.matches(matcher.context, pattern, @ptrCast(&fib.file_name))) continue;
            }
            const mark = pos;
            const rec = dos.exall.pack(buffer, room, &pos, level, &fib) orelse {
                // Not even one record fits: another call with this buffer
                // would answer the same, and a caller looping until false
                // would never end.
                if (control.entries == 0) {
                    control.last_key = 0;
                    return error.BufferOverflow;
                }
                control.last_key = @intCast(found.next - 1);
                return true;
            };
            if (control.match_func) |hook| {
                if (!matcher.takes(matcher.context, hook, level, rec)) {
                    pos = mark;
                    continue;
                }
            }
            if (last) |prev| prev.next = rec;
            last = rec;
            control.entries += 1;
        }
        control.last_key = 0;
        return error.NoMoreEntries;
    }

    /// MORE_CACHE: the cache `more` blocks larger (smaller for a negative
    /// count, 32 at the least), and the count it now has - kept for the
    /// next medium's mount too. What it held is dropped. A medium read
    /// through its mapping keeps no cache, and answers NotImplemented.
    fn moreCache(fs: *FileSystem, more: i32) Error!u32 {
        const vol = &fs.vol;
        if (vol.map != null or !vol.cache_ready) return error.NotImplemented;
        const now: i64 = vol.cache.capacity();
        const asked = now + more;
        const wanted: u32 = if (asked < 32) 32 else if (asked > 0x7FFF_FFFF) 0x7FFF_FFFF else @intCast(asked);
        if (vol.cache.resize(wanted)) {
            vol.cache_blocks = wanted;
            return wanted;
        }
        if (!vol.cache.resize(@intCast(now))) {
            if (!vol.cache.resize(32)) vol.cache_ready = false;
        }
        return error.NoMemory;
    }

    /// INFO and DISK_INFO: the volume's blocks, and how many are taken -
    /// all but those a file could still have.
    fn info(fs: *FileSystem, data: ?*dos.InfoData) Error!void {
        const vol = &fs.vol;
        const target = data orelse return error.InvalidLock;
        const total = vol.block_count;
        const free = space.available(vol);
        target.* = .{
            .num_soft_errors = 0,
            .unit_number = 0,
            .disk_state = if (vol.read_only or vol.failed) dos.ID_WRITE_PROTECTED else dos.ID_VALIDATED,
            .num_blocks = total,
            .num_blocks_used = total - @min(free, total),
            .bytes_per_block = vol.block_size,
            .disk_type = posfs.ID_POSFS_DISK,
            .volume_node = fs.volume_node,
            .in_use = if (fs.locks != null) dos.DOSTRUE else 0,
        };
    }

    // --- posfs's own packets ----------------------------------------------------------

    /// ACTION_POSFS_INFO: the volume's numbers and switches. The blocks
    /// add up: live, snapshots, recycled, pending, reserve and free are
    /// every block of the volume.
    fn posfsInfo(fs: *FileSystem, into: *packets.Info) Error!void {
        const vol = &fs.vol;
        const pool = &vol.space;
        const total = vol.block_count;
        const free_total = @min(pool.free_total, total);
        const out = @min(pool.holds_total + pool.promised, free_total);
        const reserve = @min(pool.reserve, free_total - out);
        const table = vol.voltab;
        var erased: u32 = 0;
        for (pool.erased) |byte| erased += @popCount(byte);
        const totals: layout.RecycleStats = if (recycled.on(vol)) try recycled.stats(vol) else .{};
        const recycled_blocks = @min(totals.bytes >> vol.block_shift, total - free_total);
        const held = @min(snapshots.heldBlocks(vol), total - free_total - recycled_blocks);
        const numbers: packets.Info = .{
            .version = vol.label.version,
            .block_size = vol.block_size,
            .write_unit = vol.label.write_unit,
            .blocks = total,
            .free = free_total - out - reserve,
            .live = total - free_total - recycled_blocks - held,
            .snapshots = held,
            .recycled = recycled_blocks,
            .recycled_count = totals.count,
            .pending = out,
            .reserve = reserve,
            .gen = vol.durable.gen,
            .journal_used = vol.journal.since_checkpoint,
            .journal_limit = checkpoint.journalLimit(vol),
            .erased = erased,
            .settings = settingsOf(table.flags),
            .recycled_max_count = table.recycled_max_count,
            .snapshot_count = table.snapshot_count,
            .recycled_max_bytes = table.recycled_max_bytes,
            .last_check = table.last_check,
            .incompat = vol.label.incompat | table.incompat,
            .ro_compat = vol.label.ro_compat | table.ro_compat,
        };
        try giveStruct(packets.Info, into, &numbers);
    }

    /// ACTION_POSFS_SETTINGS: the switches named in the mask set,
    /// committed by two checkpoints. What is written from then on follows
    /// them; what is on the volume stays as it was written. Recycled on is
    /// the directory made - Exists while the root has the name - and off is
    /// it emptied and taken away, InUse while something in it or it itself
    /// is used; its limits are kept to at once.
    fn setSettings(fs: *FileSystem, given: *const packets.Settings) Error!void {
        const vol = &fs.vol;
        const settings = try takeStruct(packets.Settings, given);
        const known = packets.SET_RECYCLED | packets.SET_CHECKSUMS | packets.SET_COMPRESS;
        if (settings.mask & ~known != 0) return error.InvalidArgument;
        if (vol.read_only or vol.failed) return error.ReadOnly;
        const table = vol.voltab;
        const mask = flagsOf(settings.mask);
        const flags = (table.flags & ~mask) | (flagsOf(settings.settings) & mask);
        const was_on = recycled.on(vol);
        const turned_on = flags & layout.VT_RECYCLED != 0;
        if (was_on and !turned_on) {
            if (fs.otherLock(posfs.recycled_oid, null, false)) return error.InUse;
            try fs.emptyRecycled();
            try recycled.turnOff(vol);
            table.compat &= ~layout.COMPAT_RECYCLED;
        } else if (turned_on and !was_on) {
            try recycled.turnOn(vol);
            table.compat |= layout.COMPAT_RECYCLED;
        }
        table.flags = flags;
        if (settings.mask & packets.SET_RECYCLED != 0) {
            table.recycled_max_count = settings.recycled_max_count;
            table.recycled_max_bytes = settings.recycled_max_bytes;
        }
        if (table.flags & layout.VT_COMPRESS != 0) table.compress_alg = layout.alg_lz4;
        vol.voltab_dirty = true;
        try checkpoint.write(vol, 0);
        try checkpoint.write(vol, 0);
        if (turned_on and !was_on) {
            const node = try objects.needInode(vol, posfs.recycled_oid);
            fs.appeared(.{ .oid = posfs.recycled_oid, .parent = posfs.root_oid, .pos = node.pos, .entry_type = dos.ST_USERDIR }, true);
            fs.changed(posfs.root_oid);
        } else if (was_on and !turned_on) {
            fs.changed(posfs.recycled_oid);
            fs.orphaned(posfs.recycled_oid);
            fs.changed(posfs.root_oid);
        }
        try fs.keepLimits();
    }

    /// ACTION_POSFS_MAKE_SNAPSHOT: a snapshot of what is committed, under
    /// the name given (Latin-1 or UTF-8): Exists for a name a snapshot has,
    /// BadName for one a snapshot cannot have - empty, longer than
    /// `posfs.max_snapshot_name` bytes as UTF-8, or with `/`, `:` or a
    /// control character - and DiskFull past `posfs.max_snapshots`.
    fn makeSnapshot(fs: *FileSystem, args: *const packets.SnapshotArgs) Error!void {
        const given = try takeStruct(packets.SnapshotArgs, args);
        const dos_name = span(given.name orelse return error.BadName);
        var buffer: [posfs.max_name]u8 = undefined;
        const name = try dirs.fromDos(dos_name, &buffer);
        if (snapshots.findDos(&fs.vol, dos_name) != null) return error.Exists;
        try snapshots.make(&fs.vol, name);
        fs.changed(snapshots.dir_oid);
    }

    /// The snapshot a packet names, by its place in the table: NotFound
    /// when there is none of that name.
    fn snapshotNamed(fs: *FileSystem, args: *const packets.SnapshotArgs) Error!usize {
        const given = try takeStruct(packets.SnapshotArgs, args);
        const dos_name = span(given.name orelse return error.BadName);
        return snapshots.findDos(&fs.vol, dos_name) orelse error.NotFound;
    }

    /// ACTION_POSFS_DELETE_SNAPSHOT: the snapshot gone, and what only it
    /// held free; InUse while a lock is on something in it.
    fn deleteSnapshot(fs: *FileSystem, args: *const packets.SnapshotArgs) Error!void {
        const index = try fs.snapshotNamed(args);
        if (fs.viewInUse(snapshots.all(&fs.vol)[index].id)) return error.InUse;
        try snapshots.delete(&fs.vol, index);
        fs.changed(snapshots.dir_oid);
    }

    /// ACTION_POSFS_ROLLBACK: the volume back to the snapshot named, which
    /// must be the newest (Exists while a newer one is there); InUse while
    /// a lock or a handle is on the volume. Every watch looks for its name
    /// anew, and is told.
    fn rollback(fs: *FileSystem, args: *const packets.SnapshotArgs) Error!void {
        const index = try fs.snapshotNamed(args);
        if (fs.inUse()) return error.InUse;
        fs.endCheck();
        try snapshots.rollback(&fs.vol, index);
        fs.orphans = try recycled.hasOrphans(&fs.vol);
        if (fs.watchers) |watchers| watchers.orphanAll();
        fs.settleWatches();
    }

    /// ACTION_POSFS_CHECK: one slice of the check `args.cursor` names, or
    /// of a new one for cursor 0.
    fn checkSlice(fs: *FileSystem, args: *packets.CheckArgs) Error!void {
        const vol = &fs.vol;
        const given = try takeStruct(packets.CheckArgs, args);
        var reply = given;
        if (given.cursor != 0 and (fs.checking == null or given.cursor != fs.check_serial)) return error.InvalidArgument;
        if (given.flags & packets.CHECK_STOP != 0) {
            fs.endCheck();
            reply.cursor = 0;
            return giveStruct(packets.CheckArgs, args, &reply);
        }
        if (given.cursor == 0) {
            fs.endCheck();
            // What was answered goes into a checkpoint first: the check
            // reads the newest.
            if (fs.changesWait()) try checkpoint.write(vol, 0);
            const running = try fs.create(check.Check);
            running.begin(vol, .durable, given.flags & packets.CHECK_DATA != 0) catch |err| {
                fs.freeMemory(running);
                return err;
            };
            fs.checking = running;
            fs.check_serial +%= 1;
            if (fs.check_serial == 0) fs.check_serial = 1;
        }
        const running = fs.checking.?;
        // A write that needed the blocks the check held took them.
        if (!vol.space.pin) {
            fs.endCheck();
            return error.DiskFull;
        }
        const finished = running.run(vol, vol.now() + fs.check_slice) catch |err| {
            fs.endCheck();
            return err;
        };
        fs.check_touched = vol.now();
        const report = &running.report;
        reply.errors = report.errors;
        reply.nodes = report.nodes;
        reply.objects = running.objectsSeen();
        reply.data_blocks = running.dataBlocks();
        reply.message = @splat(0);
        if (report.errors != 0) {
            var len: usize = 0;
            putText(&reply.message, &len, report.message);
            putText(&reply.message, &len, ": ");
            putNumber(&reply.message, &len, report.where);
        }
        reply.cursor = fs.check_serial;
        if (finished) {
            if (report.errors == 0 and !vol.read_only and !vol.failed) {
                vol.voltab.last_check = vol.now();
                vol.voltab_dirty = true;
            }
            fs.endCheck();
            reply.cursor = 0;
        }
        try giveStruct(packets.CheckArgs, args, &reply);
    }

    /// The check under way ended, what it held let go.
    fn endCheck(fs: *FileSystem) void {
        const running = fs.checking orelse return;
        running.end(&fs.vol) catch {};
        fs.freeMemory(running);
        fs.checking = null;
    }

    /// One of posfs's own packets.
    fn answerOwn(fs: *FileSystem, pkt: *DosPacket) Answer {
        const arg = ptrArg(pkt.args.raw[0]);
        switch (pkt.action) {
            packets.ACTION_POSFS_INFO => {
                const into: *packets.Info = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.posfsInfo(into) catch |err| return no(err);
            },
            packets.ACTION_POSFS_SETTINGS => {
                const given: *const packets.Settings = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.setSettings(given) catch |err| return no(err);
            },
            packets.ACTION_POSFS_CHECK => {
                const args: *packets.CheckArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.checkSlice(args) catch |err| return no(err);
            },
            packets.ACTION_POSFS_UNDELETE => {
                const given: *const packets.UndeleteArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.undelete(given) catch |err| return no(err);
            },
            packets.ACTION_POSFS_EMPTY_RECYCLED => fs.emptyRecycled() catch |err| return no(err),
            packets.ACTION_POSFS_ORIGIN => {
                const args: *packets.OriginArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.originOf(args) catch |err| return no(err);
            },
            packets.ACTION_POSFS_MAKE_SNAPSHOT => {
                const given: *const packets.SnapshotArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.makeSnapshot(given) catch |err| return no(err);
            },
            packets.ACTION_POSFS_DELETE_SNAPSHOT => {
                const given: *const packets.SnapshotArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.deleteSnapshot(given) catch |err| return no(err);
            },
            packets.ACTION_POSFS_ROLLBACK => {
                const given: *const packets.SnapshotArgs = @ptrFromInt(if (arg == 0) return no(error.InvalidArgument) else arg);
                fs.rollback(given) catch |err| return no(err);
            },
            else => return noCode(dos.ERROR_ACTION_NOT_KNOWN),
        }
        return yes();
    }

    // --- packets ------------------------------------------------------------------

    /// The answer to one packet (all but STARTUP and the ones about the
    /// drive - inhibit, format, die - which the process takes).
    pub fn answer(fs: *FileSystem, pkt: *DosPacket) Answer {
        const a = pkt.args.raw;
        switch (pkt.getAction()) {
            .locate_object => {
                const object = fs.locate(a[0], span(@ptrFromInt(ptrArg(a[1])))) catch |err| return no(err);
                // A lock is on what a soft link leads to: dos asks for it.
                if (object.entry_type == dos.ST_SOFTLINK) return no(error.IsSoftLink);
                const lock = fs.getLock(object, @truncate(a[2])) catch |err| return no(err);
                return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
            },
            .free_lock => {
                // A lock of a volume no longer in the drive is still
                // given back.
                if (fs.unpark(ptrArg(a[0]))) return yes();
                const lock = fs.lockArg(a[0]) catch |err| return no(err);
                if (lock) |it| {
                    if (it.open != null) return no(error.InvalidLock);
                    fs.freeLock(it);
                }
                return yes();
            },
            .copy_dir, .parent => {
                const object = fs.objectOf(a[0]) catch |err| return no(err);
                const target = if (pkt.getAction() == .parent)
                    (fs.parentOf(object) catch |err| return no(err)) orelse return .{ .res1 = 0, .res2 = 0 }
                else
                    object;
                const lock = fs.getLock(target, dos.SHARED_LOCK) catch |err| return no(err);
                return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
            },
            .same_lock => {
                const first = fs.objectOf(a[0]) catch |err| return no(err);
                const second = fs.objectOf(a[1]) catch |err| return no(err);
                const same = first.oid == second.oid and first.view == second.view;
                return .{ .res1 = if (same) dos.DOSTRUE else dos.DOSFALSE, .res2 = 0 };
            },
            .create_dir => {
                const object = fs.make(a[0], span(@ptrFromInt(ptrArg(a[1]))), dos.ST_USERDIR, "") catch |err| return no(err);
                const lock = fs.getLock(object, dos.EXCLUSIVE_LOCK) catch |err| return no(err);
                fs.appeared(object, true);
                fs.changed(object.parent);
                return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
            },
            .delete_object => {
                fs.delete(a[0], span(@ptrFromInt(ptrArg(a[1])))) catch |err| return no(err);
                return yes();
            },
            .findinput, .findoutput, .findupdate => {
                fs.find(pkt.args.find, pkt.getAction()) catch |err| return no(err);
                return yes();
            },
            .read => {
                const count = fs.read(pkt.args.io) catch |err| return minusOne(err);
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .write => {
                var failed: ?Error = null;
                const count = fs.write(pkt.args.io, &failed) catch |err| return minusOne(err);
                return .{ .res1 = @intCast(count), .res2 = if (failed) |err| codeOf(err) else 0 };
            },
            .seek => {
                pkt.args.seek.answer = @intCast(fs.seek(pkt.args.seek) catch |err| return no(err));
                return yes();
            },
            .end => {
                // A handle whose medium went is still closed; what it had
                // written is lost, and its answer says so.
                if (pkt.args.file.fh) |fh| {
                    if (fh.key) |key| {
                        const lock: *Lock = @ptrCast(@alignCast(key));
                        if (fs.isParked(lock)) {
                            const written = lock.modified;
                            _ = fs.unpark(@intFromPtr(lock));
                            fh.key = null;
                            return if (written) noCode(dos.ERROR_DEVICE_NOT_MOUNTED) else yes();
                        }
                    }
                }
                fs.close(pkt.args.file) catch |err| return no(err);
                return yes();
            },
            .examine_object, .examine_next => {
                fs.examine(pkt.args.examine, pkt.getAction() == .examine_next) catch |err| return no(err);
                return yes();
            },
            .examine_fh => {
                fs.examineFile(pkt.args.examine_fh) catch |err| return no(err);
                return yes();
            },
            .examine_all => {
                const matcher = fs.matcher orelse return noCode(dos.ERROR_ACTION_NOT_KNOWN);
                const args = pkt.args.examine_all;
                if (args.data_type < dos.ED_NAME or args.data_type > dos.ED_OWNER) return noCode(dos.ERROR_BAD_NUMBER);
                const more = fs.examineAll(args, @intCast(args.data_type), matcher) catch |err| return no(err);
                return if (more) yes() else noCode(dos.ERROR_NO_MORE_ENTRIES);
            },
            .examine_all_end => {
                if (fs.matcher == null) return noCode(dos.ERROR_ACTION_NOT_KNOWN);
                if (pkt.args.examine_all.control) |control| control.last_key = 0;
                return yes();
            },
            .more_cache => {
                const count = fs.moreCache(@truncate(pkt.args.cache.number)) catch |err| return switch (err) {
                    error.NotImplemented => noCode(dos.ERROR_ACTION_NOT_KNOWN),
                    else => no(err),
                };
                return .{ .res1 = @intCast(count), .res2 = 0 };
            },
            .rename_object => {
                fs.rename(pkt.args.rename) catch |err| return no(err);
                return yes();
            },
            .make_link => {
                fs.makeLink(pkt.args.make_link) catch |err| return no(err);
                return yes();
            },
            .read_link => {
                const len = fs.readLink(pkt.args.read_link) catch |err| return switch (err) {
                    error.BufferOverflow => .{ .res1 = -2, .res2 = dos.ERROR_BUFFER_OVERFLOW },
                    else => minusOne(err),
                };
                return .{ .res1 = @intCast(len), .res2 = 0 };
            },
            .set_protect, .set_comment, .set_date, .set_owner => {
                fs.setProperty(pkt.args.property, pkt.getAction()) catch |err| return no(err);
                return yes();
            },
            .set_file_size => {
                pkt.args.seek.answer = @intCast(fs.setFileSize(pkt.args.seek) catch |err| return no(err));
                return yes();
            },
            .lock_record => {
                const lock = fs.fileOf(pkt.args.lock_record.fh) catch |err| return no(err);
                const records = fs.records orelse return no(error.NoMemory);
                return switch (records.lock(pkt, keyOf(lock.oid), lock)) {
                    .granted => yes(),
                    .refused => |code| noCode(code),
                    .waiting => .{ .res1 = 0, .res2 = 0, .held = true },
                };
            },
            .free_record => {
                const lock = fs.fileOf(pkt.args.free_record.fh) catch |err| return no(err);
                const records = fs.records orelse return noCode(dos.ERROR_RECORD_NOT_LOCKED);
                if (!records.unlock(pkt, keyOf(lock.oid), lock)) return noCode(dos.ERROR_RECORD_NOT_LOCKED);
                return yes();
            },
            .parent_fh, .copy_dir_fh => {
                const lock = fs.fileOf(pkt.args.file.fh) catch |err| return no(err);
                const object = lock.object();
                const target = if (pkt.getAction() == .parent_fh)
                    (fs.parentOf(object) catch |err| return no(err)) orelse return .{ .res1 = 0, .res2 = 0 }
                else
                    object;
                const got = fs.getLock(target, dos.SHARED_LOCK) catch |err| return no(err);
                return .{ .res1 = @bitCast(@intFromPtr(got)), .res2 = 0 };
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
                _ = fs.lockArg(lockValue(pkt.args.info.lock)) catch |err| return no(err);
                fs.info(pkt.args.info.info) catch |err| return no(err);
                return yes();
            },
            .disk_info => {
                fs.info(@ptrFromInt(ptrArg(a[0]))) catch |err| return no(err);
                return yes();
            },
            .flush => {
                fs.flush() catch |err| return no(err);
                return yes();
            },
            .rename_disk => {
                const given: ?[*:0]const u8 = @ptrFromInt(ptrArg(a[0]));
                fs.relabel(span(given orelse return no(error.BadName))) catch |err| return no(err);
                return yes();
            },
            .add_notify => {
                fs.addNotify(@ptrFromInt(ptrArg(a[0]))) catch |err| return no(err);
                return yes();
            },
            .remove_notify => {
                if (fs.watchers) |watchers| _ = watchers.remove(@ptrFromInt(ptrArg(a[0])));
                return yes();
            },
            .is_filesystem => return yes(),
            else => return fs.answerOwn(pkt),
        }
    }
};

/// How long a check waits for its next slice before it ends.
const check_timeout: u64 = 10_000_000;

/// The volume full: what the file system around it can give up.
fn makeRoomFor(vol: *Volume) Error!bool {
    const fs: *FileSystem = @alignCast(@fieldParentPtr("vol", vol));
    return fs.makeRoom();
}

comptime {
    if (packets.SET_RECYCLED != layout.VT_RECYCLED or packets.SET_CHECKSUMS != layout.VT_CHECKSUMS or packets.SET_COMPRESS != layout.VT_COMPRESS) @compileError("the switches moved");
}

/// The volume table's switches as a packet gives them, and back.
fn settingsOf(flags: u32) u32 {
    return flags & (layout.VT_RECYCLED | layout.VT_CHECKSUMS | layout.VT_COMPRESS);
}

fn flagsOf(settings: u32) u32 {
    return settings & (packets.SET_RECYCLED | packets.SET_CHECKSUMS | packets.SET_COMPRESS);
}

/// A packet's structure as its caller has it: the bytes its size says,
/// and the rest as T's defaults. One shorter than its size field is
/// refused.
fn takeStruct(comptime T: type, from: *const T) Error!T {
    const size = from.size;
    if (size < @sizeOf(u32)) return error.InvalidArgument;
    var value: T = .{};
    const len = @min(@as(usize, size), @sizeOf(T));
    @memcpy(layout.bytesOfMut(&value)[0..len], layout.bytesOf(from)[0..len]);
    value.size = @sizeOf(T);
    return value;
}

/// An answer into the caller's structure, as far as its size reaches; its
/// size stays the caller's.
fn giveStruct(comptime T: type, into: *T, value: *const T) Error!void {
    const size = into.size;
    if (size < @sizeOf(u32)) return error.InvalidArgument;
    const len = @min(@as(usize, size), @sizeOf(T));
    @memcpy(layout.bytesOfMut(into)[@sizeOf(u32)..len], layout.bytesOf(value)[@sizeOf(u32)..len]);
}

/// Text into a NUL-terminated buffer, as much as fits.
fn putText(into: []u8, len: *usize, text: []const u8) void {
    for (text) |char| {
        if (len.* + 1 >= into.len) return;
        into[len.*] = char;
        len.* += 1;
    }
}

fn putNumber(into: []u8, len: *usize, value: u64) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = @intCast('0' + rest % 10);
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        putText(into, len, digits[count..][0..1]);
    }
}

/// A soft link's target as dos takes it, in `into`: a part in Latin-1 as
/// it is, one with characters past it as its stand-in, which names it
/// here. Its length; null when it does not fit.
fn pathToDos(target: []const u8, into: []u8) ?usize {
    var len: usize = 0;
    var at: usize = 0;
    while (at <= target.len) {
        var cut = at;
        while (cut < target.len and target[cut] != '/' and target[cut] != ':') cut += 1;
        const part = target[at..cut];
        var shown: [posfs.max_name]u8 = undefined;
        const text = if (part.len <= posfs.max_name) fold.toDos(part, &shown) else part;
        if (text.len > into.len - len) return null;
        @memcpy(into[len..][0..text.len], text);
        len += text.len;
        if (cut == target.len) break;
        if (len == into.len) return null;
        into[len] = target[cut];
        len += 1;
        at = cut + 1;
    }
    return len;
}

/// A UTF-8 text as dos sees it for now: Latin-1, other characters `_`.
fn latinOf(text: []const u8, into: []u8) []const u8 {
    var len: usize = 0;
    var at: usize = 0;
    while (at < text.len and len < into.len) : (len += 1) {
        const code = fold.decode(text, &at) orelse {
            at += 1;
            into[len] = '_';
            continue;
        };
        into[len] = if (code <= 0xFF) @intCast(code) else '_';
    }
    return into[0..len];
}
