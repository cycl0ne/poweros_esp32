// SPDX-License-Identifier: MPL-2.0
//! Rectangles of pixels moved as they are, between two surfaces of one
//! format or within one, by every core where there is enough of it
//! (`rows/_bands.zig`).
//!
//! **Between two surfaces** the rows are bands: each core copies its own.
//!
//! **Within one surface**, where the two rectangles overlap, the rows
//! cannot be cut into bands that run at once: a band would read rows that
//! another is writing. Rows `d` apart, `d` the rows the move goes by,
//! form chains, each row read before the row `d` further on is written;
//! the chains do not meet, so each part takes whole chains and walks them
//! away from where the rows are going. A move along its own rows (`d` 0)
//! is a move within each row, and its rows are bands again. A move too
//! small to share is walked a row after another, away from where it is
//! going, as a copy that overlaps always is.
//!
//! **Several rectangles** from one surface to another are one job: the
//! rows of all of them, one rectangle's after the other's, cut into
//! parts. A window seen in pieces between others is copied on to the
//! display with the cores woken once, not once a piece.
//!
//! Nothing here clips: the callers hand over rectangles that lie inside
//! both surfaces.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const rows = @import("../rows/_rows.zig");
const bands = @import("../rows/_bands.zig");

/// One rectangle moved.
const Move = struct {
    /// The destination's rows; its row `rows.first` is the source's row
    /// `src_first`.
    rows: bands.Rows,
    /// The rectangle's first column in each surface's row 0.
    dest: [*]u8,
    dest_pitch: u32,
    src: [*]const u8,
    src_pitch: u32,
    src_first: u32,
    /// The bytes of a row of it.
    bytes: usize,
    /// 0: the rows are bands. Else the rows the move goes by, and whether
    /// it takes them down, so that a chain is walked from its bottom.
    chain: u32,
    down: bool,

    fn row(job: *const Move, y: u32) void {
        const to = job.dest + @as(usize, y) * job.dest_pitch;
        const from = job.src + @as(usize, job.src_first + (y - job.rows.first)) * job.src_pitch;
        rows.copy(to, from, job.bytes);
    }

    /// Every row, one after another, away from where the rows are going.
    fn alone(job: *const Move) void {
        var left = job.rows.count();
        while (left > 0) : (left -= 1) {
            job.row(if (job.down) job.rows.first + left - 1 else job.rows.end - left);
        }
    }

    pub fn part(job: *const Move, which: u32, parts: u32) void {
        if (parts == 1) return job.alone();
        if (job.chain == 0) {
            const cut = job.rows.band(which, parts);
            var y = cut.lo;
            while (y < cut.hi) : (y += 1) job.row(y);
            return;
        }
        // The chains starting at the rows of this part of the first run
        // of `chain` rows, each walked whole.
        const lo = job.rows.first + job.chain * which / parts;
        const hi = job.rows.first + job.chain * (which + 1) / parts;
        var start = lo;
        while (start < hi and start < job.rows.end) : (start += 1) {
            const links = (job.rows.end - 1 - start) / job.chain;
            var link: u32 = 0;
            while (link <= links) : (link += 1) {
                const step = if (job.down) links - link else link;
                job.row(start + step * job.chain);
            }
        }
    }
};

/// Where a pixel of a surface is, as a number.
fn addressOf(surface: *const rtg.Surface, x: u32, y: u32, pixel: u32) usize {
    return @intFromPtr(surface.pixels.?) + @as(usize, y) * surface.pitch + @as(usize, x) * pixel;
}

/// One rectangle as `move` cuts it, for the cores or for a test to run
/// its parts by hand.
const Cut = struct { job: Move, parts: u32 };

fn cutOf(src: *const rtg.Surface, src_x: u32, src_y: u32, dest: *const rtg.Surface, dest_x: u32, dest_y: u32, width: u32, height: u32, pixel: u32) Cut {
    var job = Move{
        .rows = bands.Rows.of(dest_y, dest_y + height, dest.pitch),
        .dest = dest.pixels.? + @as(usize, dest_x) * pixel,
        .dest_pitch = dest.pitch,
        .src = src.pixels.? + @as(usize, src_x) * pixel,
        .src_pitch = src.pitch,
        .src_first = src_y,
        .bytes = @as(usize, width) * pixel,
        .chain = 0,
        .down = false,
    };
    var parts = bands.partsFor(@as(u64, width) * height);
    const src_first = addressOf(src, src_x, src_y, pixel);
    const src_end = addressOf(src, src_x + width, src_y + height - 1, pixel);
    const dest_first = addressOf(dest, dest_x, dest_y, pixel);
    const dest_end = addressOf(dest, dest_x + width, dest_y + height - 1, pixel);
    if (src_first < dest_end and dest_first < src_end) {
        if (src.pixels == dest.pixels and src.pitch == dest.pitch) {
            const meet = src_x < dest_x + width and dest_x < src_x + width and src_y < dest_y + height and dest_y < src_y + height;
            if (meet and src_y != dest_y) {
                job.chain = if (dest_y > src_y) dest_y - src_y else src_y - dest_y;
                job.down = dest_y > src_y;
                parts = @min(parts, job.chain);
            }
        } else {
            // The same memory by two descriptions: how they lie on each
            // other is not known here, so the rows go one after another.
            parts = 1;
        }
    }
    return .{ .job = job, .parts = parts };
}

/// A rectangle of `src` moved to `dest`, which may be the same surface
/// and the rectangles may overlap.
///
/// INPUTS:
/// - `sys` - exec, for its workers.
/// - `src` - the surface the pixels come from.
/// - `src_x` - the rectangle's left edge there.
/// - `src_y` - its top edge.
/// - `dest` - the surface they go to, in the same format.
/// - `dest_x` - where the left edge lands.
/// - `dest_y` - where the top edge lands.
/// - `width` - how wide the rectangle is; it lies inside both surfaces.
/// - `height` - how tall.
/// - `pixel` - the bytes a pixel takes.
pub fn move(sys: *ExecBase, src: *const rtg.Surface, src_x: u32, src_y: u32, dest: *const rtg.Surface, dest_x: u32, dest_y: u32, width: u32, height: u32, pixel: u32) void {
    if (width == 0 or height == 0) return;
    const cut = cutOf(src, src_x, src_y, dest, dest_x, dest_y, width, height, pixel);
    bands.shareParts(sys, Move, &cut.job, cut.parts);
}

/// Several rectangles from one surface to another.
const Moves = struct {
    list: []const rtg.RtgCopy,
    /// The rows of all of them together.
    rows: u32,
    dest: [*]u8,
    dest_pitch: u32,
    src: [*]const u8,
    src_pitch: u32,
    pixel: u32,

    pub fn part(job: *const Moves, which: u32, parts: u32) void {
        const lo = @as(u64, job.rows) * which / parts;
        const hi = @as(u64, job.rows) * (which + 1) / parts;
        // Where among all the rows each rectangle's first one is.
        var first: u64 = 0;
        for (job.list) |*one| {
            if (first >= hi) break;
            const height: u64 = @intCast(one.height);
            var at = @max(lo, first);
            while (at < @min(hi, first + height)) : (at += 1) job.row(one, @intCast(at - first));
            first += height;
        }
    }

    /// Row `line` of one of the rectangles.
    fn row(job: *const Moves, one: *const rtg.RtgCopy, line: u32) void {
        const bytes = @as(usize, @intCast(one.width)) * job.pixel;
        const to = job.dest + (@as(usize, @intCast(one.dest_y)) + line) * job.dest_pitch + @as(usize, @intCast(one.dest_x)) * job.pixel;
        const from = job.src + (@as(usize, @intCast(one.src_y)) + line) * job.src_pitch + @as(usize, @intCast(one.src_x)) * job.pixel;
        rows.copy(to, from, bytes);
    }
};

fn movesOf(src: *const rtg.Surface, dest: *const rtg.Surface, list: []const rtg.RtgCopy, pixel: u32) struct { job: Moves, pixels: u64 } {
    var all_rows: u32 = 0;
    var pixels: u64 = 0;
    for (list) |one| {
        all_rows += @intCast(one.height);
        pixels += @as(u64, @intCast(one.width)) * @as(u64, @intCast(one.height));
    }
    return .{ .job = .{
        .list = list,
        .rows = all_rows,
        .dest = dest.pixels.?,
        .dest_pitch = dest.pitch,
        .src = src.pixels.?,
        .src_pitch = src.pitch,
        .pixel = pixel,
    }, .pixels = pixels };
}

/// Whether two surfaces share any memory.
///
/// INPUTS:
/// - `one` - a surface with pixels.
/// - `other` - another.
pub fn overlap(one: *const rtg.Surface, other: *const rtg.Surface) bool {
    const one_start = @intFromPtr(one.pixels.?);
    const one_end = one_start + @as(usize, one.pitch) * one.height;
    const other_start = @intFromPtr(other.pixels.?);
    const other_end = other_start + @as(usize, other.pitch) * other.height;
    return one_start < other_end and other_start < one_end;
}

/// Several rectangles of `src` moved to `dest` as one job. The parts
/// copy them in no order and at once: the two surfaces share no memory
/// (`overlap`), and no rectangle overlaps another where it lands.
///
/// INPUTS:
/// - `sys` - exec, for its workers.
/// - `src` - the surface the pixels come from.
/// - `dest` - the surface they go to, in the same format.
/// - `list` - the rectangles, each inside both surfaces and none empty.
/// - `pixel` - the bytes a pixel takes.
pub fn moveMany(sys: *ExecBase, src: *const rtg.Surface, dest: *const rtg.Surface, list: []const rtg.RtgCopy, pixel: u32) void {
    if (list.len == 0) return;
    const cut = movesOf(src, dest, list, pixel);
    bands.shareParts(sys, Moves, &cut.job, bands.partsFor(cut.pixels));
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// Each move against the same done a pixel at a time out of a copy of the
// buffer as it was, the job cut into parts that run one after another,
// the last first: a part that needed another's done before it would show.

const std = @import("std");
const testing = std.testing;

fn surfaceOf(memory: []align(64) u8, width: u32, height: u32) rtg.Surface {
    const pitch = (width * 4 + 63) / 64 * 64;
    return .{ .pixels = memory.ptr, .width = width, .height = height, .pitch = pitch, .size_bytes = pitch * height, .format = .bgra32 };
}

fn scramble(surface: *const rtg.Surface, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(surface.pixels.?[0 .. @as(usize, surface.pitch) * surface.height]);
}

fn wordAt(memory: []const u8, pitch: u32, x: usize, y: usize) u32 {
    return std.mem.readInt(u32, memory[y * pitch + x * 4 ..][0..4], .little);
}

/// A job's parts, the last first.
fn runParts(job: anytype, parts: u32) void {
    var part = parts;
    while (part > 0) {
        part -= 1;
        job.part(part, parts);
    }
}

test "a move within one surface: whichever way the rectangles overlap, in any number of parts" {
    var memory: [64 * 40 * 4]u8 align(64) = undefined;
    var before: [memory.len]u8 = undefined;
    const surface = surfaceOf(&memory, 60, 40);
    const Case = struct { sx: u32, sy: u32, dx: u32, dy: u32 };
    const cases = [_]Case{
        .{ .sx = 5, .sy = 4, .dx = 5, .dy = 9 }, // down
        .{ .sx = 5, .sy = 9, .dx = 5, .dy = 4 }, // up
        .{ .sx = 5, .sy = 4, .dx = 9, .dy = 4 }, // right, along its rows
        .{ .sx = 9, .sy = 4, .dx = 5, .dy = 4 }, // left
        .{ .sx = 5, .sy = 4, .dx = 8, .dy = 7 }, // down and right
        .{ .sx = 8, .sy = 7, .dx = 5, .dy = 4 }, // up and left
        .{ .sx = 5, .sy = 4, .dx = 6, .dy = 21 }, // down by more rows than a part has
        .{ .sx = 0, .sy = 0, .dx = 30, .dy = 0 }, // beside each other: no overlap
    };
    const width = 30;
    const height = 18;
    for (cases, 0..) |case, seed| {
        for ([_]u32{ 1, 2, 3, 7 }) |wanted| {
            scramble(&surface, seed);
            before = memory;
            var cut = cutOf(&surface, case.sx, case.sy, &surface, case.dx, case.dy, width, height, 4);
            const parts = if (cut.job.chain != 0) @min(wanted, cut.job.chain) else wanted;
            cut.parts = parts;
            runParts(&cut.job, parts);
            for (0..40) |y| for (0..60) |x| {
                const inside = x >= case.dx and x < case.dx + width and y >= case.dy and y < case.dy + height;
                const expected = if (inside)
                    wordAt(&before, surface.pitch, x - case.dx + case.sx, y - case.dy + case.sy)
                else
                    wordAt(&before, surface.pitch, x, y);
                try testing.expectEqual(expected, wordAt(&memory, surface.pitch, x, y));
            };
        }
    }
}

test "a move between two surfaces, and several as one job: every row of every one, however the parts fall" {
    var from_memory: [64 * 30 * 4]u8 align(64) = undefined;
    var to_memory: [64 * 30 * 4]u8 align(64) = undefined;
    var before: [to_memory.len]u8 = undefined;
    const from = surfaceOf(&from_memory, 50, 30);
    const to = surfaceOf(&to_memory, 50, 30);
    try testing.expect(!overlap(&from, &to));
    try testing.expect(overlap(&from, &from));
    scramble(&from, 1);

    for ([_]u32{ 1, 2, 5 }) |parts| {
        scramble(&to, 2);
        before = to_memory;
        const cut = cutOf(&from, 3, 2, &to, 10, 7, 25, 20, 4);
        try testing.expectEqual(@as(u32, 0), cut.job.chain);
        runParts(&cut.job, parts);
        for (0..30) |y| for (0..50) |x| {
            const inside = x >= 10 and x < 35 and y >= 7 and y < 27;
            const expected = if (inside) wordAt(&from_memory, from.pitch, x - 7, y - 5) else wordAt(&before, to.pitch, x, y);
            try testing.expectEqual(expected, wordAt(&to_memory, to.pitch, x, y));
        };
    }

    // Three rectangles of different heights, one of them a single row.
    const list = [_]rtg.RtgCopy{
        .{ .src_x = 0, .src_y = 0, .width = 20, .height = 11, .dest_x = 1, .dest_y = 1 },
        .{ .src_x = 20, .src_y = 5, .width = 9, .height = 1, .dest_x = 30, .dest_y = 0 },
        .{ .src_x = 7, .src_y = 12, .width = 40, .height = 13, .dest_x = 5, .dest_y = 15 },
    };
    for ([_]u32{ 1, 2, 4, 9 }) |parts| {
        scramble(&to, 3);
        before = to_memory;
        const cut = movesOf(&from, &to, &list, 4);
        try testing.expectEqual(@as(u32, 25), cut.job.rows);
        runParts(&cut.job, parts);
        for (0..30) |y| for (0..50) |x| {
            var expected = wordAt(&before, to.pitch, x, y);
            for (list) |one| {
                const left: usize = @intCast(one.dest_x);
                const top: usize = @intCast(one.dest_y);
                if (x >= left and x < left + @as(usize, @intCast(one.width)) and y >= top and y < top + @as(usize, @intCast(one.height))) {
                    expected = wordAt(&from_memory, from.pitch, x - left + @as(usize, @intCast(one.src_x)), y - top + @as(usize, @intCast(one.src_y)));
                }
            }
            try testing.expectEqual(expected, wordAt(&to_memory, to.pitch, x, y));
        };
    }
}
