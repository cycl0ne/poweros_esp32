// SPDX-License-Identifier: MIT
//! The exFAT file system: the packets, the locks and the files, over the
//! bitmap (`bitmap.zig`), the table (`table.zig`), the directories
//! (`dir.zig`) and the up-case table (`upcase.zig`). `FileSystem(Media)` is
//! generic over the medium, so all of it is tested on the host.
//!
//! The packets, their arguments and their answers are FAT32's, RAM:'s and
//! the flash disk's - a program cannot tell them apart - and so are the
//! lock rules and the error codes. What is particular to this format:
//!
//! - **A key per object, and every key knows its parent's.** A directory
//!   has no ".." entry, so where an object is in the tree is known only
//!   from the walk that found it. A key holds its parent key (counted in
//!   the parent's `holds`), so PARENT, a path that goes up with a leading
//!   "/", and a check that a directory is not moved into itself all follow
//!   keys. A walk keeps the directories it passes in a trail and makes
//!   keys of them only when something is locked (`Walk`); a key nothing
//!   locks or holds is freed (`settle`).
//! - **Sizes and positions are 64 bits.** A file lists with its true size
//!   and is read and written straight through at any length. SEEK and
//!   SET_FILE_SIZE carry dos's isize, so a position past what that holds
//!   is answered ERROR_SEEK_ERROR.
//! - **A file's clusters are one run while they can be** - the stream says
//!   NoFatChain and the table is not touched. When the cluster after the
//!   run is taken, the run is linked through the table and goes on as a
//!   chain (`growOne`).
//! - **What a file holds up to its valid length is on the medium; past it
//!   up to its size it reads as zeroes.** Growing a file with
//!   SET_FILE_SIZE only moves the size; writing past the valid length
//!   writes the zeroes in between first.
//! - **The volume is marked dirty on the medium** before the first change
//!   and clean again once a packet leaves nothing half done - no file open
//!   that has been written to. A volume that was dirty when it was mounted
//!   is left dirty: it was not this handler that left it so.
//! - **Names** are `names.zig`'s: a name dos can hold as it is, otherwise
//!   its stand-in.
//! - **Moments are local time, in the system's zone** (the medium's
//!   `timeZone`, the rule the system clock is set by). A moment on the
//!   medium that says which zone it is in - its zone byte - is taken back
//!   to UTC with that zone and on into the system's; one that does not is
//!   shown as it is. What this writes is local time with the system's
//!   offset from UTC in its zone byte, so another system reads it right.
//! - **No comments, no owner**: SET_COMMENT and SET_OWNER answer
//!   ERROR_ACTION_NOT_KNOWN.
//! - **A watch holds its object's key** (notification), and so the keys
//!   above it, without making the object in use. With nothing in memory
//!   for an object nobody holds, a watch waiting for its name looks for it
//!   again by its path when an entry is made or renamed under that name,
//!   and when a volume is mounted.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const fat = dos.fat;
const notify = dos.notify;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const bitmap_area = @import("bitmap.zig");
const dir_area = @import("dir.zig");
const names = @import("names.zig");
const Upcase = @import("upcase.zig").Upcase;
const timezone = dos.timezone;
const Error = _fat.Error;
const Answer = _fat.Answer;
const Geometry = layout.Geometry;
const Chain = table_area.Chain;
const Place = table_area.Place;
const Dir = dir_area.Dir;
const Found = dir_area.Found;
const Set = dir_area.Set;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const DosPacket = dos.DosPacket;
const MsgPort = exec.MsgPort;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// Blocks the cache holds: the table, bitmap and directory blocks a
/// packet goes back to.
pub const cache_blocks: u32 = 32;

/// How many directories below the lock it starts from a walk keeps
/// without making keys of them. A path deeper than this is refused.
const max_depth: usize = 48;

/// One object on the volume, however many locks are on it.
const Key = struct {
    next: ?*Key = null,
    /// Locks and open files on it, keys whose parent it is, and watches
    /// on it. A watch keeps the key but does not make the object in use.
    locks: u32 = 0,
    holds: u32 = 0,
    watched: u32 = 0,
    /// The directory it is in; null for the root.
    parent: ?*Key = null,
    is_root: bool = false,
    /// Its file entry's index in its parent - meaningless for the root.
    index: u32 = 0,
    chain: Chain = .{},
    /// Clusters it has, how much of it has been written, and its size.
    clusters: u64 = 0,
    valid: u64 = 0,
    size: u64 = 0,
    attr: u16 = 0,
    /// What is in its entry is behind what is here.
    changed: bool = false,
    /// The medium changed under it: nothing it says is true any more.
    stale: bool = false,

    fn isDir(key: *const Key) bool {
        return key.is_root or key.attr & _fat.ATTR_DIRECTORY != 0;
    }

    pub fn dir(key: *const Key) Dir {
        return .{ .chain = key.chain, .length = key.size };
    }
};

/// Where a lock is in its file's chain.
const FileLockEx = extern struct {
    lock: FileLock,
    pos: u64 align(4) = 0,
    ordinal: u64 align(4) = 0,
    cluster: u32 = 0,
    modified: bool = false,

    fn key(lock: *const FileLockEx) *Key {
        return @ptrFromInt(lock.lock.key);
    }

    fn nextLock(lock: *const FileLockEx) ?*FileLockEx {
        const n = lock.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", n));
    }

    fn place(lock: *FileLockEx) Place {
        return .{ .ordinal = lock.ordinal, .cluster = lock.cluster };
    }

    fn setPlace(lock: *FileLockEx, where: Place) void {
        lock.ordinal = where.ordinal;
        lock.cluster = where.cluster;
    }
};

/// A directory a walk passed below its base, found but not keyed.
const Step = struct {
    index: u32,
    chain: Chain,
    size: u64,
};

/// Where a walk through a path is: a key, and the directories below it
/// it went down into since.
const Walk = struct {
    base: *Key,
    steps: [max_depth]Step = undefined,
    depth: usize = 0,

    fn dir(walk: *const Walk) Dir {
        if (walk.depth == 0) return walk.base.dir();
        const step = walk.steps[walk.depth - 1];
        return .{ .chain = step.chain, .length = step.size };
    }

    fn down(walk: *Walk, found: *const Found) Error!void {
        if (walk.depth == max_depth) return error.InvalidName;
        walk.steps[walk.depth] = .{ .index = found.index, .chain = found.chain(), .size = found.size };
        walk.depth += 1;
    }

    fn up(walk: *Walk) Error!void {
        if (walk.depth > 0) {
            walk.depth -= 1;
            return;
        }
        walk.base = walk.base.parent orelse return error.NotFound;
    }
};

/// Something a path names: a key (the lock it started from, or the
/// root), or an entry and the walk to the directory it is in.
const Object = struct {
    self_key: ?*Key = null,
    walk: *Walk,
    found: Found = .{},
};

fn yes() Answer {
    return _fat.yes();
}

fn no(err: Error) Answer {
    return _fat.no(_fat.codeOf(err));
}

/// For READ, WRITE, SEEK and SET_FILE_SIZE, which answer -1 on failure.
fn minusOne(err: Error) Answer {
    return .{ .res1 = -1, .res2 = _fat.codeOf(err) };
}

fn ptrArg(value: isize) usize {
    return @bitCast(value);
}

fn lockValue(lock: ?*FileLock) isize {
    return @bitCast(@intFromPtr(lock));
}

pub fn FileSystem(comptime Media: type) type {
    return struct {
        const Fs = @This();
        const Cache = cache_area.BlockCache(Media);
        const Table = table_area.Table(Media);
        const Bitmap = bitmap_area.Bitmap(Media);
        const Directory = dir_area.Directory(Media);

        media: *Media,
        ub: *UtilityBase,
        /// The handler's port (fl_Task of its locks).
        port: ?*MsgPort = null,
        /// The volume's DosList node (fl_Volume of its locks).
        volume_node: ?*dos.DosList = null,
        /// Who watches what (notification), when the handler has given
        /// it watchers, and the device's name, which a watch may be
        /// named on as well as the volume's.
        watchers: ?*notify.Watchers = null,
        device_name: []const u8 = "",

        geo: Geometry = undefined,
        cache: Cache = undefined,
        table: Table = undefined,
        bitmap: Bitmap = undefined,
        upcase: Upcase = .{ .map = &.{} },
        dirs: Directory = undefined,
        /// One sector, for the part of a sector a read or write does not
        /// cover, and for what goes around the cache.
        sector: []u8 = &.{},
        /// The two walks a packet may need at once: a rename's from and to.
        walks: [2]Walk = undefined,
        root_key: ?*Key = null,
        keys: ?*Key = null,
        locks: ?*FileLockEx = null,
        mounted: bool = false,
        /// Whether this handler marked the volume dirty, and whether it
        /// was so already when mounted.
        dirty: bool = false,
        found_dirty: bool = false,
        /// The medium's change count when the volume was read.
        change_num: u32 = 0,
        /// The zone the system clock keeps, read when the volume is.
        zone: timezone.Zone = .{},
        /// The volume's name, as the device list shows it.
        name_buf: [fat.exfat_label_max * 2]u8 = @splat(0),
        name_len: usize = 0,

        pub fn init(media: *Media, ub: *UtilityBase, port: ?*MsgPort) Fs {
            return .{ .media = media, .ub = ub, .port = port };
        }

        pub fn deinit(fs: *Fs) void {
            fs.unmount();
            var remaining = fs.locks;
            while (remaining) |lock| {
                const following = lock.nextLock();
                fs.free(lock);
                remaining = following;
            }
            fs.locks = null;
            var key = fs.keys;
            while (key) |other| {
                const following = other.next;
                fs.free(other);
                key = following;
            }
            fs.keys = null;
        }

        // --- memory ---------------------------------------------------------

        fn alloc(fs: *Fs, comptime T: type) ?*T {
            const block = fs.media.alloc(@sizeOf(T)) orelse return null;
            return @ptrCast(@alignCast(block.ptr));
        }

        fn free(fs: *Fs, p: anytype) void {
            const bytes: [*]u8 = @ptrCast(p);
            fs.media.free(bytes[0..@sizeOf(@TypeOf(p.*))]);
        }

        // --- mounting -------------------------------------------------------

        /// The volume on the medium, found through its partition table if
        /// it has one. Every key there was is stale from here on.
        pub fn mount(fs: *Fs) Error!void {
            fs.unmount();
            fs.change_num = fs.media.changeNum();
            if (!fs.media.present()) return error.MediumFailed;
            // Asking is what makes a device that has not looked yet
            // identify its card, and count it: the count is the one after.
            fs.change_num = fs.media.changeNum();
            const block_bytes = fs.media.blockSize();
            fs.sector = fs.media.alloc(block_bytes) orelse return error.NoMemory;
            errdefer {
                fs.media.free(fs.sector);
                fs.sector = &.{};
            }

            const volume = try _fat.findVolume(fs.media, fs.sector);
            if (volume.format != .exfat) return error.MediumFailed;
            if (!fs.media.read(volume.first, 1, fs.sector)) return error.MediumFailed;
            fs.geo = try Geometry.of(fs.sector, volume.first, fs.media.blocks(), block_bytes);
            if (!layout.checksumHolds(fs.media, volume.first, fs.sector)) return error.MediumFailed;
            fs.found_dirty = fs.geo.flags & fat.exfat_volume_dirty != 0;
            fs.zone = fs.media.timeZone();
            fs.dirty = false;

            fs.cache = Cache.init(fs.media, cache_blocks) catch return error.NoMemory;
            errdefer fs.cache.deinit();
            fs.table = Table.init(&fs.cache, &fs.geo);
            fs.dirs = .{ .cache = &fs.cache, .table = &fs.table, .geo = &fs.geo, .upcase = &fs.upcase, .ub = fs.ub };

            const root_chain: Chain = .{ .first = fs.geo.root_cluster };
            const root_clusters = try fs.table.length(fs.geo.root_cluster);
            const root_dir: Dir = .{ .chain = root_chain, .length = root_clusters * fs.geo.cluster_bytes };
            const system = try fs.dirs.system(root_dir);
            fs.upcase = try Upcase.load(Media, fs.media, &fs.cache, &fs.table, &fs.geo, system.upcase_first, system.upcase_length, system.upcase_checksum, fs.sector);
            errdefer fs.upcase.deinit(Media, fs.media);
            fs.bitmap = try Bitmap.init(&fs.cache, &fs.geo, &fs.table, system.bitmap_first, system.bitmap_length, fs.sector);

            const root = fs.alloc(Key) orelse return error.NoMemory;
            root.* = .{
                .is_root = true,
                .chain = root_chain,
                .clusters = root_clusters,
                .size = root_dir.length,
                .valid = root_dir.length,
                .attr = _fat.ATTR_DIRECTORY,
            };
            fs.root_key = root;
            fs.mounted = true;
            fs.nameVolume(&system);
            fs.arrive("", true);
        }

        /// Everything the volume held in memory written back and given up;
        /// every key left is stale.
        pub fn unmount(fs: *Fs) void {
            fs.release(true);
        }

        /// The same, and with `write_back` false nothing is written: for a
        /// medium that has changed, where whatever is held belongs to a
        /// card that is no longer there.
        fn release(fs: *Fs, write_back: bool) void {
            fs.forsakeAll();
            if (fs.mounted) {
                if (write_back) {
                    _ = fs.cache.flush() catch {};
                    fs.clearDirty();
                } else {
                    fs.cache.invalidate();
                }
                fs.upcase.deinit(Media, fs.media);
                fs.cache.deinit();
                fs.mounted = false;
            }
            if (fs.sector.len != 0) {
                fs.media.free(fs.sector);
                fs.sector = &.{};
            }
            if (fs.root_key) |root| {
                root.stale = true;
                fs.root_key = null;
                // The root goes with the volume unless a lock or a key
                // below it holds it; then the last of those frees it.
                if (root.locks == 0 and root.holds == 0) fs.free(root) else {
                    root.next = fs.keys;
                    fs.keys = root;
                }
            }
            var key = fs.keys;
            while (key) |other| : (key = other.next) other.stale = true;
        }

        /// Whether the medium is still the one mounted. If not, what was
        /// held is dropped without being written and the new one mounted.
        /// True if anything changed, so the caller renews the volume node.
        pub fn checkMedium(fs: *Fs) bool {
            if (!fs.mounted) _ = fs.media.present();
            if (fs.media.changeNum() == fs.change_num) return false;
            fs.release(false);
            fs.mount() catch {};
            return true;
        }

        /// The volume's name: its label, or its serial number as a PC
        /// shows it. A character of the label dos cannot hold is `_`.
        fn nameVolume(fs: *Fs, system: *const dir_area.System) void {
            if (system.label_len > 0) {
                for (system.label[0..system.label_len], 0..) |unit, at| {
                    fs.name_buf[at] = if (unit <= 0xFF and unit >= 0x20) @intCast(unit) else '_';
                }
                fs.name_len = system.label_len;
                return;
            }
            const digits = "0123456789ABCDEF";
            var at: usize = 0;
            var shift: u5 = 28;
            while (true) : (shift -= 4) {
                if (at == 4) {
                    fs.name_buf[at] = '-';
                    at += 1;
                }
                fs.name_buf[at] = digits[(fs.geo.serial >> shift) & 0xF];
                at += 1;
                if (shift == 0) break;
            }
            fs.name_len = at;
        }

        pub fn volumeName(fs: *const Fs) []const u8 {
            return fs.name_buf[0..fs.name_len];
        }

        /// ACTION_RENAME_DISK: the root directory's label entry, written
        /// over or made in a free entry, holding up to eleven characters
        /// as UTF-16. A longer name is refused.
        fn relabel(fs: *Fs, name: []const u8) Error!void {
            if (name.len > fat.exfat_label_max or !dos.volumename.valid(name)) return error.InvalidName;
            try fs.changing();
            const root_key = try fs.rootKey();
            const root = root_key.dir();
            var entry: [fat.entry_bytes]u8 = @splat(0);
            entry[0] = fat.exfat_type_label;
            entry[fat.exfat_label_length] = @intCast(name.len);
            for (name, 0..) |char, at| fat.putU16(&entry, fat.exfat_label_chars + at * 2, char);
            var system = try fs.dirs.system(root);
            const index = system.label_index orelse (try fs.dirs.room(root, 1)) orelse grown: {
                try fs.growDir(root_key);
                break :grown try fs.dirs.room(root_key.dir(), 1) orelse return error.DiskFull;
            };
            try fs.dirs.writeEntry(root_key.dir(), index, &entry);
            system.label_len = name.len;
            for (name, 0..) |char, at| system.label[at] = char;
            fs.nameVolume(&system);
        }

        // --- the dirty flag -------------------------------------------------

        /// The boot sector's VolumeFlags and PercentInUse, written straight
        /// to the medium: they are outside its checksum, and the backup
        /// region's are left as they are.
        fn writeFlags(fs: *Fs, dirty: bool) Error!void {
            const boot = fs.geo.bootBlock();
            fs.cache.readRun(boot, 1, fs.sector) catch return error.MediumFailed;
            var flags = fat.u16At(fs.sector, fat.exfat_volume_flags);
            flags = if (dirty) flags | fat.exfat_volume_dirty else flags & ~fat.exfat_volume_dirty;
            fat.putU16(fs.sector, fat.exfat_volume_flags, flags);
            const used = fs.geo.cluster_count - fs.bitmap.free_count;
            fs.sector[fat.exfat_percent_in_use] = if (dirty) fat.exfat_percent_unknown else @intCast(@as(u64, used) * 100 / fs.geo.cluster_count);
            fs.cache.writeRun(boot, 1, fs.sector) catch return error.MediumFailed;
        }

        /// About to change the volume: it must take writes, and it is
        /// marked dirty first, so a card pulled half way through is known
        /// to need checking.
        fn changing(fs: *Fs) Error!void {
            if (!fs.media.writable()) return error.WriteProtected;
            if (fs.dirty or fs.found_dirty) return;
            try fs.writeFlags(true);
            fs.dirty = true;
        }

        /// Clean again, if this handler made it dirty and nothing is left
        /// half done: no open file has been written to.
        fn clearDirty(fs: *Fs) void {
            if (!fs.dirty) return;
            var it = fs.locks;
            while (it) |lock| : (it = lock.nextLock()) if (lock.modified) return;
            fs.writeFlags(false) catch return;
            fs.dirty = false;
        }

        // --- keys and locks -------------------------------------------------

        fn rootKey(fs: *Fs) Error!*Key {
            return fs.root_key orelse error.MediumFailed;
        }

        /// The key of the object at `index` in `parent`, the one already
        /// there if it has one. A new key holds its parent.
        fn keyFor(fs: *Fs, parent: *Key, index: u32, found: ?*const Found, step: ?Step) Error!*Key {
            if (fs.childKey(parent, index)) |other| return other;
            const key = fs.alloc(Key) orelse return error.NoMemory;
            if (found) |entry| {
                key.* = .{
                    .next = fs.keys,
                    .parent = parent,
                    .index = index,
                    .chain = entry.chain(),
                    .clusters = if (entry.chain().first == 0) 0 else fs.geo.clustersFor(entry.size),
                    .valid = entry.valid,
                    .size = entry.size,
                    .attr = entry.attr,
                };
            } else {
                const dir = step.?;
                key.* = .{
                    .next = fs.keys,
                    .parent = parent,
                    .index = index,
                    .chain = dir.chain,
                    .clusters = if (dir.chain.first == 0) 0 else fs.geo.clustersFor(dir.size),
                    .valid = dir.size,
                    .size = dir.size,
                    .attr = _fat.ATTR_DIRECTORY,
                };
            }
            fs.keys = key;
            parent.holds += 1;
            return key;
        }

        /// A walk's directory as a key: the base, and a key for every
        /// directory below it. The walk then stands on that key.
        fn keyOfWalk(fs: *Fs, walk: *Walk) Error!*Key {
            var key = walk.base;
            for (walk.steps[0..walk.depth]) |step| key = try fs.keyFor(key, step.index, null, step);
            walk.base = key;
            walk.depth = 0;
            return key;
        }

        /// The key of an object, made if it has none.
        fn keyOf(fs: *Fs, object: *Object) Error!*Key {
            if (object.self_key) |key| return key;
            const dir_key = try fs.keyOfWalk(object.walk);
            errdefer fs.settle(dir_key);
            return fs.keyFor(dir_key, object.found.index, &object.found, null);
        }

        /// The key of the object at `index` in `parent`, if it has one.
        fn childKey(fs: *Fs, parent: *const Key, index: u32) ?*Key {
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (!other.stale and other.parent == parent and other.index == index) return other;
            }
            return null;
        }

        /// The key of a walk's directory if it has one: the walk followed
        /// down through the keys there are.
        fn walkKey(fs: *Fs, walk: *const Walk) ?*Key {
            var dir = walk.base;
            for (walk.steps[0..walk.depth]) |step| dir = fs.childKey(dir, step.index) orelse return null;
            return dir;
        }

        /// The key of an object if it has one. An object whose directory
        /// has no key has none.
        fn existingKey(fs: *Fs, object: *const Object) ?*Key {
            if (object.self_key) |key| return key;
            const dir = fs.walkKey(object.walk) orelse return null;
            return fs.childKey(dir, object.found.index);
        }

        fn unlinkKey(fs: *Fs, key: *Key) void {
            if (fs.keys == key) {
                fs.keys = key.next;
                return;
            }
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (other.next == key) {
                    other.next = key.next;
                    return;
                }
            }
        }

        /// A key nothing locks, holds or watches any more freed, and its
        /// parent after it if that leaves the parent the same.
        fn settle(fs: *Fs, from: *Key) void {
            var key = from;
            while (key != fs.root_key and key.locks == 0 and key.holds == 0 and key.watched == 0) {
                const parent = key.parent;
                fs.unlinkKey(key);
                fs.free(key);
                const up = parent orelse return;
                up.holds -= 1;
                key = up;
            }
        }

        /// How many of this body's locks and open files point at `node` as
        /// their volume: the handler keeps a volume node it has taken off
        /// the device list until none does.
        pub fn locksOn(fs: *Fs, node: *dos.DosList) u32 {
            var count: u32 = 0;
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.lock.volume == node) count += 1;
            }
            return count;
        }

        /// Whether a lock - a FileLock's address, or a file handle's key -
        /// is one this body made: for the handler, which keeps a body per
        /// format, to hand a packet about a lock to the one it belongs to.
        pub fn holdsLock(fs: *Fs, address: usize) bool {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) if (@intFromPtr(other) == address) return true;
            return false;
        }

        fn owns(fs: *Fs, lock: *FileLockEx) bool {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) if (other == lock) return true;
            return false;
        }

        /// A lock from a packet: one of ours, or null for the root. A lock
        /// from a card that has gone is no longer any good.
        fn lockArg(fs: *Fs, value: isize) Error!?*FileLockEx {
            if (value == 0) return null;
            const lock: *FileLockEx = @ptrFromInt(ptrArg(value));
            if (!fs.owns(lock)) return error.InvalidLock;
            if (lock.key().stale) return error.InvalidLock;
            return lock;
        }

        /// The key a lock from a packet stands for (null: the root).
        fn keyArg(fs: *Fs, value: isize) Error!*Key {
            const lock = try fs.lockArg(value) orelse return fs.rootKey();
            return lock.key();
        }

        /// A new lock on a key: shared locks go together, an exclusive one
        /// wants the object to itself.
        fn getLock(fs: *Fs, key: *Key, access: i32) Error!*FileLockEx {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.key() == key and (access == dos.EXCLUSIVE_LOCK or other.lock.access == dos.EXCLUSIVE_LOCK)) return error.InUse;
            }
            const lock = fs.alloc(FileLockEx) orelse return error.NoMemory;
            lock.* = .{ .lock = .{
                .link = if (fs.locks) |head| &head.lock else null,
                .key = @intFromPtr(key),
                .access = if (access == dos.EXCLUSIVE_LOCK) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK,
                .task = fs.port,
                .volume = fs.volume_node,
            } };
            fs.locks = lock;
            key.locks += 1;
            return lock;
        }

        /// A lock on a key, or - if it cannot be had - the key settled so a
        /// key made for it does not stay behind.
        fn lockKey(fs: *Fs, key: *Key, access: i32) Error!*FileLockEx {
            return fs.getLock(key, access) catch |err| {
                fs.settle(key);
                return err;
            };
        }

        fn freeLock(fs: *Fs, lock: *FileLockEx) void {
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
            const key = lock.key();
            fs.free(lock);
            key.locks -= 1;
            fs.settle(key);
        }

        /// Whether a lock but `lock` is on the key (with `exclusive_only`,
        /// an exclusive one).
        fn otherLock(fs: *Fs, key: *Key, lock: ?*FileLockEx, exclusive_only: bool) bool {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other == lock or other.key() != key) continue;
                if (!exclusive_only or other.lock.access == dos.EXCLUSIVE_LOCK) return true;
            }
            return false;
        }

        // --- notification -----------------------------------------------------

        /// An object changed: its watchers told.
        fn tell(fs: *Fs, key: *Key) void {
            if (key.watched == 0) return;
            if (fs.watchers) |watchers| watchers.changed(key);
        }

        /// An object gone from where it was - deleted, renamed away: its
        /// watches wait for its name again, and its key is let go of.
        fn forsake(fs: *Fs, key: *Key) void {
            if (key.watched == 0) return;
            if (fs.watchers) |watchers| watchers.orphan(key);
            key.watched = 0;
            fs.settle(key);
        }

        /// The volume gone: every watch on it waits for its name, on the
        /// card that comes next. Letting a key go may free the keys above
        /// it, so the list is looked through again after each.
        fn forsakeAll(fs: *Fs) void {
            if (fs.root_key) |root| fs.forsake(root);
            while (true) {
                var it = fs.keys;
                const watched = while (it) |key| : (it = key.next) {
                    if (key.watched != 0) break key;
                } else break;
                fs.forsake(watched);
            }
        }

        /// Something came to be under `name` - made, or renamed there - or,
        /// with "", a volume was mounted: the watches waiting for such a
        /// name look for it again, and with `tell_them` those that find it
        /// are told.
        fn arrive(fs: *Fs, name: []const u8, tell_them: bool) void {
            const watchers = fs.watchers orelse return;
            watchers.settle(Arrival{ .fs = fs, .name = name }, Arrival.find, tell_them);
        }

        const Arrival = struct {
            fs: *Fs,
            name: []const u8,

            fn find(arrival: Arrival, request: *notify.NotifyRequest) ?*anyopaque {
                const fs = arrival.fs;
                if (!_fat.endsIn(fs.ub, notify.Watchers.pathOf(request), arrival.name)) return null;
                return fs.watchKey(request);
            }
        };

        /// The key of the object a request names, held for its watch; null
        /// when it is not there, or the request names another volume.
        fn watchKey(fs: *Fs, request: *notify.NotifyRequest) ?*Key {
            if (!fs.mounted) return null;
            if (!_fat.watchedHere(fs.ub, request, fs.volumeName(), fs.device_name)) return null;
            const full = request.full_name orelse return null;
            var object: Object = .{ .walk = &fs.walks[0] };
            fs.locate(0, full, &object) catch return null;
            const key = fs.keyOf(&object) catch return null;
            key.watched += 1;
            return key;
        }

        /// ADD_NOTIFY: the request watched on the object its name names,
        /// or on its name until one does.
        fn addNotify(fs: *Fs, request: *notify.NotifyRequest) Error!void {
            const watchers = fs.watchers orelse return error.NoMemory;
            const key = fs.watchKey(request);
            if (watchers.add(request, key)) return;
            if (key) |held| {
                held.watched -= 1;
                fs.settle(held);
            }
            return error.NoMemory;
        }

        /// REMOVE_NOTIFY: the request's watch dropped, and its key let go.
        fn removeNotify(fs: *Fs, request: *notify.NotifyRequest) void {
            const watchers = fs.watchers orelse return;
            const held: ?*Key = @ptrCast(@alignCast(watchers.keyOf(request)));
            if (!watchers.remove(request)) return;
            if (held) |key| {
                key.watched -= 1;
                fs.settle(key);
            }
        }

        // --- paths ----------------------------------------------------------

        /// Walk the directories of `path` from `start`, the device dropped
        /// and "" going up; the last part is answered.
        fn walkTo(fs: *Fs, walk: *Walk, start: *Key, path: [*:0]const u8) Error![]const u8 {
            var s = path[0..fs.ub.Strlen(path)];
            for (s, 0..) |char, at| if (char == ':') {
                s = s[at + 1 ..];
                break;
            };
            if (!start.isDir()) return error.WrongType;
            walk.* = .{ .base = start };
            var found: Found = .{};
            while (true) {
                var slash: ?usize = null;
                for (s, 0..) |char, at| if (char == '/') {
                    slash = at;
                    break;
                };
                const cut = slash orelse return s;
                const part = s[0..cut];
                s = s[cut + 1 ..];
                if (part.len == 0) {
                    try walk.up();
                    continue;
                }
                if (part.len > fat.name_max) return error.InvalidName;
                var wanted: names.Wanted = undefined;
                wanted.init(part, &fs.upcase);
                if (!try fs.dirs.find(walk.dir(), &wanted, &found)) return error.NotFound;
                if (!found.isDir()) return error.WrongType;
                try walk.down(&found);
            }
        }

        /// The object a path names, from the key a lock stands for.
        fn locate(fs: *Fs, dir_arg: isize, path: [*:0]const u8, object: *Object) Error!void {
            const start = try fs.keyArg(dir_arg);
            object.* = .{ .walk = object.walk };
            if (path[0] == 0) {
                object.self_key = start;
                return;
            }
            const name = try fs.walkTo(object.walk, start, path);
            if (name.len == 0) {
                // The directory the path ends in, itself.
                const walk = object.walk;
                if (walk.depth == 0) {
                    object.self_key = walk.base;
                    return;
                }
                const step = walk.steps[walk.depth - 1];
                walk.depth -= 1;
                if (!try fs.dirs.load(walk.dir(), step.index, &object.found)) return error.MediumFailed;
                return;
            }
            if (name.len > fat.name_max) return error.InvalidName;
            var wanted: names.Wanted = undefined;
            wanted.init(name, &fs.upcase);
            if (!try fs.dirs.find(object.walk.dir(), &wanted, &object.found)) return error.NotFound;
        }

        /// Whether an object is a directory.
        fn objectIsDir(object: *const Object) bool {
            if (object.self_key) |key| return key.isDir();
            return object.found.isDir();
        }

        // --- clusters -------------------------------------------------------

        /// One more cluster on the end of a key's chain: after its last if
        /// that is free, which keeps a run a run; anywhere else otherwise,
        /// and a run is then linked through the table first.
        fn growOne(fs: *Fs, key: *Key) Error!u32 {
            if (key.clusters == 0) {
                const cluster = try fs.bitmap.allocate();
                key.chain = .{ .first = cluster, .contiguous = true };
                key.clusters = 1;
                key.changed = true;
                return cluster;
            }
            var place: Place = .{};
            const last = try fs.table.clusterAt(key.chain, &place, key.clusters - 1);
            if (key.chain.contiguous and try fs.bitmap.allocateAfter(last)) {
                key.clusters += 1;
                key.changed = true;
                return last + 1;
            }
            const cluster = try fs.bitmap.allocate();
            if (key.chain.contiguous) {
                try fs.table.link(key.chain.first, key.clusters);
                key.chain.contiguous = false;
            }
            try fs.table.set(last, cluster);
            try fs.table.set(cluster, fat.exfat_eoc);
            key.clusters += 1;
            key.changed = true;
            return cluster;
        }

        /// The cluster `ordinal` steps into a key's chain, taking clusters
        /// where the chain runs out.
        fn clusterFor(fs: *Fs, key: *Key, place: *Place, ordinal: u64) Error!u32 {
            while (key.clusters <= ordinal) _ = try fs.growOne(key);
            return fs.table.clusterAt(key.chain, place, ordinal);
        }

        /// A key's chain cut to its first `keep` clusters, the rest given
        /// back to the bitmap.
        fn cutChain(fs: *Fs, key: *Key, keep: u64) Error!void {
            if (keep >= key.clusters) return;
            if (key.chain.contiguous) {
                var ordinal = keep;
                while (ordinal < key.clusters) : (ordinal += 1) try fs.bitmap.release(@intCast(key.chain.first + ordinal));
            } else {
                var place: Place = .{};
                var cluster: ?u32 = if (keep == 0) key.chain.first else blk: {
                    const last = try fs.table.clusterAt(key.chain, &place, keep - 1);
                    const following = try fs.table.next(last);
                    try fs.table.set(last, fat.exfat_eoc);
                    break :blk following;
                };
                var freed: u64 = 0;
                while (cluster) |this| : (freed += 1) {
                    if (freed >= key.clusters - keep) break;
                    const following = try fs.table.next(this);
                    try fs.bitmap.release(this);
                    cluster = following;
                }
            }
            key.clusters = keep;
            if (keep == 0) key.chain = .{};
            key.changed = true;
        }

        // --- entries ----------------------------------------------------------

        fn now(fs: *Fs) u32 {
            return dir_area.momentOf(_fat.stampOf(fs.ub, fs.media.now()));
        }

        /// Seconds since the DateStamp epoch for a DateStamp, and back.
        fn secondsOf(when: dos.DateStamp) i64 {
            return @as(i64, when.days) * 86400 + @as(i64, when.minute) * 60 + @divTrunc(@as(i64, when.tick), _fat.ticks_per_second);
        }

        fn dateStampOf(seconds: i64) dos.DateStamp {
            const whole = @max(seconds, 0);
            return .{
                .days = @intCast(@divTrunc(whole, 86400)),
                .minute = @intCast(@divTrunc(@mod(whole, 86400), 60)),
                .tick = @intCast(@mod(whole, 60) * _fat.ticks_per_second),
            };
        }

        /// The zone byte a local moment is written with: the system's
        /// offset from UTC then, in quarter hours, marked as there.
        fn zoneByte(fs: *Fs, moment: u32) u8 {
            const local = secondsOf(_fat.dateOf(fs.ub, dir_area.stampOf(moment)));
            // The offset is the zone's at that moment in UTC; the standard
            // offset is near enough to find which it is.
            const utc = local - fs.zone.standard;
            const offset = fs.zone.offsetAt(utc + timezone.datestamp_epoch);
            const quarters: i8 = @intCast(@divTrunc(offset, 900));
            return fat.exfat_utc_valid | (@as(u8, @bitCast(quarters)) & 0x7F);
        }

        /// A moment on the medium as a DateStamp in the system's zone.
        fn shownDate(fs: *Fs, moment: u32, zone: u8) dos.DateStamp {
            const stored = _fat.dateOf(fs.ub, dir_area.stampOf(moment));
            if (zone & fat.exfat_utc_valid == 0) return stored;
            // Seven bits, signed: quarter hours east of UTC.
            const raw: i32 = zone & 0x7F;
            const quarters: i32 = if (raw & 0x40 != 0) raw - 128 else raw;
            const utc = secondsOf(stored) - @as(i64, quarters) * 900;
            return dateStampOf(utc + fs.zone.offsetAt(utc + timezone.datestamp_epoch));
        }

        /// What a key says - where its data is, how much, its attributes -
        /// written into its entry, and with a moment its date too.
        fn syncKey(fs: *Fs, key: *Key, when: ?u32) Error!void {
            if (key.is_root or key.stale) return;
            if (!key.changed and when == null) return;
            const parent = key.parent orelse return;
            var set: Set = .{};
            if (!try fs.dirs.readSet(parent.dir(), key.index, &set)) return error.MediumFailed;
            set.setStream(key.chain, key.valid, key.size);
            if (when) |moment| {
                set.setModified(moment, fs.zoneByte(moment), false);
                if (!key.isDir()) key.attr |= _fat.ATTR_ARCHIVE;
            }
            set.setAttributes(key.attr);
            try fs.dirs.writeSet(parent.dir(), key.index, &set);
            key.changed = false;
        }

        /// A directory one cluster longer: taken, cleared, and its length
        /// written into its entry (the root's is its chain's).
        fn growDir(fs: *Fs, dir_key: *Key) Error!void {
            const cluster = try fs.growOne(dir_key);
            try fs.dirs.clear(cluster, fs.sector);
            dir_key.size = dir_key.clusters * fs.geo.cluster_bytes;
            dir_key.valid = dir_key.size;
            try fs.syncKey(dir_key, null);
        }

        /// A set written into a directory, which grows if it has no room
        /// for it. The index it went to.
        fn placeSet(fs: *Fs, dir_key: *Key, set: *Set) Error!u32 {
            while (true) {
                if (try fs.dirs.room(dir_key.dir(), set.count)) |index| {
                    try fs.dirs.writeSet(dir_key.dir(), index, set);
                    return index;
                }
                try fs.growDir(dir_key);
            }
        }

        /// A new file or directory, written down and locked.
        fn create(fs: *Fs, dir_arg: isize, path: [*:0]const u8, directory: bool, access: i32) Error!*FileLockEx {
            const start = try fs.keyArg(dir_arg);
            const walk = &fs.walks[0];
            const name = try fs.walkTo(walk, start, path);
            try _fat.validLong(name);
            var wanted: names.Wanted = undefined;
            wanted.init(name, &fs.upcase);
            var found: Found = .{};
            if (try fs.dirs.find(walk.dir(), &wanted, &found)) return error.Exists;
            try fs.changing();

            // Held while this works: the new file's key holds it after, and
            // if anything fails on the way it is settled once, here.
            const dir_key = try fs.keyOfWalk(walk);
            dir_key.locks += 1;
            defer {
                dir_key.locks -= 1;
                fs.settle(dir_key);
            }
            var units: [fat.name_max]u16 = undefined;
            const utf16 = names.fromDos(name, &units);
            var set: Set = .{};
            const attr: u16 = if (directory) _fat.ATTR_DIRECTORY else _fat.ATTR_ARCHIVE;
            const moment = fs.now();
            set.compose(utf16, fs.upcase.hash(utf16), attr, moment, fs.zoneByte(moment));
            var made: Key = .{};
            if (directory) {
                const cluster = try fs.growOne(&made);
                errdefer fs.bitmap.release(cluster) catch {};
                try fs.dirs.clear(cluster, fs.sector);
                made.size = fs.geo.cluster_bytes;
                made.valid = made.size;
                set.setStream(made.chain, made.valid, made.size);
            }
            const index = try fs.placeSet(dir_key, &set);
            if (!try fs.dirs.load(dir_key.dir(), index, &found)) return error.MediumFailed;
            const key = try fs.keyFor(dir_key, index, &found, null);
            const lock = try fs.lockKey(key, access);
            if (!directory) lock.modified = true;
            // A file is told of when it is closed, and its directory with
            // it; a directory now.
            fs.arrive(name, directory);
            if (directory) fs.tell(dir_key);
            return lock;
        }

        fn delete(fs: *Fs, dir_arg: isize, path: [*:0]const u8) Error!void {
            var object: Object = .{ .walk = &fs.walks[0] };
            try fs.locate(dir_arg, path, &object);
            if (object.self_key != null) return error.InUse;
            const found = &object.found;
            // A key only watches keep does not make it in use.
            const key = fs.existingKey(&object);
            if (key) |held| if (held.locks != 0 or held.holds != 0) return error.InUse;
            if (_fat.protectionOf(@truncate(found.attr)) & dos.FIBF_DELETE != 0) return error.DeleteProtected;
            if (found.isDir() and !try fs.dirs.empty(.{ .chain = found.chain(), .length = found.size })) return error.NotEmpty;
            try fs.changing();
            try fs.dirs.erase(object.walk.dir(), found.index, found.count);
            // Told it went, and its directory; then let go: its watches
            // wait for its name.
            const dir_key = if (key) |gone| gone.parent else fs.walkKey(object.walk);
            if (key) |gone| fs.tell(gone);
            if (dir_key) |dir| fs.tell(dir);
            if (key) |gone| fs.forsake(gone);
            // Its clusters back, whichever way they are kept.
            var gone: Key = .{ .chain = found.chain(), .clusters = if (found.chain().first == 0) 0 else fs.geo.clustersFor(found.size) };
            try fs.cutChain(&gone, 0);
        }

        // --- files ----------------------------------------------------------

        fn fileOf(fs: *Fs, fh: ?*FileHandle) Error!*FileLockEx {
            const handle = fh orelse return error.InvalidLock;
            const lock: *FileLockEx = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
            if (!fs.owns(lock)) return error.InvalidLock;
            if (lock.key().stale) return error.InvalidLock;
            return lock;
        }

        /// Every lock on a key whose place in the chain may be gone starts
        /// again from the beginning, its position kept inside `size`.
        fn forgetPlaces(fs: *Fs, key: *Key, size: u64) void {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.key() != key) continue;
                other.setPlace(.{});
                if (other.pos > size) other.pos = size;
            }
        }

        /// FINDINPUT (an existing file, shared), FINDOUTPUT (a new or
        /// emptied file, exclusive), FINDUPDATE (an existing or new file,
        /// shared).
        fn open(fs: *Fs, args: dos.FindArgs, action: dos.ActionCode) Error!void {
            const fh = args.fh orelse return error.InvalidLock;
            const dir_arg = lockValue(args.lock);
            const path = args.name orelse return error.InvalidName;
            var object: Object = .{ .walk = &fs.walks[0] };
            const lock: *FileLockEx = switch (action) {
                .findinput => blk: {
                    try fs.locate(dir_arg, path, &object);
                    if (objectIsDir(&object)) return error.WrongType;
                    break :blk try fs.lockKey(try fs.keyOf(&object), dos.SHARED_LOCK);
                },
                .findoutput => if (fs.locate(dir_arg, path, &object)) |_| blk: {
                    if (objectIsDir(&object)) return error.WrongType;
                    if (_fat.protectionOf(@truncate(object.found.attr)) & dos.FIBF_WRITE != 0) return error.WriteProtected;
                    try fs.changing();
                    const key = try fs.keyOf(&object);
                    const lock = try fs.lockKey(key, dos.EXCLUSIVE_LOCK);
                    errdefer fs.freeLock(lock);
                    try fs.cutChain(key, 0);
                    key.size = 0;
                    key.valid = 0;
                    fs.forgetPlaces(key, 0);
                    try fs.syncKey(key, null);
                    lock.modified = true;
                    break :blk lock;
                } else |err| blk: {
                    if (err != error.NotFound) return err;
                    break :blk try fs.create(dir_arg, path, false, dos.EXCLUSIVE_LOCK);
                },
                else => if (fs.locate(dir_arg, path, &object)) |_| blk: {
                    if (objectIsDir(&object)) return error.WrongType;
                    break :blk try fs.lockKey(try fs.keyOf(&object), dos.SHARED_LOCK);
                } else |err| blk: {
                    if (err != error.NotFound) return err;
                    break :blk try fs.create(dir_arg, path, false, dos.SHARED_LOCK);
                },
            };
            fh.key = lock;
            fh.interactive = false;
        }

        /// A run of whole sectors from `block`, in clusters that follow one
        /// another, up to `wanted_sectors`: how many there are.
        fn runAhead(fs: *Fs, key: *const Key, place: *Place, sector: u32, wanted_sectors: u64) Error!u64 {
            var sectors: u64 = @min(wanted_sectors, fs.geo.sectors_per_cluster - sector);
            while (sectors < wanted_sectors and place.ordinal + 1 < key.clusters) {
                const following = if (key.chain.contiguous)
                    place.cluster + 1
                else
                    try fs.table.next(place.cluster) orelse break;
                if (following != place.cluster + 1) break;
                place.* = .{ .ordinal = place.ordinal + 1, .cluster = following };
                sectors += @min(wanted_sectors - sectors, fs.geo.sectors_per_cluster);
            }
            return sectors;
        }

        fn read(fs: *Fs, args: dos.IOArgs) Error!usize {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            const buffer = args.buffer orelse return 0;
            const len: usize = if (args.length > 0) @intCast(args.length) else 0;
            var place = lock.place();
            defer lock.setPlace(place);
            const sector_bytes = fs.geo.sector_bytes;
            const cluster_bytes = fs.geo.cluster_bytes;
            var done: usize = 0;
            while (done < len and lock.pos < key.size) {
                // Past what has been written, up to the size: zeroes.
                if (lock.pos >= key.valid) {
                    const zeroes: usize = @intCast(@min(@as(u64, len - done), key.size - lock.pos));
                    @memset(buffer[done..][0..zeroes], 0);
                    done += zeroes;
                    lock.pos += zeroes;
                    continue;
                }
                const want: u64 = @min(@as(u64, len - done), key.valid - lock.pos);
                const cluster = try fs.table.clusterAt(key.chain, &place, lock.pos / cluster_bytes);
                const in_cluster: u32 = @intCast(lock.pos % cluster_bytes);
                const sector = in_cluster / sector_bytes;
                const in_sector = in_cluster % sector_bytes;
                const block = fs.geo.clusterBlock(cluster) + sector;
                var count: usize = undefined;
                if (in_sector == 0 and want >= sector_bytes) {
                    // Whole sectors: the rest of this cluster, and on into
                    // the clusters after it while they lie next to it. One
                    // transfer is kept within what a device request holds.
                    const wanted_sectors = @min(want / sector_bytes, max_run_sectors);
                    const sectors = try fs.runAhead(key, &place, sector, wanted_sectors);
                    count = @intCast(sectors * sector_bytes);
                    fs.cache.readRun(block, @intCast(sectors), buffer[done..][0..count]) catch return error.MediumFailed;
                } else {
                    count = @intCast(@min(want, sector_bytes - in_sector));
                    fs.cache.readRun(block, 1, fs.sector) catch return error.MediumFailed;
                    @memcpy(buffer[done..][0..count], fs.sector[in_sector..][0..count]);
                }
                done += count;
                lock.pos += count;
            }
            return done;
        }

        /// `len` bytes at `pos` of a key's file: from `from`, or zeroes
        /// when it is null. The chain grows as it has to, and the size and
        /// the valid length with it; `place` is where the writing got to.
        fn put(fs: *Fs, key: *Key, place: *Place, pos: u64, from: ?[*]const u8, len: u64) Error!void {
            const sector_bytes = fs.geo.sector_bytes;
            const cluster_bytes = fs.geo.cluster_bytes;
            var at = pos;
            var done: u64 = 0;
            while (done < len) {
                const cluster = try fs.clusterFor(key, place, at / cluster_bytes);
                const in_cluster: u32 = @intCast(at % cluster_bytes);
                const sector = in_cluster / sector_bytes;
                const in_sector = in_cluster % sector_bytes;
                const block = fs.geo.clusterBlock(cluster) + sector;
                const left = len - done;
                var count: u64 = undefined;
                if (in_sector == 0 and left >= sector_bytes and from != null) {
                    // Whole sectors, to the end of this cluster at most.
                    const sectors: u64 = @min(@min(left / sector_bytes, fs.geo.sectors_per_cluster - sector), max_run_sectors);
                    count = sectors * sector_bytes;
                    const start: usize = @intCast(done);
                    fs.cache.writeRun(block, @intCast(sectors), from.?[start..][0..@intCast(count)]) catch return error.MediumFailed;
                } else {
                    // Part of a sector, or zeroes: through the one-sector
                    // buffer, with what is there read first if the sector
                    // holds any of what has been written.
                    count = @min(left, sector_bytes - in_sector);
                    const sector_start = at - in_sector;
                    if (sector_start < key.valid and (in_sector != 0 or count != sector_bytes)) {
                        fs.cache.readRun(block, 1, fs.sector) catch return error.MediumFailed;
                    } else {
                        @memset(fs.sector, 0);
                    }
                    const n: usize = @intCast(count);
                    if (from) |bytes| {
                        @memcpy(fs.sector[in_sector..][0..n], bytes[@intCast(done)..][0..n]);
                    } else {
                        @memset(fs.sector[in_sector..][0..n], 0);
                    }
                    fs.cache.writeRun(block, 1, fs.sector) catch return error.MediumFailed;
                }
                done += count;
                at += count;
                if (at > key.valid) key.valid = at;
                if (at > key.size) key.size = at;
                key.changed = true;
            }
        }

        fn write(fs: *Fs, args: dos.IOArgs) Error!usize {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            const buffer = args.buffer orelse return 0;
            if (args.length <= 0) return 0;
            try fs.changing();
            const len: u64 = @intCast(args.length);
            var place = lock.place();
            defer lock.setPlace(place);
            lock.modified = true;
            // What lies between what has been written and where this goes
            // has to read as zeroes once the valid length passes it.
            if (lock.pos > key.valid) {
                var gap_place: Place = .{};
                try fs.put(key, &gap_place, key.valid, null, lock.pos - key.valid);
            }
            try fs.put(key, &place, lock.pos, buffer, len);
            lock.pos += len;
            try fs.syncKey(key, null);
            return @intCast(len);
        }

        /// A position a packet asked for, from the beginning, the current
        /// position or the end.
        fn target(lock: *const FileLockEx, key: *const Key, args: dos.SeekArgs) Error!i128 {
            const from: i128 = switch (args.mode) {
                dos.OFFSET_BEGINNING => 0,
                dos.OFFSET_CURRENT => lock.pos,
                dos.OFFSET_END => key.size,
                else => return error.SeekError,
            };
            return from + args.position;
        }

        /// To a position; the old one. Not before the start or past the
        /// end, and not from or to where dos's isize cannot say.
        fn seek(fs: *Fs, args: dos.SeekArgs) Error!isize {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            const to = try target(lock, key, args);
            if (to < 0 or to > key.size) return error.SeekError;
            if (lock.pos > std.math.maxInt(isize)) return error.SeekError;
            const old: isize = @intCast(lock.pos);
            lock.pos = @intCast(to);
            return old;
        }

        /// END: the file dated and marked for archiving if it was written
        /// to, and its lock freed.
        fn close(fs: *Fs, args: dos.FileHandleArgs) Error!void {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            if (lock.modified and fs.media.writable()) try fs.syncKey(key, fs.now());
            if (lock.modified) {
                fs.tell(key);
                if (key.parent) |dir| fs.tell(dir);
            }
            lock.modified = false;
            fs.freeLock(lock);
            args.fh.?.key = null;
        }

        /// SET_FILE_SIZE: the file cut or grown. Grown, only its size
        /// moves - what is past its valid length reads as zeroes - and its
        /// clusters are taken. Handles past a new end move back to it.
        fn setFileSize(fs: *Fs, args: dos.SeekArgs) Error!isize {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            const to = try target(lock, key, args);
            if (to < 0) return error.SeekError;
            if (to > std.math.maxInt(isize)) return error.SeekError;
            try fs.changing();
            const size: u64 = @intCast(to);
            if (size < key.size) {
                try fs.cutChain(key, fs.geo.clustersFor(size));
                key.size = size;
                if (key.valid > size) key.valid = size;
                fs.forgetPlaces(key, size);
            } else if (size > key.size) {
                const wanted = fs.geo.clustersFor(size);
                while (key.clusters < wanted) _ = try fs.growOne(key);
                key.size = size;
            }
            key.changed = true;
            lock.modified = true;
            try fs.syncKey(key, null);
            return @intCast(size);
        }

        /// FH_FROM_LOCK: the lock on a file becomes the handle's.
        fn fhFromLock(fs: *Fs, args: dos.FhFromLockArgs) Error!void {
            const fh = args.fh orelse return error.InvalidLock;
            const lock = try fs.lockArg(lockValue(args.lock)) orelse return error.InvalidLock;
            if (lock.key().isDir()) return error.WrongType;
            lock.pos = 0;
            lock.setPlace(.{});
            fh.key = lock;
            fh.interactive = false;
        }

        /// CHANGE_MODE, as RAM:'s.
        fn changeMode(fs: *Fs, args: dos.ChangeModeArgs) Error!void {
            var lock: *FileLockEx = undefined;
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
            if (exclusive and fs.otherLock(lock.key(), lock, false)) return error.InUse;
            lock.lock.access = if (exclusive) dos.EXCLUSIVE_LOCK else dos.SHARED_LOCK;
        }

        // --- examine ----------------------------------------------------------

        /// A FileInfoBlock for an entry, `next` the entry to go on from.
        fn fillFound(fs: *Fs, fib: *FileInfoBlock, found: *const Found, size: u64, attr: u16, next: u32) void {
            const kind: i32 = if (found.isDir()) dos.ST_USERDIR else dos.ST_FILE;
            const shown: u64 = if (found.isDir()) 0 else size;
            fib.* = .{
                .disk_key = next,
                .dir_entry_type = kind,
                .entry_type = kind,
                .protection = _fat.protectionOf(@truncate(attr)),
                .size = shown,
                .num_blocks = fs.geo.clustersFor(shown),
                .date = fs.shownDate(found.modified, found.modified_zone),
            };
            var buffer: [_fat.fib_name_max]u8 = undefined;
            const name = names.toDos(found.name(), found.hash, &buffer);
            @memcpy(fib.file_name[0..name.len], name);
        }

        fn fillRoot(fs: *Fs, fib: *FileInfoBlock) void {
            fib.* = .{
                .disk_key = 0,
                .dir_entry_type = dos.ST_ROOT,
                .entry_type = dos.ST_ROOT,
                .date = .{ .days = _fat.dos_epoch_days, .minute = 0, .tick = 0 },
            };
            const name = fs.volumeName();
            @memcpy(fib.file_name[0..name.len], name);
        }

        /// A FileInfoBlock for what a key stands for; its size is the
        /// key's, which may be ahead of what the entry says.
        fn fillKey(fs: *Fs, fib: *FileInfoBlock, key: *Key) Error!void {
            if (key.is_root) return fs.fillRoot(fib);
            const parent = key.parent orelse return error.MediumFailed;
            var found: Found = .{};
            if (!try fs.dirs.load(parent.dir(), key.index, &found)) return error.MediumFailed;
            fs.fillFound(fib, &found, key.size, key.attr, 0);
        }

        fn examineFile(fs: *Fs, args: dos.ExamineFHArgs) Error!void {
            const lock = try fs.fileOf(args.fh);
            try fs.fillKey(args.fib orelse return error.InvalidLock, lock.key());
        }

        /// EXAMINE_OBJECT (`next` false) and EXAMINE_NEXT. fib_DiskKey is
        /// the index of the entry to look at next; entries never move, so
        /// the walk goes on correctly whatever is deleted in between.
        fn examine(fs: *Fs, args: dos.ExamineArgs, next: bool) Error!void {
            const key = try fs.keyArg(lockValue(args.lock));
            const fib = args.fib orelse return error.InvalidLock;
            if (!next) return fs.fillKey(fib, key);
            if (!key.isDir()) return error.NoMoreEntries;
            var index: u32 = @truncate(fib.disk_key);
            var found: Found = .{};
            if (!try fs.dirs.next(key.dir(), &index, &found)) return error.NoMoreEntries;
            // An object that is open reports what it is now.
            var size = found.size;
            var attr = found.attr;
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (!other.stale and other.parent == key and other.index == found.index) {
                    size = other.size;
                    attr = other.attr;
                    break;
                }
            }
            fs.fillFound(fib, &found, size, attr, index);
        }

        // --- changing -----------------------------------------------------------

        /// Whether `inner` is `outer` or inside it: a directory must not be
        /// moved into itself.
        fn within(inner: *Key, outer: *Key) bool {
            var key: ?*Key = inner;
            while (key) |this| : (key = this.parent) if (this == outer) return true;
            return false;
        }

        /// RENAME_OBJECT: the set written again under its new name in its
        /// new directory, dates and all, and the old one erased. Its locks
        /// follow it.
        fn rename(fs: *Fs, args: dos.RenameArgs) Error!void {
            var from: Object = .{ .walk = &fs.walks[0] };
            try fs.locate(lockValue(args.from_lock), args.from_name orelse return error.InvalidName, &from);
            if (from.self_key) |key| if (key.is_root) return error.WrongType;
            const to_walk = &fs.walks[1];
            const to_name = try fs.walkTo(to_walk, try fs.keyArg(lockValue(args.to_lock)), args.to_name orelse return error.InvalidName);
            try _fat.validLong(to_name);
            try fs.changing();

            // Both ends as keys: the object, its directory, and the target
            // directory - which is how moving a directory into itself is
            // seen, and how its locks follow it.
            const key = try fs.keyOf(&from);
            key.locks += 1; // held while this works
            defer {
                key.locks -= 1;
                fs.settle(key);
            }
            if (fs.otherLock(key, null, true)) return error.InUse;
            const from_dir = key.parent orelse return error.WrongType;
            const to_dir = try fs.keyOfWalk(to_walk);
            to_dir.locks += 1;
            defer {
                to_dir.locks -= 1;
                fs.settle(to_dir);
            }
            if (key.isDir() and within(to_dir, key)) return error.InUse;

            var wanted: names.Wanted = undefined;
            wanted.init(to_name, &fs.upcase);
            var there: Found = .{};
            if (try fs.dirs.find(to_dir.dir(), &wanted, &there)) {
                // Only the object itself may already have the name: a
                // rename that changes nothing but the case.
                if (to_dir != from_dir or there.index != key.index) return error.Exists;
            }

            var old: Set = .{};
            if (!try fs.dirs.readSet(from_dir.dir(), key.index, &old)) return error.MediumFailed;
            var units: [fat.name_max]u16 = undefined;
            const utf16 = names.fromDos(to_name, &units);
            var set: Set = .{};
            set.compose(utf16, fs.upcase.hash(utf16), old.attributes(), 0, 0);
            // Everything of the old file entry past its checksum and
            // attributes - its three moments - and the old stream's fields.
            @memcpy(set.entry(0)[fat.exfat_file_created..], old.entry(0)[fat.exfat_file_created..]);
            set.setStream(key.chain, key.valid, key.size);
            // The new set first, the old one erased after: a directory that
            // cannot grow for the new one leaves the file where it was.
            const index = try fs.placeSet(to_dir, &set);
            try fs.dirs.erase(from_dir.dir(), key.index, old.count);
            // Told it went, and both its directories; its watches wait for
            // its old name.
            fs.tell(key);
            fs.tell(from_dir);
            if (to_dir != from_dir) fs.tell(to_dir);
            fs.forsake(key);

            if (to_dir != from_dir) {
                from_dir.holds -= 1;
                to_dir.holds += 1;
                key.parent = to_dir;
                fs.settle(from_dir);
            }
            key.index = index;
            fs.arrive(to_name, true);
        }

        /// SET_PROTECT and SET_DATE on (lock, name). The format keeps no
        /// comment and no owner, so those two are not known.
        fn setProperty(fs: *Fs, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
            if (action == .set_comment or action == .set_owner) return error.NotImplemented;
            var object: Object = .{ .walk = &fs.walks[0] };
            try fs.locate(lockValue(args.lock), args.name orelse return error.InvalidName, &object);
            if (object.self_key) |key| if (key.is_root) return error.WrongType;
            try fs.changing();
            const key = try fs.keyOf(&object);
            key.locks += 1;
            defer {
                key.locks -= 1;
                fs.settle(key);
            }
            const parent = key.parent orelse return error.WrongType;
            var set: Set = .{};
            if (!try fs.dirs.readSet(parent.dir(), key.index, &set)) return error.MediumFailed;
            switch (action) {
                .set_protect => {
                    const attr: u16 = _fat.attributeOf(@truncate(ptrArg(args.value)), @truncate(key.attr));
                    key.attr = attr;
                    set.setAttributes(attr);
                },
                else => {
                    const date: ?*const dos.DateStamp = @ptrFromInt(ptrArg(args.value));
                    const moment = if (date) |into| dir_area.momentOf(_fat.stampOf(fs.ub, into.*)) else fs.now();
                    set.setModified(moment, fs.zoneByte(moment), false);
                },
            }
            try fs.dirs.writeSet(parent.dir(), key.index, &set);
            fs.tell(key);
        }

        /// INFO and DISK_INFO: the volume in clusters, how many are in use.
        fn info(fs: *Fs, data: ?*dos.InfoData) Error!void {
            const into = data orelse return error.InvalidLock;
            into.* = .{
                .num_soft_errors = 0,
                .unit_number = 0,
                .disk_state = if (fs.media.writable()) dos.ID_VALIDATED else dos.ID_WRITE_PROTECTED,
                .num_blocks = fs.geo.cluster_count,
                .num_blocks_used = fs.geo.cluster_count - fs.bitmap.free_count,
                .bytes_per_block = fs.geo.cluster_bytes,
                .disk_type = dos.ID_MSDOS_DISK,
                .volume_node = fs.volume_node,
                .in_use = if (fs.locks != null) -1 else 0,
            };
        }

        // --- packets --------------------------------------------------------------

        /// The answer to one packet (all but STARTUP, which the process
        /// takes). What a packet changed is on the medium before it is
        /// answered, and the volume is marked clean again if that leaves
        /// nothing half done.
        pub fn answer(fs: *Fs, pkt: *DosPacket) Answer {
            const result = fs.respond(pkt);
            switch (pkt.getAction()) {
                .create_dir,
                .delete_object,
                .rename_object,
                .rename_disk,
                .set_protect,
                .set_date,
                .set_file_size,
                .findoutput,
                .findupdate,
                .write,
                .end,
                .flush,
                => if (fs.mounted) {
                    _ = fs.cache.flush() catch |err| {
                        // A packet that did its work is not answered as
                        // done if the work did not reach the medium.
                        if (result.res1 != dos.DOSFALSE and result.res1 != -1) return no(switch (err) {
                            error.NoMemory => error.NoMemory,
                            else => error.MediumFailed,
                        });
                    };
                    fs.clearDirty();
                },
                else => {},
            }
            return result;
        }

        fn respond(fs: *Fs, pkt: *DosPacket) Answer {
            const raw = pkt.args.raw;
            switch (pkt.getAction()) {
                .locate_object => {
                    var object: Object = .{ .walk = &fs.walks[0] };
                    fs.locate(raw[0], @ptrFromInt(ptrArg(raw[1])), &object) catch |err| return no(err);
                    const key = fs.keyOf(&object) catch |err| return no(err);
                    const lock = fs.lockKey(key, @truncate(raw[2])) catch |err| return no(err);
                    return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
                },
                .free_lock => {
                    const lock = fs.lockArg(raw[0]) catch |err| {
                        // A lock from a card that has gone is still freed.
                        if (err == error.InvalidLock and raw[0] != 0) {
                            const stale: *FileLockEx = @ptrFromInt(ptrArg(raw[0]));
                            if (fs.owns(stale)) {
                                fs.freeLock(stale);
                                return yes();
                            }
                        }
                        return no(err);
                    };
                    if (lock) |it| fs.freeLock(it);
                    return yes();
                },
                .copy_dir, .parent => {
                    const key = fs.keyArg(raw[0]) catch |err| return no(err);
                    return fs.lockParentOrSelf(key, pkt.getAction() == .parent);
                },
                .same_lock => {
                    const one = fs.keyArg(raw[0]) catch |err| return no(err);
                    const two = fs.keyArg(raw[1]) catch |err| return no(err);
                    return .{ .res1 = if (one == two) dos.DOSTRUE else dos.DOSFALSE, .res2 = 0 };
                },
                .create_dir => {
                    const lock = fs.create(raw[0], @ptrFromInt(ptrArg(raw[1])), true, dos.EXCLUSIVE_LOCK) catch |err| return no(err);
                    return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
                },
                .delete_object => {
                    fs.delete(raw[0], @ptrFromInt(ptrArg(raw[1]))) catch |err| return no(err);
                    return yes();
                },
                .findinput, .findoutput, .findupdate => {
                    fs.open(pkt.args.find, pkt.getAction()) catch |err| return no(err);
                    return yes();
                },
                .read => {
                    const count = fs.read(pkt.args.io) catch |err| return minusOne(err);
                    return .{ .res1 = @intCast(count), .res2 = 0 };
                },
                .write => {
                    const count = fs.write(pkt.args.io) catch |err| return minusOne(err);
                    return .{ .res1 = @intCast(count), .res2 = 0 };
                },
                .seek => {
                    const old = fs.seek(pkt.args.seek) catch |err| return minusOne(err);
                    return .{ .res1 = old, .res2 = 0 };
                },
                .end => {
                    fs.close(pkt.args.file) catch |err| {
                        // A file on a card that has gone is still closed:
                        // its lock is ours to free, whatever it is good for.
                        if (err == error.InvalidLock) if (pkt.args.file.fh) |fh| if (fh.key) |held| {
                            const stale: *FileLockEx = @ptrCast(@alignCast(held));
                            if (fs.owns(stale)) {
                                fs.freeLock(stale);
                                fh.key = null;
                                return yes();
                            }
                        };
                        return no(err);
                    };
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
                .rename_object => {
                    fs.rename(pkt.args.rename) catch |err| return no(err);
                    return yes();
                },
                .rename_disk => {
                    const given: ?[*:0]const u8 = @ptrFromInt(ptrArg(raw[0]));
                    const name = given orelse return no(error.InvalidName);
                    var len: usize = 0;
                    while (name[len] != 0) len += 1;
                    fs.relabel(name[0..len]) catch |err| return no(err);
                    return yes();
                },
                .set_protect, .set_comment, .set_date, .set_owner => {
                    fs.setProperty(pkt.args.property, pkt.getAction()) catch |err| return no(err);
                    return yes();
                },
                .set_file_size => {
                    const size = fs.setFileSize(pkt.args.seek) catch |err| return minusOne(err);
                    return .{ .res1 = size, .res2 = 0 };
                },
                .parent_fh, .copy_dir_fh => {
                    const lock = fs.fileOf(pkt.args.file.fh) catch |err| return no(err);
                    return fs.lockParentOrSelf(lock.key(), pkt.getAction() == .parent_fh);
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
                    fs.info(@ptrFromInt(ptrArg(raw[0]))) catch |err| return no(err);
                    return yes();
                },
                .flush => return yes(),
                .more_cache => return .{ .res1 = @intCast(cache_blocks), .res2 = 0 },
                .add_notify => {
                    const request: ?*notify.NotifyRequest = @ptrFromInt(ptrArg(raw[0]));
                    fs.addNotify(request orelse return no(error.NotFound)) catch |err| return no(err);
                    return yes();
                },
                .remove_notify => {
                    const request: ?*notify.NotifyRequest = @ptrFromInt(ptrArg(raw[0]));
                    if (request) |watched| fs.removeNotify(watched);
                    return yes();
                },
                .is_filesystem => return yes(),
                .die => return no(error.InUse),
                else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
            }
        }

        /// A shared lock on a key's object itself, or on the directory it
        /// is in; the root has no parent and answers 0.
        fn lockParentOrSelf(fs: *Fs, key: *Key, parent: bool) Answer {
            var target_key = key;
            if (parent) target_key = key.parent orelse return .{ .res1 = 0, .res2 = 0 };
            const lock = fs.getLock(target_key, dos.SHARED_LOCK) catch |err| return no(err);
            return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
        }
    };
}

/// The most sectors one transfer moves: what a device request's 32-bit
/// length holds, rounded down to a whole cluster of the largest size.
const max_run_sectors: u64 = (1 << 31) / 512;
