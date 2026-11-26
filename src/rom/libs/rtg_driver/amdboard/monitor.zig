// SPDX-License-Identifier: MPL-2.0
//! The board's connector, and what is on it.
//!
//! The board's connector is the one the video BIOS lists whose PHY drives
//! the link the firmware lit (`sound.litLink`: a link's back end and the
//! PHY it drives are the same number). Its DDC line and hot-plug line
//! are where the BIOS's table of GPIO pins puts its pins, held against
//! the engine's own GPIO registers (`i2c.lineOf`, `hpd.lineOf`).
//!
//! What is on it: whether its hot-plug line senses a monitor, and that
//! monitor's EDID, read over its DDC line by the engine's I2C engine for
//! an HDMI or DVI connector (`i2c.zig`), by I2C over the line's AUX
//! channel for a DisplayPort one (`aux.zig`). A connector without a
//! hot-plug line is taken to have a monitor where an EDID reads. The
//! board's `detect` and RTGCTRL_AMD_EDID both ask here, one at a time.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const rtg = sdk.rtg;
const tags = rtg.tags;
const err = rtg.errors;
const dcn = @import("dcn.zig");
const hpd = @import("hpd.zig");
const i2c = @import("i2c.zig");
const aux = @import("aux.zig");
const sound = @import("sound.zig");

/// A line a connector does not have.
pub const no_line: u32 = 0xFF;

/// A connector, as the board keeps it.
pub const Connector = struct {
    found: bool = false,
    index: u32 = 0,
    kind: u32 = amdgpu.GPUCONNECTOR_OTHER,
    ddc_line: u32 = no_line,
    hpd_line: u32 = no_line,
};

/// Connector `index` as the BIOS lists it, with its lines: not found
/// past the last.
pub fn connector(engine: dcn.Engine, index: u32) Connector {
    var listed: amdgpu.GPUConnector = .{};
    if (!engine.gpu.GetGPUConnector(index, &listed)) return .{};
    return .{
        .found = true,
        .index = index,
        .kind = listed.kind,
        .ddc_line = i2c.lineOf(engine, listed) orelse no_line,
        .hpd_line = hpd.lineOf(engine, listed) orelse no_line,
    };
}

/// The board's connector: the one whose PHY drives the lit link.
pub fn boards(engine: dcn.Engine) Connector {
    const link = sound.litLink(engine) orelse return .{};
    var index: u32 = 0;
    while (index < amdgpu.GPUCONNECTORS_MAX) : (index += 1) {
        var listed: amdgpu.GPUConnector = .{};
        if (!engine.gpu.GetGPUConnector(index, &listed)) break;
        if (listed.phy == link) return connector(engine, index);
    }
    return .{};
}

/// Whether the connector's monitor speaks over I2C on its DDC line: an
/// HDMI or DVI one, on a line with the engine.
pub fn readsOverI2c(on: Connector) bool {
    if (on.ddc_line == no_line) return false;
    return on.kind == amdgpu.GPUCONNECTOR_HDMI or on.kind == amdgpu.GPUCONNECTOR_DVI;
}

/// Whether the connector's monitor speaks over its AUX channel: a
/// DisplayPort one, on a line with an AUX engine.
pub fn readsOverAux(on: Connector) bool {
    if (on.ddc_line == no_line or on.ddc_line >= aux.lines) return false;
    return on.kind == amdgpu.GPUCONNECTOR_DISPLAYPORT;
}

/// The EDID of the connector's monitor into `into`: the bytes read, by
/// whichever way it speaks; 0 for a connector that speaks neither.
fn readEdid(engine: dcn.Engine, on: Connector, into: []u8) u32 {
    if (readsOverI2c(on)) return i2c.readEdid(engine, on.ddc_line, into).bytes;
    if (readsOverAux(on)) return aux.readEdid(engine, on.ddc_line, into).bytes;
    return 0;
}

/// Whether a monitor is on the connector, as its hot-plug line senses
/// it; null for a connector without one.
pub fn present(engine: dcn.Engine, on: Connector) ?bool {
    if (on.hpd_line == no_line) return null;
    return hpd.senses(engine, on.hpd_line);
}

/// The board's `detect`: whether a monitor is on the connector, and its
/// EDID into the library's buffer. RTGERR_NOT_SUPPORTED where the board
/// has no connector the BIOS lists.
pub fn detect(engine: dcn.Engine, on: Connector, into: *rtg.modes.RtgDetect) i32 {
    if (!on.found) return err.RTGERR_NOT_SUPPORTED;
    into.edid_size = 0;
    into.present = 0;
    const sensed = present(engine, on);
    if (sensed == false) return err.RTGERR_OK;
    if (!readsOverI2c(on) and !readsOverAux(on)) {
        into.present = @intFromBool(sensed == true);
        return err.RTGERR_OK;
    }
    if (into.edid_max < i2c.block_bytes) {
        into.present = @intFromBool(sensed == true);
        return err.RTGERR_OK;
    }
    const bytes = readEdid(engine, on, into.edid[0..into.edid_max]);
    into.edid_size = bytes;
    into.present = @intFromBool(sensed == true or bytes != 0);
    return err.RTGERR_OK;
}

/// RTGCTRL_AMD_EDID: the connector the asker names - or the board's own,
/// `boards_own` - read as `detect` reads it, into `into`.
pub fn edid(engine: dcn.Engine, boards_own: Connector, into: *tags.RtgAmdEdid) i32 {
    const on = if (into.connector == tags.RTG_AMD_BOARDS_CONNECTOR) boards_own else connector(engine, into.connector);
    if (!on.found) return err.RTGERR_BAD_ARG;
    into.kind = on.kind;
    into.ddc_line = on.ddc_line;
    into.hpd_line = on.hpd_line;
    into.present = @intFromBool(present(engine, on) == true);
    into.bytes = 0;
    if (readsOverAux(on)) {
        aux.read(engine, on.ddc_line, into.found[0..4]);
        const read = aux.readEdid(engine, on.ddc_line, &into.edid);
        aux.read(engine, on.ddc_line, into.after[0..4]);
        into.bytes = read.bytes;
        into.result = read.reply.result;
        into.answer = read.reply.answer;
        return err.RTGERR_OK;
    }
    if (!readsOverI2c(on)) return err.RTGERR_NOT_SUPPORTED;
    i2c.read(engine, on.ddc_line, &into.found);
    const read = i2c.readEdid(engine, on.ddc_line, &into.edid);
    i2c.read(engine, on.ddc_line, &into.after);
    into.bytes = read.bytes;
    into.result = @intFromEnum(read.result);
    return err.RTGERR_OK;
}

/// Whether `timings` are those the pipe is scanning: its picture, and a
/// line and a frame as long as its own.
pub fn isLit(engine: dcn.Engine, timings: rtg.RtgTimings) bool {
    return sameTiming(engine.width, engine.height, engine.h_total, engine.v_total, timings);
}

/// The timing generator holds a line's and a frame's length less one.
fn sameTiming(width: u32, height: u32, h_total_less_one: u32, v_total_less_one: u32, timings: rtg.RtgTimings) bool {
    if (timings.flags & rtg.modes.RTGTM_INTERLACED != 0) return false;
    if (timings.h_active != width or timings.v_active != height) return false;
    const h_total = timings.h_active + timings.h_front + timings.h_sync + timings.h_back;
    const v_total = timings.v_active + timings.v_front + timings.v_sync + timings.v_back;
    return h_total == h_total_less_one + 1 and v_total == v_total_less_one + 1;
}

test "the lit timing is the one with the pipe's picture, line and frame" {
    const testing = @import("std").testing;
    // The box's monitor's own 2560x1440, as its EDID names it.
    const own: rtg.RtgTimings = .{
        .pixel_clock_hz = 241_500_000,
        .h_active = 2560,
        .h_front = 48,
        .h_sync = 32,
        .h_back = 80,
        .v_active = 1440,
        .v_front = 3,
        .v_sync = 5,
        .v_back = 33,
    };
    try testing.expect(sameTiming(2560, 1440, 2719, 1480, own));
    // The standard's 2560x1440 at 60 has a longer line.
    var other = own;
    other.h_front = 160;
    try testing.expect(!sameTiming(2560, 1440, 2719, 1480, other));
    try testing.expect(!sameTiming(1920, 1080, 2719, 1480, own));
    var interlaced = own;
    interlaced.flags = rtg.modes.RTGTM_INTERLACED;
    try testing.expect(!sameTiming(2560, 1440, 2719, 1480, interlaced));
}

comptime {
    // The results as the SDK names them.
    const assert = @import("std").debug.assert;
    assert(@intFromEnum(i2c.Result.ok) == tags.RTG_AMD_DDC_OK);
    assert(@intFromEnum(i2c.Result.busy) == tags.RTG_AMD_DDC_BUSY);
    assert(@intFromEnum(i2c.Result.nack) == tags.RTG_AMD_DDC_NO_ANSWER);
    assert(@intFromEnum(i2c.Result.timeout) == tags.RTG_AMD_DDC_TIMEOUT);
    assert(@intFromEnum(i2c.Result.failed) == tags.RTG_AMD_DDC_FAILED);
    assert(@intFromEnum(i2c.Result.too_long) == tags.RTG_AMD_DDC_TOO_LONG);
    assert(no_line == 0xFF);
}
