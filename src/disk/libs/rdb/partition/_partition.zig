// SPDX-License-Identifier: MIT
//! What AddPartition and WriteRDB both check of a partition - its name
//! and its cylinders against the table and the other partitions - and
//! the largest run of cylinders nobody has, which AddPartition takes when
//! it is given none.
//!
//! Cylinders are the RigidDiskBlock's: a partition's environment counts
//! them with the same heads and blocks per track, which is how
//! AddPartition makes it.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const dos = sdk.dos;
const _handle = @import("../handle/_handle.zig");

/// Whether `name` may name a partition: 1 to MAX_DEVICE_NAME characters,
/// with no colon or slash, which would end the name in a path.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > dos.MAX_DEVICE_NAME) return false;
    for (name) |char| {
        if (char == ':' or char == '/') return false;
    }
    return true;
}

/// Two names the same, in any case.
pub fn sameName(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
}

/// A C string as a slice: at most a drive name's length.
pub fn nameOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0 and length <= dos.MAX_DEVICE_NAME) length += 1;
    return text[0..length];
}

/// A partition's drive name as a slice.
pub fn driveName(part: *const rdb.RDBPartition) []const u8 {
    return part.block.name();
}

/// The partitions on the handle's list, in order.
pub const Partitions = struct {
    node: ?*sdk.exec.Node,

    pub fn of(handle: *rdb.RDBHandle) Partitions {
        return .{ .node = handle.partitions.first() };
    }

    pub fn next(walk: *Partitions) ?*rdb.RDBPartition {
        const node = walk.node orelse return null;
        walk.node = node.next();
        return @fieldParentPtr("node", node);
    }
};

/// The partition other than `except` with this name, if there is one.
pub fn named(handle: *rdb.RDBHandle, name: []const u8, except: ?*const rdb.RDBPartition) ?*rdb.RDBPartition {
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (part == except) continue;
        if (sameName(driveName(part), name)) return part;
    }
    return null;
}

/// Whether cylinders `low` to `high` may be a partition's: the right way
/// round, inside the table's usable ones, and none of them another
/// partition's (other than `except`).
pub fn rangeFree(handle: *rdb.RDBHandle, low: u32, high: u32, except: ?*const rdb.RDBPartition) bool {
    const table = &handle.rdb;
    if (low > high or low < table.lo_cylinder or high > table.hi_cylinder) return false;
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (part == except) continue;
        const env = &part.block.environment;
        if (low <= env.high_cyl and env.low_cyl <= high) return false;
    }
    return true;
}

pub const Run = struct { low: u32, high: u32 };

/// The longest run of usable cylinders no partition has, the first of
/// them on a tie; null when every one is taken.
pub fn largestFree(handle: *rdb.RDBHandle) ?Run {
    const table = &handle.rdb;
    if (table.lo_cylinder > table.hi_cylinder) return null;
    var best: ?Run = null;
    var start: u64 = table.lo_cylinder;
    // From each free cylinder, the run goes to the nearest partition above
    // it; the next run starts past the partition that ends it.
    while (start <= table.hi_cylinder) {
        var end: u64 = table.hi_cylinder;
        var resume_at: u64 = @as(u64, table.hi_cylinder) + 1;
        var inside = false;
        var walk = Partitions.of(handle);
        while (walk.next()) |part| {
            const env = &part.block.environment;
            if (env.low_cyl <= start and start <= env.high_cyl) {
                inside = true;
                resume_at = @as(u64, env.high_cyl) + 1;
                break;
            }
            if (env.low_cyl > start and env.low_cyl - 1 < end) {
                end = env.low_cyl - 1;
                resume_at = @as(u64, env.high_cyl) + 1;
            }
        }
        if (!inside) {
            const length = end - start;
            if (best == null or length > best.?.high - best.?.low) {
                best = .{ .low = @intCast(start), .high = @intCast(end) };
            }
        }
        start = resume_at;
    }
    return best;
}

/// How many PartitionBlocks the table's own blocks have room for: the RDB
/// area less the RigidDiskBlock's block and the kept chains'.
pub fn blocksFor(handle: *_handle.Handle) u32 {
    const table = &handle.public.rdb;
    var room: u32 = 0;
    var block = table.rdb_blocks_lo;
    while (block <= table.rdb_blocks_hi and block < _handle.mapped_blocks) : (block += 1) {
        if (block == handle.public.block or handle.kept.has(block)) continue;
        room += 1;
    }
    return room;
}

/// How many partitions the handle's list holds.
pub fn count(handle: *rdb.RDBHandle) u32 {
    var total: u32 = 0;
    var walk = Partitions.of(handle);
    while (walk.next()) |_| total += 1;
    return total;
}
