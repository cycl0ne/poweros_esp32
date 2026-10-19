// SPDX-License-Identifier: MIT
//! HDToolBox's workings that need nothing of the system: where a table's
//! partitions lie and what is free between them, a partition made in a
//! free run, moved and resized as far as its neighbours let it, the
//! boundaries a partition snaps to, the bar's cylinders and pixels, the
//! name a new partition is offered, sizes as text, which drives a save
//! leaves without their data, and a GPT's partitions on the bar.
//!
//! **Cylinders.** A partition is a run of the table's usable cylinders,
//! lo_cylinder to hi_cylinder (`Span`). A boundary is the place before a
//! cylinder: a partition's low boundary is its first cylinder, its high
//! one the cylinder past its last, so a partition always keeps at least
//! one. The partitions are worked on in the order of their cylinders
//! (`order`), whatever the order of the handle's list.
//!
//! **The grid** (`Grid`). On a medium without an erase unit - a card, a
//! stick, a disk - a new partition starts on a whole MiB from the
//! medium's first block, where the medium's own erase blocks begin, so a
//! file system's blocks line up with them. A boundary that is dragged
//! snaps to the nearest whole MiB, or to a neighbour or the table's edge
//! when one is nearer, so nothing is left over between two partitions. On
//! the flash disk a cylinder is what the flash erases, and every one is a
//! boundary.
//!
//! **What a save does to the drives** (`sameLayout`). A drive mounted
//! from a table reads its blocks where its environment says. After a
//! save it still finds its file system where a partition of the new
//! table is laid out as its environment is: the same cylinders, block
//! size, heads, blocks per track, reserved and pre-allocated blocks,
//! interleave and DosType. Its name may differ: a drive keeps its name
//! until the next start. Any other drive of the unit is stale (`stale`),
//! and so is one over the whole medium once the medium has a table. A
//! partition of the old table that no partition of the new one is laid
//! out as loses what it holds.
//!
//! **A disk with a GPT.** The bar is the whole disk: its cylinders are
//! the table's, counted from the disk's first block, and the table's own
//! are moved along by the container's first cylinder. The GPT's other
//! partitions lie on the bar over the cylinders their blocks reach into
//! (`blockSpan`). A drive mounted from the container reads the table's
//! cylinders moved along the same way (`onDisk`), and one mounted from a
//! partition of the GPT reads exactly that partition's blocks (`covers`).

const sdk = @import("sdk");
const dos = sdk.dos;
const DosEnvec = dos.DosEnvec;

/// A run of cylinders, `low` to `high`, both in it.
pub const Span = struct {
    low: u32,
    high: u32,

    /// A partition's cylinders, from its environment.
    pub fn of(env: *const DosEnvec) Span {
        return .{ .low = env.low_cyl, .high = env.high_cyl };
    }

    /// How many cylinders it has; none the wrong way round.
    pub fn cylinders(span: Span) u64 {
        if (span.high < span.low) return 0;
        return @as(u64, span.high) - span.low + 1;
    }

    /// The boundary past its last cylinder.
    pub fn end(span: Span) u64 {
        return @as(u64, span.high) + 1;
    }
};

/// The spans' indices in the order of their first cylinders, into the
/// first `spans.len` of `into`.
pub fn order(spans: []const Span, into: []u32) void {
    for (into[0..spans.len], 0..) |*slot, index| slot.* = @intCast(index);
    // One at a time into place: a table holds a few dozen at most.
    var placed: usize = 1;
    while (placed < spans.len) : (placed += 1) {
        const item = into[placed];
        var at = placed;
        while (at > 0 and spans[into[at - 1]].low > spans[item].low) : (at -= 1) {
            into[at] = into[at - 1];
        }
        into[at] = item;
    }
}

/// The free runs of `area` between the `sorted` spans, lowest first, as
/// many as `into` holds.
pub fn gaps(area: Span, sorted: []const Span, into: []Span) []Span {
    var count: usize = 0;
    var next: u64 = area.low;
    for (sorted) |span| {
        if (span.low > next and next <= area.high and count < into.len) {
            const last: u64 = @min(@as(u64, span.low) - 1, @as(u64, area.high));
            into[count] = .{ .low = @intCast(next), .high = @intCast(last) };
            count += 1;
        }
        const past: u64 = span.end();
        if (past > next) next = past;
    }
    if (next <= area.high and count < into.len) {
        into[count] = .{ .low = @intCast(next), .high = area.high };
        count += 1;
    }
    return into[0..count];
}

/// The cylinders the `index`th of the `sorted` spans may have when it is
/// moved or resized: from past the one below it to before the one above
/// it, or to the area's edges.
pub fn room(area: Span, sorted: []const Span, index: usize) Span {
    const span = sorted[index];
    const below: u32 = if (index == 0) area.low else sorted[index - 1].high +| 1;
    const above: u32 = if (index + 1 == sorted.len) area.high else sorted[index + 1].low -| 1;
    return .{ .low = @min(below, span.low), .high = @max(above, span.high) };
}

const mebibyte: u64 = 1 << 20;

/// The boundaries a partition's edges snap to.
pub const Grid = struct {
    /// The cylinders from one boundary on the grid to the next; 1: every
    /// boundary is on it.
    step: u64 = 1,

    /// The grid of a medium with cylinders of `cylinder_bytes` and an
    /// erase unit of `erase_size` bytes (0: none): whole MiB without an
    /// erase unit, where a cylinder goes into a MiB evenly; every
    /// cylinder otherwise.
    pub fn of(cylinder_bytes: u64, erase_size: u32) Grid {
        if (erase_size != 0 or cylinder_bytes == 0 or cylinder_bytes >= mebibyte) return .{};
        if (mebibyte % cylinder_bytes != 0) return .{};
        return .{ .step = mebibyte / cylinder_bytes };
    }

    /// The grid's boundary at or below `boundary`.
    pub fn down(grid: Grid, boundary: u64) u64 {
        return boundary / grid.step * grid.step;
    }

    /// The grid's boundary at or above `boundary`.
    pub fn up(grid: Grid, boundary: u64) u64 {
        return grid.down(boundary +| (grid.step - 1));
    }

    /// The place nearest `wanted` from `lowest` to `highest`: a boundary
    /// on the grid, or one of the two ends, which are a neighbour's or an
    /// edge's and always allowed.
    fn place(grid: Grid, wanted: u64, lowest: u64, highest: u64) u64 {
        if (wanted <= lowest) return lowest;
        if (wanted >= highest) return highest;
        const below = grid.down(wanted);
        const before = if (below < lowest) lowest else below;
        const after = if (below + grid.step > highest) highest else below + grid.step;
        return if (wanted - before <= after - wanted) before else after;
    }
};

/// `span` moved to begin at cylinder `low`, its size kept, as far as
/// `within` lets it, and on the grid.
pub fn moved(within: Span, span: Span, low: i64, grid: Grid) Span {
    const size = span.cylinders();
    if (size == 0 or within.cylinders() < size) return span;
    const wanted: u64 = if (low < 0) 0 else @intCast(low);
    const start = grid.place(wanted, within.low, within.end() - size);
    return .{ .low = @intCast(start), .high = @intCast(start + size - 1) };
}

/// A partition's two edges.
pub const Edge = enum { low, high };

/// `span` with one edge taken to `boundary`, as far as `within` lets it,
/// on the grid, and one cylinder long at least.
pub fn resized(within: Span, span: Span, edge: Edge, boundary: u64, grid: Grid) Span {
    return switch (edge) {
        .low => .{ .low = @intCast(grid.place(boundary, within.low, span.high)), .high = span.high },
        .high => .{ .low = span.low, .high = @intCast(grid.place(boundary, @as(u64, span.low) + 1, within.end()) - 1) },
    };
}

/// The partition a free run gets: from its first boundary on the grid to
/// its end - or the whole run, where the grid leaves nothing of it.
pub fn fresh(gap: Span, grid: Grid) Span {
    const start = grid.up(gap.low);
    if (start > gap.high) return gap;
    return .{ .low = @intCast(start), .high = gap.high };
}

// --- the bar ---------------------------------------------------------------------

/// The bar the table is drawn as: the area's cylinders across `width`
/// pixels, a partition over the pixels of its cylinders.
pub const Bar = struct {
    area: Span,
    width: u32,

    /// The pixel a boundary is drawn at, 0 to `width`.
    pub fn x(bar: Bar, boundary: u64) u32 {
        const cylinders = bar.area.cylinders();
        if (cylinders == 0 or boundary <= bar.area.low) return 0;
        const into = @min(boundary - bar.area.low, cylinders);
        return @intCast(into * bar.width / cylinders);
    }

    /// The pixels a span is drawn over, `left` up to `right`: one at
    /// least, however few cylinders it has.
    pub fn pixels(bar: Bar, span: Span) struct { left: u32, right: u32 } {
        const left = bar.x(span.low);
        const right = bar.x(span.end());
        return .{ .left = left, .right = if (right > left) right else left + 1 };
    }

    /// The boundary nearest pixel `pixel`.
    pub fn boundaryAt(bar: Bar, pixel: i32) u64 {
        if (pixel <= 0 or bar.width == 0) return bar.area.low;
        const at: u64 = @min(@as(u64, @intCast(pixel)), @as(u64, bar.width));
        return bar.area.low + (at * bar.area.cylinders() + bar.width / 2) / bar.width;
    }

    /// The cylinder under pixel `pixel`.
    pub fn cylinderAt(bar: Bar, pixel: i32) u32 {
        if (pixel <= 0 or bar.width == 0) return bar.area.low;
        const at: u64 = @min(@as(u64, @intCast(pixel)), @as(u64, bar.width) - 1);
        const cylinder = bar.area.low + at * bar.area.cylinders() / bar.width;
        return @intCast(@min(cylinder, @as(u64, bar.area.high)));
    }
};

/// Where a partition is held: by an edge, or in the middle to move it.
pub const Grip = enum { low, middle, high };

/// Which of the `spans` is drawn under pixel `pixel` of the bar, by its
/// index; null for none.
pub fn under(bar: Bar, spans: []const Span, pixel: i32) ?usize {
    if (pixel < 0 or pixel >= bar.width) return null;
    const at: u32 = @intCast(pixel);
    for (spans, 0..) |span, index| {
        const drawn = bar.pixels(span);
        if (at >= drawn.left and at < drawn.right) return index;
    }
    return null;
}

/// What a pixel of the bar is over.
pub const Hit = union(enum) {
    /// Off the bar, or a pixel no run is drawn at.
    none,
    /// A partition: its place among the sorted spans, and where.
    part: struct { index: usize, grip: Grip },
    /// A free run.
    gap: Span,
};

/// What pixel `pixel` of the bar is over, with the `sorted` spans on it.
/// An edge is held within `grip` pixels of it, as far as a third of the
/// partition's width each, so a narrow partition can still be moved.
pub fn hit(bar: Bar, sorted: []const Span, pixel: i32, grip: u32) Hit {
    if (pixel < 0 or pixel >= bar.width) return .none;
    const at: u32 = @intCast(pixel);
    for (sorted, 0..) |span, index| {
        const drawn = bar.pixels(span);
        if (at < drawn.left or at >= drawn.right) continue;
        const reach = @min(grip, (drawn.right - drawn.left) / 3);
        const held: Grip = if (at < drawn.left + reach) .low else if (at >= drawn.right - reach) .high else .middle;
        return .{ .part = .{ .index = index, .grip = held } };
    }
    const cylinder = bar.cylinderAt(pixel);
    var next: u64 = bar.area.low;
    for (sorted) |span| {
        if (cylinder < span.low) {
            if (cylinder < next) return .none;
            return .{ .gap = .{ .low = @intCast(next), .high = span.low - 1 } };
        }
        const past: u64 = span.end();
        if (past > next) next = past;
    }
    if (cylinder < next) return .none;
    return .{ .gap = .{ .low = @intCast(next), .high = bar.area.high } };
}

// --- a GPT -----------------------------------------------------------------------

/// Blocks `first` to `last` of a disk as the cylinders of `unit` blocks
/// each that they reach into.
pub fn blockSpan(first: u64, last: u64, unit: u64) Span {
    const per = @max(unit, 1);
    return .{ .low = @intCast(@min(first / per, 0xFFFF_FFFF)), .high = @intCast(@min(last / per, 0xFFFF_FFFF)) };
}

/// A table's partition as it lies on the disk when the table is in a
/// container whose first block is `container`: its cylinders counted
/// from the disk's first block, as MountPartition mounts it. A container
/// that does not start on one of the partition's cylinders leaves it as
/// it is, since such a partition is not mounted.
pub fn onDisk(env: *const DosEnvec, container: u64) DosEnvec {
    var moved_env = env.*;
    const cylinder = @as(u64, env.surfaces) * env.blocks_per_track;
    if (container == 0 or cylinder == 0 or container % cylinder != 0) return moved_env;
    const offset = container / cylinder;
    moved_env.low_cyl = @intCast(@min(@as(u64, env.low_cyl) + offset, 0xFFFF_FFFF));
    moved_env.high_cyl = @intCast(@min(@as(u64, env.high_cyl) + offset, 0xFFFF_FFFF));
    return moved_env;
}

/// Whether a drive over `env` reads exactly blocks `first` to `last` of
/// `block_bytes` each: a partition of the GPT, mounted.
pub fn covers(env: *const DosEnvec, first: u64, last: u64, block_bytes: u32) bool {
    if (env.wholeMedium() or last < first) return false;
    return env.byteOf(0) == first * block_bytes and env.blocks() * env.size_block == (last - first + 1) * block_bytes;
}

// --- names -----------------------------------------------------------------------

/// The most a name can be, with its number.
pub const name_room = dos.MAX_DEVICE_NAME;

/// The letters a unit's new partitions are named with, by what the device
/// is called past its last `/` or `:`: `DH` on the flash disk, `SD` on a
/// card, `DU` on a stick, `HD` on any other disk.
pub fn prefixFor(device: [*:0]const u8) []const u8 {
    var start: usize = 0;
    var length: usize = 0;
    while (device[length] != 0) : (length += 1) {
        if (device[length] == '/' or device[length] == ':') start = length + 1;
    }
    const tail = device[start..length];
    if (equal(tail, "flash.device")) return "DH";
    if (equal(tail, "sdcard.device")) return "SD";
    if (equal(tail, "disk.device")) return "DU";
    return "HD";
}

fn equal(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// Two names the same, in any case, as dos's list and the table compare
/// them.
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

fn isTaken(name: []const u8, taken: []const []const u8) bool {
    for (taken) |other| {
        if (sameName(name, other)) return true;
    }
    return false;
}

/// The first name of `prefix` and a number, from 0 on, that none of
/// `taken` is, into `into`.
pub fn freeName(prefix: []const u8, taken: []const []const u8, into: *[name_room]u8) []const u8 {
    @memcpy(into[0..prefix.len], prefix);
    var number: u32 = 0;
    while (true) : (number += 1) {
        const length = prefix.len + decimal(into[prefix.len..], number);
        // Among n names, one of the numbers 0 to n is free.
        if (!isTaken(into[0..length], taken) or number > taken.len) return into[0..length];
    }
}

/// What is wrong with a partition's name.
pub const NameProblem = enum {
    none,
    empty,
    /// Longer than MAX_DEVICE_NAME.
    long,
    /// It holds a colon or a slash, which would end it in a path.
    separator,
    /// Another partition of the table has it.
    taken,
};

/// Whether `name` may name a partition beside the `others` of its table.
pub fn nameProblem(name: []const u8, others: []const []const u8) NameProblem {
    if (name.len == 0) return .empty;
    if (name.len > dos.MAX_DEVICE_NAME) return .long;
    for (name) |char| {
        if (char == ':' or char == '/') return .separator;
    }
    if (isTaken(name, others)) return .taken;
    return .none;
}

// --- numbers as text ---------------------------------------------------------------

/// The most `sizeText` writes.
pub const size_room = 24;

/// `number` in decimal at the start of `into`; how many digits.
pub fn decimal(into: []u8, number: u64) usize {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var rest = number;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    for (0..count) |index| into[index] = digits[count - 1 - index];
    return count;
}

/// A whole number typed, spaces round it allowed; null for anything
/// else, or one past `u64`'s range.
pub fn parseNumber(text: []const u8) ?u64 {
    var start: usize = 0;
    var stop = text.len;
    while (start < stop and text[start] == ' ') start += 1;
    while (stop > start and text[stop - 1] == ' ') stop -= 1;
    if (start == stop) return null;
    var value: u64 = 0;
    for (text[start..stop]) |char| {
        if (char < '0' or char > '9') return null;
        const times = @mulWithOverflow(value, 10);
        if (times[1] != 0) return null;
        const sum = @addWithOverflow(times[0], char - '0');
        if (sum[1] != 0) return null;
        value = sum[0];
    }
    return value;
}

/// The most `typeText` writes.
pub const type_room = 16;

/// A DosType as its four characters, one that is not printable as its
/// number after a backslash: `POS\0`, `MSD\0`.
pub fn typeText(dos_type: u32, into: *[type_room]u8) []const u8 {
    var at: usize = 0;
    var shift: u5 = 24;
    while (true) : (shift -= 8) {
        const char: u8 = @truncate(dos_type >> shift);
        if (char < ' ' or char > '~') {
            into[at] = '\\';
            at += 1;
            at += decimal(into[at..], char);
        } else {
            into[at] = char;
            at += 1;
        }
        if (shift == 0) break;
    }
    return into[0..at];
}

/// `bytes` as a size is shown: in the largest of K, M, G and T that is
/// no more than them, with a tenth while it is below 100 of them - `1.5M`,
/// `120G` - or in bytes below a K.
pub fn sizeText(bytes: u64, into: *[size_room]u8) []const u8 {
    const units = [_]struct { scale: u64, tag: u8 }{
        .{ .scale = 1 << 40, .tag = 'T' },
        .{ .scale = 1 << 30, .tag = 'G' },
        .{ .scale = 1 << 20, .tag = 'M' },
        .{ .scale = 1 << 10, .tag = 'K' },
    };
    for (units) |unit| {
        if (bytes < unit.scale) continue;
        const whole = bytes / unit.scale;
        var at = decimal(into, whole);
        if (whole < 100) {
            into[at] = '.';
            at += 1;
            at += decimal(into[at..], (bytes % unit.scale) * 10 / unit.scale);
        }
        into[at] = unit.tag;
        return into[0 .. at + 1];
    }
    return into[0..decimal(into, bytes)];
}

// --- what a save does ----------------------------------------------------------------

/// Whether a file system over one area finds its blocks where the other
/// has them.
pub fn sameLayout(one: *const DosEnvec, other: *const DosEnvec) bool {
    return one.low_cyl == other.low_cyl and
        one.high_cyl == other.high_cyl and
        one.dos_type == other.dos_type and
        one.size_block == other.size_block and
        one.surfaces == other.surfaces and
        one.blocks_per_track == other.blocks_per_track and
        one.sector_per_block == other.sector_per_block and
        one.reserved == other.reserved and
        one.pre_alloc == other.pre_alloc and
        one.interleave == other.interleave;
}

/// Whether one of the `table`'s partitions is laid out as `env`: what
/// is there keeps its data.
pub fn kept(table: []const DosEnvec, env: *const DosEnvec) bool {
    for (table) |*other| {
        if (sameLayout(other, env)) return true;
    }
    return false;
}

/// Whether a drive mounted over `env` is stale once its unit's table is
/// `table`: one over the whole medium is, and one over an area no
/// partition of the table is laid out as.
pub fn stale(env: *const DosEnvec, table: []const DosEnvec) bool {
    if (env.wholeMedium()) return true;
    return !kept(table, env);
}
