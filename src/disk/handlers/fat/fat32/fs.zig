// SPDX-License-Identifier: MIT
//! The FAT32 file system: the packets, the locks and the files, over the
//! table (`table.zig`) and the directories (`dir.zig`). `FileSystem(Media)`
//! is generic over the medium, so all of it is tested on the host.
//!
//! The packets, their arguments and their answers are RAM:'s and the
//! flash disk's - a program cannot tell the three apart - and so are the
//! lock rules and the error codes. What is particular to this format:
//!
//! - **A key per object.** Every lock and every open file on the same
//!   object shares one key: where its entry is on the medium, its first
//!   cluster, its size and its attributes. So a file written through one
//!   handle has its new size seen through every other, and whether an
//!   object is locked at all is whether it has a key. The root directory
//!   has no entry; its key is made at mount and kept.
//! - **A lock keeps its place in the chain.** Besides its position a lock
//!   remembers which cluster that position is in, so reading on from where
//!   it stopped does not walk the chain again from the start.
//! - **A file's bytes go around the block cache**, straight between the
//!   caller's buffer and the medium, and whole sectors in a row that lie
//!   in clusters next to each other go as one command. Only a sector that
//!   is partly written is read first.
//! - **What a packet changed is on the medium before it is answered**: the
//!   table, the free count and the directory entries. A file's entry gets
//!   its new size after every write, and its date and archive bit when it
//!   is closed.
//! - **Names** are `names.zig`'s: a long name dos can hold, otherwise the
//!   short one; a lookup matches either.
//! - **No comments, no owner.** The format has nowhere to put either, so
//!   SET_COMMENT and SET_OWNER answer ERROR_ACTION_NOT_KNOWN.
//! - **A file is at most 4 GiB less a byte**, the size field's width.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const fat = dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const dir_area = @import("dir.zig");
const names = @import("names.zig");
const Error = _fat.Error;
const Answer = _fat.Answer;
const Geometry = layout.Geometry;
const Found = dir_area.Found;
const Cursor = dir_area.Cursor;
const Spot = dir_area.Spot;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const DosPacket = dos.DosPacket;
const MsgPort = exec.MsgPort;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// Blocks the cache holds: the table sectors and directory blocks a
/// packet goes back to.
pub const cache_blocks: u32 = 32;

/// The largest a file can be.
const max_size: u64 = 0xFFFF_FFFF;

/// One object on the volume, however many locks are on it.
const Key = struct {
    next: ?*Key = null,
    /// Locks and open files using it.
    locks: u32 = 0,
    is_root: bool = false,
    /// Its directory's first cluster and its number there, and where its
    /// entry lies - meaningless for the root.
    dir: u32 = 0,
    index: u32 = 0,
    spot: Spot = .{ .block = 0, .at = 0 },
    /// Its first cluster (0: a file with nothing in it) and its size.
    first: u32 = 0,
    size: u32 = 0,
    attr: u8 = 0,
    /// The first cluster or the size is not yet in the entry.
    changed: bool = false,
    /// The medium changed under it: nothing it says is true any more.
    stale: bool = false,

    fn isDir(key: *const Key) bool {
        return key.is_root or key.attr & _fat.ATTR_DIRECTORY != 0;
    }
};

/// Where a lock is in its file's chain: the cluster `ordinal` steps from
/// the start. A cluster of 0 is nowhere yet.
const Place = struct { ordinal: u32 = 0, cluster: u32 = 0 };

/// A lock: the FileLock first, then what an open file needs.
const FatLock = extern struct {
    lock: FileLock,
    pos: u32 = 0,
    ordinal: u32 = 0,
    cluster: u32 = 0,
    modified: bool = false,

    fn key(lock: *const FatLock) *Key {
        return @ptrFromInt(lock.lock.key);
    }

    fn nextLock(lock: *const FatLock) ?*FatLock {
        const n = lock.lock.link orelse return null;
        return @alignCast(@fieldParentPtr("lock", n));
    }

    fn place(lock: *FatLock) Place {
        return .{ .ordinal = lock.ordinal, .cluster = lock.cluster };
    }

    fn setPlace(lock: *FatLock, where: Place) void {
        lock.ordinal = where.ordinal;
        lock.cluster = where.cluster;
    }
};

/// Something a path names: the root, or an entry and the directory it
/// is in.
const Object = struct {
    is_root: bool = false,
    dir: u32 = 0,
    found: Found = .{},
};

/// Where a path ends: the directory, and its last part (empty: the
/// directory itself).
const PathEnd = struct { dir: u32, name: []const u8 };

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
        const Dir = dir_area.Directory(Media);

        media: *Media,
        ub: *UtilityBase,
        /// The handler's port (fl_Task of its locks).
        port: ?*MsgPort = null,
        /// The volume's DosList node (fl_Volume of its locks).
        volume_node: ?*dos.DosList = null,

        geo: Geometry = undefined,
        cache: Cache = undefined,
        table: Table = undefined,
        dirs: Dir = undefined,
        /// One sector, for the part of a sector a read or write does not
        /// cover.
        sector: []u8 = &.{},
        root_key: ?*Key = null,
        keys: ?*Key = null,
        locks: ?*FatLock = null,
        mounted: bool = false,
        /// The medium's change count when the volume was read.
        change_num: u32 = 0,
        /// The volume's name, as the device list shows it.
        name_buf: [fat.ent_name_bytes]u8 = @splat(0),
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

        // --- mounting ---------------------------------------------------------

        /// The volume on the medium: the medium itself if its first block
        /// is a FAT32 boot sector, else the first partition of its table
        /// that is one. Every key there was is stale from here on.
        pub fn mount(fs: *Fs) Error!void {
            fs.unmount();
            fs.change_num = fs.media.changeNum();
            if (!fs.media.present()) return error.MediumFailed;
            const block_bytes = fs.media.blockSize();
            const buffer = fs.media.alloc(block_bytes) orelse return error.NoMemory;
            fs.sector = buffer;
            errdefer {
                fs.media.free(fs.sector);
                fs.sector = &.{};
            }

            const first = try fs.volumeStart();
            if (!fs.media.read(first, 1, fs.sector)) return error.MediumFailed;
            fs.geo = try Geometry.of(fs.sector, first, fs.media.blocks(), block_bytes);
            fs.cache = Cache.init(fs.media, cache_blocks) catch return error.NoMemory;
            errdefer fs.cache.deinit();
            fs.table = Table.init(&fs.cache, &fs.geo);
            fs.dirs = .{ .cache = &fs.cache, .table = &fs.table, .geo = &fs.geo, .ub = fs.ub };
            try fs.table.loadHints();

            const root = fs.alloc(Key) orelse return error.NoMemory;
            root.* = .{ .is_root = true, .first = fs.geo.root_cluster, .attr = _fat.ATTR_DIRECTORY };
            fs.root_key = root;
            fs.mounted = true;
            fs.nameVolume() catch {};
        }

        /// Where the volume starts: block 0 if it is a boot sector itself,
        /// else the first partition worth mounting whose first block is one.
        fn volumeStart(fs: *Fs) Error!u64 {
            if (!fs.media.read(0, 1, fs.sector)) return error.MediumFailed;
            switch (fat.formatOf(fs.sector)) {
                .fat32 => return 0,
                .exfat => return error.NotImplemented,
                .unknown => {},
            }
            if (!fat.signed(fs.sector)) return error.MediumFailed;
            var partitions: [fat.partition_count]fat.Partition = undefined;
            for (&partitions, 0..) |*partition, which| partition.* = fat.partitionOf(fs.sector, which);
            for (partitions) |partition| {
                if (!partition.real() or !fat.mountable(partition.kind)) continue;
                if (!fs.media.read(partition.first, 1, fs.sector)) return error.MediumFailed;
                switch (fat.formatOf(fs.sector)) {
                    .fat32 => return partition.first,
                    .exfat => return error.NotImplemented,
                    .unknown => {},
                }
            }
            return error.MediumFailed;
        }

        /// Everything the volume held in memory written back and given up;
        /// every key left is stale.
        pub fn unmount(fs: *Fs) void {
            fs.release(true);
        }

        /// The same, and with `write_back` false nothing is written: for a
        /// medium that has changed, where whatever is held belongs to a
        /// card that is no longer there and would damage the one that is.
        fn release(fs: *Fs, write_back: bool) void {
            if (fs.mounted) {
                if (write_back) {
                    fs.table.flush() catch {};
                } else {
                    fs.cache.invalidate();
                }
                fs.cache.deinit();
                fs.mounted = false;
            }
            if (fs.sector.len != 0) {
                fs.media.free(fs.sector);
                fs.sector = &.{};
            }
            if (fs.root_key) |root| {
                root.stale = true;
                // The root key goes with the volume unless a lock holds
                // it, in which case the lock's freeing takes it.
                if (root.locks == 0) fs.free(root) else {
                    root.next = fs.keys;
                    fs.keys = root;
                }
                fs.root_key = null;
            }
            var key = fs.keys;
            while (key) |other| : (key = other.next) other.stale = true;
        }

        /// Whether the medium is still the one mounted. If not, what was
        /// held is dropped without being written - it belongs to a card
        /// that is no longer there - and the new one is mounted. True if
        /// anything changed, so the caller renews the volume node.
        pub fn checkMedium(fs: *Fs) bool {
            // With nothing mounted, asking whether a card is in is what
            // makes the device look for one put in since.
            if (!fs.mounted) _ = fs.media.present();
            if (fs.media.changeNum() == fs.change_num) return false;
            fs.release(false);
            fs.mount() catch {};
            return true;
        }

        /// The volume's name: the root directory's label, the boot
        /// sector's if that says something, else its serial number as a
        /// PC shows it - a volume needs a name, and two cards without a
        /// label should not have the same one.
        fn nameVolume(fs: *Fs) Error!void {
            var label: [fat.ent_name_bytes]u8 = undefined;
            var text = try fs.dirs.label(&label);
            if (text.len == 0) {
                var len: usize = fat.ent_name_bytes;
                while (len > 0 and fs.geo.label[len - 1] == ' ') len -= 1;
                const boot = fs.geo.label[0..len];
                const unnamed = "NO NAME";
                var is_unnamed = boot.len == unnamed.len;
                if (is_unnamed) for (boot, unnamed) |raw, b| {
                    is_unnamed = is_unnamed and raw == b;
                };
                if (!is_unnamed) text = boot;
            }
            if (text.len != 0) {
                @memcpy(fs.name_buf[0..text.len], text);
                fs.name_len = text.len;
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
                fs.name_buf[at] = digits[(fs.geo.volume_id >> shift) & 0xF];
                at += 1;
                if (shift == 0) break;
            }
            fs.name_len = at;
        }

        pub fn volumeName(fs: *const Fs) []const u8 {
            return fs.name_buf[0..fs.name_len];
        }

        // --- keys and locks -----------------------------------------------------

        fn rootKey(fs: *Fs) Error!*Key {
            return fs.root_key orelse error.MediumFailed;
        }

        /// The key of an object, the one already there if it has one.
        fn keyOf(fs: *Fs, object: *const Object) Error!*Key {
            if (object.is_root) return fs.rootKey();
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (!other.stale and other.dir == object.dir and other.index == object.found.index) return other;
            }
            const key = fs.alloc(Key) orelse return error.NoMemory;
            key.* = .{
                .next = fs.keys,
                .dir = object.dir,
                .index = object.found.index,
                .spot = object.found.spot,
                .first = object.found.cluster,
                .size = if (object.found.isDir()) 0 else object.found.size,
                .attr = object.found.attr,
            };
            fs.keys = key;
            return key;
        }

        /// The key of an object if it has one: whether it is locked.
        fn existingKey(fs: *Fs, dir: u32, index: u32) ?*Key {
            var it = fs.keys;
            while (it) |other| : (it = other.next) {
                if (!other.stale and other.locks != 0 and other.dir == dir and other.index == index) return other;
            }
            return null;
        }

        fn dropKey(fs: *Fs, key: *Key) void {
            if (key == fs.root_key) return;
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
            fs.free(key);
        }

        fn owns(fs: *Fs, lock: *FatLock) bool {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) if (other == lock) return true;
            return false;
        }

        /// A lock from a packet: one of ours, or null for the root. A lock
        /// from a card that has gone is no longer any good.
        fn lockArg(fs: *Fs, value: isize) Error!?*FatLock {
            if (value == 0) return null;
            const lock: *FatLock = @ptrFromInt(ptrArg(value));
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
        fn getLock(fs: *Fs, key: *Key, access: i32) Error!*FatLock {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.key() == key and (access == dos.EXCLUSIVE_LOCK or other.lock.access == dos.EXCLUSIVE_LOCK)) return error.InUse;
            }
            const lock = fs.alloc(FatLock) orelse return error.NoMemory;
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

        fn freeLock(fs: *Fs, lock: *FatLock) void {
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
            if (key.locks == 0 and key != fs.root_key) fs.dropKey(key);
        }

        /// Whether a lock but `l` is on the key (with `exclusive_only`, an
        /// exclusive one).
        fn otherLock(fs: *Fs, key: *Key, lock: ?*FatLock, exclusive_only: bool) bool {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other == lock or other.key() != key) continue;
                if (!exclusive_only or other.lock.access == dos.EXCLUSIVE_LOCK) return true;
            }
            return false;
        }

        // --- names ----------------------------------------------------------------

        /// A directory key's first cluster.
        fn dirCluster(fs: *Fs, key: *const Key) Error!u32 {
            if (!key.isDir()) return error.WrongType;
            if (key.is_root) return fs.geo.root_cluster;
            return if (key.first == 0) fs.geo.root_cluster else key.first;
        }

        /// A directory's first cluster from an entry that names one; a
        /// directory entry with no cluster is how the format names the root.
        fn clusterOfDir(fs: *Fs, found: *const Found) u32 {
            return if (found.cluster == 0) fs.geo.root_cluster else found.cluster;
        }

        /// Drop the device, walk the directories from
        /// `start` ("" goes up), and leave the last part.
        fn findDir(fs: *Fs, start: *Key, path: [*:0]const u8) Error!PathEnd {
            var s = path[0..fs.ub.Strlen(path)];
            for (s, 0..) |char, at| if (char == ':') {
                s = s[at + 1 ..];
                break;
            };
            var dir = try fs.dirCluster(start);
            var found: Found = .{};
            while (true) {
                var slash: ?usize = null;
                for (s, 0..) |char, at| if (char == '/') {
                    slash = at;
                    break;
                };
                const cut = slash orelse return .{ .dir = dir, .name = s };
                const part = s[0..cut];
                s = s[cut + 1 ..];
                if (part.len == 0) {
                    if (dir == fs.geo.root_cluster) return error.NotFound;
                    dir = try fs.dirs.parentOf(dir);
                    continue;
                }
                if (part.len > fat.name_max) return error.InvalidName;
                if (!try fs.dirs.find(dir, part, &found)) return error.NotFound;
                if (!found.isDir()) return error.WrongType;
                dir = fs.clusterOfDir(&found);
            }
        }

        /// The object a directory is: the root, or its entry in its parent.
        fn directoryObject(fs: *Fs, cluster: u32, object: *Object) Error!void {
            if (cluster == fs.geo.root_cluster) {
                object.* = .{ .is_root = true };
                return;
            }
            const parent = try fs.dirs.parentOf(cluster);
            if (!try fs.dirs.findCluster(parent, cluster, &object.found)) return error.MediumFailed;
            object.is_root = false;
            object.dir = parent;
        }

        /// The object a key stands for, its entry read again.
        fn keyObject(fs: *Fs, key: *const Key, object: *Object) Error!void {
            if (key.is_root) {
                object.* = .{ .is_root = true };
                return;
            }
            if (!try fs.dirs.at(key.dir, key.index, &object.found)) return error.MediumFailed;
            object.is_root = false;
            object.dir = key.dir;
        }

        /// The object a path names, from the key a lock stands for.
        fn locate(fs: *Fs, dir_arg: isize, path: [*:0]const u8, object: *Object) Error!void {
            const start = try fs.keyArg(dir_arg);
            if (path[0] == 0) return fs.keyObject(start, object);
            const spot = try fs.findDir(start, path);
            if (spot.name.len == 0) return fs.directoryObject(spot.dir, object);
            if (spot.name.len > fat.name_max) return error.InvalidName;
            if (!try fs.dirs.find(spot.dir, spot.name, &object.found)) return error.NotFound;
            object.is_root = false;
            object.dir = spot.dir;
        }

        // --- changing entries -----------------------------------------------------

        fn now(fs: *Fs) _fat.Stamp {
            return _fat.stampOf(fs.ub, fs.media.now());
        }

        fn writable(fs: *Fs) Error!void {
            if (!fs.media.writable()) return error.WriteProtected;
        }

        /// A key's first cluster and size into its entry, and with a date
        /// its date and archive bit too.
        fn syncKey(fs: *Fs, key: *Key, when: ?_fat.Stamp) Error!void {
            if (key.is_root or key.stale) return;
            if (!key.changed and when == null) return;
            const entry = try fs.dirs.entryForWrite(key.spot);
            fat.setEntryCluster(entry, key.first);
            if (!key.isDir()) fat.putU32(entry, fat.ent_size, key.size);
            if (when) |stamp| {
                dir_area.stamp(entry, stamp, false);
                key.attr |= _fat.ATTR_ARCHIVE;
            }
            entry[fat.ent_attr] = key.attr;
            key.changed = false;
        }

        /// A new file or directory, written down and locked.
        fn create(fs: *Fs, dir_arg: isize, path: [*:0]const u8, directory: bool, access: i32) Error!*FatLock {
            try fs.writable();
            const start = try fs.keyArg(dir_arg);
            const spot = try fs.findDir(start, path);
            try names.validLong(spot.name);
            var object: Object = .{ .dir = spot.dir };
            if (try fs.dirs.find(spot.dir, spot.name, &object.found)) return error.Exists;

            const stamp = fs.now();
            var cluster: u32 = 0;
            if (directory) {
                cluster = try fs.table.allocate(null);
                errdefer fs.table.freeChain(cluster) catch {};
                try fs.dirs.initDirectory(cluster, spot.dir, stamp);
            }
            const attr: u8 = if (directory) _fat.ATTR_DIRECTORY else _fat.ATTR_ARCHIVE;
            try fs.dirs.create(spot.dir, spot.name, .{ .attr = attr, .cluster = cluster, .stamp = stamp }, &object.found);
            const key = try fs.keyOf(&object);
            const lock = try fs.getLock(key, access);
            if (!directory) lock.modified = true;
            return lock;
        }

        fn delete(fs: *Fs, dir_arg: isize, path: [*:0]const u8) Error!void {
            try fs.writable();
            var object: Object = .{};
            try fs.locate(dir_arg, path, &object);
            if (object.is_root) return error.WrongType;
            const found = &object.found;
            if (fs.existingKey(object.dir, found.index) != null) return error.InUse;
            if (_fat.protectionOf(found.attr) & dos.FIBF_DELETE != 0) return error.DeleteProtected;
            if (found.isDir() and !try fs.dirs.empty(fs.clusterOfDir(found))) return error.NotEmpty;
            try fs.dirs.erase(object.dir, found);
            if (fs.geo.usable(found.cluster)) try fs.table.freeChain(found.cluster);
        }

        // --- files ------------------------------------------------------------------

        fn fileOf(fs: *Fs, fh: ?*FileHandle) Error!*FatLock {
            const handle = fh orelse return error.InvalidLock;
            const lock: *FatLock = @ptrCast(@alignCast(handle.key orelse return error.InvalidLock));
            if (!fs.owns(lock)) return error.InvalidLock;
            if (lock.key().stale) return error.InvalidLock;
            return lock;
        }

        /// A file emptied: its chain given back, every lock on it moved to
        /// its start.
        fn empty(fs: *Fs, key: *Key) Error!void {
            if (fs.geo.usable(key.first)) try fs.table.freeChain(key.first);
            key.first = 0;
            key.size = 0;
            key.changed = true;
            fs.forgetPlaces(key, 0);
        }

        /// Every lock on a key whose place in the chain may be gone starts
        /// again from the beginning, its position kept inside `size`.
        fn forgetPlaces(fs: *Fs, key: *Key, size: u32) void {
            var it = fs.locks;
            while (it) |other| : (it = other.nextLock()) {
                if (other.key() != key) continue;
                other.setPlace(.{});
                if (other.pos > size) other.pos = size;
            }
        }

        /// FINDINPUT (an existing file, shared), FINDOUTPUT (a new or
        /// emptied file, exclusive), FINDUPDATE (an existing or new file,
        /// shared), as RAM: has them.
        fn open(fs: *Fs, args: dos.FindArgs, action: dos.ActionCode) Error!void {
            const fh = args.fh orelse return error.InvalidLock;
            const dir_arg = lockValue(args.lock);
            const path = args.name orelse return error.InvalidName;
            var object: Object = .{};
            const lock: *FatLock = switch (action) {
                .findinput => blk: {
                    try fs.locate(dir_arg, path, &object);
                    if (object.is_root or object.found.isDir()) return error.WrongType;
                    break :blk try fs.getLock(try fs.keyOf(&object), dos.SHARED_LOCK);
                },
                .findoutput => if (fs.locate(dir_arg, path, &object)) |_| blk: {
                    if (object.is_root or object.found.isDir()) return error.WrongType;
                    try fs.writable();
                    if (_fat.protectionOf(object.found.attr) & dos.FIBF_WRITE != 0) return error.WriteProtected;
                    const key = try fs.keyOf(&object);
                    const lock = try fs.getLock(key, dos.EXCLUSIVE_LOCK);
                    errdefer fs.freeLock(lock);
                    try fs.empty(key);
                    try fs.syncKey(key, null);
                    lock.modified = true;
                    break :blk lock;
                } else |err| blk: {
                    if (err != error.NotFound) return err;
                    break :blk try fs.create(dir_arg, path, false, dos.EXCLUSIVE_LOCK);
                },
                else => if (fs.locate(dir_arg, path, &object)) |_| blk: {
                    if (object.is_root or object.found.isDir()) return error.WrongType;
                    break :blk try fs.getLock(try fs.keyOf(&object), dos.SHARED_LOCK);
                } else |err| blk: {
                    if (err != error.NotFound) return err;
                    break :blk try fs.create(dir_arg, path, false, dos.SHARED_LOCK);
                },
            };
            fh.key = lock;
            fh.interactive = false;
        }

        /// The cluster `ordinal` steps into a key's chain, walked from the
        /// place given if that is not past it. The place is moved there.
        fn clusterAt(fs: *Fs, key: *const Key, place: *Place, ordinal: u32) Error!u32 {
            if (!fs.geo.usable(key.first)) return error.MediumFailed;
            if (place.cluster == 0 or place.ordinal > ordinal) place.* = .{ .cluster = key.first };
            while (place.ordinal < ordinal) {
                place.cluster = try fs.table.next(place.cluster) orelse return error.MediumFailed;
                place.ordinal += 1;
            }
            return place.cluster;
        }

        /// The same, taking clusters where the chain runs out: what writing
        /// past the end of a file needs.
        fn clusterFor(fs: *Fs, key: *Key, place: *Place, ordinal: u32) Error!u32 {
            if (key.first == 0) {
                key.first = try fs.table.allocate(null);
                key.changed = true;
                place.* = .{ .cluster = key.first };
            }
            if (place.cluster == 0 or place.ordinal > ordinal) place.* = .{ .cluster = key.first };
            while (place.ordinal < ordinal) {
                place.cluster = try fs.table.next(place.cluster) orelse try fs.table.allocate(place.cluster);
                place.ordinal += 1;
            }
            return place.cluster;
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
                const want: u32 = @intCast(@min(@as(u64, len - done), key.size - lock.pos));
                const cluster = try fs.clusterAt(key, &place, lock.pos / cluster_bytes);
                const in_cluster = lock.pos % cluster_bytes;
                const sector = in_cluster / sector_bytes;
                const in_sector = in_cluster % sector_bytes;
                const block = fs.geo.clusterBlock(cluster) + sector;
                var count: u32 = undefined;
                if (in_sector == 0 and want >= sector_bytes) {
                    // Whole sectors: the rest of this cluster, and on into
                    // the clusters after it while they lie next to it.
                    const wanted_sectors = want / sector_bytes;
                    var sectors = @min(wanted_sectors, fs.geo.sectors_per_cluster - sector);
                    var ahead = place;
                    while (sectors < wanted_sectors) {
                        const following = try fs.table.next(ahead.cluster) orelse break;
                        if (following != ahead.cluster + 1) break;
                        ahead = .{ .ordinal = ahead.ordinal + 1, .cluster = following };
                        sectors += @min(wanted_sectors - sectors, fs.geo.sectors_per_cluster);
                    }
                    count = sectors * sector_bytes;
                    fs.cache.readRun(block, sectors, buffer[done..][0..count]) catch return error.MediumFailed;
                    place = ahead;
                } else {
                    count = @min(want, sector_bytes - in_sector);
                    fs.cache.readRun(block, 1, fs.sector) catch return error.MediumFailed;
                    @memcpy(buffer[done..][0..count], fs.sector[in_sector..][0..count]);
                }
                done += count;
                lock.pos += count;
            }
            return done;
        }

        /// `len` bytes at `pos` of a key's file: from `from`, or zeroes
        /// when it is null. The chain grows as it has to and the size with
        /// it; `place` is where in the chain the writing got to.
        fn put(fs: *Fs, key: *Key, place: *Place, pos: u32, from: ?[*]const u8, len: u32) Error!void {
            const sector_bytes = fs.geo.sector_bytes;
            const cluster_bytes = fs.geo.cluster_bytes;
            var at = pos;
            var done: u32 = 0;
            while (done < len) {
                const cluster = try fs.clusterFor(key, place, at / cluster_bytes);
                const in_cluster = at % cluster_bytes;
                const sector = in_cluster / sector_bytes;
                const in_sector = in_cluster % sector_bytes;
                const block = fs.geo.clusterBlock(cluster) + sector;
                const left = len - done;
                var count: u32 = undefined;
                if (in_sector == 0 and left >= sector_bytes and from != null) {
                    // Whole sectors, to the end of this cluster at most.
                    const sectors = @min(left / sector_bytes, fs.geo.sectors_per_cluster - sector);
                    count = sectors * sector_bytes;
                    fs.cache.writeRun(block, sectors, from.?[done..][0..count]) catch return error.MediumFailed;
                } else {
                    // Part of a sector, or zeroes: through the one-sector
                    // buffer, with what is already there read first if the
                    // sector holds any of the file.
                    count = @min(left, sector_bytes - in_sector);
                    const sector_start = at - in_sector;
                    if (sector_start < key.size and (in_sector != 0 or count != sector_bytes)) {
                        fs.cache.readRun(block, 1, fs.sector) catch return error.MediumFailed;
                    } else {
                        @memset(fs.sector, 0);
                    }
                    if (from) |bytes| {
                        @memcpy(fs.sector[in_sector..][0..count], bytes[done..][0..count]);
                    } else {
                        @memset(fs.sector[in_sector..][0..count], 0);
                    }
                    fs.cache.writeRun(block, 1, fs.sector) catch return error.MediumFailed;
                }
                done += count;
                at += count;
                if (at > key.size) {
                    key.size = at;
                    key.changed = true;
                }
            }
        }

        fn write(fs: *Fs, args: dos.IOArgs) Error!usize {
            const lock = try fs.fileOf(args.fh);
            try fs.writable();
            const key = lock.key();
            const buffer = args.buffer orelse return 0;
            if (args.length <= 0) return 0;
            if (@as(u64, lock.pos) + @as(u64, @intCast(args.length)) > max_size) return error.DiskFull;
            const len: u32 = @intCast(args.length);
            var place = lock.place();
            defer lock.setPlace(place);
            lock.modified = true;
            try fs.put(key, &place, lock.pos, buffer, len);
            lock.pos += len;
            try fs.syncKey(key, null);
            return len;
        }

        /// To a position from the beginning, the current position or the
        /// end; the old position. Not before the start or past the end.
        fn seek(fs: *Fs, args: dos.SeekArgs) Error!u32 {
            const lock = try fs.fileOf(args.fh);
            const size: i64 = lock.key().size;
            const from: i64 = switch (args.mode) {
                dos.OFFSET_BEGINNING => 0,
                dos.OFFSET_CURRENT => lock.pos,
                dos.OFFSET_END => size,
                else => return error.SeekError,
            };
            const target = from + args.position;
            if (target < 0 or target > size) return error.SeekError;
            const old = lock.pos;
            lock.pos = @intCast(target);
            return old;
        }

        /// END: the file dated and marked for archiving if it was written
        /// to, and its lock freed.
        fn close(fs: *Fs, args: dos.FileHandleArgs) Error!void {
            const lock = try fs.fileOf(args.fh);
            const key = lock.key();
            if (lock.modified and fs.media.writable()) try fs.syncKey(key, fs.now());
            fs.freeLock(lock);
            args.fh.?.key = null;
        }

        /// SET_FILE_SIZE: the file cut or grown, grown with zeroes; handles
        /// past the new end move back to it. The new size.
        fn setFileSize(fs: *Fs, args: dos.SeekArgs) Error!u32 {
            const lock = try fs.fileOf(args.fh);
            try fs.writable();
            const key = lock.key();
            const from: i64 = switch (args.mode) {
                dos.OFFSET_BEGINNING => 0,
                dos.OFFSET_CURRENT => lock.pos,
                dos.OFFSET_END => key.size,
                else => return error.SeekError,
            };
            const target = from + args.position;
            if (target < 0) return error.SeekError;
            if (target > max_size) return error.DiskFull;
            const size: u32 = @intCast(target);
            if (size < key.size) {
                const keep = (size + fs.geo.cluster_bytes - 1) / fs.geo.cluster_bytes;
                if (keep == 0) {
                    try fs.empty(key);
                } else {
                    var place: Place = .{};
                    try fs.table.cutAfter(try fs.clusterAt(key, &place, keep - 1));
                    key.size = size;
                    key.changed = true;
                    fs.forgetPlaces(key, size);
                }
            } else if (size > key.size) {
                var place: Place = .{};
                try fs.put(key, &place, key.size, null, size - key.size);
            }
            lock.modified = true;
            try fs.syncKey(key, null);
            return size;
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
            var lock: *FatLock = undefined;
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

        // --- examine ------------------------------------------------------------------

        /// A FileInfoBlock for an entry, `next` the entry to go on from.
        fn fillFound(fs: *Fs, fib: *FileInfoBlock, found: *const Found, size: u32, next: u32) void {
            const kind: i32 = if (found.isDir()) dos.ST_USERDIR else dos.ST_FILE;
            const shown: u32 = if (found.isDir()) 0 else size;
            fib.* = .{
                .disk_key = next,
                .dir_entry_type = kind,
                .entry_type = kind,
                .protection = _fat.protectionOf(found.attr),
                .size = shown,
                .num_blocks = (@as(u64, shown) + fs.geo.cluster_bytes - 1) / fs.geo.cluster_bytes,
                .date = _fat.dateOf(fs.ub, found.write),
            };
            const name = found.name();
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
            var object: Object = .{};
            try fs.keyObject(key, &object);
            fs.fillFound(fib, &object.found, key.size, 0);
            fib.protection = _fat.protectionOf(key.attr);
        }

        /// EXAMINE_FH: the open file's own entry.
        fn examineFile(fs: *Fs, args: dos.ExamineFHArgs) Error!void {
            const lock = try fs.fileOf(args.fh);
            try fs.fillKey(args.fib orelse return error.InvalidLock, lock.key());
        }

        /// EXAMINE_OBJECT (`next` false) and EXAMINE_NEXT. fib_DiskKey is
        /// the number of the entry to look at next: EXAMINE_OBJECT sets it
        /// to the start, and every EXAMINE_NEXT leaves it past what it
        /// gave. Entries never move, so the walk goes on correctly however
        /// much is deleted between two calls.
        fn examine(fs: *Fs, args: dos.ExamineArgs, next: bool) Error!void {
            const key = try fs.keyArg(lockValue(args.lock));
            const fib = args.fib orelse return error.InvalidLock;
            if (!next) return fs.fillKey(fib, key);
            if (!key.isDir()) return error.NoMoreEntries;
            const dir = try fs.dirCluster(key);
            var cursor = Cursor.at(dir);
            var index: u32 = @truncate(fib.disk_key);
            var found: Found = .{};
            if (!try fs.dirs.next(&cursor, &index, &found)) return error.NoMoreEntries;
            // An object that is open reports the size it has now.
            const size = if (fs.existingKey(dir, found.index)) |open_key| open_key.size else found.size;
            fs.fillFound(fib, &found, size, index);
        }

        // --- changing -------------------------------------------------------------------

        /// Whether `inner` is `outer` or inside it: a directory must not be
        /// moved into itself.
        fn within(fs: *Fs, inner: u32, outer: u32) Error!bool {
            var dir = inner;
            var steps: u32 = 0;
            while (true) : (steps += 1) {
                if (dir == outer) return true;
                if (dir == fs.geo.root_cluster) return false;
                if (steps > fs.geo.cluster_count) return error.MediumFailed;
                dir = try fs.dirs.parentOf(dir);
            }
        }

        /// RENAME_OBJECT: the entry written again under its new name in its
        /// new directory, dates and all, and the old one erased.
        fn rename(fs: *Fs, args: dos.RenameArgs) Error!void {
            try fs.writable();
            var from: Object = .{};
            try fs.locate(lockValue(args.from_lock), args.from_name orelse return error.InvalidName, &from);
            if (from.is_root) return error.WrongType;
            const target = try fs.findDir(try fs.keyArg(lockValue(args.to_lock)), args.to_name orelse return error.InvalidName);
            try names.validLong(target.name);

            var there: Found = .{};
            if (try fs.dirs.find(target.dir, target.name, &there)) {
                // Only the object itself may already have the name: a
                // rename that changes nothing but the case.
                if (target.dir != from.dir or there.index != from.found.index) return error.Exists;
            }
            if (from.found.isDir() and try fs.within(target.dir, fs.clusterOfDir(&from.found))) return error.InUse;
            const key = fs.existingKey(from.dir, from.found.index);
            if (key) |other| if (fs.otherLock(other, null, true)) return error.InUse;

            // The entry's bytes past its name - attributes, dates, cluster,
            // size - kept to go into the new one.
            var old: [fat.entry_bytes]u8 = undefined;
            @memcpy(&old, try fs.dirs.entryForWrite(from.found.spot));

            var made: Found = .{};
            try fs.dirs.create(target.dir, target.name, .{
                .attr = from.found.attr,
                .cluster = from.found.cluster,
                .size = from.found.size,
                .stamp = from.found.write,
            }, &made);
            const entry = try fs.dirs.entryForWrite(made.spot);
            @memcpy(entry[fat.ent_create_tenth..], old[fat.ent_create_tenth..]);
            try fs.dirs.erase(from.dir, &from.found);
            if (from.found.isDir() and target.dir != from.dir) try fs.dirs.setParent(fs.clusterOfDir(&from.found), target.dir);

            // Its locks follow it to where it is now.
            if (key) |other| {
                other.dir = target.dir;
                other.index = made.index;
                other.spot = made.spot;
            }
        }

        /// SET_PROTECT and SET_DATE on (lock, name). The format keeps no
        /// comment and no owner, so those two are not known.
        fn setProperty(fs: *Fs, args: dos.PropertyArgs, action: dos.ActionCode) Error!void {
            if (action == .set_comment or action == .set_owner) return error.NotImplemented;
            try fs.writable();
            var object: Object = .{};
            try fs.locate(lockValue(args.lock), args.name orelse return error.InvalidName, &object);
            if (object.is_root) return error.WrongType;
            const entry = try fs.dirs.entryForWrite(object.found.spot);
            const key = fs.existingKey(object.dir, object.found.index);
            switch (action) {
                .set_protect => {
                    const attr = _fat.attributeOf(@truncate(ptrArg(args.value)), entry[fat.ent_attr]);
                    entry[fat.ent_attr] = attr;
                    if (key) |other| other.attr = attr;
                },
                else => {
                    const date: ?*const dos.DateStamp = @ptrFromInt(ptrArg(args.value));
                    const stamp = if (date) |into| _fat.stampOf(fs.ub, into.*) else fs.now();
                    dir_area.stamp(entry, stamp, false);
                },
            }
        }

        /// INFO and DISK_INFO: the volume in clusters, how many are in use.
        fn info(fs: *Fs, data: ?*dos.InfoData) Error!void {
            const into = data orelse return error.InvalidLock;
            const unused = try fs.table.freeClusters();
            into.* = .{
                .num_soft_errors = 0,
                .unit_number = 0,
                .disk_state = if (fs.media.writable()) dos.ID_VALIDATED else dos.ID_WRITE_PROTECTED,
                .num_blocks = fs.geo.cluster_count,
                .num_blocks_used = fs.geo.cluster_count - unused,
                .bytes_per_block = fs.geo.cluster_bytes,
                .disk_type = dos.ID_MSDOS_DISK,
                .volume_node = fs.volume_node,
                .in_use = if (fs.locks != null) -1 else 0,
            };
        }

        // --- packets --------------------------------------------------------------------

        /// The answer to one packet (all but STARTUP, which the process
        /// takes). What a packet changed is on the medium before it is
        /// answered.
        pub fn answer(fs: *Fs, pkt: *DosPacket) Answer {
            const result = fs.respond(pkt);
            switch (pkt.getAction()) {
                .create_dir,
                .delete_object,
                .rename_object,
                .set_protect,
                .set_date,
                .set_file_size,
                .findoutput,
                .findupdate,
                .write,
                .end,
                .flush,
                => if (fs.mounted) fs.table.flush() catch |err| {
                    // A packet that did its work is not answered as done
                    // if the work did not reach the medium.
                    if (result.res1 != dos.DOSFALSE and result.res1 != -1) return no(err);
                },
                else => {},
            }
            return result;
        }

        fn respond(fs: *Fs, pkt: *DosPacket) Answer {
            const raw = pkt.args.raw;
            switch (pkt.getAction()) {
                .locate_object => {
                    var object: Object = .{};
                    fs.locate(raw[0], @ptrFromInt(ptrArg(raw[1])), &object) catch |err| return no(err);
                    const key = fs.keyOf(&object) catch |err| return no(err);
                    const lock = fs.getLock(key, @truncate(raw[2])) catch |err| {
                        if (key.locks == 0) fs.dropKey(key);
                        return no(err);
                    };
                    return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
                },
                .free_lock => {
                    const lock = fs.lockArg(raw[0]) catch |err| {
                        // A lock from a card that has gone is still freed.
                        if (err == error.InvalidLock and raw[0] != 0) {
                            const stale: *FatLock = @ptrFromInt(ptrArg(raw[0]));
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
                    return .{ .res1 = @intCast(old), .res2 = 0 };
                },
                .end => {
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
                .rename_object => {
                    fs.rename(pkt.args.rename) catch |err| return no(err);
                    return yes();
                },
                .set_protect, .set_comment, .set_date, .set_owner => {
                    fs.setProperty(pkt.args.property, pkt.getAction()) catch |err| return no(err);
                    return yes();
                },
                .set_file_size => {
                    const size = fs.setFileSize(pkt.args.seek) catch |err| return minusOne(err);
                    return .{ .res1 = @intCast(size), .res2 = 0 };
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
                .is_filesystem => return yes(),
                .die => return no(error.InUse),
                else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
            }
        }

        /// A shared lock on a key's object itself, or on the directory it
        /// is in; the root has no parent and answers 0.
        fn lockParentOrSelf(fs: *Fs, key: *Key, parent: bool) Answer {
            var target = key;
            if (parent) {
                if (key.is_root) return .{ .res1 = 0, .res2 = 0 };
                var object: Object = .{};
                fs.directoryObject(key.dir, &object) catch |err| return no(err);
                target = fs.keyOf(&object) catch |err| return no(err);
            }
            const lock = fs.getLock(target, dos.SHARED_LOCK) catch |err| {
                if (target.locks == 0) fs.dropKey(target);
                return no(err);
            };
            return .{ .res1 = @bitCast(@intFromPtr(lock)), .res2 = 0 };
        }
    };
}
