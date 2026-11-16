// SPDX-License-Identifier: MPL-2.0
//! A job over rows of a surface, done by the cores at once.
//!
//! A display that reads its picture out of RAM has no drawing engine, so
//! every pixel is the CPU's - and the CPU is several cores on a machine
//! that has them. A job over much of a surface is cut into bands of rows,
//! and exec's workers, a task on each core, draw them at once with the
//! task that asked (ShareWork): it draws a band itself, and its call
//! returns when every band is drawn.
//!
//! A job too small to be worth handing out (`least`), or of one row, is
//! done by its asker with no call to exec: handing a band out costs a few
//! signals between the cores, and a glyph or a small fill is done sooner
//! than that.
//!
//! **Bands** are whole rows, and a band starts on a cache line: a
//! board's rows are whole lines, and a band's height is rounded to as
//! many rows as a line takes otherwise. Two cores then never write one
//! line.
//!
//! **A job** is a structure with a `band(job, lo, hi)` - the surface's
//! rows `lo` up to `hi` - for `share`, or a `part(job, which, parts)`
//! that cuts the work itself, for `shareParts`: a move within one
//! surface, whose rows cannot be taken in any order, and several
//! rectangles as one job. Nothing a job points at may change while it
//! runs, and its parts write no row in common.
//!
//! **Where it is built**: on the 64-bit machines, where a display's
//! picture is in RAM. Elsewhere `shared` is false at compile time and a
//! job is its asker's alone, as it was.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;

/// Whether this build shares a job between the cores at all.
pub const shared = @sizeOf(usize) == 8;

/// The fewest pixels a job has before it is shared: about 64 KiB of a
/// buffer of four bytes a pixel.
pub const least: u64 = 16384;

/// The most parts a job is asked to be cut into: exec cuts it into no
/// more than it has cores for.
const most_parts: u32 = 16;

/// The cache line, which a band starts on.
const line_bytes: u32 = 64;

/// The rows a job writes, from `first` up to `end`, and how many rows a
/// band is a multiple of so that it starts on a cache line.
pub const Rows = struct {
    first: u32,
    end: u32,
    step: u32,

    /// The rows `first` up to `end` of a surface whose rows are `pitch`
    /// bytes apart.
    ///
    /// INPUTS:
    /// - `first` - the first row written.
    /// - `end` - one past the last.
    /// - `pitch` - bytes from one row to the next.
    pub fn of(first: u32, end: u32, pitch: u32) Rows {
        return .{ .first = first, .end = end, .step = line_bytes / common(pitch, line_bytes) };
    }

    /// Part `part` of `parts`: rows `lo` up to `hi`, which may be none.
    ///
    /// INPUTS:
    /// - `rows` - the job's rows.
    /// - `part` - which part, from 0.
    /// - `parts` - how many parts there are.
    pub fn band(rows: Rows, part: u32, parts: u32) Band {
        const all: u64 = rows.end - rows.first;
        return .{
            .lo = rows.at(all * part / parts),
            .hi = if (part + 1 == parts) rows.end else rows.at(all * (part + 1) / parts),
        };
    }

    fn at(rows: Rows, offset: u64) u32 {
        return rows.first + @as(u32, @intCast(offset)) / rows.step * rows.step;
    }

    /// How many rows there are.
    pub fn count(rows: Rows) u32 {
        return rows.end - rows.first;
    }
};

/// Rows `lo` up to `hi`.
pub const Band = struct { lo: u32, hi: u32 };

/// The largest number both divide by; `second` is not 0.
fn common(first: u32, second: u32) u32 {
    var larger = first;
    var smaller = second;
    while (smaller != 0) {
        const rest = larger % smaller;
        larger = smaller;
        smaller = rest;
    }
    return if (larger == 0) second else larger;
}

/// How many parts a job of `pixels` is worth: 1 for one its asker does
/// alone.
///
/// INPUTS:
/// - `pixels` - how many pixels the job writes, or reads where that is
///   more.
pub fn partsFor(pixels: u64) u32 {
    if (!shared or pixels < 2 * least) return 1;
    return @intCast(@min(pixels / least, most_parts));
}

/// A job's rows drawn, in bands on several cores where it is worth it.
///
/// INPUTS:
/// - `sys` - exec, for its workers.
/// - `Job` - the job's type: it has `band(job: *const Job, lo: u32, hi:
///   u32) void`.
/// - `job` - the job.
/// - `rows` - the rows it writes.
/// - `pixels` - how much work it is, in pixels.
pub fn share(sys: *ExecBase, comptime Job: type, job: *const Job, rows: Rows, pixels: u64) void {
    if (rows.first >= rows.end) return;
    const parts = partsFor(pixels);
    if (parts < 2 or rows.count() < 2) return job.band(rows.first, rows.end);
    const Shared = struct {
        job: *const Job,
        rows: Rows,

        fn part(data: ?*anyopaque, which: u32, of: u32) callconv(.c) void {
            const work: *const @This() = @ptrCast(@alignCast(data.?));
            const cut = work.rows.band(which, of);
            if (cut.lo < cut.hi) work.job.band(cut.lo, cut.hi);
        }
    };
    var work = Shared{ .job = job, .rows = rows };
    _ = sys.ShareWork(&Shared.part, &work, @min(parts, rows.count()));
}

/// A job done in parts it cuts itself, on several cores where `parts`
/// is more than one.
///
/// INPUTS:
/// - `sys` - exec, for its workers.
/// - `Job` - the job's type: it has `part(job: *const Job, which: u32,
///   parts: u32) void`.
/// - `job` - the job.
/// - `parts` - how many parts it is worth at most, from `partsFor`.
pub fn shareParts(sys: *ExecBase, comptime Job: type, job: *const Job, parts: u32) void {
    if (parts < 2) return job.part(0, 1);
    const Shared = struct {
        fn part(data: ?*anyopaque, which: u32, of: u32) callconv(.c) void {
            const work: *const Job = @ptrCast(@alignCast(data.?));
            work.part(which, of);
        }
    };
    _ = sys.ShareWork(&Shared.part, @constCast(job), parts);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "bands: every row once, each band on a cache line" {
    // Rows a line long: a band may start at any row.
    const whole = Rows.of(3, 20, 128);
    try testing.expectEqual(@as(u32, 1), whole.step);
    var next: u32 = 3;
    for (0..4) |part| {
        const cut = whole.band(@intCast(part), 4);
        try testing.expectEqual(next, cut.lo);
        next = cut.hi;
    }
    try testing.expectEqual(@as(u32, 20), next);

    // Rows of 40 bytes: eight of them are five lines, so a band is a
    // multiple of eight rows from the first.
    const ragged = Rows.of(2, 50, 40);
    try testing.expectEqual(@as(u32, 8), ragged.step);
    next = 2;
    for (0..3) |part| {
        const cut = ragged.band(@intCast(part), 3);
        try testing.expectEqual(next, cut.lo);
        try testing.expectEqual(@as(u32, 0), (cut.lo - 2) % 8);
        next = cut.hi;
    }
    try testing.expectEqual(@as(u32, 50), next);

    // More parts than rows: the parts that fall together are empty.
    const few = Rows.of(0, 2, 64);
    var rows_seen: u32 = 0;
    for (0..5) |part| {
        const cut = few.band(@intCast(part), 5);
        rows_seen += cut.hi - cut.lo;
    }
    try testing.expectEqual(@as(u32, 2), rows_seen);
}

test "bands: a job below the least is one part" {
    try testing.expectEqual(@as(u32, 1), partsFor(0));
    try testing.expectEqual(@as(u32, 1), partsFor(2 * least - 1));
    try testing.expectEqual(@as(u32, 2), partsFor(2 * least));
    try testing.expectEqual(most_parts, partsFor(1 << 40));
}
