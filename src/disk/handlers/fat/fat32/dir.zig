// SPDX-License-Identifier: MIT
//! Directories: a run of 32-byte entries in a chain of clusters, the root
//! directory included - on this format it is a chain like any other.
//!
//! **An entry is known by its directory and its number in it.** Nothing
//! on the medium moves an entry once it is written: deleting one only
//! marks it, and a directory never closes up. So (directory, number) is
//! a name for an entry that stays true for as long as the entry is
//! there, and it is what a lock keeps and what examine counts with.
//!
//! **A cursor** walks a directory's chain. It remembers the cluster it is
//! in, so going on to the next entry costs nothing, and only a step back
//! sends it round from the start again.
//!
//! **A scan** puts long names together as it goes. Their pieces come
//! before the entry they name, last piece first; a run of pieces counts
//! only if it is whole and carries the check of the short name after it
//! (`names.LongName`).
//!
//! **A new entry** takes the first run of free slots long enough for it
//! and its long name, and the directory grows by a cluster if there is
//! no such run - the new cluster zeroed first, because a zero entry is
//! what says nothing comes after it.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const names = @import("names.zig");
const Error = _fat.Error;
const Geometry = layout.Geometry;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The most entries a directory may have: the format keeps a directory
/// under 2 MiB so that an entry's number fits sixteen bits.
pub const max_entries: u32 = 65536;

/// An entry's size and the most pieces a long name has, in the width the
/// entry numbers are counted in.
const entry_size: u32 = fat.entry_bytes;
const most_pieces: u32 = fat.lfn_max_pieces;

/// Where one entry lies on the medium.
pub const Spot = struct { block: u64, at: u32 };

/// An entry a scan found, with its name put together.
pub const Found = struct {
    /// The entry's number in its directory, and the number of the first
    /// piece of its long name (the same when it has none).
    index: u32 = 0,
    first_index: u32 = 0,
    spot: Spot = .{ .block = 0, .at = 0 },
    /// The eleven bytes of its short name, as stored.
    short: [fat.ent_name_bytes]u8 = @splat(' '),
    attr: u8 = 0,
    cluster: u32 = 0,
    size: u32 = 0,
    write: _fat.Stamp = .{ .time = 0, .date = 0 },
    /// The name dos is given (`names` says which one that is).
    name_buf: [fat.name_max]u8 = undefined,
    name_len: usize = 0,
    /// The long name in Latin-1, when there is one, for matching.
    long_buf: [fat.name_max]u8 = undefined,
    long_len: usize = 0,
    /// The short name spelled out, for matching.
    short_buf: [names.short_max]u8 = undefined,
    short_len: usize = 0,

    pub fn name(found: *const Found) []const u8 {
        return found.name_buf[0..found.name_len];
    }

    pub fn isDir(found: *const Found) bool {
        return found.attr & _fat.ATTR_DIRECTORY != 0;
    }

    /// Whether `wanted` is this entry's long name or its short one.
    pub fn named(found: *const Found, ub: *UtilityBase, wanted: []const u8) bool {
        if (found.long_len != 0 and names.same(ub, found.long_buf[0..found.long_len], wanted)) return true;
        return names.same(ub, found.short_buf[0..found.short_len], wanted);
    }
};

/// A place in a directory's chain.
pub const Cursor = struct {
    /// The directory's first cluster.
    first: u32,
    /// The cluster the cursor is in, and which one of the chain it is.
    cluster: u32,
    ordinal: u32 = 0,

    pub fn at(first: u32) Cursor {
        return .{ .first = first, .cluster = first };
    }
};

/// What a new entry is given.
pub const Entry = struct {
    attr: u8,
    cluster: u32 = 0,
    size: u32 = 0,
    stamp: _fat.Stamp,
};

pub fn Directory(comptime Media: type) type {
    return struct {
        const Self = @This();
        const Cache = cache_area.BlockCache(Media);
        const Table = table_area.Table(Media);

        cache: *Cache,
        table: *Table,
        geo: *const Geometry,
        ub: *UtilityBase,

        fn entriesPerCluster(self: *const Self) u32 {
            return self.geo.cluster_bytes / entry_size;
        }

        /// Where entry `index` lies, the cursor moved to its cluster; null
        /// if the directory's chain ends before it.
        pub fn spotOf(self: *Self, cursor: *Cursor, index: u32) Error!?Spot {
            const per_cluster = self.entriesPerCluster();
            const ordinal = index / per_cluster;
            if (ordinal < cursor.ordinal) cursor.* = Cursor.at(cursor.first);
            while (cursor.ordinal < ordinal) {
                cursor.cluster = try self.table.next(cursor.cluster) orelse return null;
                cursor.ordinal += 1;
            }
            const byte = (index % per_cluster) * entry_size;
            return .{
                .block = self.geo.clusterBlock(cursor.cluster) + byte / self.geo.sector_bytes,
                .at = byte % self.geo.sector_bytes,
            };
        }

        /// Entry `index`'s 32 bytes, or null past the end of the chain.
        /// Good until the next call that reads a block.
        fn raw(self: *Self, cursor: *Cursor, index: u32) Error!?[]const u8 {
            const spot = try self.spotOf(cursor, index) orelse return null;
            const block = self.cache.get(spot.block) catch return error.MediumFailed;
            return block[spot.at..][0..fat.entry_bytes];
        }

        fn rawForWrite(self: *Self, cursor: *Cursor, index: u32) Error![]u8 {
            const spot = try self.spotOf(cursor, index) orelse return error.MediumFailed;
            const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
            return block[spot.at..][0..fat.entry_bytes];
        }

        /// The next entry at or after `index.*` that names a file or a
        /// directory, with its name; `index.*` is left past it. Null at
        /// the end of the directory.
        pub fn next(self: *Self, cursor: *Cursor, index: *u32, found: *Found) Error!bool {
            var long: names.LongName = .{};
            var long_first: u32 = index.*;
            while (index.* < max_entries) {
                const here = index.*;
                const entry = try self.raw(cursor, here) orelse return false;
                index.* += 1;
                const first_byte = entry[fat.ent_name];
                if (first_byte == _fat.entry_end) return false;
                if (first_byte == _fat.entry_erased) {
                    long.reset();
                    continue;
                }
                if (fat.isLongName(entry)) {
                    if (entry[fat.lfn_order] & fat.lfn_last != 0) long_first = here;
                    long.take(entry);
                    continue;
                }
                // A volume label, and the two entries that lead back.
                if (entry[fat.ent_attr] & _fat.ATTR_VOLUME_LABEL != 0 or first_byte == '.') {
                    long.reset();
                    continue;
                }
                const whole = long.completes(entry);
                self.fill(found, entry, here, if (whole) long_first else here, if (whole) &long else null);
                found.spot = (try self.spotOf(cursor, here)).?;
                return true;
            }
            return false;
        }

        fn fill(self: *Self, found: *Found, entry: []const u8, index: u32, first_index: u32, long: ?*const names.LongName) void {
            found.index = index;
            found.first_index = first_index;
            @memcpy(&found.short, entry[0..fat.ent_name_bytes]);
            found.attr = entry[fat.ent_attr];
            found.cluster = fat.entryCluster(entry);
            found.size = fat.u32At(entry, fat.ent_size);
            found.write = .{
                .time = fat.u16At(entry, fat.ent_write_time),
                .date = fat.u16At(entry, fat.ent_write_date),
            };
            const short = names.shortName(self.ub, entry, &found.short_buf);
            found.short_len = short.len;
            found.long_len = 0;
            if (long) |pieces| {
                if (pieces.latin1(&found.long_buf)) |text| found.long_len = text.len;
            }
            const given = if (found.long_len != 0 and found.long_len <= names.fib_name_max)
                found.long_buf[0..found.long_len]
            else
                short;
            @memcpy(found.name_buf[0..given.len], given);
            found.name_len = given.len;
        }

        /// The entry in directory `first` called `wanted`, by either name.
        pub fn find(self: *Self, first: u32, wanted: []const u8, found: *Found) Error!bool {
            var cursor = Cursor.at(first);
            var index: u32 = 0;
            while (try self.next(&cursor, &index, found)) {
                if (found.named(self.ub, wanted)) return true;
            }
            return false;
        }

        /// The entry of directory `first` whose chain starts at `cluster`:
        /// how a directory is found from its parent.
        pub fn findCluster(self: *Self, first: u32, cluster: u32, found: *Found) Error!bool {
            var cursor = Cursor.at(first);
            var index: u32 = 0;
            while (try self.next(&cursor, &index, found)) {
                if (found.cluster == cluster and found.isDir()) return true;
            }
            return false;
        }

        /// The entry at `index` of directory `first`, whole, with its long
        /// name - for a lock that knows only where its entry is.
        pub fn at(self: *Self, first: u32, index: u32, found: *Found) Error!bool {
            var cursor = Cursor.at(first);
            // The long name is before the entry: scan from the start of
            // the run, which is at most twenty pieces back.
            var from: u32 = if (index > most_pieces) index - most_pieces else 0;
            while (try self.next(&cursor, &from, found)) {
                if (found.index == index) return true;
                if (found.index > index) return false;
            }
            return false;
        }

        /// Whether a directory has nothing in it but its two leading
        /// entries.
        pub fn empty(self: *Self, first: u32) Error!bool {
            var cursor = Cursor.at(first);
            var index: u32 = 0;
            var found: Found = .{};
            return !(try self.next(&cursor, &index, &found));
        }

        /// The first cluster of a directory's parent: what its `..` entry
        /// says, with 0 - how the format writes the root - made the root's
        /// own cluster.
        pub fn parentOf(self: *Self, first: u32) Error!u32 {
            if (first == self.geo.root_cluster) return first;
            var cursor = Cursor.at(first);
            const entry = try self.raw(&cursor, 1) orelse return error.MediumFailed;
            if (entry[0] != '.' or entry[1] != '.') return error.MediumFailed;
            const parent = fat.entryCluster(entry);
            return if (parent == 0) self.geo.root_cluster else parent;
        }

        /// The volume's label: the root directory's label entry, spaces
        /// cut; empty if it has none.
        pub fn label(self: *Self, into: *[fat.ent_name_bytes]u8) Error![]const u8 {
            var cursor = Cursor.at(self.geo.root_cluster);
            var index: u32 = 0;
            while (index < max_entries) : (index += 1) {
                const entry = try self.raw(&cursor, index) orelse break;
                if (entry[0] == _fat.entry_end) break;
                if (entry[0] == _fat.entry_erased or fat.isLongName(entry)) continue;
                if (entry[fat.ent_attr] & _fat.ATTR_VOLUME_LABEL == 0) continue;
                @memcpy(into, entry[0..fat.ent_name_bytes]);
                var len: usize = fat.ent_name_bytes;
                while (len > 0 and into[len - 1] == ' ') len -= 1;
                return into[0..len];
            }
            return into[0..0];
        }

        // --- making and removing entries ----------------------------------

        /// Whether any entry of directory `first` has these eleven bytes
        /// as its short name.
        fn shortTaken(self: *Self, first: u32, short: *const [fat.ent_name_bytes]u8) Error!bool {
            var cursor = Cursor.at(first);
            var index: u32 = 0;
            while (index < max_entries) : (index += 1) {
                const entry = try self.raw(&cursor, index) orelse return false;
                if (entry[0] == _fat.entry_end) return false;
                if (entry[0] == _fat.entry_erased or fat.isLongName(entry)) continue;
                var alike = true;
                for (entry[0..fat.ent_name_bytes], short) |have, want| alike = alike and have == want;
                if (alike) return true;
            }
            return false;
        }

        /// The first entry of a run of `count` free ones, the directory
        /// grown if it has none.
        fn freeRun(self: *Self, first: u32, count: u32) Error!u32 {
            var cursor = Cursor.at(first);
            var run_start: u32 = 0;
            var run: u32 = 0;
            var index: u32 = 0;
            while (index < max_entries) {
                // Where the chain ends another cluster goes on, and the
                // run carries on into it - as often as a long name needs,
                // which on the smallest clusters is more than one.
                const entry = try self.raw(&cursor, index) orelse {
                    try self.grow(cursor.cluster);
                    continue;
                };
                const byte = entry[0];
                if (byte == _fat.entry_end or byte == _fat.entry_erased) {
                    if (run == 0) run_start = index;
                    run += 1;
                    if (run == count) return run_start;
                } else {
                    run = 0;
                }
                index += 1;
            }
            return error.DiskFull;
        }

        /// One more cluster on the end of a directory, zeroed.
        fn grow(self: *Self, last: u32) Error!void {
            const cluster = try self.table.allocate(last);
            try self.zeroCluster(cluster);
        }

        /// Every block of a cluster set to zeroes, through the cache so a
        /// directory block is not read back from the medium right after.
        pub fn zeroCluster(self: *Self, cluster: u32) Error!void {
            const block = self.geo.clusterBlock(cluster);
            for (0..self.geo.sectors_per_cluster) |sector| {
                _ = self.cache.fresh(block + sector) catch return error.MediumFailed;
            }
        }

        /// A new entry in directory `first` called `name`, which the caller
        /// has made sure is not taken. Its long name goes before it if it
        /// needs one. What was made, as a scan would find it.
        pub fn create(self: *Self, first: u32, name: []const u8, what: Entry, found: *Found) Error!void {
            try names.validLong(name);
            var short: [fat.ent_name_bytes]u8 = undefined;
            var case: u8 = 0;
            var pieces: usize = 0;
            if (names.asShort(self.ub, name)) |fits| {
                short = fits.bytes;
                case = fits.case;
            } else {
                pieces = names.pieceCount(name.len);
                const basis = names.basisOf(self.ub, name);
                var number: u32 = 1;
                while (true) : (number += 1) {
                    if (number > 999_999) return error.Exists;
                    short = names.withTail(basis, number);
                    if (!try self.shortTaken(first, &short)) break;
                }
            }

            const count: u32 = @intCast(pieces + 1);
            const start = try self.freeRun(first, count);
            var cursor = Cursor.at(first);
            const checksum = fat.shortNameChecksum(&short);
            // The pieces, last one first, then the entry.
            for (0..pieces) |k| {
                const entry = try self.rawForWrite(&cursor, start + @as(u32, @intCast(k)));
                names.fillPiece(entry, name, pieces - k, checksum);
            }
            const index = start + count - 1;
            const entry = try self.rawForWrite(&cursor, index);
            @memset(entry, 0);
            @memcpy(entry[0..fat.ent_name_bytes], &short);
            entry[fat.ent_attr] = what.attr;
            entry[fat.ent_case] = case;
            fat.setEntryCluster(entry, what.cluster);
            fat.putU32(entry, fat.ent_size, what.size);
            stamp(entry, what.stamp, true);

            _ = try self.at(first, index, found);
        }

        /// An entry and the pieces of its long name marked free.
        pub fn erase(self: *Self, first: u32, found: *const Found) Error!void {
            var cursor = Cursor.at(first);
            var index = found.first_index;
            while (index <= found.index) : (index += 1) {
                const entry = try self.rawForWrite(&cursor, index);
                entry[0] = _fat.entry_erased;
            }
        }

        /// A new directory's first cluster: zeroed, then the entry that
        /// is itself and the one that is its parent - 0 for the root, as
        /// the format writes it.
        pub fn initDirectory(self: *Self, cluster: u32, parent: u32, when: _fat.Stamp) Error!void {
            try self.zeroCluster(cluster);
            var cursor = Cursor.at(cluster);
            const dot = try self.rawForWrite(&cursor, 0);
            @memcpy(dot[0..fat.ent_name_bytes], ".          ");
            dot[fat.ent_attr] = _fat.ATTR_DIRECTORY;
            fat.setEntryCluster(dot, cluster);
            stamp(dot, when, true);
            const dotdot = try self.rawForWrite(&cursor, 1);
            @memcpy(dotdot[0..fat.ent_name_bytes], "..         ");
            dotdot[fat.ent_attr] = _fat.ATTR_DIRECTORY;
            fat.setEntryCluster(dotdot, if (parent == self.geo.root_cluster) 0 else parent);
            stamp(dotdot, when, true);
        }

        /// A directory's `..` pointed at a new parent: what moving it
        /// needs.
        pub fn setParent(self: *Self, first: u32, parent: u32) Error!void {
            var cursor = Cursor.at(first);
            const dotdot = try self.rawForWrite(&cursor, 1);
            fat.setEntryCluster(dotdot, if (parent == self.geo.root_cluster) 0 else parent);
        }

        /// An entry's bytes where it lies, to be changed in place.
        pub fn entryForWrite(self: *Self, spot: Spot) Error![]u8 {
            const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
            return block[spot.at..][0..fat.entry_bytes];
        }
    };
}

/// The write date and time into an entry, and with `created` the
/// creation and access dates too.
pub fn stamp(entry: []u8, when: _fat.Stamp, created: bool) void {
    fat.putU16(entry, fat.ent_write_time, when.time);
    fat.putU16(entry, fat.ent_write_date, when.date);
    fat.putU16(entry, fat.ent_access_date, when.date);
    if (created) {
        entry[fat.ent_create_tenth] = 0;
        fat.putU16(entry, fat.ent_create_time, when.time);
        fat.putU16(entry, fat.ent_create_date, when.date);
    }
}
