// SPDX-License-Identifier: MIT
//! Directories on an exFAT volume: runs of 32-byte entries, a file being
//! one **set** of them - its file entry, its stream extension, and one
//! name entry for every fifteen characters of its name - held together by
//! a checksum over the whole set.
//!
//! **A directory is its chain and its length**, not a cluster alone: a
//! subdirectory's clusters may be one run with no table entries, and how
//! long it is is in its own stream entry, in its parent. The root has no
//! entry; it is linked through the table and is as long as its chain.
//! There are no "." and ".." entries - where a directory is in the tree is
//! known only to whoever walked down to it (`fs.zig` keeps that).
//!
//! **An entry is found by its index** - its place counted from the start
//! of the directory in entries - which never changes while the entry is
//! there, so a lock can keep it and a listing can go on from it.
//!
//! **A set that does not add up is passed over**: a checksum that does
//! not hold, a secondary missing or of the wrong kind, a name shorter than
//! its stream says. It is not the handler's to repair, and reading on past
//! it keeps every other file in the directory reachable.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const names = @import("names.zig");
const Upcase = @import("upcase.zig").Upcase;
const Error = _fat.Error;
const Geometry = layout.Geometry;
const Chain = table_area.Chain;
const Place = table_area.Place;
const UtilityBase = sdk.interface.utility.UtilityBase;

const entry_bytes = fat.entry_bytes;

/// The most entries a set has: the file entry and its secondaries.
pub const max_set: usize = 1 + fat.exfat_max_secondaries;

/// A directory: where its clusters are and how many bytes it holds.
pub const Dir = struct {
    chain: Chain,
    length: u64,
};

/// Where an entry lies: the block and the byte in it.
pub const Spot = struct { block: u64, at: u32 };

/// An exFAT moment: the date in the high half and the time in the low, as
/// FAT keeps them in two words.
pub fn stampOf(moment: u32) _fat.Stamp {
    return .{ .time = @truncate(moment), .date = @truncate(moment >> 16) };
}

pub fn momentOf(stamp: _fat.Stamp) u32 {
    return (@as(u32, stamp.date) << 16) | stamp.time;
}

/// One file's set, as read.
pub const Found = struct {
    /// The file entry's index, and how many entries the set has.
    index: u32 = 0,
    count: u32 = 0,
    attr: u16 = 0,
    created: u32 = 0,
    modified: u32 = 0,
    /// The zone `modified` is in: its offset from UTC in quarter hours,
    /// in the low seven bits, if bit 7 says there is one.
    modified_zone: u8 = 0,
    flags: u8 = 0,
    first: u32 = 0,
    valid: u64 = 0,
    size: u64 = 0,
    hash: u16 = 0,
    name_len: usize = 0,
    name_units: [fat.name_max]u16 = undefined,

    pub fn name(found: *const Found) []const u16 {
        return found.name_units[0..found.name_len];
    }

    pub fn isDir(found: *const Found) bool {
        return found.attr & _fat.ATTR_DIRECTORY != 0;
    }

    /// Where its clusters are. A stream with no allocation has none.
    pub fn chain(found: *const Found) Chain {
        if (found.flags & fat.exfat_allocation_possible == 0) return .{};
        return .{ .first = found.first, .contiguous = found.flags & fat.exfat_no_fat_chain != 0 };
    }
};

/// A set's bytes, to be changed and written back as a whole: the checksum
/// covers every entry of it.
pub const Set = struct {
    bytes: [max_set * entry_bytes]u8 = @splat(0),
    count: u32 = 0,

    pub fn entry(set: *Set, at: usize) []u8 {
        return set.bytes[at * entry_bytes ..][0..entry_bytes];
    }

    /// The stream's fields: where the data is and how much there is.
    pub fn setStream(set: *Set, chain: Chain, valid: u64, size: u64) void {
        const stream = set.entry(1);
        var flags = stream[fat.exfat_stream_flags] & ~(fat.exfat_allocation_possible | fat.exfat_no_fat_chain);
        if (chain.first != 0) {
            flags |= fat.exfat_allocation_possible;
            if (chain.contiguous) flags |= fat.exfat_no_fat_chain;
        }
        stream[fat.exfat_stream_flags] = flags;
        fat.putU32(stream, fat.exfat_stream_cluster, chain.first);
        fat.putU64(stream, fat.exfat_stream_valid_length, valid);
        fat.putU64(stream, fat.exfat_stream_data_length, size);
    }

    pub fn setAttributes(set: *Set, attr: u16) void {
        fat.putU16(set.entry(0), fat.exfat_file_attributes, attr);
    }

    pub fn attributes(set: *Set) u16 {
        return fat.u16At(set.entry(0), fat.exfat_file_attributes);
    }

    /// The moment it was last changed, and the zone byte that says which
    /// time zone the moment is in; with `created`, when it was made as
    /// well. The hundredths are cleared: this system does not keep them.
    pub fn setModified(set: *Set, moment: u32, zone: u8, created: bool) void {
        const file = set.entry(0);
        fat.putU32(file, fat.exfat_file_modified, moment);
        fat.putU32(file, fat.exfat_file_accessed, moment);
        file[fat.exfat_file_modified_10ms] = 0;
        file[fat.exfat_file_modified_utc] = zone;
        file[fat.exfat_file_accessed_utc] = zone;
        if (created) {
            fat.putU32(file, fat.exfat_file_created, moment);
            file[fat.exfat_file_created_10ms] = 0;
            file[fat.exfat_file_created_utc] = zone;
        }
    }

    /// A new set for a file named `name`, `hash` its name's hash.
    pub fn compose(set: *Set, name: []const u16, hash: u16, attr: u16, moment: u32, zone: u8) void {
        const name_entries = (name.len + fat.exfat_name_chars - 1) / fat.exfat_name_chars;
        set.* = .{};
        set.count = @intCast(2 + name_entries);
        const file = set.entry(0);
        file[0] = fat.exfat_type_file;
        file[fat.exfat_file_secondaries] = @intCast(set.count - 1);
        set.setAttributes(attr);
        set.setModified(moment, zone, true);
        const stream = set.entry(1);
        stream[0] = fat.exfat_type_stream;
        stream[fat.exfat_stream_name_length] = @intCast(name.len);
        fat.putU16(stream, fat.exfat_stream_name_hash, hash);
        for (0..name_entries) |piece| {
            const into = set.entry(2 + piece);
            into[0] = fat.exfat_type_name;
            for (0..fat.exfat_name_chars) |char| {
                const at = piece * fat.exfat_name_chars + char;
                // What is left after the name's end is 0, as the format asks.
                const unit: u16 = if (at < name.len) name[at] else 0;
                fat.putU16(into, fat.exfat_name_chars_at + char * 2, unit);
            }
        }
    }

    /// The checksum of the set as it is now, into its file entry.
    pub fn seal(set: *Set) void {
        var sum: u16 = 0;
        for (0..set.count) |at| sum = fat.exfatSetChecksum(sum, set.entry(at), at == 0);
        fat.putU16(set.entry(0), fat.exfat_file_checksum, sum);
    }
};

/// What a root directory holds besides files: where the allocation bitmap
/// and the up-case table are, and the volume's label.
pub const System = struct {
    bitmap_first: u32 = 0,
    bitmap_length: u64 = 0,
    upcase_first: u32 = 0,
    upcase_length: u64 = 0,
    upcase_checksum: u32 = 0,
    label_len: usize = 0,
    label: [fat.exfat_label_max]u16 = @splat(0),
    /// The label entry's index, if there is one.
    label_index: ?u32 = null,
};

pub fn Directory(comptime Media: type) type {
    return struct {
        const Self = @This();
        const Cache = cache_area.BlockCache(Media);
        const Table = table_area.Table(Media);

        cache: *Cache,
        table: *Table,
        geo: *const Geometry,
        upcase: *const Upcase,
        ub: *UtilityBase,

        /// Where entry `index` of `dir` lies, or null past its end. `place`
        /// is where the walk along its chain got to, kept between calls.
        pub fn spotOf(self: *Self, dir: Dir, index: u32, place: *Place) Error!?Spot {
            const offset = @as(u64, index) * entry_bytes;
            if (offset >= dir.length) return null;
            const cluster_bits: u6 = @as(u6, self.geo.sector_shift) + self.geo.cluster_shift;
            const cluster = try self.table.clusterAt(dir.chain, place, offset >> cluster_bits);
            const in_cluster = offset & (self.geo.cluster_bytes - 1);
            return .{
                .block = self.geo.clusterBlock(cluster) + (in_cluster >> self.geo.sector_shift),
                .at = @intCast(in_cluster & (self.geo.sector_bytes - 1)),
            };
        }

        /// Entry `index`, copied into `into`. False past the directory's end.
        fn readEntry(self: *Self, dir: Dir, index: u32, place: *Place, into: []u8) Error!bool {
            const spot = try self.spotOf(dir, index, place) orelse return false;
            const block = self.cache.get(spot.block) catch return error.MediumFailed;
            @memcpy(into[0..entry_bytes], block[spot.at..][0..entry_bytes]);
            return true;
        }

        /// The set whose file entry is at `index`, into `set`: false if
        /// there is no whole, sound set there.
        pub fn readSet(self: *Self, dir: Dir, index: u32, set: *Set) Error!bool {
            var place: Place = .{};
            if (!try self.readEntry(dir, index, &place, set.entry(0))) return false;
            const file = set.entry(0);
            if (file[0] != fat.exfat_type_file) return false;
            const secondaries = file[fat.exfat_file_secondaries];
            if (secondaries < 2 or secondaries > fat.exfat_max_secondaries) return false;
            set.count = @as(u32, secondaries) + 1;
            var sum = fat.exfatSetChecksum(0, file, true);
            for (1..set.count) |at| {
                if (!try self.readEntry(dir, index + @as(u32, @intCast(at)), &place, set.entry(at))) return false;
                const entry = set.entry(at);
                // Every secondary is in use and is a secondary.
                if (entry[0] & (fat.exfat_entry_in_use | fat.exfat_entry_secondary) != (fat.exfat_entry_in_use | fat.exfat_entry_secondary)) return false;
                sum = fat.exfatSetChecksum(sum, entry, false);
            }
            if (sum != fat.u16At(file, fat.exfat_file_checksum)) return false;
            return set.entry(1)[0] == fat.exfat_type_stream;
        }

        /// A set's fields and name, from its bytes. False if its name
        /// entries do not hold the name its stream says.
        fn decode(set: *Set, index: u32, found: *Found) bool {
            const file = set.entry(0);
            const stream = set.entry(1);
            found.* = .{
                .index = index,
                .count = set.count,
                .attr = fat.u16At(file, fat.exfat_file_attributes),
                .created = fat.u32At(file, fat.exfat_file_created),
                .modified = fat.u32At(file, fat.exfat_file_modified),
                .modified_zone = file[fat.exfat_file_modified_utc],
                .flags = stream[fat.exfat_stream_flags],
                .first = fat.u32At(stream, fat.exfat_stream_cluster),
                .valid = fat.u64At(stream, fat.exfat_stream_valid_length),
                .size = fat.u64At(stream, fat.exfat_stream_data_length),
                .hash = fat.u16At(stream, fat.exfat_stream_name_hash),
            };
            const name_len = stream[fat.exfat_stream_name_length];
            if (name_len == 0) return false;
            var len: usize = 0;
            for (2..set.count) |at| {
                const entry = set.entry(at);
                // A benign secondary a vendor added is passed over.
                if (entry[0] != fat.exfat_type_name) continue;
                for (0..fat.exfat_name_chars) |char| {
                    if (len == name_len) break;
                    found.name_units[len] = fat.u16At(entry, fat.exfat_name_chars_at + char * 2);
                    len += 1;
                }
            }
            if (len != name_len) return false;
            found.name_len = len;
            return true;
        }

        /// The set at exactly `index`, decoded: false if there is none.
        pub fn load(self: *Self, dir: Dir, index: u32, found: *Found) Error!bool {
            var set: Set = .{};
            if (!try self.readSet(dir, index, &set)) return false;
            return decode(&set, index, found);
        }

        /// The next file at or after `index.*`, and `index.*` moved past
        /// it. False at the end of the directory. Deleted entries, the
        /// volume's own entries and sets that do not add up are passed
        /// over.
        pub fn next(self: *Self, dir: Dir, index: *u32, found: *Found) Error!bool {
            var place: Place = .{};
            var entry: [entry_bytes]u8 = undefined;
            while (true) {
                if (!try self.readEntry(dir, index.*, &place, &entry)) return false;
                const kind = entry[0];
                if (kind == fat.exfat_entry_end) return false;
                if (kind == fat.exfat_type_file) {
                    var set: Set = .{};
                    if (try self.readSet(dir, index.*, &set) and decode(&set, index.*, found)) {
                        index.* += set.count;
                        return true;
                    }
                    index.* += 1;
                    continue;
                }
                // A benign primary another system added: it and its
                // secondaries. The bitmap, up-case and label entries have
                // no secondaries; nor has an entry not in use.
                const benign_primary = kind & (fat.exfat_entry_in_use | fat.exfat_entry_secondary | fat.exfat_entry_benign) == (fat.exfat_entry_in_use | fat.exfat_entry_benign);
                index.* += if (benign_primary) @as(u32, entry[1]) + 1 else 1;
            }
        }

        /// The file named `wanted` in `dir`: its set in `found`, or false.
        pub fn find(self: *Self, dir: Dir, wanted: *const names.Wanted, found: *Found) Error!bool {
            var index: u32 = 0;
            while (try self.next(dir, &index, found)) {
                if (wanted.matches(self.ub, self.upcase, found.name(), found.hash)) return true;
            }
            return false;
        }

        /// The set whose stream names cluster `first`: a directory's own
        /// entry in its parent.
        pub fn findCluster(self: *Self, dir: Dir, first: u32, found: *Found) Error!bool {
            var index: u32 = 0;
            while (try self.next(dir, &index, found)) {
                if (found.first == first and found.flags & fat.exfat_allocation_possible != 0) return true;
            }
            return false;
        }

        /// Whether a directory holds no file.
        pub fn empty(self: *Self, dir: Dir) Error!bool {
            var index: u32 = 0;
            var found: Found = .{};
            return !try self.next(dir, &index, &found);
        }

        /// Where `count` entries in a row are free in `dir`: entries no
        /// longer in use, and everything from the directory's end marker
        /// on. Null if the directory is too short for them - it has to
        /// grow first.
        pub fn room(self: *Self, dir: Dir, count: u32) Error!?u32 {
            var place: Place = .{};
            var entry: [entry_bytes]u8 = undefined;
            var index: u32 = 0;
            var run_start: u32 = 0;
            var run: u32 = 0;
            while (try self.readEntry(dir, index, &place, &entry)) : (index += 1) {
                if (entry[0] == fat.exfat_entry_end) {
                    // Everything past the end marker is free too.
                    const left = dir.length / entry_bytes - index;
                    if (run + left >= count) return if (run > 0) run_start else index;
                    return null;
                }
                if (entry[0] & fat.exfat_entry_in_use == 0) {
                    if (run == 0) run_start = index;
                    run += 1;
                    if (run == count) return run_start;
                } else {
                    run = 0;
                }
            }
            return null;
        }

        /// A set written at `index`, sealed with its checksum first.
        pub fn writeSet(self: *Self, dir: Dir, index: u32, set: *Set) Error!void {
            set.seal();
            var place: Place = .{};
            for (0..set.count) |at| {
                const spot = try self.spotOf(dir, index + @as(u32, @intCast(at)), &place) orelse return error.MediumFailed;
                const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
                @memcpy(block[spot.at..][0..entry_bytes], set.entry(at));
            }
        }

        /// One entry written at `index`, as it is: the volume label's, which
        /// is no set and has no checksum.
        pub fn writeEntry(self: *Self, dir: Dir, index: u32, entry: *const [entry_bytes]u8) Error!void {
            var place: Place = .{};
            const spot = try self.spotOf(dir, index, &place) orelse return error.MediumFailed;
            const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
            @memcpy(block[spot.at..][0..entry_bytes], entry);
        }

        /// A set taken out of use, its entries left for the next one to
        /// reuse.
        pub fn erase(self: *Self, dir: Dir, index: u32, count: u32) Error!void {
            var place: Place = .{};
            for (0..count) |at| {
                const spot = try self.spotOf(dir, index + @as(u32, @intCast(at)), &place) orelse return error.MediumFailed;
                const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
                block[spot.at] &= ~fat.exfat_entry_in_use;
            }
        }

        /// The root's own entries: the bitmap, the up-case table and the
        /// label. A volume whose root lacks either of the first two is not
        /// one this can read.
        pub fn system(self: *Self, root: Dir) Error!System {
            var place: Place = .{};
            var entry: [entry_bytes]u8 = undefined;
            var found: System = .{};
            var index: u32 = 0;
            var have_bitmap = false;
            var have_upcase = false;
            while (try self.readEntry(root, index, &place, &entry)) : (index += 1) {
                switch (entry[0]) {
                    fat.exfat_entry_end => break,
                    fat.exfat_type_bitmap => if (!have_bitmap) {
                        // With two tables, the first bitmap goes with the
                        // first; only one table is kept here.
                        found.bitmap_first = fat.u32At(&entry, fat.exfat_region_cluster);
                        found.bitmap_length = fat.u64At(&entry, fat.exfat_region_length);
                        have_bitmap = true;
                    },
                    fat.exfat_type_upcase => {
                        found.upcase_first = fat.u32At(&entry, fat.exfat_region_cluster);
                        found.upcase_length = fat.u64At(&entry, fat.exfat_region_length);
                        found.upcase_checksum = fat.u32At(&entry, fat.exfat_upcase_checksum);
                        have_upcase = true;
                    },
                    fat.exfat_type_label => {
                        found.label_len = @min(entry[fat.exfat_label_length], fat.exfat_label_max);
                        for (0..found.label_len) |char| found.label[char] = fat.u16At(&entry, fat.exfat_label_chars + char * 2);
                        found.label_index = index;
                    },
                    else => {},
                }
            }
            if (!have_bitmap or !have_upcase) return error.MediumFailed;
            return found;
        }

        /// A new directory cluster made zeroes, so it begins with its end
        /// marker: straight to the medium, a sector of zeroes from
        /// `scratch` at a time, rather than through the cache, which a
        /// 128 KiB cluster would empty of everything worth keeping.
        pub fn clear(self: *Self, cluster: u32, scratch: []u8) Error!void {
            @memset(scratch, 0);
            const first = self.geo.clusterBlock(cluster);
            for (0..self.geo.sectors_per_cluster) |sector| {
                self.cache.writeRun(first + sector, 1, scratch[0..self.geo.sector_bytes]) catch return error.MediumFailed;
            }
        }
    };
}
