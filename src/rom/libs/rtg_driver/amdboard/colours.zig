// SPDX-License-Identifier: MPL-2.0
//! The colours the board's link sends: its RGB in full range - every
//! value a colour - or limited, 16 to 235 as a television takes them.
//!
//! Which: the range the board's settings ask for (`RtgBoardInfo.
//! color_range`); where they ask for none, a CEA mode but the first goes
//! out limited to an HDMI monitor that does not let its range be chosen
//! (QS), as CEA-861 has such a monitor take it, and everything else full.
//! An HDMI monitor is told the range in the AVI infoframe where the
//! settings ask for one or the monitor lets it be chosen; a DVI monitor
//! takes no infoframe and is told nothing.
//!
//! How: the blender's output matrix for the pipe's output (the MPC's
//! OCSC, mpc3_set_ocsc_default), in its first set of coefficients - for
//! full range the identity, for limited the vendor's 0x1B67 of each
//! colour - some 219/256 - and 0x201 added, some 16/256 of full scale -
//! in S2.13, a row a colour: red, green, blue,
//! each three factors and an offset. Written while the pipe runs, it is
//! taken up from the next pixel on.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");

/// The blender's output matrices: the coefficients' format, shared by
/// every output; each output's mode and its first set of coefficients,
/// two to a register - an output's set its stride apart.
const coefficient_format = 0x05a0;
const matrix_mode = 0x05a1;
const matrix_first = 0x05a2;
const output_stride = 0x0d;
const matrix_registers = 6;

/// The matrix's modes: off - the colours passed through - or its first
/// set of coefficients; and the two of a register's halves.
const mode_mask: u32 = 0x3;
const mode_off: u32 = 0;
const mode_first: u32 = 1;
const half_shift = 16;

/// The vendor's matrices (output_csc_matrix), a row a colour - red,
/// green, blue - of three factors and an offset.
const full_matrix = [12]u16{ 0x2000, 0, 0, 0, 0, 0x2000, 0, 0, 0, 0, 0x2000, 0 };
const limited_matrix = [12]u16{ 0x1B67, 0, 0, 0x201, 0, 0x1B67, 0, 0x201, 0, 0, 0x1B67, 0x201 };

/// How a mode goes out: limited or full, and whether the AVI infoframe
/// says which.
pub const Output = struct {
    limited: bool = false,
    said: bool = false,
};

/// How `timings` go to the monitor `said` describes, with the range
/// `asked` (`RTGRANGE_*`) the settings ask for.
pub fn outputFor(said: *const rtg.RtgMonitorInfo, timings: *const rtg.RtgTimings, asked: u8) Output {
    const hdmi = said.flags & rtg.modes.RTGMON_HDMI != 0;
    const selectable = said.flags & rtg.modes.RTGMON_RANGE_SELECTABLE != 0;
    const chosen = asked != rtg.RTGRANGE_AUTO;
    const cea_limited = hdmi and timings.vic > 1;
    return .{
        .limited = if (chosen) asked == rtg.RTGRANGE_LIMITED else cea_limited and !selectable,
        .said = hdmi and (chosen or selectable),
    };
}

/// The AVI infoframe's flags (`RTGAVI_RANGE_*`) for `output`.
pub fn aviFlags(output: Output) u32 {
    if (!output.said) return 0;
    return if (output.limited) rtg.RTGAVI_RANGE_LIMITED else rtg.RTGAVI_RANGE_FULL;
}

/// The matrix's registers' words for a range: two coefficients to a
/// word, the first in its low half.
pub fn matrixWords(limited: bool) [matrix_registers]u32 {
    const matrix = if (limited) &limited_matrix else &full_matrix;
    var words: [matrix_registers]u32 = undefined;
    for (&words, 0..) |*word, index| word.* = @as(u32, matrix[2 * index]) | @as(u32, matrix[2 * index + 1]) << half_shift;
    return words;
}

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.blender) + offset) * 4);
}

/// Whether the engine's blender is reached: without it the range stays
/// as the firmware left it.
pub fn reached(engine: dcn.Engine) bool {
    return engine.blender != 0;
}

/// Output `output`'s colours sent in limited range or in full, from the
/// next pixel on (mpc3_set_ocsc_default): the coefficients' format the
/// fixed one, the matrix's mode its first set, and that set written.
pub fn setRange(engine: dcn.Engine, output: u32, limited: bool) void {
    if (!reached(engine)) return;
    at(engine, coefficient_format).* = 0;
    const mode = at(engine, matrix_mode + output * output_stride);
    mode.* = (mode.* & ~mode_mask) | mode_first;
    const words = matrixWords(limited);
    for (words, 0..) |word, index| at(engine, matrix_first + output * output_stride + @as(u32, @intCast(index))).* = word;
}

/// Whether output `output` sends its colours in limited range, as its
/// matrix reads: null where the blender is not reached, or the matrix is
/// one this does not write.
pub fn rangeOf(engine: dcn.Engine, output: u32) ?bool {
    if (!reached(engine)) return null;
    const mode = at(engine, matrix_mode + output * output_stride).* & mode_mask;
    if (mode == mode_off) return false;
    if (mode != mode_first) return null;
    const first = at(engine, matrix_first + output * output_stride).*;
    if (first == matrixWords(false)[0]) return false;
    if (first == matrixWords(true)[0]) return true;
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the range: CEA's modes limited to a monitor without QS, the settings' range said" {
    const full_hd: rtg.RtgTimings = .{ .pixel_clock_hz = 148_500_000, .h_active = 1920, .v_active = 1080, .vic = 16 };
    const vga: rtg.RtgTimings = .{ .pixel_clock_hz = 25_175_000, .h_active = 640, .v_active = 480, .vic = 1 };
    const own: rtg.RtgTimings = .{ .pixel_clock_hz = 241_500_000, .h_active = 2560, .v_active = 1440 };
    // The box's Dell: HDMI, its range selectable - full, and said.
    const dell: rtg.RtgMonitorInfo = .{ .flags = rtg.modes.RTGMON_HDMI | rtg.modes.RTGMON_RANGE_SELECTABLE };
    try testing.expectEqual(Output{ .limited = false, .said = true }, outputFor(&dell, &full_hd, rtg.RTGRANGE_AUTO));
    try testing.expectEqual(rtg.RTGAVI_RANGE_FULL, aviFlags(outputFor(&dell, &own, rtg.RTGRANGE_AUTO)));
    try testing.expectEqual(rtg.RTGAVI_RANGE_LIMITED, aviFlags(outputFor(&dell, &own, rtg.RTGRANGE_LIMITED)));
    // Without QS a CEA mode goes out limited, unsaid; VIC 1 and a mode
    // of no number full.
    const plain: rtg.RtgMonitorInfo = .{ .flags = rtg.modes.RTGMON_HDMI };
    try testing.expectEqual(Output{ .limited = true, .said = false }, outputFor(&plain, &full_hd, rtg.RTGRANGE_AUTO));
    try testing.expect(!outputFor(&plain, &vga, rtg.RTGRANGE_AUTO).limited);
    try testing.expect(!outputFor(&plain, &own, rtg.RTGRANGE_AUTO).limited);
    // Asked for, it is sent so and said, QS or not.
    try testing.expectEqual(Output{ .limited = false, .said = true }, outputFor(&plain, &full_hd, rtg.RTGRANGE_FULL));
    // DVI: as asked, and never said.
    const dvi: rtg.RtgMonitorInfo = .{};
    try testing.expectEqual(Output{ .limited = true, .said = false }, outputFor(&dvi, &full_hd, rtg.RTGRANGE_LIMITED));
    try testing.expectEqual(Output{}, outputFor(&dvi, &full_hd, rtg.RTGRANGE_AUTO));
    try testing.expectEqual(@as(u32, 0), aviFlags(outputFor(&dvi, &full_hd, rtg.RTGRANGE_LIMITED)));
}

test "the range: the blender's matrix words, the vendor's coefficients two to a word" {
    try testing.expectEqualSlices(u32, &.{ 0x0000_2000, 0, 0x2000_0000, 0, 0, 0x2000 }, &matrixWords(false));
    try testing.expectEqualSlices(u32, &.{ 0x0000_1B67, 0x0201_0000, 0x1B67_0000, 0x0201_0000, 0, 0x0201_1B67 }, &matrixWords(true));
}
