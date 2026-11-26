// SPDX-License-Identifier: MPL-2.0
//! The board's pipe taken down and brought up again in the mode it is
//! in: its timing generator, the link's front end - the stream encoder
//! that packs the pipe's pixels for the link - and back end, the PHY that
//! drives the socket, and the PHY's own PLL, which makes the pixel clock.
//!
//! The PHY and its PLL are the video BIOS's command tables' to switch,
//! which on this engine the display controller runs (`dmub.runTable`):
//! the transmitter's table switches the PHY on, with its lanes and its
//! symbol clock, or off; the pixel clock's sets the PLL for a pipe or
//! powers it down; the encoder's sets a front end up for a stream. The
//! rest is the engine's own registers.
//!
//! **Down**, in this order: an HDMI monitor told to mute picture and
//! sound (the general control packet's AVMUTE) and given three frames to
//! hear it; the timing generator stopped where it was told to stop - at
//! the end of a frame's first blank line - and waited for, its clocks
//! gated; the front end's FIFO stopped and the front end let go of by
//! the back end; the PHY switched off where it is on; its PLL powered
//! down.
//!
//! **Up**: the timing generator's clocks on and waited for; the PLL set
//! for the mode's pixel clock - times the deep colour's factor on HDMI -
//! and the deep colour's resync put back; the timing generator started
//! and a frame let pass; the back end told the link's kind; the
//! encoder's table run for the stream, and the front end's packing and
//! the HDMI packets' controls put back as they were found, since that
//! table may set them its own way; the back end given the front end, the
//! FIFO reset and started; the PHY switched on; the back end told the
//! link's kind once more, which the transmitter's table can leave
//! otherwise; the FIFO reset and started again, now with the symbol clock
//! running; the display clock's divider written with what it reads,
//! which has the FIFOs between the clock domains find their places
//! again; the mute lifted as it was found, and three frames let pass so
//! that what the pipe sends then is a whole frame's.
//!
//! **Nothing new is chosen.** The mode is the one the timing generator
//! holds - stopping it leaves its timing as it is - and the pixel clock
//! is the mode's as the library has it, the board's monitor's own; what
//! the engine's registers say of the stream - its kind, its deep colour,
//! which front end the back end takes - is read before the pipe goes
//! down and put back as it was. Taken: HDMI and DVI on a single link, up
//! to 340 MHz, one pipe without its picture split between several, RGB
//! or 4:4:4. Not touched: the planes, the audio's own registers, the
//! packets' contents, the power of the front end's memories.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const tags = sdk.rtg.tags;
const err = sdk.rtg.errors;
const dcn = @import("dcn.zig");
const dmub = @import("dmub.zig");
const monitor = @import("monitor.zig");
const sound = @import("sound.zig");

// --- the registers, in 32-bit words from the engine's third address ---------------

/// A timing generator's control and its clocks' control, a pipe's
/// stride apart; its vertical timing's own control, one word apart; the
/// control of its clock input and where its picture comes from and in
/// what format, the output's stride apart.
const otg_control = 0x1b41;
const otg_clock_control = 0x1b85;
const otg_stride = 0x80;
const vtg_control = 0x052d;
const optc_source = 0x1acb;
const optc_format = 0x1acc;
const optc_input_clock = 0x1acf;
const optc_stride = 0x10;

/// A link's front end and back end, a link's stride apart: the front
/// end's control, its FIFO's, the HDMI control, the HDMI packets'
/// controls and the general control packet; the back end's control and
/// whether it is on.
const dig_front = 0x208b;
const dig_fifo = 0x2091;
const hdmi_control = 0x2094;
const hdmi_gc = 0x209e;
const dig_back = 0x20b1;
const dig_back_enable = 0x20b2;
const link_stride = 0x100;

/// What of the front end is put back after the encoder's table: the
/// HDMI control, the packets' controls and the general control packet,
/// whole.
const kept = [_]u32{ hdmi_control, 0x2098, 0x2099, 0x209a, 0x209b, 0x209c, 0x209d, 0x209f, 0x20a0, 0x20a1, 0x20a2, 0x20a3, 0x20a4, 0x20a5, 0x20a6, hdmi_gc };

comptime {
    // The general control packet is put back last, its mute with it.
    @import("std").debug.assert(kept[kept.len - 1] == hdmi_gc);
}

/// Of the clocks, counted from the engine's second address: each PHY's
/// PLL's deep colour resync, and the display clock's divider.
const phypll_resync = [_]u32{ 0x0040, 0x0041, 0x0042, 0x0043, 0x004c };
const dentist = 0x0064;

// --- their fields --------------------------------------------------------------------

const otg_master_enable: u32 = 1 << 0;
const vtg_enable: u32 = 1 << 31;
const otg_clock_enable: u32 = 1 << 0;
const otg_clock_gate_off: u32 = 1 << 1;
const otg_clock_on: u32 = 1 << 8;
const otg_busy: u32 = 1 << 16;
const input_clock_gate_off: u32 = 1 << 0;
const input_clock_enable: u32 = 1 << 1;
const input_clock_on: u32 = 1 << 2;
const source_segments_mask: u32 = 0x3;
const format_mask: u32 = 0x3;

const front_source_mask: u32 = 0x7;
const front_symclk_on: u32 = 1 << 24;
const front_packing: u32 = 0xD000_0000;
const fifo_enable: u32 = 1 << 0;
const fifo_reset: u32 = 1 << 1;
const fifo_reset_done: u32 = 1 << 20;
const hdmi_deep_color_enable: u32 = 1 << 24;
const hdmi_deep_color_shift = 28;
const hdmi_deep_color_mask: u32 = 0x3;
const gc_avmute: u32 = 1 << 0;
const back_mode_shift = 16;
const back_mode_mask: u32 = 0x7 << back_mode_shift;
const back_fronts_shift = 8;
const back_enable: u32 = 1 << 0;
const resync_deep_color: u32 = 0x30;
const dentist_write_mask: u32 = 0x7f;
const dentist_read_shift = 8;

/// The back end's kinds of link.
const mode_dvi: u32 = 2;
const mode_hdmi: u32 = 3;

// --- the BIOS's tables' parameters -----------------------------------------------------

/// The transmitter's actions; the encoder's action that sets a stream
/// up; the links' kinds as the tables number them, and none.
const transmitter_off: u8 = 0;
const transmitter_on: u8 = 1;
const encoder_stream_setup: u8 = 0x0f;
const table_mode_dvi: u8 = 2;
const table_mode_hdmi: u8 = 3;
const table_mode_none: u8 = 15;
/// The first of the PHYs' PLLs as the pixel clock's table numbers them,
/// the PHY's own one; its asking that a PLL be set whatever it holds;
/// the pipe none is.
const first_phy_pll: u8 = 20;
const pll_force: u8 = 0x01;
const no_pipe: u8 = 0xff;
/// A single link's lanes; the transmitter's table's revision whose last
/// bytes are reserved, and the number of an HPO encoder none is - the
/// later revisions' byte for one, which a TMDS link has none of.
const lanes: u8 = 4;
const transmitter_revision_short = 6;
const no_hpo: u8 = 0xf6;

/// Where the video BIOS names its list of command tables, and the
/// transmitter's place in it.
const atom_header_at = 0x48;
const atom_commands_at = 0x1e;
const transmitter_table_index = 76;

// --- what is taken, and how long it waits -------------------------------------------

/// The fastest pixel clock a link here is taken at, in kHz: past it,
/// HDMI scrambles and DVI wants a second link.
const fastest_tmds_khz: u32 = 340_000;
const fastest_dvi_khz: u32 = 165_000;

/// How long the timing generator is waited for to stop, and its clocks
/// and the FIFO's reset to come.
const stop_wait_us: u64 = 100_000;
const clock_wait_us: u64 = 10_000;
const fifo_wait_us: u64 = 50_000;

/// The deep colour's bits a pixel, by its number: what the pixel clock
/// is multiplied by over 24.
const deep_color_bits = [4]u32{ 24, 30, 36, 48 };

/// The stream on the board's pipe, as it was read before the pipe goes
/// down: everything up puts back.
pub const Stream = struct {
    pipe: u32 = 0,
    front: u32 = 0,
    back: u32 = 0,
    phy: u32 = 0,
    hdmi: bool = false,
    deep_color: u32 = 0,
    /// The mode's pixel clock in 100 Hz, the PLL's, and the PHY's
    /// symbol clock in kHz.
    pixel_100hz: u32 = 0,
    pll_100hz: u32 = 0,
    symbol_khz: u32 = 0,
    /// A frame's time.
    frame_us: u64 = 0,
    /// The hot-plug line as the tables number it, from 1; 0 for none.
    hpd_select: u8 = 0,
    /// The connector's and the encoder's object numbers, the low byte
    /// of each the BIOS lists.
    connector_object: u8 = 0,
    encoder_object: u8 = 0,
    transmitter_revision: u32 = 0,
    /// The registers put back.
    front_control: u32 = 0,
    fifo: u32 = 0,
    back_control: u32 = 0,
    resync: u32 = 0,
    kept: [kept.len]u32 = @splat(0),
};

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

fn clockAt(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.clocks) + offset) * 4);
}

fn pipeAt(engine: dcn.Engine, pipe: u32, offset: u32) *volatile u32 {
    return at(engine, offset + pipe * otg_stride);
}

fn outputAt(engine: dcn.Engine, pipe: u32, offset: u32) *volatile u32 {
    return at(engine, offset + pipe * optc_stride);
}

fn linkAt(engine: dcn.Engine, link: u32, offset: u32) *volatile u32 {
    return at(engine, offset + link * link_stride);
}

/// Wait until `register` holds `wanted` under `mask`, for `limit_us` at
/// the most: whether it did.
fn until(engine: dcn.Engine, register: *volatile u32, mask: u32, wanted: u32, limit_us: u64) bool {
    const deadline = engine.sys.UptimeUs() + limit_us;
    while (register.* & mask != wanted) {
        if (engine.sys.UptimeUs() > deadline) return false;
        dcn.pause(engine.sys, 10);
    }
    return true;
}

/// The stream on the board's pipe into `into`, read off the engine, the
/// BIOS's connector `on` and the mode's `pixel_clock_hz`: RTGERR_OK, or
/// why it is not one this takes.
pub fn take(engine: dcn.Engine, on: monitor.Connector, pixel_clock_hz: u32, into: *Stream) i32 {
    into.* = .{};
    if (!on.found) return err.RTGERR_NOT_SUPPORTED;
    if (on.kind != amdgpu.GPUCONNECTOR_HDMI and on.kind != amdgpu.GPUCONNECTOR_DVI) return err.RTGERR_NOT_SUPPORTED;
    if (pixel_clock_hz == 0) return err.RTGERR_BAD_MODE;
    var listed: amdgpu.GPUConnector = .{};
    if (!engine.gpu.GetGPUConnector(on.index, &listed) or listed.phy >= phypll_resync.len) return err.RTGERR_NOT_SUPPORTED;

    const pipe = engine.pipe;
    if (pipeAt(engine, pipe, otg_control).* & otg_master_enable == 0) return err.RTGERR_NO_DISPLAY;
    if (outputAt(engine, pipe, optc_source).* & source_segments_mask != 0) return err.RTGERR_NOT_SUPPORTED;
    if (outputAt(engine, pipe, optc_format).* & format_mask != 0) return err.RTGERR_NOT_SUPPORTED;
    const front = sound.litLink(engine) orelse return err.RTGERR_NO_DISPLAY;
    const back = backOf(engine, front) orelse return err.RTGERR_NOT_SUPPORTED;
    const back_control = linkAt(engine, back, dig_back).*;
    const mode = (back_control & back_mode_mask) >> back_mode_shift;
    if (mode != mode_hdmi and mode != mode_dvi) return err.RTGERR_NOT_SUPPORTED;

    into.pipe = pipe;
    into.front = front;
    into.back = back;
    into.phy = listed.phy;
    into.hdmi = mode == mode_hdmi;
    const hdmi = linkAt(engine, front, hdmi_control).*;
    if (into.hdmi and hdmi & hdmi_deep_color_enable != 0) into.deep_color = (hdmi >> hdmi_deep_color_shift) & hdmi_deep_color_mask;
    into.pixel_100hz = pixel_clock_hz / 100;
    into.pll_100hz = scaled(into.pixel_100hz, into.deep_color);
    into.symbol_khz = into.pll_100hz / 10;
    if (into.symbol_khz > fastest_tmds_khz) return err.RTGERR_NOT_SUPPORTED;
    if (!into.hdmi and into.symbol_khz > fastest_dvi_khz) return err.RTGERR_NOT_SUPPORTED;
    const line: u64 = engine.h_total + 1;
    const frame: u64 = engine.v_total + 1;
    into.frame_us = line * frame * 1_000_000 / pixel_clock_hz;
    into.hpd_select = if (on.hpd_line == monitor.no_line) 0 else @intCast(on.hpd_line + 1);
    into.connector_object = @truncate(listed.object);
    into.encoder_object = @truncate(listed.encoder);
    into.transmitter_revision = transmitterRevision(engine);

    into.front_control = linkAt(engine, front, dig_front).*;
    into.fifo = linkAt(engine, front, dig_fifo).*;
    into.back_control = back_control;
    into.resync = clockAt(engine, phypll_resync[into.phy]).*;
    for (kept, &into.kept) |offset, *value| value.* = linkAt(engine, front, offset).*;
    return err.RTGERR_OK;
}

/// The back end that takes front end `front`: null for none.
fn backOf(engine: dcn.Engine, front: u32) ?u32 {
    var back: u32 = 0;
    while (back < phypll_resync.len) : (back += 1) {
        if ((linkAt(engine, back, dig_back).* >> back_fronts_shift) & (@as(u32, 1) << @intCast(front)) != 0) return back;
    }
    return null;
}

/// A pixel clock in 100 Hz times the deep colour's factor.
pub fn scaled(pixel_100hz: u32, deep_color: u32) u32 {
    return @intCast(@as(u64, pixel_100hz) * deep_color_bits[deep_color & 3] / 24);
}

/// The revision of the video BIOS's transmitter table, as its header
/// says: 0 where the BIOS lists none or is not had.
fn transmitterRevision(engine: dcn.Engine) u32 {
    var found: amdgpu.GPUBios = .{};
    if (!engine.gpu.GetGPUBios(&found)) return 0;
    return tableRevision(found.image.?[0..found.bytes], transmitter_table_index);
}

/// The revision of command table `index` in the video BIOS `image`: its
/// header's fourth byte, 0 where the list names none.
pub fn tableRevision(image: []const u8, index: u32) u32 {
    const header = half(image, atom_header_at) orelse return 0;
    const list = half(image, @as(usize, header) + atom_commands_at) orelse return 0;
    const table = half(image, @as(usize, list) + 4 + index * 2) orelse return 0;
    if (table == 0 or @as(usize, table) + 4 > image.len) return 0;
    return image[@as(usize, table) + 3];
}

fn half(image: []const u8, offset: usize) ?u16 {
    if (offset + 2 > image.len) return null;
    return @as(u16, image[offset]) | @as(u16, image[offset + 1]) << 8;
}

/// The pipe's registers RtgAmdPipe holds into `into`.
pub fn read(engine: dcn.Engine, stream: *const Stream, into: *[tags.RTG_AMD_PIPE_REGISTERS]u32) void {
    into.* = .{
        pipeAt(engine, stream.pipe, otg_control).*,
        pipeAt(engine, stream.pipe, otg_clock_control).*,
        linkAt(engine, stream.front, dig_front).*,
        linkAt(engine, stream.front, dig_fifo).*,
        linkAt(engine, stream.back, dig_back).*,
        linkAt(engine, stream.back, dig_back_enable).*,
        linkAt(engine, stream.front, hdmi_control).*,
        linkAt(engine, stream.front, hdmi_gc).*,
    };
}

// --- the BIOS's tables ---------------------------------------------------------------

/// The transmitter's table's parameters: the PHY, the action, the link's
/// kind, the lanes, the symbol clock in 10 kHz, the hot-plug line, the
/// front end (always the first: the back end is told which), the
/// connector's object - named when switching off - and the HPO encoder.
pub fn transmitterParameters(stream: *const Stream, on: bool) [dmub.table_bytes_most]u8 {
    var parameters: [dmub.table_bytes_most]u8 = @splat(0);
    parameters[0] = @intCast(stream.phy);
    parameters[1] = if (on) transmitter_on else transmitter_off;
    parameters[2] = if (stream.hdmi) table_mode_hdmi else table_mode_dvi;
    parameters[3] = if (on) lanes else 0;
    putWord(&parameters, 4, if (on) stream.symbol_khz / 10 else 0);
    parameters[8] = stream.hpd_select;
    parameters[10] = if (on) 0 else stream.connector_object;
    if (stream.transmitter_revision != transmitter_revision_short) parameters[11] = no_hpo;
    return parameters;
}

/// The pixel clock's table's parameters: the PLL's clock in 100 Hz, the
/// PLL, the encoder's object, the link's kind, whether it is forced, the
/// pipe and the deep colour - or the PLL powered down.
pub fn pixelClockParameters(stream: *const Stream, on: bool) [16]u8 {
    var parameters: [16]u8 = @splat(0);
    parameters[4] = first_phy_pll + @as(u8, @intCast(stream.phy));
    if (!on) {
        parameters[6] = table_mode_none;
        parameters[7] = pll_force;
        parameters[8] = no_pipe;
        return parameters;
    }
    putWord(&parameters, 0, stream.pll_100hz);
    parameters[5] = stream.encoder_object;
    parameters[6] = if (stream.hdmi) table_mode_hdmi else table_mode_dvi;
    parameters[8] = @intCast(stream.pipe);
    parameters[9] = if (stream.hdmi) @intCast(stream.deep_color) else 0;
    return parameters;
}

/// The encoder's table's parameters for setting a stream up: the front
/// end, the action, the link's kind, the lanes and the symbol clock in
/// 10 kHz; the bits a colour left to the front end's own.
pub fn encoderParameters(stream: *const Stream) [12]u8 {
    var parameters: [12]u8 = @splat(0);
    parameters[0] = @intCast(stream.front);
    parameters[1] = encoder_stream_setup;
    parameters[2] = if (stream.hdmi) table_mode_hdmi else table_mode_dvi;
    parameters[3] = lanes;
    putWord(&parameters, 4, stream.symbol_khz / 10);
    return parameters;
}

fn putWord(bytes: []u8, offset: usize, word: u32) void {
    for (0..4) |index| bytes[offset + index] = @truncate(word >> @intCast(index * 8));
}

// --- down and up ---------------------------------------------------------------------

/// The pipe taken down, as the file's header says, `stage` moved on as
/// it goes: RTGERR_OK, RTGERR_TIMEOUT where the timing generator did not
/// stop or the controller did not take a table.
pub fn down(engine: dcn.Engine, controller: *dmub.Controller, stream: *const Stream, stage: *u32) i32 {
    if (stream.hdmi) {
        linkAt(engine, stream.front, hdmi_gc).* = stream.kept[kept.len - 1] | gc_avmute;
        dcn.pause(engine.sys, 3 * stream.frame_us);
    }
    stage.* = tags.RTG_AMD_PIPE_MUTED;

    const control = pipeAt(engine, stream.pipe, otg_control);
    control.* &= ~otg_master_enable;
    at(engine, vtg_control + stream.pipe).* &= ~vtg_enable;
    if (!until(engine, pipeAt(engine, stream.pipe, otg_clock_control), otg_busy, 0, stop_wait_us)) return err.RTGERR_TIMEOUT;
    pipeAt(engine, stream.pipe, otg_clock_control).* &= ~(otg_clock_enable | otg_clock_gate_off);
    outputAt(engine, stream.pipe, optc_input_clock).* &= ~(input_clock_enable | input_clock_gate_off);
    stage.* = tags.RTG_AMD_PIPE_STOPPED;

    linkAt(engine, stream.front, dig_fifo).* &= ~fifo_enable;
    linkAt(engine, stream.back, dig_back).* &= ~(@as(u32, 1) << @intCast(back_fronts_shift + stream.front));
    stage.* = tags.RTG_AMD_PIPE_RELEASED;

    if (linkAt(engine, stream.back, dig_back_enable).* & back_enable != 0) {
        const parameters = transmitterParameters(stream, false);
        if (!dmub.runTable(engine, controller, dmub.table_transmitter, &parameters)) return err.RTGERR_TIMEOUT;
    }
    stage.* = tags.RTG_AMD_PIPE_PHY_OFF;

    const clock = pixelClockParameters(stream, false);
    if (!dmub.runTable(engine, controller, dmub.table_pixel_clock, &clock)) return err.RTGERR_TIMEOUT;
    stage.* = tags.RTG_AMD_PIPE_DOWN;
    return err.RTGERR_OK;
}

/// The pipe brought up again, as the file's header says, `stage` moved
/// on as it goes: RTGERR_OK, RTGERR_TIMEOUT where a clock did not come or
/// the controller did not take a table.
pub fn up(engine: dcn.Engine, controller: *dmub.Controller, stream: *const Stream, stage: *u32) i32 {
    const input = outputAt(engine, stream.pipe, optc_input_clock);
    input.* |= input_clock_enable | input_clock_gate_off;
    if (!until(engine, input, input_clock_on, input_clock_on, clock_wait_us)) return err.RTGERR_TIMEOUT;
    const clocks = pipeAt(engine, stream.pipe, otg_clock_control);
    clocks.* |= otg_clock_enable | otg_clock_gate_off;
    if (!until(engine, clocks, otg_clock_on, otg_clock_on, clock_wait_us)) return err.RTGERR_TIMEOUT;
    const clock = pixelClockParameters(stream, true);
    if (!dmub.runTable(engine, controller, dmub.table_pixel_clock, &clock)) return err.RTGERR_TIMEOUT;
    const resync = clockAt(engine, phypll_resync[stream.phy]);
    resync.* = (resync.* & ~resync_deep_color) | (stream.resync & resync_deep_color);
    stage.* = tags.RTG_AMD_PIPE_CLOCKED;

    at(engine, vtg_control + stream.pipe).* |= vtg_enable;
    pipeAt(engine, stream.pipe, otg_control).* |= otg_master_enable;
    dcn.pause(engine.sys, stream.frame_us);
    stage.* = tags.RTG_AMD_PIPE_STARTED;

    tellMode(engine, stream);
    const setup = encoderParameters(stream);
    if (!dmub.runTable(engine, controller, dmub.table_encoder, &setup)) return err.RTGERR_TIMEOUT;
    const front = linkAt(engine, stream.front, dig_front);
    front.* = (front.* & ~front_packing) | (stream.front_control & front_packing);
    // The mute stays on until the PHY carries the stream again.
    for (kept, stream.kept, 0..) |offset, value, index| {
        const mute = if (index == kept.len - 1 and stream.hdmi) gc_avmute else 0;
        linkAt(engine, stream.front, offset).* = value | mute;
    }
    stage.* = tags.RTG_AMD_PIPE_STREAM;

    linkAt(engine, stream.back, dig_back).* |= @as(u32, 1) << @intCast(back_fronts_shift + stream.front);
    startFifo(engine, stream);
    const parameters = transmitterParameters(stream, true);
    if (!dmub.runTable(engine, controller, dmub.table_transmitter, &parameters)) return err.RTGERR_TIMEOUT;
    stage.* = tags.RTG_AMD_PIPE_PHY_ON;

    tellMode(engine, stream);
    startFifo(engine, stream);
    const divider = clockAt(engine, dentist);
    const now = divider.*;
    divider.* = (now & ~dentist_write_mask) | ((now >> dentist_read_shift) & dentist_write_mask);
    linkAt(engine, stream.front, hdmi_gc).* = stream.kept[kept.len - 1];
    dcn.pause(engine.sys, 3 * stream.frame_us);
    stage.* = tags.RTG_AMD_PIPE_UP;
    return err.RTGERR_OK;
}

/// The back end told the link's kind it was found with.
fn tellMode(engine: dcn.Engine, stream: *const Stream) void {
    const back = linkAt(engine, stream.back, dig_back);
    back.* = (back.* & ~back_mode_mask) | (stream.back_control & back_mode_mask);
}

/// The front end's FIFO reset and started, from where it was found to
/// start reading. Its reset is said done only while the symbol clock
/// reaches the front end; without it, a while is let pass instead.
fn startFifo(engine: dcn.Engine, stream: *const Stream) void {
    const fifo = linkAt(engine, stream.front, dig_fifo);
    const clocked = linkAt(engine, stream.front, dig_front).* & front_symclk_on != 0;
    fifo.* = (stream.fifo & ~(fifo_enable | fifo_reset)) | fifo_reset;
    if (clocked) _ = until(engine, fifo, fifo_reset_done, fifo_reset_done, fifo_wait_us) else dcn.pause(engine.sys, 10);
    fifo.* &= ~fifo_reset;
    if (clocked) _ = until(engine, fifo, fifo_reset_done, 0, fifo_wait_us) else dcn.pause(engine.sys, 10);
    fifo.* |= fifo_enable;
}

/// RTGCTRL_AMD_PIPE: the stream taken, the pipe down and up again,
/// `into` filled in. The controller runs.
pub fn cycle(engine: dcn.Engine, controller: *dmub.Controller, on: monitor.Connector, pixel_clock_hz: u32, into: *tags.RtgAmdPipe) i32 {
    into.* = .{};
    if (!controller.running) return err.RTGERR_NOT_SUPPORTED;
    var stream: Stream = .{};
    const taken = take(engine, on, pixel_clock_hz, &stream);
    into.pipe = engine.pipe;
    if (taken != err.RTGERR_OK) return taken;
    into.front = stream.front;
    into.back = stream.back;
    into.phy = stream.phy;
    into.link = if (stream.hdmi) tags.RTG_AMD_LINK_HDMI else tags.RTG_AMD_LINK_DVI;
    into.deep_color = stream.deep_color;
    into.pixel_khz = stream.pixel_100hz / 10;
    into.symbol_khz = stream.symbol_khz;
    into.transmitter_revision = stream.transmitter_revision;
    read(engine, &stream, &into.before);
    into.stage = tags.RTG_AMD_PIPE_TAKEN;

    const started = engine.sys.UptimeUs();
    const went_down = down(engine, controller, &stream, &into.stage);
    read(engine, &stream, &into.down);
    if (went_down != err.RTGERR_OK) return went_down;
    const came_up = up(engine, controller, &stream, &into.stage);
    into.down_us = @intCast(@min(engine.sys.UptimeUs() - started, 0xffff_ffff));
    read(engine, &stream, &into.after);
    return came_up;
}

test "the pixel clock grows with the deep colour" {
    const testing = @import("std").testing;
    // The box's monitor's 241.5 MHz, and HDMI's 10, 12 and 16 bits.
    try testing.expectEqual(@as(u32, 2_415_000), scaled(2_415_000, 0));
    try testing.expectEqual(@as(u32, 3_018_750), scaled(2_415_000, 1));
    try testing.expectEqual(@as(u32, 3_622_500), scaled(2_415_000, 2));
    try testing.expectEqual(@as(u32, 4_830_000), scaled(2_415_000, 3));
}

test "the tables' parameters" {
    const testing = @import("std").testing;
    // HDMI on PHY B from front end 1, pipe 0, hot-plug line 2, its
    // connector HDMI's (0x0C) and its encoder the first UNIPHY's (0x1E).
    const stream: Stream = .{
        .pipe = 0,
        .front = 1,
        .back = 1,
        .phy = 1,
        .hdmi = true,
        .pixel_100hz = 2_415_000,
        .pll_100hz = 2_415_000,
        .symbol_khz = 241_500,
        .hpd_select = 2,
        .connector_object = 0x0c,
        .encoder_object = 0x1e,
        .transmitter_revision = 7,
    };
    const on = transmitterParameters(&stream, true);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 3, 4, 0x56, 0x5e, 0, 0, 2, 0, 0, 0xf6 }, on[0..12]);
    for (on[12..]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    const off = transmitterParameters(&stream, false);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 3, 0, 0, 0, 0, 0, 2, 0, 0x0c, 0xf6 }, off[0..12]);
    var short = stream;
    short.transmitter_revision = 6;
    try testing.expectEqual(@as(u8, 0), transmitterParameters(&short, true)[11]);

    try testing.expectEqualSlices(u8, &.{ 0x98, 0xd9, 0x24, 0x00, 21, 0x1e, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &pixelClockParameters(&stream, true));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 21, 0, 15, 1, 0xff, 0, 0, 0, 0, 0, 0, 0 }, &pixelClockParameters(&stream, false));
    try testing.expectEqualSlices(u8, &.{ 1, 0x0f, 3, 4, 0x56, 0x5e, 0, 0, 0, 0, 0, 0 }, &encoderParameters(&stream));
}

test "a command table's revision is read from the BIOS's list" {
    const testing = @import("std").testing;
    var image: [0x400]u8 = @splat(0);
    // The tables' header at 0x100, the list at 0x200, the transmitter's
    // table at 0x300, revision 1.7.
    image[atom_header_at] = 0x00;
    image[atom_header_at + 1] = 0x01;
    image[0x100 + atom_commands_at] = 0x00;
    image[0x100 + atom_commands_at + 1] = 0x02;
    const entry = 0x200 + 4 + transmitter_table_index * 2;
    image[entry] = 0x00;
    image[entry + 1] = 0x03;
    image[0x302] = 1;
    image[0x303] = 7;
    try testing.expectEqual(@as(u32, 7), tableRevision(&image, transmitter_table_index));
    // A table the list names none of, and a list past the image's end.
    try testing.expectEqual(@as(u32, 0), tableRevision(&image, 12));
    image[0x100 + atom_commands_at + 1] = 0x05;
    try testing.expectEqual(@as(u32, 0), tableRevision(&image, transmitter_table_index));
}
