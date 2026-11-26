// SPDX-License-Identifier: MPL-2.0
//! The hub's arbiter, which passes the fetchers' requests on to the
//! memory: the watermarks it holds each fetcher's time to urgency
//! against, and whether it lets the memory into self-refresh between the
//! fetchers' bursts - written as the vendor's driver writes them for this
//! engine (hubbub31_program_watermarks).
//!
//! **The watermarks** are those the model of what the planes read works
//! out (`bandwidth.Watermarks`, `marksOf`): urgency - a fetcher whose time
//! to urgency falls below it has its requests made urgent - a trip to the
//! memory, self-refresh's entry and exit and the engine's deeper state's
//! (Z8), self-refresh's exit and the deeper state's, and the memory
//! clock's change, each in nanoseconds; and the share of the return the
//! planes read without their bursts, nominal and with an immediate flip -
//! none, the board's flips waiting for the update - in thousandths. The
//! hub holds four sets of them, which the power manager picks between by
//! the display controller's clock (the ranges `smu.sendRanges` hands it);
//! the vendor works out the first for this engine and copies it into the
//! other three, and so does the board. A time goes in in the hub's
//! reference cycles, 24 a microsecond, rounded down, a share as it is -
//! each at most what its register holds.
//!
//! **In two passes** round a change, as the clocks are (`clocks.zig`):
//! before it, once the clocks have gone up, each watermark that goes up;
//! after it, once the pipes have taken it and before the clocks go down,
//! every one - and then the memory is let into self-refresh, the force
//! the firmware holds it out with taken off (`DRAM_STATE_CNTL`). A
//! watermark is written into the four sets together, in the vendor's
//! order: the urgent ones, self-refresh's, the memory clock's. What was
//! last written is kept (`Marks`), from nothing as the vendor's is: the
//! first pass writes every watermark there is.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const rtg = sdk.rtg;
const dcn = @import("dcn.zig");
const bandwidth = @import("bandwidth.zig");

/// The hub's watermarks in a set, in the order of their registers:
/// urgency, a trip to the memory, self-refresh's entry and exit, the
/// deeper state's, self-refresh's exit, the deeper state's, the memory
/// clock's change, the share of the return read nominally and with an
/// immediate flip - as the board's controls report them
/// (`RtgAmdClocks.asked_marks`, `hub_marks`).
pub const marks_count = rtg.tags.RTG_AMD_MARKS;
pub const Marks = [marks_count]u32;
pub const urgency = 0;
pub const trip = 1;
pub const enter_exit = 2;
pub const deeper_enter_exit = 3;
pub const exit = 4;
pub const deeper_exit = 5;
pub const change = 6;
pub const nominal = 7;
pub const flip = 8;

/// The hub's sets: how many, the first one's first register, and the
/// stride to the next.
pub const set_count = rtg.tags.RTG_AMD_SETS;
const first_set = 0x04fd;
const set_stride = 9;

/// What each register holds at most.
const most = [marks_count]u32{ 0x3fff, 0x3fff, 0xffff, 0xfffff, 0xffff, 0xfffff, 0xffff, 0x3ff, 0x3ff };

/// The hub's reference, in MHz: the 48 MHz crystal halved, which the
/// fetchers' schedules count in too.
const reference_mhz = 24;

/// The order the vendor writes them in: the urgent ones, self-refresh's,
/// the memory clock's, each group into every set before the next.
const groups = [_][]const usize{
    &.{ urgency, flip, nominal, trip },
    &.{ enter_exit, exit, deeper_enter_exit, deeper_exit },
    &.{change},
};

/// The hub's control of the memory's states: in its two low bits, what
/// self-refresh is forced to - allowed - and whether it is forced.
const dram_state = 0x04fc;
const self_refresh_value: u32 = 1 << 0;
const self_refresh_forced: u32 = 1 << 1;

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

/// The watermarks the model works out, as the hub is given them: in
/// nanoseconds, rounded down, and thousandths.
pub fn marksOf(watermarks: bandwidth.Watermarks) Marks {
    var marks: Marks = @splat(0);
    marks[urgency] = nanoseconds(watermarks.urgent_ps);
    marks[trip] = nanoseconds(watermarks.latency_ps);
    marks[enter_exit] = nanoseconds(watermarks.enter_exit_ps);
    marks[deeper_enter_exit] = nanoseconds(watermarks.z8_enter_exit_ps);
    marks[exit] = nanoseconds(watermarks.exit_ps);
    marks[deeper_exit] = nanoseconds(watermarks.z8_exit_ps);
    marks[change] = nanoseconds(watermarks.change_ps);
    marks[nominal] = watermarks.fraction;
    return marks;
}

fn nanoseconds(ps: u64) u32 {
    return @intCast(@min(ps / 1000, 0xffff_ffff));
}

/// Watermark `index` of `value` as its register holds it
/// (convert_and_clamp): a time in reference cycles, rounded down, a share
/// as it is - at most what the register holds.
pub fn registerOf(index: usize, value: u32) u32 {
    const counted: u64 = if (index < nominal) @as(u64, value) * reference_mhz / 1000 else value;
    return @intCast(@min(counted, most[index]));
}

/// Whether a pass writes a watermark from `now` to `wanted`: the first
/// one where it goes up, the second every one.
fn writes(lowers: bool, wanted: u32, now: u32) bool {
    return lowers or wanted > now;
}

/// The first pass of a change (`lowers` false) or the second: `marks`
/// written into the four sets where the pass writes them from what
/// `written` keeps, which keeps them then; after the second, the memory
/// let into self-refresh.
pub fn program(engine: dcn.Engine, written: *Marks, marks: Marks, lowers: bool) void {
    for (groups) |group| {
        var due: [marks_count]bool = @splat(false);
        for (group) |index| {
            if (!writes(lowers, marks[index], written[index])) continue;
            due[index] = true;
            written[index] = marks[index];
        }
        for (0..set_count) |set| {
            const base: u32 = @intCast(first_set + set * set_stride);
            for (group) |index| {
                if (due[index]) at(engine, base + @as(u32, @intCast(index))).* = registerOf(index, marks[index]);
            }
        }
    }
    if (lowers) at(engine, dram_state).* &= ~(self_refresh_value | self_refresh_forced);
}

/// The hub's four sets as it holds them, each register's own bits.
pub fn read(engine: dcn.Engine, into: *[set_count]Marks) void {
    for (into, 0..) |*set, set_index| {
        const base: u32 = @intCast(first_set + set_index * set_stride);
        for (set, 0..) |*mark, index| mark.* = at(engine, base + @as(u32, @intCast(index))).* & most[index];
    }
}

/// Whether the hub lets the memory into self-refresh: not forced, or
/// forced to allow it.
pub fn selfRefreshAllowed(engine: dcn.Engine) bool {
    const state = at(engine, dram_state).*;
    return state & self_refresh_forced == 0 or state & self_refresh_value != 0;
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

test "a watermark in the hub's reference cycles, rounded down, at most what its register holds" {
    try testing.expectEqual(@as(u32, 156), registerOf(urgency, 6_500));
    try testing.expectEqual(@as(u32, 155), registerOf(urgency, 6_499));
    try testing.expectEqual(@as(u32, 0x3fff), registerOf(trip, 1_000_000));
    try testing.expectEqual(@as(u32, 0xffff), registerOf(enter_exit, 3_000_000));
    try testing.expectEqual(@as(u32, 72_000), registerOf(deeper_enter_exit, 3_000_000));
    try testing.expectEqual(@as(u32, 1692), registerOf(change, 70_500));
    try testing.expectEqual(@as(u32, 250), registerOf(nominal, 250));
    try testing.expectEqual(@as(u32, 0x3ff), registerOf(flip, 5_000));
}

test "the first pass writes a watermark that goes up, the second every one" {
    try testing.expect(writes(false, 2, 1));
    try testing.expect(!writes(false, 1, 1));
    try testing.expect(!writes(false, 1, 2));
    try testing.expect(writes(true, 1, 2));
    try testing.expect(writes(true, 1, 1));
}

test "the model's watermarks as the hub is given them" {
    const marks = marksOf(.{
        .urgent_ps = 6_617_499,
        .change_ps = 18_270_832,
        .exit_ps = 19_400_000,
        .enter_exit_ps = 21_400_999,
        .z8_exit_ps = 4_000_000,
        .z8_enter_exit_ps = 5_000_000,
        .latency_ps = 4_000_000,
        .fraction = 87,
    });
    try testing.expectEqual(@as(u32, 6_617), marks[urgency]);
    try testing.expectEqual(@as(u32, 4_000), marks[trip]);
    try testing.expectEqual(@as(u32, 21_400), marks[enter_exit]);
    try testing.expectEqual(@as(u32, 5_000), marks[deeper_enter_exit]);
    try testing.expectEqual(@as(u32, 19_400), marks[exit]);
    try testing.expectEqual(@as(u32, 4_000), marks[deeper_exit]);
    try testing.expectEqual(@as(u32, 18_270), marks[change]);
    try testing.expectEqual(@as(u32, 87), marks[nominal]);
    try testing.expectEqual(@as(u32, 0), marks[flip]);
}
