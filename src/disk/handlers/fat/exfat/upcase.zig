// SPDX-License-Identifier: MIT
//! The up-case table: what every UTF-16 character is in capitals, as the
//! volume itself says. Two names are the same name on exFAT when their
//! characters are the same through this table, and the hash a stream
//! carries is taken over a name put through it - so a name is compared
//! and hashed with the table on the card, not with any rule of our own.
//!
//! **It is kept compressed on the medium**: a run of characters that stay
//! as they are is written as 0xFFFF and the run's length. It is read once,
//! when the volume is mounted, and laid out whole - 65536 characters, 128
//! KiB - so every lookup is one index. A table that ends early leaves the
//! rest as they are, which is what the format says a short table means.
//!
//! **Its checksum is checked** against the one its directory entry
//! carries. A table that does not match is refused, and so is the volume:
//! names compared with the wrong table find the wrong files.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const Error = _fat.Error;
const Geometry = layout.Geometry;
const Chain = table_area.Chain;
const Place = table_area.Place;

/// The characters there are, and so the laid-out table's length.
pub const units: usize = 0x10000;

/// A table stored compressed marks a run of unchanged characters with
/// this, followed by the run's length.
const run_mark: u16 = 0xFFFF;

pub const Upcase = struct {
    /// Every character's capital, `units` of them.
    map: []u16,

    /// The capital of a character.
    pub fn upper(self: *const Upcase, unit: u16) u16 {
        return self.map[unit];
    }

    /// A name's capitals, into `into`.
    pub fn upcase(self: *const Upcase, name: []const u16, into: []u16) []const u16 {
        for (name, 0..) |unit, at| into[at] = self.map[unit];
        return into[0..name.len];
    }

    /// The hash a stream carries for this name.
    pub fn hash(self: *const Upcase, name: []const u16) u16 {
        var upcased: [fat.name_max]u16 = undefined;
        return fat.exfatNameHash(self.upcase(name, &upcased));
    }

    /// Whether two names are the same name: the same length, and the same
    /// characters once both are put through the table.
    pub fn same(self: *const Upcase, one: []const u16, other: []const u16) bool {
        if (one.len != other.len) return false;
        for (one, other) |mine, theirs| if (self.map[mine] != self.map[theirs]) return false;
        return true;
    }

    /// The table stored at `first`, `length` bytes long, laid out in
    /// memory the medium gives, and checked against `checksum`. It is read
    /// a block at a time through `scratch`.
    pub fn load(comptime Media: type, media: *Media, cache: *cache_area.BlockCache(Media), table: *table_area.Table(Media), geo: *const Geometry, first: u32, length: u64, checksum: u32, scratch: []u8) Error!Upcase {
        // More than the whole table uncompressed is not a table.
        if (length == 0 or length > units * 2 or length % 2 != 0) return error.MediumFailed;
        const bytes = media.alloc(units * 2) orelse return error.NoMemory;
        errdefer media.free(bytes);
        const map: []u16 = @as([*]u16, @ptrCast(@alignCast(bytes.ptr)))[0..units];
        for (map, 0..) |*unit, at| unit.* = @intCast(at);

        var sum: u32 = 0;
        var place: Place = .{};
        const chain: Chain = .{ .first = first };
        var read: u64 = 0;
        var next_unit: usize = 0;
        // A run's length follows its mark, and may be in the next block.
        var after_mark = false;
        while (read < length) {
            const block_in_table = read >> geo.sector_shift;
            const holding = try table.clusterAt(chain, &place, block_in_table >> geo.cluster_shift);
            const sector = block_in_table & (geo.sectors_per_cluster - 1);
            cache.readRun(geo.clusterBlock(holding) + sector, 1, scratch) catch return error.MediumFailed;
            const take: usize = @intCast(@min(length - read, geo.sector_bytes));
            sum = fat.exfatTableChecksum(sum, scratch[0..take]);
            var at: usize = 0;
            while (at + 1 < take) : (at += 2) {
                const value = fat.u16At(scratch, at);
                if (after_mark) {
                    next_unit += value;
                    after_mark = false;
                } else if (value == run_mark) {
                    after_mark = true;
                } else if (next_unit < units) {
                    map[next_unit] = value;
                    next_unit += 1;
                }
            }
            read += take;
        }
        if (sum != checksum) return error.MediumFailed;
        return .{ .map = map };
    }

    pub fn deinit(self: *Upcase, comptime Media: type, media: *Media) void {
        const bytes: [*]u8 = @ptrCast(self.map.ptr);
        media.free(bytes[0 .. units * 2]);
        self.map = &.{};
    }
};

/// A table for a fresh volume, stored compressed into `into` (which must
/// hold 512 bytes): ASCII's small letters and Latin-1's made capitals, the
/// rest left as they are. Every name this system can give a file is in
/// Latin-1, and this is what those names are compared by. Its length in
/// bytes is answered.
pub fn freshTable(into: []u8) usize {
    var at: usize = 0;
    const put = struct {
        fn unit(bytes: []u8, where: *usize, value: u16) void {
            fat.putU16(bytes, where.*, value);
            where.* += 2;
        }
    }.unit;
    // 0x00-0x60 as they are.
    put(into, &at, run_mark);
    put(into, &at, 'a');
    // a-z: A-Z.
    for ('a'..'z' + 1) |char| put(into, &at, @intCast(char - 0x20));
    // 0x7B-0xDF as they are.
    put(into, &at, run_mark);
    put(into, &at, 0xE0 - ('z' + 1));
    // à-þ: À-Þ, but for ÷, which has no capital.
    for (0xE0..0xFF) |char| put(into, &at, if (char == 0xF7) 0xF7 else @intCast(char - 0x20));
    // ÿ: Ÿ, which is outside Latin-1.
    put(into, &at, 0x0178);
    return at;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const fixture = @import("testfixture.zig");
const Cache = cache_area.BlockCache(TestMedia);
const Table = table_area.Table(TestMedia);

/// The fixture's up-case entry, found in its root directory.
fn fixtureEntry(media: *TestMedia, geo: *const Geometry) ![32]u8 {
    var block: [512]u8 = undefined;
    try testing.expect(media.read(geo.clusterBlock(geo.root_cluster), 1, &block));
    var at: usize = 0;
    while (at < 512) : (at += 32) {
        if (block[at] == fat.exfat_type_upcase) return block[at..][0..32].*;
    }
    return error.NotFound;
}

test "the kernel's up-case table is read and checks out" {
    var media = TestMedia.init(512, fixture.blocks());
    defer media.deinit();
    try fixture.load(&media, 0);
    var boot: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &boot));
    const geo = try Geometry.of(&boot, 0, media.blocks(), 512);
    var cache = try Cache.init(&media, 8);
    defer cache.deinit();
    var table = Table.init(&cache, &geo);
    const entry = try fixtureEntry(&media, &geo);
    var scratch: [512]u8 = undefined;
    var upcase = try Upcase.load(
        TestMedia,
        &media,
        &cache,
        &table,
        &geo,
        fat.u32At(&entry, fat.exfat_region_cluster),
        fat.u64At(&entry, fat.exfat_region_length),
        fat.u32At(&entry, fat.exfat_upcase_checksum),
        &scratch,
    );
    defer upcase.deinit(TestMedia, &media);
    try testing.expectEqual(@as(u16, 'A'), upcase.upper('a'));
    try testing.expectEqual(@as(u16, 'Z'), upcase.upper('Z'));
    try testing.expectEqual(@as(u16, 0xC9), upcase.upper(0xE9)); // é
    try testing.expectEqual(@as(u16, 0x0391), upcase.upper(0x03B1)); // Greek alpha
    try testing.expectEqual(@as(u16, 0x65E5), upcase.upper(0x65E5)); // 日 has no capital
    try testing.expect(upcase.same(&.{ 'c', 'a', 'f', 0xE9 }, &.{ 'C', 'A', 'F', 0xC9 }));

    // A table whose checksum is not the entry's is refused.
    try testing.expectError(error.MediumFailed, Upcase.load(
        TestMedia,
        &media,
        &cache,
        &table,
        &geo,
        fat.u32At(&entry, fat.exfat_region_cluster),
        fat.u64At(&entry, fat.exfat_region_length),
        fat.u32At(&entry, fat.exfat_upcase_checksum) ^ 1,
        &scratch,
    ));
}

test "the fresh table capitalises Latin-1 and nothing else" {
    var stored: [512]u8 = undefined;
    const len = freshTable(&stored);
    try testing.expect(len < 512);
    // Laid out by hand the way load does, to check it round-trips.
    var map: [units]u16 = undefined;
    for (&map, 0..) |*unit, at| unit.* = @intCast(at);
    var next: usize = 0;
    var at: usize = 0;
    while (at < len) : (at += 2) {
        const value = fat.u16At(&stored, at);
        if (value == run_mark) {
            at += 2;
            next += fat.u16At(&stored, at);
        } else {
            map[next] = value;
            next += 1;
        }
    }
    try testing.expectEqual(@as(u16, 'Q'), map['q']);
    try testing.expectEqual(@as(u16, '{'), map['{']);
    try testing.expectEqual(@as(u16, 0xC0), map[0xE0]);
    try testing.expectEqual(@as(u16, 0xF7), map[0xF7]);
    try testing.expectEqual(@as(u16, 0x0178), map[0xFF]);
    try testing.expectEqual(@as(u16, 0x0100), map[0x0100]);
}
