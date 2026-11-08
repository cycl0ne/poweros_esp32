// SPDX-License-Identifier: MIT
//! Query pools: where what a frame's work came to is counted - the samples
//! that passed the tests, what each stage was given, or the clock as a
//! command was played.
//!
//! A pool is one block: the pool, then its values - a timestamp for each
//! query, or a counter for each (several for a statistics query, one for
//! each statistic asked for, lowest bit first) - then a flag for each
//! saying whether it is available. The values are written where the work is
//! done - the queue's task for what a draw was given, the cores at once for
//! what the tiles shaded - and their addresses stay put for as long as the
//! pool does.
//!
//! A counter is 64 bits wide, as Vulkan's are, and is kept in `lanes`
//! lanes, one for each part a frame's tiles are drawn in: each part adds
//! to its own lane and to no other, and a counter is read as the sum of
//! them. That is llvmpipe's query, which keeps a count for each of its
//! rasterizer threads (`llvmpipe_query.start` and `end`,
//! src/gallium/drivers/llvmpipe/lp_query.h:45-46), each thread adding to
//! its own (`lp_rast_end_query`, lp_rast.c:665-688), and adds them up when
//! it is read (`llvmpipe_get_query_result`, lp_query.c:122-129, 196-206).
//! What the queue's task adds - a draw's numbers, a dispatch's, the V3D's
//! frame - goes into the first lane, part 0's, which is the task's own:
//! exec's `ShareWork` has the caller do part 0. So no lane has two writers
//! and none needs an atomic add, which a 32-bit machine has not got for 64
//! bits (since 1.122; a counter was 32 bits before, added to atomically
//! and held at its highest). A timestamp is 64 bits and is written whole
//! by the one task that plays the commands. The flag that makes a query
//! available is what carries its values to whoever reads them; one read
//! before that, a partial count, is what the lanes hold at that moment,
//! and on a 32-bit machine a lane being added to may be read between its
//! two words.
//!
//! What counts what: a draw's own numbers are added as it is played
//! (driver/cpu/_draw.zig), the triangles the rasterizer kept come from its
//! statistics either side of the draw, and the pixels a fragment function
//! was called for and the samples that passed are added by the tiles while
//! they are drawn (driver/cpu/raster/batched.zig). The last of those land
//! when the pass's tiles are drawn, which is after the command that ended
//! the query: a program reads the values once the submission is done, which
//! is what `QUERY_RESULT_WAIT` waits for.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;

/// A statistic, numbered as its `QUERY_PIPELINE_STATISTIC_` bit is.
pub const Statistic = enum(u5) {
    input_vertices = 0,
    input_primitives = 1,
    vertex_invocations = 2,
    geometry_invocations = 3,
    geometry_primitives = 4,
    clipping_invocations = 5,
    clipping_primitives = 6,
    fragment_invocations = 7,
    patches = 8,
    evaluations = 9,
    compute_invocations = 10,

    pub fn bit(statistic: Statistic) u32 {
        return @as(u32, 1) << @intFromEnum(statistic);
    }
};

/// The statistics no stage of this library has: there is no geometry
/// shader, so a pool may ask for these two and they read 0, which is what
/// Vulkan says a statistic of a stage that never ran holds (since 1.43).
pub const no_statistics: u32 = Statistic.geometry_invocations.bit() | Statistic.geometry_primitives.bit();

/// The lanes each counter is kept in: one for each part a frame's tiles
/// may be drawn in, which the cores' driver holds the rasterizer's
/// `most_parts` to (since 1.122).
pub const lanes = 4;

/// A counter: its `lanes` lanes, one after another, part 0's first.
pub const Counter = [*]u64;

pub const Pool = struct {
    device: *Device,
    kind: facet.QueryType,
    count: u32,
    /// The `QUERY_PIPELINE_STATISTIC_` bits asked for; 0 for the other
    /// kinds.
    statistics: u32,
    /// The values one query holds: 1, or one for each statistic.
    stride: u32,
    /// What the work adds: `count * stride` counters of `lanes` lanes
    /// each, and none of them for a pool of timestamps.
    counts: [*]u64,
    /// Where a timestamp goes: `count` of them, and none of them for a pool
    /// of another kind.
    times: [*]u64,
    available: [*]bool,
};

/// A pool as `info` asks for it, nothing counted; null when memory ran out.
pub fn make(sys: *ExecBase, device: *Device, info: *const facet.QueryPoolCreateInfo) ?*Pool {
    const timing = info.query_type == .timestamp;
    const stride: u32 = if (info.query_type == .pipeline_statistics) @popCount(info.pipeline_statistics) else 1;
    // The widest first, so that each lies where it must: the timestamps,
    // then the counters' lanes, then the flags. The first after the pool,
    // which on a 32-bit machine may be a size of 4 more than 8.
    const head = std.mem.alignForward(usize, @sizeOf(Pool), @alignOf(u64));
    const times_bytes: usize = if (timing) @as(usize, info.query_count) * @sizeOf(u64) else 0;
    const counts_bytes: usize = if (timing) 0 else @as(usize, info.query_count) * stride * lanes * @sizeOf(u64);
    const flags_bytes = info.query_count * @sizeOf(bool);
    const memory = sys.AllocVec(head + times_bytes + counts_bytes + flags_bytes, exec.MEMF_CLEAR) orelse return null;
    const pool: *Pool = @ptrCast(@alignCast(memory));
    const times: [*]u64 = @ptrFromInt(@intFromPtr(memory) + head);
    const counts: [*]u64 = @ptrFromInt(@intFromPtr(times) + times_bytes);
    const available: [*]bool = @ptrFromInt(@intFromPtr(counts) + counts_bytes);
    pool.* = .{
        .device = device,
        .kind = info.query_type,
        .count = info.query_count,
        .statistics = if (info.query_type == .pipeline_statistics) info.pipeline_statistics else 0,
        .stride = stride,
        .counts = counts,
        .times = times,
        .available = available,
    };
    return pool;
}

/// `count` queries from `first` set back to nothing counted and not
/// available; what lies past the pool's last is left alone.
pub fn reset(pool: *Pool, first: u32, count: u32) void {
    const end: u32 = @intCast(@min(@as(u64, first) + count, pool.count));
    var at: u32 = first;
    while (at < end) : (at += 1) {
        if (pool.kind == .timestamp) {
            pool.times[at] = 0;
        } else {
            for (pool.counts[@as(usize, at) * pool.stride * lanes ..][0 .. pool.stride * lanes]) |*lane| storeLane(lane, 0);
        }
        @atomicStore(bool, &pool.available[at], false, .release);
    }
}

/// Query `index` made available: what it has counted may be read.
pub fn finish(pool: *Pool, index: u32) void {
    if (index >= pool.count) return;
    @atomicStore(bool, &pool.available[index], true, .release);
}

pub fn isAvailable(pool: *const Pool, index: u32) bool {
    if (index >= pool.count) return false;
    return @atomicLoad(bool, &pool.available[index], .acquire);
}

/// Value `slot` of query `index`: a timestamp whole, or what a counter has
/// come to, its lanes added up.
pub fn valueAt(pool: *const Pool, index: u32, slot: u32) u64 {
    if (pool.kind == .timestamp) return pool.times[index];
    var sum: u64 = 0;
    for (pool.counts[(@as(usize, index) * pool.stride + slot) * lanes ..][0..lanes]) |*lane| sum +%= loadLane(lane);
    return sum;
}

/// Where `statistic` is counted in query `index`; null for one the pool
/// does not count, and for a pool of another kind.
pub fn counterOf(pool: *Pool, index: u32, statistic: Statistic) ?Counter {
    if (pool.kind != .pipeline_statistics or index >= pool.count) return null;
    const bit = statistic.bit();
    if (pool.statistics & bit == 0) return null;
    // The values are in the order of the bits: how many below this one.
    const slot = @popCount(pool.statistics & (bit - 1));
    return pool.counts + (@as(usize, index) * pool.stride + slot) * lanes;
}

/// Where an occlusion query counts its samples; null for a pool of another
/// kind.
pub fn samplesOf(pool: *Pool, index: u32) ?Counter {
    if (pool.kind != .occlusion or index >= pool.count) return null;
    return pool.counts + @as(usize, index) * pool.stride * lanes;
}

/// Where the timestamp of query `index` goes.
pub fn timeOf(pool: *Pool, index: u32) ?*u64 {
    if (pool.kind != .timestamp or index >= pool.count) return null;
    return &pool.times[index];
}

/// Where a draw's, a patch's or a dispatch's numbers go: the counters of
/// the query being counted into, worked out once when it begins. A null is
/// a number nothing asked for.
pub const Counters = struct {
    input_vertices: ?Counter = null,
    input_primitives: ?Counter = null,
    vertex_invocations: ?Counter = null,
    clipping_invocations: ?Counter = null,
    clipping_primitives: ?Counter = null,
    fragment_invocations: ?Counter = null,
    patches: ?Counter = null,
    evaluations: ?Counter = null,
    compute_invocations: ?Counter = null,
    /// An occlusion query's samples.
    samples: ?Counter = null,

    /// What query `index` of `pool` counts.
    pub fn of(pool: *Pool, index: u32) Counters {
        return .{
            .input_vertices = counterOf(pool, index, .input_vertices),
            .input_primitives = counterOf(pool, index, .input_primitives),
            .vertex_invocations = counterOf(pool, index, .vertex_invocations),
            .clipping_invocations = counterOf(pool, index, .clipping_invocations),
            .clipping_primitives = counterOf(pool, index, .clipping_primitives),
            .fragment_invocations = counterOf(pool, index, .fragment_invocations),
            .patches = counterOf(pool, index, .patches),
            .evaluations = counterOf(pool, index, .evaluations),
            .compute_invocations = counterOf(pool, index, .compute_invocations),
            .samples = samplesOf(pool, index),
        };
    }

    /// Whether anything at all is counted: what says a draw need not look.
    pub fn any(counters: *const Counters) bool {
        inline for (@typeInfo(Counters).@"struct".fields) |field| {
            if (@field(counters, field.name) != null) return true;
        }
        return false;
    }
};

/// Nothing counted: what a driver hands on where no query is being counted
/// into.
pub const none: Counters = .{};

/// `by` added to a counter, where there is one, by the queue's task: in
/// the first lane, which is the task's own (`lanes`). A part drawing tiles
/// adds to its own lane instead (driver/cpu/raster/batched.zig
/// `Batch.countPixels`).
pub inline fn add(counter: ?Counter, by: u64) void {
    const at = counter orelse return;
    if (by == 0) return;
    storeLane(&at[0], loadLane(&at[0]) +% by);
}

/// Whether a lane is read and written whole: a 64-bit machine does that
/// in one go, which is all a lane of one writer needs to be read while it
/// is added to; a 32-bit one has no 64-bit atomic.
const whole_lanes = @bitSizeOf(usize) >= 64;

inline fn loadLane(lane: *const u64) u64 {
    return if (comptime whole_lanes) @atomicLoad(u64, lane, .monotonic) else lane.*;
}

inline fn storeLane(lane: *u64, value: u64) void {
    if (comptime whole_lanes) @atomicStore(u64, lane, value, .monotonic) else lane.* = value;
}

/// The queries `first` to `count` past it written into `into`, `stride`
/// bytes apart, as `flags` says: `error_validation_failed` where `into` is
/// too small for them (VUID-vkGetQueryPoolResults-dataSize-00817;
/// `error_out_of_host_memory` until 1.134), and `not_ready` where a query
/// is not available and nothing waited.
pub fn write(pool: *Pool, first: u32, count: u32, into: []u8, stride: u64, flags: u32) facet.Result {
    const wide = flags & facet.QUERY_RESULT_64 != 0;
    const unit: u64 = if (wide) 8 else 4;
    const with_availability = flags & facet.QUERY_RESULT_WITH_AVAILABILITY != 0;
    const partial = flags & facet.QUERY_RESULT_PARTIAL != 0;
    const values = pool.stride + @intFromBool(with_availability);
    var answer: facet.Result = .success;
    for (0..count) |k| {
        const index = first + @as(u32, @intCast(k));
        if (index >= pool.count) break;
        // Room for each query asked for (VUID-vkGetQueryPoolResults-dataSize-00817),
        // worked out so that no stride or size overflows: a program's
        // mistake, and no memory run out (since 1.134).
        const offset = std.math.mul(u64, k, stride) catch return .error_validation_failed;
        if (offset > into.len or values * unit > into.len - offset) return .error_validation_failed;
        const at: usize = @intCast(offset);
        const ready = isAvailable(pool, index);
        if (!ready) answer = .not_ready;
        for (0..pool.stride) |slot| {
            // A query that is not available writes nothing unless its
            // partial count was asked for, as Vulkan has it.
            if (!ready and !partial) continue;
            put(into[at + slot * @as(usize, @intCast(unit)) ..], wide, valueAt(pool, index, @intCast(slot)));
        }
        if (with_availability) put(into[at + @as(usize, pool.stride) * @as(usize, @intCast(unit)) ..], wide, @intFromBool(ready));
    }
    return answer;
}

/// One value written, of 4 bytes or of 8, little-endian as the machine has
/// it; what will not fit in 4 is held at the most there is room for.
fn put(into: []u8, wide: bool, value: u64) void {
    if (wide) {
        std.mem.writeInt(u64, into[0..8], value, .little);
    } else {
        std.mem.writeInt(u32, into[0..4], @intCast(@min(value, 0xFFFF_FFFF)), .little);
    }
}

/// The bytes `count` queries take, `stride` bytes apart, as `write` writes
/// them.
pub fn bytesFor(pool: *const Pool, count: u32, stride: u64, flags: u32) u64 {
    if (count == 0) return 0;
    const unit: u64 = if (flags & facet.QUERY_RESULT_64 != 0) 8 else 4;
    const values = pool.stride + @intFromBool(flags & facet.QUERY_RESULT_WITH_AVAILABILITY != 0);
    return (count - 1) * stride + values * unit;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "the counters of a statistics query: where each one lies, its lanes added up, and 64 bits of it kept whole" {
    var counts = [_]u64{0} ** (3 * lanes);
    var flags = [1]bool{false};
    var pool = Pool{
        .device = undefined,
        .kind = .pipeline_statistics,
        .count = 1,
        // Bits 0, 2 and 10, so three values in that order.
        .statistics = Statistic.input_vertices.bit() | Statistic.vertex_invocations.bit() | Statistic.compute_invocations.bit(),
        .stride = 3,
        .counts = &counts,
        .times = undefined,
        .available = &flags,
    };
    // Each counter is its lanes, one after another.
    try testing.expectEqual(@as(Counter, &counts), counterOf(&pool, 0, .input_vertices).?);
    try testing.expectEqual(@as(Counter, counts[lanes..]), counterOf(&pool, 0, .vertex_invocations).?);
    try testing.expectEqual(@as(Counter, counts[2 * lanes ..]), counterOf(&pool, 0, .compute_invocations).?);
    // Not asked for, past the last, and of another kind: nothing to add to.
    try testing.expectEqual(null, counterOf(&pool, 0, .input_primitives));
    try testing.expectEqual(null, counterOf(&pool, 1, .input_vertices));
    try testing.expectEqual(null, samplesOf(&pool, 0));
    try testing.expectEqual(null, timeOf(&pool, 0));

    const counters = Counters.of(&pool, 0);
    try testing.expect(counters.any());
    try testing.expectEqual(null, counters.fragment_invocations);
    // The queue's task adds in the first lane; a value is its lanes added
    // up, the others being what the parts drawing tiles added.
    add(counters.input_vertices, 3);
    add(counters.input_vertices, 4);
    add(counters.vertex_invocations, 0);
    try testing.expectEqual(7, valueAt(&pool, 0, 0));
    try testing.expectEqual(@as(u64, 7), counts[0]);
    try testing.expectEqual(0, valueAt(&pool, 0, 1));
    counts[1] = 10;
    counts[lanes - 1] = 200;
    try testing.expectEqual(217, valueAt(&pool, 0, 0));
    try testing.expectEqual(0, valueAt(&pool, 0, 1));
    // A count that outgrows 32 bits is kept whole, in a lane and in the
    // sum of them.
    add(counters.compute_invocations, std.math.maxInt(u32) - 1);
    add(counters.compute_invocations, 100);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 99, valueAt(&pool, 0, 2));
    add(counters.compute_invocations, 1 << 40);
    counts[2 * lanes + 2] = 1 << 33;
    try testing.expectEqual((1 << 40) + (1 << 33) + @as(u64, std.math.maxInt(u32)) + 99, valueAt(&pool, 0, 2));

    // Nothing counted: what a draw is handed where no query is being
    // counted into, and adding to it does nothing.
    try testing.expect(!none.any());
    add(none.input_vertices, 5);

    // A reset clears every lane.
    reset(&pool, 0, 4);
    try testing.expectEqual(0, valueAt(&pool, 0, 0));
    try testing.expectEqual(0, valueAt(&pool, 0, 2));
    try testing.expectEqual([_]u64{0} ** (3 * lanes), counts);
    try testing.expect(!isAvailable(&pool, 0));
    finish(&pool, 0);
    try testing.expect(isAvailable(&pool, 0));
    // Past the last: nothing is made available, and nothing asked about it.
    finish(&pool, 1);
    try testing.expect(!isAvailable(&pool, 1));
}

test "the values written as they were asked for: four bytes or eight, availability, and a partial count" {
    var times = [2]u64{ 5, 0x1_0000_0007 };
    var flags = [2]bool{ true, false };
    var pool = Pool{
        .device = undefined,
        .kind = .timestamp,
        .count = 2,
        .statistics = 0,
        .stride = 1,
        .counts = undefined,
        .times = &times,
        .available = &flags,
    };
    try testing.expectEqual(&times[1], timeOf(&pool, 1).?);
    try testing.expectEqual(null, timeOf(&pool, 2));

    // Eight bytes each with the availability after it, 16 apart. The
    // second is not available: it says so, and nothing is written for it.
    const wide = facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WITH_AVAILABILITY;
    try testing.expectEqual(32, bytesFor(&pool, 2, 16, wide));
    var into: [64]u8 = @splat(0xAA);
    try testing.expectEqual(facet.Result.not_ready, write(&pool, 0, 2, &into, 16, wide));
    try testing.expectEqual(5, std.mem.readInt(u64, into[0..8], .little));
    try testing.expectEqual(1, std.mem.readInt(u64, into[8..16], .little));
    try testing.expectEqual(0xAAAA_AAAA_AAAA_AAAA, std.mem.readInt(u64, into[16..24], .little));
    try testing.expectEqual(0, std.mem.readInt(u64, into[24..32], .little));
    // Nothing past them was touched.
    try testing.expectEqual(0xAAAA_AAAA_AAAA_AAAA, std.mem.readInt(u64, into[32..40], .little));

    // Four bytes each: what will not fit is held at the most there is room
    // for, and the partial count is written although it is not ready.
    into = @splat(0xAA);
    try testing.expectEqual(facet.Result.not_ready, write(&pool, 0, 2, &into, 4, facet.QUERY_RESULT_PARTIAL));
    try testing.expectEqual(8, bytesFor(&pool, 2, 4, facet.QUERY_RESULT_PARTIAL));
    try testing.expectEqual(5, std.mem.readInt(u32, into[0..4], .little));
    try testing.expectEqual(0xFFFF_FFFF, std.mem.readInt(u32, into[4..8], .little));

    // The one that is available alone, and a room too small for it.
    into = @splat(0xAA);
    try testing.expectEqual(facet.Result.success, write(&pool, 0, 1, &into, 8, facet.QUERY_RESULT_64));
    try testing.expectEqual(5, std.mem.readInt(u64, into[0..8], .little));
    // Too small breaks Vulkan's rules (VUID-vkGetQueryPoolResults-dataSize-00817;
    // `error_out_of_host_memory` until 1.134), and so does a stride that
    // runs past what can be counted: refused, not overflowed.
    try testing.expectEqual(facet.Result.error_validation_failed, write(&pool, 0, 1, into[0..4], 8, facet.QUERY_RESULT_64));
    try testing.expectEqual(facet.Result.error_validation_failed, write(&pool, 0, 2, &into, 0xFFFF_FFFF_FFFF_FFF8, facet.QUERY_RESULT_64));
    // Past the pool's last: what is there is written and no more, and the
    // one that is not available still says it is not ready.
    try testing.expectEqual(facet.Result.not_ready, write(&pool, 1, 4, &into, 8, facet.QUERY_RESULT_PARTIAL));
    try testing.expectEqual(0, bytesFor(&pool, 0, 8, 0));
}

test "an occlusion count past 32 bits: what every part and the queue's task added, eight bytes of it whole and four held at their most" {
    var counts = [_]u64{0} ** (2 * lanes);
    var flags = [2]bool{ true, true };
    var pool = Pool{
        .device = undefined,
        .kind = .occlusion,
        .count = 2,
        .statistics = 0,
        .stride = 1,
        .counts = &counts,
        .times = undefined,
        .available = &flags,
    };
    // The second query's lanes, after the first's.
    const second = samplesOf(&pool, 1).?;
    try testing.expectEqual(@as(Counter, counts[lanes..]), second);
    // Each part counted a frame's samples past 32 bits in its own lane,
    // and the queue's task five more in the first.
    for (0..lanes) |part| second[part] = (1 << 32) + part;
    add(second, 5);
    const whole: u64 = lanes * (1 << 32) + lanes * (lanes - 1) / 2 + 5;
    var into: [16]u8 = @splat(0xAA);
    try testing.expectEqual(facet.Result.success, write(&pool, 0, 2, &into, 8, facet.QUERY_RESULT_64));
    try testing.expectEqual(0, std.mem.readInt(u64, into[0..8], .little));
    try testing.expectEqual(whole, std.mem.readInt(u64, into[8..16], .little));
    try testing.expectEqual(facet.Result.success, write(&pool, 1, 1, &into, 4, 0));
    try testing.expectEqual(0xFFFF_FFFF, std.mem.readInt(u32, into[0..4], .little));
}
