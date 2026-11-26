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
//!
//! **Asleep** (`sleep`, `wake`), the pipe goes down and comes up the same
//! way in its mode: on these chips the timing generator takes its pixel
//! clock from the PHY's PLL, so it would stop with the PHY whatever is
//! kept, and the PLL is set again on waking.
//!
//! **A mode set** (`set`) goes down and up the same way with a new mode
//! (`mode.zig`) in between: the fetcher is blanked once the timing
//! generator has stopped and let go of again once it runs; the mode is
//! written as the clocks come on, before the timing generator starts;
//! the PLL is set for the new pixel clock, the back end and the encoder's
//! table told the link's kind the monitor takes - HDMI where its EDID
//! says so, DVI otherwise - with 8 bits a colour. On HDMI the front end
//! is set up as an HDMI stream is - its packets' generator, the general
//! control and null packets, the audio infoframe - and sends the mode's
//! AVI infoframe from its first packet generator; the packets' contents
//! go in before the PHY carries them. Whether the fetcher or the output
//! ran short of pixels is read once the pipe has run three frames more.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const tags = sdk.rtg.tags;
const err = sdk.rtg.errors;
const dcn = @import("dcn.zig");
const dmub = @import("dmub.zig");
const monitor = @import("monitor.zig");
const sound = @import("sound.zig");
const mode = @import("mode.zig");

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
/// The HDMI packets' controls a mode set changes: which packets are sent
/// each frame, the infoframes', the audio infoframe's line, the generic
/// packets' and the first generic packet's line.
const hdmi_vbi = 0x2098;
const hdmi_infoframe = 0x2099;
const hdmi_infoframe_line = 0x209a;
const hdmi_generic = 0x209b;
const hdmi_generic_line = 0x209f;
const dig_back = 0x20b1;
const dig_back_enable = 0x20b2;
const link_stride = 0x100;
/// The front end's double buffering of the HDMI packets' controls, and
/// its audio's clock.
const hdmi_double_buffer = 0x20a7;
const afmt_control = 0x20b0;
/// The front end's packet generator: which of its packets the data
/// register reaches and the data, the packets taken up at once, its
/// status and the power of its memory.
const vpg_access = 0x2068;
const vpg_data = 0x2069;
const vpg_immediate = 0x206b;
const vpg_status = 0x206c;
const vpg_memory_power = 0x206d;
/// Where an output's input reports running short of pixels.
const optc_input_global = 0x1aca;

/// What of the front end is put back after the encoder's table: the
/// HDMI control, the packets' controls and the general control packet,
/// whole.
const kept = [_]u32{ hdmi_control, hdmi_vbi, hdmi_infoframe, hdmi_infoframe_line, hdmi_generic, 0x209c, 0x209d, hdmi_generic_line, 0x20a0, 0x20a1, 0x20a2, 0x20a3, 0x20a4, 0x20a5, 0x20a6, hdmi_gc };

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

/// An HDMI stream's setup: in the HDMI control, the packets' generator,
/// keep-outs, no extra null packets, no deep colour, no scrambling, the
/// clock channel at the character rate; the null and general control
/// packets sent every frame, no audio content protection; the audio
/// infoframe sent, on line 2; the first generic packet - the AVI
/// infoframe - sent every frame, on line 2.
const hdmi_setup_mask: u32 = 0x3100_001F;
const hdmi_setup: u32 = 0x0000_0019;
const vbi_sent: u32 = 0x31;
const vbi_acp: u32 = 1 << 12;
const audio_info_send: u32 = 1 << 4;
const audio_info_line_mask: u32 = 0x3f << 8;
const generic0_sent: u32 = 0x3;
const generic0_line_mask: u32 = 0xffff;
const packet_line: u32 = 2;
const double_buffer_off: u32 = 1 << 12;
const audio_clock_on: u32 = 1 << 0;
/// The packet generator's: its conflict seen and cleared, the first
/// packet taken up at once, its memory kept awake and not put to sleep.
const vpg_conflict: u32 = 1 << 1;
const vpg_conflict_clear: u32 = 1 << 4;
const vpg_first_now: u32 = 1 << 0;
const vpg_awake: u32 = 1 << 0;
const vpg_asleep: u32 = 1 << 4;
/// An output's input having run short, and its note cleared.
const optc_underflow: u32 = 1 << 10;
const optc_underflow_clear: u32 = 1 << 12;

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
const idle_wait_us: u64 = 100_000;
const vpg_wait_us: u64 = 500;

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
    /// A mode set's: the fetcher, and the AVI infoframe sent on HDMI.
    fetcher: u32 = 0,
    avi: ?[sdk.rtg.RTG_AVI_BYTES]u8 = null,
};

/// Where register `offset` is among those kept.
fn keptAt(comptime offset: u32) usize {
    return comptime found: {
        for (kept, 0..) |one, index| {
            if (one == offset) break :found index;
        }
        @compileError("not a kept register");
    };
}

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
    const kind = (back_control & back_mode_mask) >> back_mode_shift;
    if (kind != mode_hdmi and kind != mode_dvi) return err.RTGERR_NOT_SUPPORTED;

    into.pipe = pipe;
    into.front = front;
    into.back = back;
    into.phy = listed.phy;
    into.hdmi = kind == mode_hdmi;
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

/// Whether the lit link's back end is set up as HDMI.
pub fn litAsHdmi(engine: dcn.Engine) bool {
    const front = sound.litLink(engine) orelse return false;
    const back = backOf(engine, front) orelse return false;
    return (linkAt(engine, back, dig_back).* & back_mode_mask) >> back_mode_shift == mode_hdmi;
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
/// it goes - for a mode set (`setting`) the fetcher blanked once the
/// timing generator has stopped: RTGERR_OK, RTGERR_TIMEOUT where the
/// timing generator did not stop or the controller did not take a table.
pub fn down(engine: dcn.Engine, controller: *dmub.Controller, stream: *const Stream, setting: bool, stage: *u32) i32 {
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
    if (setting) mode.blankFetcher(engine, stream.fetcher, true, idle_wait_us);
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
/// on as it goes - for a mode set the mode written as the clocks come on
/// and the fetcher let go of once the timing generator runs:
/// RTGERR_OK, RTGERR_TIMEOUT where a clock did not come or the controller
/// did not take a table.
pub fn up(engine: dcn.Engine, controller: *dmub.Controller, stream: *const Stream, setting: ?*const mode.Mode, stage: *u32) i32 {
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
    if (setting) |new| {
        mode.writeTiming(engine, stream.pipe, new);
        mode.writePlane(engine, stream.fetcher, mode.outputOf(engine, stream.pipe), new);
    }
    stage.* = tags.RTG_AMD_PIPE_CLOCKED;

    at(engine, vtg_control + stream.pipe).* |= vtg_enable;
    pipeAt(engine, stream.pipe, otg_control).* |= otg_master_enable;
    dcn.pause(engine.sys, stream.frame_us);
    if (setting != null) mode.blankFetcher(engine, stream.fetcher, false, 0);
    stage.* = tags.RTG_AMD_PIPE_STARTED;

    tellMode(engine, stream);
    const setup = encoderParameters(stream);
    if (!dmub.runTable(engine, controller, dmub.table_encoder, &setup)) return err.RTGERR_TIMEOUT;
    const front = linkAt(engine, stream.front, dig_front);
    front.* = (front.* & ~front_packing) | (stream.front_control & front_packing);
    if (stream.avi) |*frame| {
        linkAt(engine, stream.front, hdmi_double_buffer).* |= double_buffer_off;
        linkAt(engine, stream.front, afmt_control).* |= audio_clock_on;
        writePacket(engine, stream.front, frame);
    }
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

/// The packet `frame` - an infoframe as rtg.library builds one - into
/// the front end's packet generator as its first packet, taken up at
/// once (vpg3_update_generic_info_packet): a conflict with the hardware
/// reading the packets waited out a while and cleared, its header's
/// three bytes and a fourth of 0, then its checksum and bytes from the
/// first data word on, eight words in all. Its memory is kept awake
/// first.
fn writePacket(engine: dcn.Engine, front: u32, frame: *const [sdk.rtg.RTG_AVI_BYTES]u8) void {
    const power = linkAt(engine, front, vpg_memory_power);
    power.* = (power.* & ~vpg_asleep) | vpg_awake;
    _ = until(engine, linkAt(engine, front, vpg_status), vpg_conflict, 0, vpg_wait_us);
    linkAt(engine, front, vpg_status).* |= vpg_conflict_clear;
    linkAt(engine, front, vpg_access).* = 0;
    const words = packetWords(frame);
    const data = linkAt(engine, front, vpg_data);
    for (words) |word| data.* = word;
    linkAt(engine, front, vpg_immediate).* |= vpg_first_now;
}

/// The AVI infoframe `frame` sent on the running link of front end
/// `front` from the next frame on, as a stream's infoframes are updated
/// (enc3_stream_encoder_update_hdmi_info_packets): the HDMI packets'
/// controls taken at once, the audio's clock on for the packet
/// generator, the frame written as its first packet, and that packet
/// sent every frame on line 2.
pub fn sendAvi(engine: dcn.Engine, front: u32, frame: *const [sdk.rtg.RTG_AVI_BYTES]u8) void {
    linkAt(engine, front, hdmi_double_buffer).* |= double_buffer_off;
    linkAt(engine, front, afmt_control).* |= audio_clock_on;
    writePacket(engine, front, frame);
    linkAt(engine, front, hdmi_generic).* |= generic0_sent;
    const line = linkAt(engine, front, hdmi_generic_line);
    line.* = (line.* & ~generic0_line_mask) | packet_line;
}

/// An infoframe as the packet generator's data register takes it: the
/// header's three bytes and a 0, then the checksum and the bytes, the
/// rest 0.
pub fn packetWords(frame: *const [sdk.rtg.RTG_AVI_BYTES]u8) [9]u32 {
    var body: [32]u8 = @splat(0);
    @memcpy(body[0 .. frame.len - 3], frame[3..]);
    var words: [9]u32 = undefined;
    words[0] = @as(u32, frame[0]) | @as(u32, frame[1]) << 8 | @as(u32, frame[2]) << 16;
    for (words[1..], 0..) |*word, index| {
        const at_byte = index * 4;
        word.* = @as(u32, body[at_byte]) | @as(u32, body[at_byte + 1]) << 8 | @as(u32, body[at_byte + 2]) << 16 | @as(u32, body[at_byte + 3]) << 24;
    }
    return words;
}

/// The stream read before the pipe went down turned to the new mode's:
/// its pixel clock and the PLL's - 8 bits a colour, no deep colour - the
/// PHY's symbol clock and a frame's time; the link's kind, HDMI or DVI,
/// for the back end and the tables; on HDMI the front end's controls set
/// up as an HDMI stream's (the file's header) and the AVI infoframe
/// `avi` to send, on DVI the first generic packet no longer sent.
/// RTGERR_OK, RTGERR_NOT_SUPPORTED for a pixel clock the link is not
/// taken at.
pub fn retarget(stream: *Stream, new: *const mode.Mode, hdmi: bool, avi: ?*const [sdk.rtg.RTG_AVI_BYTES]u8) i32 {
    stream.hdmi = hdmi;
    stream.deep_color = 0;
    stream.pixel_100hz = new.pixel_hz / 100;
    stream.pll_100hz = stream.pixel_100hz;
    stream.symbol_khz = stream.pll_100hz / 10;
    stream.frame_us = mode.frameUs(new);
    if (stream.symbol_khz > fastest_tmds_khz) return err.RTGERR_NOT_SUPPORTED;
    if (!hdmi and stream.symbol_khz > fastest_dvi_khz) return err.RTGERR_NOT_SUPPORTED;
    stream.back_control = (stream.back_control & ~back_mode_mask) | ((if (hdmi) mode_hdmi else mode_dvi) << back_mode_shift);
    stream.resync &= ~resync_deep_color;
    const kept_values = &stream.kept;
    const generics = &kept_values[keptAt(hdmi_generic)];
    if (!hdmi) {
        generics.* &= ~generic0_sent;
        stream.avi = null;
        return err.RTGERR_OK;
    }
    const control = &kept_values[keptAt(hdmi_control)];
    control.* = (control.* & ~hdmi_setup_mask) | hdmi_setup;
    const vbi = &kept_values[keptAt(hdmi_vbi)];
    vbi.* = (vbi.* | vbi_sent) & ~vbi_acp;
    kept_values[keptAt(hdmi_infoframe)] |= audio_info_send;
    const audio_line = &kept_values[keptAt(hdmi_infoframe_line)];
    audio_line.* = (audio_line.* & ~audio_info_line_mask) | (packet_line << 8);
    stream.avi = if (avi) |frame| frame.* else null;
    if (stream.avi == null) {
        generics.* &= ~generic0_sent;
        return err.RTGERR_OK;
    }
    generics.* |= generic0_sent;
    const generic_line = &kept_values[keptAt(hdmi_generic_line)];
    generic_line.* = (generic_line.* & ~generic0_line_mask) | packet_line;
    return err.RTGERR_OK;
}

/// A mode set: the stream taken - with the pixel clock the board's mode
/// had, `old_pixel_hz`, or the new one's where that is not known - the
/// pipe down, the stream turned to the new mode (`retarget`), the pipe
/// up in it, and three frames later whether the fetcher or the output ran
/// short; `into` filled in as RTGCTRL_AMD_PIPE fills it, with the mode's
/// picture and that. The controller runs.
pub fn set(engine: dcn.Engine, controller: *dmub.Controller, on: monitor.Connector, new: *const mode.Mode, hdmi: bool, avi: ?*const [sdk.rtg.RTG_AVI_BYTES]u8, old_pixel_hz: u32, into: *tags.RtgAmdPipe) i32 {
    into.* = .{};
    if (!controller.running) return err.RTGERR_NOT_SUPPORTED;
    var stream: Stream = .{};
    const taken = take(engine, on, if (old_pixel_hz != 0) old_pixel_hz else new.pixel_hz, &stream);
    into.pipe = engine.pipe;
    into.width = new.width;
    into.height = new.height;
    if (taken != err.RTGERR_OK) return taken;
    stream.fetcher = engine.fetcher;
    var target = stream;
    const turned = retarget(&target, new, hdmi, avi);
    if (turned != err.RTGERR_OK) return turned;
    into.front = stream.front;
    into.back = stream.back;
    into.phy = stream.phy;
    into.link = if (hdmi) tags.RTG_AMD_LINK_HDMI else tags.RTG_AMD_LINK_DVI;
    into.pixel_khz = target.pixel_100hz / 10;
    into.symbol_khz = target.symbol_khz;
    into.transmitter_revision = stream.transmitter_revision;
    read(engine, &stream, &into.before);
    into.stage = tags.RTG_AMD_PIPE_TAKEN;

    const started = engine.sys.UptimeUs();
    const went_down = down(engine, controller, &stream, true, &into.stage);
    read(engine, &stream, &into.down);
    if (went_down != err.RTGERR_OK) return went_down;
    const came_up = up(engine, controller, &target, new, &into.stage);
    into.down_us = @intCast(@min(engine.sys.UptimeUs() - started, 0xffff_ffff));
    read(engine, &target, &into.after);
    if (came_up != err.RTGERR_OK) return came_up;

    mode.clearUnderflow(engine, target.fetcher);
    const input = outputAt(engine, target.pipe, optc_input_global);
    input.* |= optc_underflow_clear;
    input.* &= ~optc_underflow_clear;
    dcn.pause(engine.sys, 3 * target.frame_us);
    if (mode.fetcherControl(engine, target.fetcher) & mode.hubp_underflow != 0) into.underflow |= tags.RTG_AMD_UNDERFLOW_FETCHER;
    if (input.* & optc_underflow != 0) into.underflow |= tags.RTG_AMD_UNDERFLOW_OUTPUT;
    return err.RTGERR_OK;
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
    const went_down = down(engine, controller, &stream, false, &into.stage);
    read(engine, &stream, &into.down);
    if (went_down != err.RTGERR_OK) return went_down;
    const came_up = up(engine, controller, &stream, null, &into.stage);
    into.down_us = @intCast(@min(engine.sys.UptimeUs() - started, 0xffff_ffff));
    read(engine, &stream, &into.after);
    return came_up;
}

/// The monitor sent nothing, which it sleeps at: the stream taken into
/// `into` - all `wake` needs - at the pixel clock of the board's mode,
/// and the pipe taken down (`down`): an HDMI monitor muted, the timing
/// generator stopped, the link let go of, the PHY off and its PLL powered
/// down. RTGERR_OK; why the stream is not one this takes, with nothing
/// done; RTGERR_TIMEOUT where a step did not finish, `stage` saying how
/// far it got. The controller runs.
pub fn sleep(engine: dcn.Engine, controller: *dmub.Controller, on: monitor.Connector, pixel_clock_hz: u32, into: *Stream, stage: *u32) i32 {
    stage.* = tags.RTG_AMD_PIPE_NONE;
    if (!controller.running) return err.RTGERR_NOT_SUPPORTED;
    const taken = take(engine, on, pixel_clock_hz, into);
    if (taken != err.RTGERR_OK) return taken;
    stage.* = tags.RTG_AMD_PIPE_TAKEN;
    return down(engine, controller, into, false, stage);
}

/// The monitor sent the stream `stream` again, the one `sleep` took: the
/// pipe brought up in its mode (`up`). RTGERR_OK, RTGERR_TIMEOUT where a
/// step did not finish.
pub fn wake(engine: dcn.Engine, controller: *dmub.Controller, stream: *const Stream, stage: *u32) i32 {
    stage.* = tags.RTG_AMD_PIPE_DOWN;
    if (!controller.running) return err.RTGERR_NOT_SUPPORTED;
    return up(engine, controller, stream, null, stage);
}

/// Whether the stream's PHY is on: its back end enabled.
pub fn phyOn(engine: dcn.Engine, stream: *const Stream) bool {
    return linkAt(engine, stream.back, dig_back_enable).* & back_enable != 0;
}

test "an infoframe's words: its header, then its checksum and body" {
    const testing = @import("std").testing;
    // 1920x1080 at 60 (VIC 16), RGB, full range.
    var frame: [sdk.rtg.RTG_AVI_BYTES]u8 = @splat(0);
    frame[0] = 0x82;
    frame[1] = 2;
    frame[2] = 13;
    frame[3] = 0x37;
    frame[4] = 0x10;
    frame[5] = 0x28;
    frame[6] = 0x08;
    frame[7] = 16;
    const words = packetWords(&frame);
    try testing.expectEqual(@as(u32, 0x000D0282), words[0]);
    try testing.expectEqual(@as(u32, 0x08281037), words[1]);
    try testing.expectEqual(@as(u32, 16), words[2]);
    for (words[3..]) |word| try testing.expectEqual(@as(u32, 0), word);
}

test "a stream turned to HDMI sends its infoframe each frame, one to DVI none" {
    const testing = @import("std").testing;
    const own: sdk.rtg.RtgTimings = .{
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
    const new = mode.of(own, 2560, 1440, .{ .display_khz = 1_200_000, .pipes_khz = 1_200_000, .pitch = 2560, .watermark = 0 }) orelse return error.TestUnexpectedResult;
    var frame: [sdk.rtg.RTG_AVI_BYTES]u8 = @splat(0);
    frame[0] = 0x82;
    var stream: Stream = .{ .deep_color = 2, .back_control = 0x10030200, .resync = resync_deep_color };
    stream.kept[keptAt(hdmi_generic)] = 0x88888888;
    try testing.expectEqual(err.RTGERR_OK, retarget(&stream, &new, true, &frame));
    try testing.expectEqual(@as(u32, 2_415_000), stream.pixel_100hz);
    try testing.expectEqual(@as(u32, 241_500), stream.symbol_khz);
    try testing.expectEqual(@as(u32, 0), stream.deep_color);
    try testing.expectEqual(@as(u32, 0), stream.resync & resync_deep_color);
    try testing.expectEqual(mode_hdmi, (stream.back_control & back_mode_mask) >> back_mode_shift);
    try testing.expectEqual(hdmi_setup, stream.kept[keptAt(hdmi_control)] & hdmi_setup_mask);
    try testing.expectEqual(vbi_sent, stream.kept[keptAt(hdmi_vbi)] & (vbi_sent | vbi_acp));
    try testing.expectEqual(@as(u32, 0x8888888B), stream.kept[keptAt(hdmi_generic)]);
    try testing.expectEqual(packet_line, stream.kept[keptAt(hdmi_generic_line)] & generic0_line_mask);
    try testing.expect(stream.avi != null);

    try testing.expectEqual(err.RTGERR_NOT_SUPPORTED, retarget(&stream, &new, false, null));
    var slower = own;
    slower.pixel_clock_hz = 148_500_000;
    const dvi = mode.of(slower, 2560, 1440, .{ .display_khz = 1_200_000, .pipes_khz = 1_200_000, .pitch = 2560, .watermark = 0 }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(err.RTGERR_OK, retarget(&stream, &dvi, false, &frame));
    try testing.expectEqual(mode_dvi, (stream.back_control & back_mode_mask) >> back_mode_shift);
    try testing.expectEqual(@as(u32, 0x88888888), stream.kept[keptAt(hdmi_generic)]);
    try testing.expect(stream.avi == null);
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
