// SPDX-License-Identifier: MPL-2.0
//! A mode for the board's pipe: what its timing generator, fetcher,
//! scaler and output are told, worked out from a monitor's timings, and
//! the writes that tell them.
//!
//! **The timing generator** counts a line from the start of its sync
//! pulse and a frame from the start of its vertical one: its totals hold
//! the line's and the frame's length less one, its syncs run from 0 to
//! their width, its blanking ends where sync and back porch end and
//! starts again that end plus the picture. A sync's polarity bit is set
//! for a pulse that goes low. Its vertical counter starts each frame at
//! the line blanking starts on, and the second front porch is what the
//! fetcher's start falls before the frame's first line.
//!
//! **The fetcher** reads a viewport of the picture's size from the top
//! left of the frame, whose rows stay as far apart as the frame's are.
//! When it starts each frame, how far ahead it fetches and how its
//! requests are paced are the schedule (`Schedule`), worked out for what
//! it reads (`Fetch`) - a plane of 32-bit pixels, or a 4:2:0 picture's
//! brightness and colour, scaled or not - in linear memory, without a
//! cursor of its own (`scheduleOf`):
//!
//! - The fetcher starts a nominal blank before the picture: as many lines
//!   as 668 us take, at least the sync, the back porch and two lines, at
//!   most the blank less one. Its double-buffered registers are taken a
//!   quarter line into it, for as long as the slowest of the display's
//!   clocks need to take them; it is ready a while after.
//! - Its prefetch takes a quarter line for the page table, half a line
//!   twice for its rows and the lines of each plane's first rows at the
//!   rate the picture is scanned at - those its taps reach before the
//!   first line's and one more, two unscaled - or fewer lines read
//!   faster where the time left before the picture allows no more: the
//!   time from the fetcher's start, less that to take its registers, to
//!   wait for the memory and to work out the request, and the pipe's own
//!   delay, longer where its scaler scales. A 4:2:0 picture's pixel
//!   counts as a byte and a half there, its colour having a pair of
//!   samples for each four pixels. The earliest start from the ninth
//!   line before the picture on that leaves the prefetch two lines, and
//!   its rows no more than four times as fast as they are scanned, is
//!   the one it is worked out for; a mode with no such start is refused.
//!   The wait for the memory is the one the prefetch mode allows for the
//!   board's memory (`Held.wait_ns`, `bandwidth.waitOf`), the time to work
//!   out a request 24 cycles of the controller's clock in deep sleep
//!   (`Held.deep_sleep_hz`).
//! - Its pace - the reference cycles a line, a request and the blank's
//!   end take, for each plane - is counted in the hub's reference, the
//!   48 MHz crystal halved: a plane whose lines come no faster than the
//!   glass's at the rate its place is scanned, one whose lines come
//!   faster at the rate its scaler takes them across. Its time to urgency
//!   in a blank is the longest of the hub's watermarks, in the sets the
//!   firmware wrote that the hub runs on (`Held.watermark`,
//!   `hubWatermark`), the time to work out a request, and the time from
//!   the start worked out to the one the fetcher has.
//!
//! The fetcher's requests' sizes and its buffer stay as they are, the
//! frames' surface being the same in every mode.
//!
//! **The scaler** passes the picture through at its own size: its
//! output rectangle, its size into the blender and the blanking it is
//! told are the mode's, and it is in its bypass (`passThrough`), as the
//! vendor's driver puts a scaler that scales neither way. The firmware
//! leaves it scaling by 1 with its filters' first phase at 0, which lays
//! the picture a pixel or two right of and below where it belongs.
//! **The output's** pattern generator is told the picture's size.
//!
//! What a mode needs that this does not: an interlaced timing, a picture
//! larger than the frames, a line longer than the counters hold, a
//! blank too short for the fetcher's start.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");

// --- the registers, in 32-bit words from the engine's third address ---------------

/// A timing generator's totals, blanking, syncs and their polarities,
/// and its global sync: where in the blank the fetcher starts, and where
/// its double-buffered registers and the fetcher's ready fall. One set
/// per pipe, a stride apart; the vertical timing's own control one word
/// apart per pipe.
const otg_h_total = 0x1b2a;
const otg_h_blank = 0x1b2b;
const otg_h_sync = 0x1b2c;
const otg_h_sync_control = 0x1b2d;
const otg_v_total = 0x1b2f;
const otg_v_blank = 0x1b36;
const otg_v_sync = 0x1b37;
const otg_v_sync_control = 0x1b38;
const otg_vstartup = 0x1b86;
const otg_vupdate = 0x1b87;
const otg_vready = 0x1b88;
const otg_stride = 0x80;
const vtg_control = 0x052d;

/// A fetcher's viewports, its control, its surface's row length, and its
/// schedule's registers.
const hubp_surface_config = 0x05e5;
const hubp_viewport_start = 0x05e9;
const hubp_viewport = 0x05ea;
const hubp_second_viewport_start = 0x05ed;
const hubp_second_viewport = 0x05ee;
const hubp_control = 0x05f3;
const hubp_pitch = 0x0607;
const hubp_qos = 0x062a;
const hubp_global_ttu = 0x062b;
const hubp_surface_ttu = 0x062c;
const hubp_surface_ttu_prefetch = 0x062d;
const hubp_chroma_ttu = 0x062e;
const hubp_chroma_ttu_prefetch = 0x062f;
const hubp_blank_offset = 0x0644;
const hubp_next_start = 0x0645;
const hubp_dst_dimensions = 0x0646;
const hubp_after_scaler = 0x0647;
const hubp_prefetch = 0x0648;
const hubp_prefetch_chroma = 0x0649;
const hubp_vblank = 0x064a;
const hubp_line_delivery_prefetch = 0x065a;
const hubp_line_delivery = 0x065b;
const hubp_reference_to_pixel = 0x065d;
const hubp_stride = 0xdc;

/// The hub's watermarks of its first set - urgency, self-refresh's entry
/// and the memory clock's change - and the stride to the next of its four.
const hub_urgency = 0x04fd;
const hub_self_refresh = 0x04ff;
const hub_memory_clock = 0x0503;
const hub_set_stride = 9;
const hub_sets = 4;

/// A pipe's scaler: the blanking it is told, its output rectangle's
/// start and size, its size into the blender.
const dscl_h_blank = 0x0d0f;
const dscl_v_blank = 0x0d10;
const dscl_recout_start = 0x0d11;
const dscl_recout_size = 0x0d12;
const dscl_mpc_size = 0x0d13;
/// Its mode, in the low three bits: 0 passes the picture through as it
/// is (DSCL_MODE_SCALING_444_BYPASS).
const dscl_mode = 0x0cfb;
const dscl_mode_mask: u32 = 0x7;
const dpp_stride = 0x16b;

/// An output's pattern generator's size, one per output a stride apart;
/// which output a timing generator takes its picture from.
const dpg_dimensions = 0x1856;
const opp_stride = 0x5a;
const optc_source = 0x1acb;
const optc_stride = 0x10;

// --- the fields --------------------------------------------------------------------

const vtg_enable: u32 = 1 << 31;
const vtg_count_init_shift = 16;
const sync_low: u32 = 1 << 0;
const high_shift = 16;
const source_mask: u32 = 0xf << 16;
const source_shift = 16;
/// In the fetcher's control: blank it, and that it has no requests out.
pub const hubp_blank: u32 = 1 << 0;
pub const hubp_idle: u32 = 1 << 1;
pub const hubp_underflow: u32 = 0x7 << 28;
pub const hubp_underflow_clear: u32 = 1 << 31;
/// In the fetcher's control: that it is ready at or after the vertical
/// sync.
const hubp_ready_after_sync: u32 = 1 << 8;
const pitch_mask: u32 = 0x3fff;
const urgency_mask: u32 = 0x3fff;
const self_refresh_mask: u32 = 0xfffff;
const memory_clock_mask: u32 = 0xffff;

/// What the counters hold: a total, a blank's ends and a sync's in 15
/// bits, a picture's side in 14.
const counter_most: u32 = 0x7fff;
const side_most: u32 = 0x3fff;

// --- a mode --------------------------------------------------------------------------

/// A mode's registers, as `of` works them out.
pub const Mode = struct {
    width: u32 = 0,
    height: u32 = 0,
    pixel_hz: u32 = 0,
    /// The timing generator's.
    h_total: u32 = 0,
    h_blank: u32 = 0,
    h_sync: u32 = 0,
    h_sync_control: u32 = 0,
    v_total: u32 = 0,
    v_blank: u32 = 0,
    v_sync: u32 = 0,
    v_sync_control: u32 = 0,
    vtg: u32 = 0,
    /// The picture's size as the fetcher, the scaler and the blender take
    /// it - width low - and as the pattern generator does - height low.
    size: u32 = 0,
    pattern_size: u32 = 0,
    schedule: Schedule = .{},
};

/// When the fetcher starts each frame and how its requests are paced:
/// the timing generator's global sync and the fetcher's own registers.
pub const Schedule = struct {
    vstartup: u32 = 0,
    vupdate: u32 = 0,
    vready: u32 = 0,
    ready_after_sync: bool = false,
    blank_offset: u32 = 0,
    next_start: u32 = 0,
    dst_dimensions: u32 = 0,
    after_scaler: u32 = 0,
    reference_to_pixel: u32 = 0,
    prefetch: u32 = 0,
    /// The colour's prefetch ratio, 1 for a picture of one plane.
    prefetch_chroma: u32 = ratio_one,
    vblank: u32 = 0,
    /// A line's delivery, the brightness's low and the colour's high.
    line_delivery: u32 = 0,
    line_delivery_prefetch: u32 = 0,
    qos: u32 = 0,
    global_ttu: u32 = 0,
    surface_ttu: u32 = 0,
    surface_ttu_prefetch: u32 = 0,
    /// A 4:2:0 picture's: its colour's request delivery.
    two_planes: bool = false,
    chroma_ttu: u32 = 0,
    chroma_ttu_prefetch: u32 = 0,
};

/// What a mode is worked out at besides its timings: the clocks the
/// display runs at, the frames' row length, the longest watermark the
/// blank allows, and the wait for the memory.
pub const Held = struct {
    /// The display clock and the pipe's clock, in kHz.
    display_khz: u32,
    pipes_khz: u32,
    /// The frames' row length, in pixels.
    pitch: u32,
    /// The longest of the watermarks the blank allows - urgency,
    /// self-refresh's entry and exit, the memory clock's change - in the
    /// hub's reference cycles.
    watermark: u32,
    /// The display controller's clock in deep sleep, in Hz.
    deep_sleep_hz: u32,
    /// The wait for the memory the prefetch allows, in nanoseconds.
    wait_ns: u32,
};

/// The longest of the hub's watermarks in any of its sets - urgency,
/// self-refresh's entry, the memory clock's change - in its reference
/// cycles: what a fetcher's time to urgency in a blank starts from while
/// the hub runs on the sets the firmware wrote.
pub fn hubWatermark(engine: dcn.Engine) u32 {
    var watermark: u32 = 0;
    for (0..hub_sets) |set| {
        const base: u32 = @intCast(set * hub_set_stride);
        watermark = @max(watermark, at(engine, hub_urgency + base).* & urgency_mask);
        watermark = @max(watermark, at(engine, hub_self_refresh + base).* & self_refresh_mask);
        watermark = @max(watermark, at(engine, hub_memory_clock + base).* & memory_clock_mask);
    }
    return watermark;
}

/// The row length of the surface `fetcher` reads, in pixels.
pub fn pitchOf(engine: dcn.Engine, fetcher: u32) u32 {
    return (at(engine, fetcher * hubp_stride + hubp_pitch).* & pitch_mask) + 1;
}

/// The parts of a timing the registers are worked out from, in its own
/// units: pixels across, lines down.
const Lengths = struct {
    h_total: u32,
    h_blank_end: u32,
    v_total: u32,
    v_blank_end: u32,
};

fn lengthsOf(timings: rtg.RtgTimings) Lengths {
    return .{
        .h_total = timings.h_active + timings.h_front + timings.h_sync + timings.h_back,
        .h_blank_end = timings.h_sync + timings.h_back,
        .v_total = timings.v_active + timings.v_front + timings.v_sync + timings.v_back,
        .v_blank_end = timings.v_sync + timings.v_back,
    };
}

/// The mode for `timings`, in frames `frame_width` by `frame_height`
/// pixels, at what `held` says: null for one this cannot make.
pub fn of(timings: rtg.RtgTimings, frame_width: u32, frame_height: u32, held: Held) ?Mode {
    if (timings.flags & rtg.modes.RTGTM_INTERLACED != 0) return null;
    if (timings.pixel_clock_hz == 0) return null;
    if (timings.h_active == 0 or timings.v_active == 0) return null;
    if (timings.h_active > frame_width or timings.v_active > frame_height) return null;
    if (timings.h_active > side_most or timings.v_active > side_most) return null;
    if (timings.h_sync == 0 or timings.v_sync == 0 or timings.v_front == 0) return null;
    const lengths = lengthsOf(timings);
    if (lengths.h_total > counter_most + 1 or lengths.v_total > counter_most + 1) return null;
    const schedule = scheduleOf(timings, lengths, held, pictureFetch(timings.h_active, held.pitch), null) orelse return null;

    const h_blank_start = lengths.h_blank_end + timings.h_active;
    const v_blank_start = lengths.v_blank_end + timings.v_active;
    // The fetcher's start falls that many lines before the picture's
    // first; where it falls before the frame's, the second front porch
    // makes up the rest.
    const fp2: u32 = if (schedule.vstartup > lengths.v_blank_end + 1) schedule.vstartup - lengths.v_blank_end - 1 else 0;
    return .{
        .width = timings.h_active,
        .height = timings.v_active,
        .pixel_hz = timings.pixel_clock_hz,
        .h_total = lengths.h_total - 1,
        .h_blank = h_blank_start | lengths.h_blank_end << high_shift,
        .h_sync = timings.h_sync << high_shift,
        .h_sync_control = if (timings.flags & rtg.modes.RTGTM_HSYNC_HIGH != 0) 0 else sync_low,
        .v_total = lengths.v_total - 1,
        .v_blank = v_blank_start | lengths.v_blank_end << high_shift,
        .v_sync = timings.v_sync << high_shift,
        .v_sync_control = if (timings.flags & rtg.modes.RTGTM_VSYNC_HIGH != 0) 0 else sync_low,
        .vtg = fp2 | v_blank_start << vtg_count_init_shift,
        .size = timings.h_active | timings.v_active << high_shift,
        .pattern_size = timings.v_active | timings.h_active << high_shift,
        .schedule = schedule,
    };
}

/// A frame's time in microseconds.
pub fn frameUs(mode: *const Mode) u64 {
    const line: u64 = mode.h_total + 1;
    const frame: u64 = mode.v_total + 1;
    return line * frame * 1_000_000 / mode.pixel_hz;
}

// --- the schedule ----------------------------------------------------------------------

/// The hub's reference, in Hz: the crystal halved.
const reference_hz: u64 = 24_000_000;
/// The nominal blank the fetcher starts in, in microseconds; the lines
/// it starts before the picture at least and at most.
const nominal_blank_us: u64 = 668;
const vstartup_least: u32 = 9;
const vstartup_most: u32 = 1023;
/// The pipe's own delay before the blender, in cycles of the pipes'
/// clock - its scaler's part where it passes the picture through and
/// where it scales - and of the display clock.
const pipe_delay_cycles: u64 = 46 + 27;
const scaler_delay_cycles: u64 = 16;
const scaling_delay_cycles: u64 = 50;
const display_delay_cycles: u64 = 119;
/// The cursor's part of the pipe's delay, where the pipe lays it.
const cursor_delay_cycles: u64 = 6;
/// The prefetch's quarter line for the page table and half a line twice
/// for its rows, in quarters of a line; the rows of pixels it fetches.
const prefetch_table_quarters: u32 = 1 + 2 * 2;
const prefetch_rows: u32 = 2;
/// The bytes a request reads.
const request_bytes: u32 = 256;
/// The fetcher's prefetch ratio and the fetch's urgency level for a
/// flip, as the registers hold them.
const ratio_one: u32 = 1 << 19;
const flip_level: u32 = 14;
const fixed_level: u32 = 8;

/// Fixed point: 16 bits of a pixel.
const fraction_bits = 16;
const fraction_one: u64 = 1 << fraction_bits;

/// `cycles` of a clock at `clock_hz` in pixels at `pixel_hz`, in fixed
/// point.
fn pixelsOf(cycles: u64, clock_hz: u64, pixel_hz: u64) u64 {
    return cycles * pixel_hz * fraction_one / clock_hz;
}

/// A fixed-point count rounded up to a whole one.
fn wholeUp(fixed: u64) u64 {
    return (fixed + fraction_one - 1) >> fraction_bits;
}

/// What a fetcher reads, for its schedule: the width of its place on
/// the glass; its picture's planes - the one plane of its pixels, or a
/// 4:2:0 picture's brightness and its colour - whether its scaler
/// scales, as it does a 4:2:0 picture's colour, and whether its pipe
/// lays the cursor, as every pipe but a film's does.
pub const Fetch = struct {
    out_width: u32,
    luma: Read,
    chroma: ?Read = null,
    scaled: bool = false,
    cursor: bool = true,
};

/// One plane a fetcher reads: its viewport's width, the surface's width
/// and its rows' length, in the plane's elements - its pixels, or the
/// colour's pairs of samples - and an element's bytes; how it is scaled
/// each way: its ratio, in 19 bits of a pixel, and its taps.
pub const Read = struct {
    width: u32,
    surface: u32,
    pitch: u32,
    bytes: u32,
    h_ratio: u32 = ratio_one,
    v_ratio: u32 = ratio_one,
    h_taps: u32 = 1,
    v_taps: u32 = 1,
};

/// A picture of 32-bit pixels `width` across, unscaled, in rows `pitch`
/// pixels long.
pub fn pictureFetch(width: u32, pitch: u32) Fetch {
    return .{ .out_width = width, .luma = .{ .width = width, .surface = width, .pitch = pitch, .bytes = 4 } };
}

/// The schedule of a plane `width` pixels across, unscaled, at `timings`
/// beside the picture: its fetcher's registers for the timing generator's
/// start `vstartup` as it runs (`vstartupOf`) - the timing generator's
/// own are left as they are. Null as `scheduleOf`, and for a start the
/// blank has no room for.
pub fn planeSchedule(timings: rtg.RtgTimings, width: u32, held: Held, vstartup: u32) ?Schedule {
    return fetchSchedule(timings, pictureFetch(width, held.pitch), held, vstartup);
}

/// The schedule of what `fetch` says a fetcher reads at `timings`
/// beside the picture, as `planeSchedule`.
pub fn fetchSchedule(timings: rtg.RtgTimings, fetch: Fetch, held: Held, vstartup: u32) ?Schedule {
    return scheduleFor(timings, fetch, held, vstartup);
}

/// The schedule of what `fetch` says a fetcher reads at `timings`, from
/// the timing generator's start `vstartup` where it runs already, else
/// from the one worked out: null as `scheduleOf`, and for what no fetcher
/// reads.
pub fn scheduleFor(timings: rtg.RtgTimings, fetch: Fetch, held: Held, vstartup: ?u32) ?Schedule {
    if (fetch.out_width == 0 or fetch.out_width > side_most) return null;
    if (fetch.luma.width == 0 or fetch.luma.bytes == 0 or fetch.luma.bytes > request_bytes) return null;
    if (fetch.chroma) |chroma| {
        if (chroma.width == 0 or chroma.bytes == 0 or chroma.bytes > request_bytes) return null;
    }
    if (timings.pixel_clock_hz == 0 or timings.h_active == 0 or timings.v_active == 0) return null;
    return scheduleOf(timings, lengthsOf(timings), held, fetch, vstartup);
}

/// The pipe's own delay before the blender, in picoseconds, at the
/// display clock and the pipe's clock (in kHz): longer where its scaler
/// scales, and where it lays the cursor.
pub fn afterScalerPs(fetch: Fetch, display_khz: u32, pipes_khz: u32) u64 {
    return pipeCycles(fetch) * 1_000_000_000 / @max(1, pipes_khz) + display_delay_cycles * 1_000_000_000 / @max(1, display_khz);
}

/// The pipe's own delay in cycles of its clock.
fn pipeCycles(fetch: Fetch) u64 {
    const scaler_cycles = if (fetch.scaled) scaling_delay_cycles else scaler_delay_cycles;
    return pipe_delay_cycles + scaler_cycles + (if (fetch.cursor) cursor_delay_cycles else 0);
}

/// The rows of a plane its prefetch reads: those its taps reach before
/// the first line's and one more, its swath being a row
/// (CalculatePrefetchSourceLines).
fn sourceLines(plane: Read) u32 {
    return @intCast((@as(u64, plane.v_ratio) + (@as(u64, plane.v_taps) + 1) * ratio_one) / (2 * @as(u64, ratio_one)) + 1);
}

/// The elements of a row the prefetch is counted to read: the viewport
/// less one rounded up to a request and one more, no more than the
/// surface rounded up to one.
pub fn swathOf(plane: Read) u64 {
    const element = request_bytes / plane.bytes;
    const surface = (@as(u64, plane.surface) + element - 1) / element * element;
    const row = (@as(u64, plane.width) - 1 + element - 1) / element * element + element;
    return @min(surface, row);
}

/// A plane's pace, in the hub's reference: a line's delivery and a
/// request's, in 10 bits of a cycle, as it is scanned and in the
/// prefetch.
const Delivery = struct { line: u64 = 0, line_prefetch: u64 = 0, request: u64 = 0, request_prefetch: u64 = 0 };

/// The pace of `plane` read into a place `out_width` across at
/// `pixel_hz`, its prefetch at `prefetch_ratio` (get_refcyc_per_delivery):
/// where its lines come no faster than the glass's, the place's width at
/// the rate it is scanned; where faster, what it reads at the rate its
/// scaler takes it across - the pipes' clock twice over, or times twice
/// its ratio across where it is made smaller that way, its ratio alone
/// past six taps, at most four times.
fn deliveryOf(plane: Read, out_width: u32, prefetch_ratio: u64, pixel_hz: u64, pipes_hz: u64) Delivery {
    const element = request_bytes / plane.bytes;
    // A row's requests: the viewport less one rounded up to a request
    // and one more, or the surface's row where that is shorter.
    var row: u64 = (@as(u64, plane.width) - 1 + element - 1) / element * element + element;
    if (row > plane.pitch and plane.pitch >= plane.width) row = plane.pitch;
    const requests = @max(1, row / element);
    const factor: u64 = if (plane.h_ratio <= ratio_one)
        2 * @as(u64, ratio_one)
    else if (plane.h_taps <= 6)
        @min(2 * @as(u64, plane.h_ratio), 4 * @as(u64, ratio_one))
    else
        @min(@as(u64, plane.h_ratio), 4 * @as(u64, ratio_one));
    const rate = factor * pipes_hz / ratio_one;
    const scanned_line = @as(u64, out_width) * reference_hz / pixel_hz;
    const scanned_request = @as(u64, out_width) * reference_hz * 1024 / (pixel_hz * requests);
    const scaled_line = reference_hz * row / rate;
    const scaled_request = @as(u64, plane.width) * reference_hz * 1024 / (rate * requests);
    return .{
        .line = if (plane.v_ratio <= ratio_one) scanned_line else scaled_line,
        .line_prefetch = if (prefetch_ratio <= ratio_one) scanned_line else scaled_line,
        .request = if (plane.v_ratio <= ratio_one) scanned_request else scaled_request,
        .request_prefetch = if (prefetch_ratio <= ratio_one) scanned_request else scaled_request,
    };
}

/// The schedule for what `fetch` says a fetcher reads at `timings` (the
/// module's header says how it is worked out), from the timing
/// generator's start `started` where it runs already, else from the one
/// worked out: null where no start leaves the prefetch its lines, or a
/// register would not hold its part.
fn scheduleOf(timings: rtg.RtgTimings, lengths: Lengths, held: Held, fetch: Fetch, started: ?u32) ?Schedule {
    const pixel_hz: u64 = timings.pixel_clock_hz;
    const display_hz: u64 = @as(u64, held.display_khz) * 1000;
    const pipes_hz: u64 = @as(u64, held.pipes_khz) * 1000;
    if (display_hz == 0 or pipes_hz == 0) return null;
    const h_total: u64 = lengths.h_total;
    const v_blank = lengths.v_total - timings.v_active;

    // The fetcher's start: a nominal blank before the picture.
    const nominal_lines: u64 = (nominal_blank_us * pixel_hz + h_total * 1_000_000 - 1) / (h_total * 1_000_000);
    var nominal: u32 = @intCast(@min(@as(u64, v_blank), nominal_lines));
    nominal = @min(@max(nominal, lengths.v_blank_end + 2), vstartup_most);
    const vstartup = started orelse @min(@min(v_blank, nominal) - 1, vstartup_most);
    if (vstartup < vstartup_least or vstartup >= v_blank or vstartup > vstartup_most) return null;

    // The registers taken, and the fetcher ready: the controller's deep
    // sleep clock is the slowest.
    const deep_sleep_hz: u64 = held.deep_sleep_hz;
    if (deep_sleep_hz == 0) return null;
    const reload = pixelsOf(16, pipes_hz, pixel_hz) + pixelsOf(24, display_hz, pixel_hz);
    const vupdate_offset = (h_total + 3) / 4;
    const vupdate_width = wholeUp(pixelsOf(14, deep_sleep_hz, pixel_hz) + pixelsOf(12, pipes_hz, pixel_hz) + reload);
    const vready_offset = wholeUp(@max(pixelsOf(150, pipes_hz, pixel_hz), reload + pixelsOf(20, deep_sleep_hz, pixel_hz) + pixelsOf(10, pipes_hz, pixel_hz)));
    if (vupdate_offset > 0xffff or vupdate_width > 0x3ff or vready_offset > 0xffff) return null;
    const setup = vupdate_offset + vupdate_width + vready_offset;

    // The prefetch's lines, in quarters: the table's and the rows' at the
    // scan's rate, or what the time left allows.
    const rows_luma = sourceLines(fetch.luma);
    const rows_chroma: u32 = if (fetch.chroma) |chroma| sourceLines(chroma) else 0;
    const rows_most = @max(rows_luma, rows_chroma);
    var row_bytes: u64 = rows_luma * swathOf(fetch.luma) * fetch.luma.bytes;
    if (fetch.chroma) |chroma| row_bytes += rows_chroma * swathOf(chroma) * chroma.bytes;
    // A pixel's bytes, in quarters: a 4:2:0 picture's colour has a pair
    // of samples for each four pixels.
    const pixel_quarters: u64 = 4 * @as(u64, fetch.luma.bytes) + (if (fetch.chroma) |chroma| chroma.bytes else 0);
    const scan_ratio: u64 = @min(ratio_one, fetch.luma.v_ratio);
    const scan = pixel_quarters * h_total * scan_ratio;
    const scanned = (16 * row_bytes * ratio_one + scan - 1) / scan;
    const row_quarters: u32 = @intCast(@max(@min(scanned, 4 * @as(u64, rows_most)), @max(4, rows_most)));
    const at_once_quarters = prefetch_table_quarters + row_quarters;
    const calculate = pixelsOf(24, deep_sleep_hz, pixel_hz);
    const delay = pixelsOf(pipeCycles(fetch), pipes_hz, pixel_hz) + pixelsOf(display_delay_cycles, display_hz, pixel_hz);
    const taken = (setup << fraction_bits) + pixelsOf(held.wait_ns, 1_000_000_000, pixel_hz) + calculate + delay;
    const line_fixed = h_total * fraction_one;
    var start: u32 = vstartup_least;
    var prefetch_quarters: u32 = 0;
    while (start <= vstartup) : (start += 1) {
        const left: i64 = @as(i64, @intCast(4 * start * line_fixed + line_fixed / 2)) - @as(i64, @intCast(4 * taken));
        if (left < 0) continue;
        const left_quarters: u32 = @intCast(@min(255, @as(u64, @intCast(left)) / line_fixed));
        if (left_quarters < 8) continue;
        const quarters = @min(at_once_quarters, left_quarters);
        // Its rows no more than four times as fast as they are scanned.
        if (quarters - prefetch_table_quarters < rows_most) continue;
        prefetch_quarters = quarters;
        break;
    }
    if (prefetch_quarters == 0) return null;
    const rows_quarters = prefetch_quarters - prefetch_table_quarters;
    const ratio = @max(ratio_one, (@as(u64, 4 * rows_luma) << 19) / rows_quarters);
    const ratio_chroma: u64 = if (fetch.chroma != null) @max(ratio_one, (@as(u64, 4 * rows_chroma) << 19) / rows_quarters) else ratio_one;

    // The pace, in the hub's reference.
    const h_blank_end = lengths.h_blank_end * reference_hz / pixel_hz;
    const per_line = h_total * reference_hz * 256 / pixel_hz;
    const delay_lines = delay / line_fixed;
    const delay_cycles = (delay - delay_lines * line_fixed) * reference_hz / pixel_hz >> fraction_bits;
    const reference_to_pixel = reference_hz * ratio_one / pixel_hz;
    if (h_blank_end > 0x1fff or per_line > 0x1fffff or delay_cycles > 0x1fff or delay_lines > 7 or reference_to_pixel > 0x1fffff) return null;
    const luma = deliveryOf(fetch.luma, fetch.out_width, ratio, pixel_hz, pipes_hz);
    const chroma: Delivery = if (fetch.chroma) |plane| deliveryOf(plane, fetch.out_width, ratio_chroma, pixel_hz, pipes_hz) else .{};
    const high_level = 4 * h_total * reference_hz / pixel_hz;
    const next_start: u64 = (2 * @as(u64, lengths.v_total) - timings.v_front - timings.v_active - vstartup + setup / h_total) * 4;
    if (@max(luma.line, chroma.line) > 0x1fff or @max(luma.line_prefetch, chroma.line_prefetch) > 0x1fff) return null;
    if (high_level > 0x3fff or next_start > 0x3ffff) return null;

    // Its time to urgency in a blank: the hub's watermarks, the time to
    // work out a request and the start's margin.
    const margin = @as(u64, vstartup - start) * h_total * reference_hz / pixel_hz;
    const blank_ttu = @min(0xffffff, held.watermark + 24 * reference_hz / deep_sleep_hz + margin);

    return .{
        .vstartup = vstartup,
        .vupdate = @intCast(vupdate_offset | vupdate_width << high_shift),
        .vready = @intCast(vready_offset),
        .ready_after_sync = @as(i64, @intCast(setup)) <= (@as(i64, lengths.v_blank_end) - vstartup) * @as(i64, @intCast(h_total)),
        .blank_offset = @intCast(h_blank_end | @as(u64, lengths.v_blank_end) << high_shift),
        .next_start = @intCast(next_start),
        .dst_dimensions = @intCast(per_line),
        .after_scaler = @intCast(delay_cycles | delay_lines << high_shift),
        .reference_to_pixel = @intCast(reference_to_pixel),
        .prefetch = @intCast(@as(u64, prefetch_quarters) << 24 | ratio),
        .prefetch_chroma = @intCast(ratio_chroma),
        .vblank = 1 | 2 << 8,
        .line_delivery = @intCast(luma.line | chroma.line << high_shift),
        .line_delivery_prefetch = @intCast(luma.line_prefetch | chroma.line_prefetch << high_shift),
        .qos = @intCast(high_level << high_shift),
        .global_ttu = @intCast(blank_ttu | @as(u64, flip_level) << 28),
        .surface_ttu = @intCast(@min(0x7fffff, luma.request) | @as(u64, fixed_level) << 24),
        .surface_ttu_prefetch = @intCast(@min(0x7fffff, luma.request_prefetch)),
        .two_planes = fetch.chroma != null,
        .chroma_ttu = @intCast(@min(0x7fffff, chroma.request) | @as(u64, fixed_level) << 24),
        .chroma_ttu_prefetch = @intCast(@min(0x7fffff, chroma.request_prefetch)),
    };
}

// --- the writes --------------------------------------------------------------------------

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

/// The output timing generator `pipe` takes its picture from.
pub fn outputOf(engine: dcn.Engine, pipe: u32) u32 {
    return (at(engine, optc_source + pipe * optc_stride).* & source_mask) >> source_shift;
}

/// The timing generator of `pipe` told the mode: its totals, blanking,
/// syncs, vertical counter and global sync. Written while it is stopped,
/// which takes them at once.
pub fn writeTiming(engine: dcn.Engine, pipe: u32, mode: *const Mode) void {
    const base = pipe * otg_stride;
    at(engine, base + otg_h_total).* = mode.h_total;
    at(engine, base + otg_h_blank).* = mode.h_blank;
    at(engine, base + otg_h_sync).* = mode.h_sync;
    const h_control = at(engine, base + otg_h_sync_control);
    h_control.* = (h_control.* & ~sync_low) | mode.h_sync_control;
    at(engine, base + otg_v_total).* = mode.v_total;
    at(engine, base + otg_v_blank).* = mode.v_blank;
    at(engine, base + otg_v_sync).* = mode.v_sync;
    const v_control = at(engine, base + otg_v_sync_control);
    v_control.* = (v_control.* & ~sync_low) | mode.v_sync_control;
    const vtg = at(engine, vtg_control + pipe);
    vtg.* = (vtg.* & vtg_enable) | mode.vtg;
    at(engine, base + otg_vstartup).* = mode.schedule.vstartup;
    at(engine, base + otg_vupdate).* = mode.schedule.vupdate;
    at(engine, base + otg_vready).* = mode.schedule.vready;
}

/// The fetcher `fetcher`, its scaler and the output `output` told the
/// mode's picture and schedule: the viewports from the frame's top left,
/// the schedule's registers (the chroma's prefetch ratio 1, as a plane
/// without one is told), the scaler's blanking, output rectangle and
/// size into the blender, the pattern generator's size.
pub fn writePlane(engine: dcn.Engine, fetcher: u32, output: u32, mode: *const Mode) void {
    const hubp = fetcher * hubp_stride;
    at(engine, hubp + hubp_viewport_start).* = 0;
    at(engine, hubp + hubp_viewport).* = mode.size;
    at(engine, hubp + hubp_second_viewport_start).* = 0;
    at(engine, hubp + hubp_second_viewport).* = mode.size;
    const schedule = mode.schedule;
    const control = at(engine, hubp + hubp_control);
    control.* = (control.* & ~hubp_ready_after_sync) | (if (schedule.ready_after_sync) hubp_ready_after_sync else 0);
    writeSchedule(engine, fetcher, &schedule);

    const dpp = fetcher * dpp_stride;
    at(engine, dpp + dscl_h_blank).* = scalerBlank(mode.h_blank);
    at(engine, dpp + dscl_v_blank).* = scalerBlank(mode.v_blank);
    at(engine, dpp + dscl_recout_start).* = 0;
    at(engine, dpp + dscl_recout_size).* = mode.size;
    at(engine, dpp + dscl_mpc_size).* = mode.size;
    passThrough(engine, fetcher);

    at(engine, output * opp_stride + dpg_dimensions).* = mode.pattern_size;
}

/// The scaler of the pipe `fetcher` in its bypass from the pipe's next
/// update on: each pixel where the fetcher read it, the vendor's mode for
/// a picture scaled neither way (dpp1_dscl_get_dscl_mode).
pub fn passThrough(engine: dcn.Engine, fetcher: u32) void {
    const scaling = at(engine, fetcher * dpp_stride + dscl_mode);
    scaling.* &= ~dscl_mode_mask;
}

/// The fetcher `fetcher` told its pace (`Schedule`): when it starts in
/// the blank, its prefetch - the colour's at a ratio of 1 for a picture
/// of one plane - and the time it has for its requests, a 4:2:0
/// picture's colour's too. Its ready is the caller's, which knows whether
/// the timing generator's is its own.
pub fn writeSchedule(engine: dcn.Engine, fetcher: u32, schedule: *const Schedule) void {
    const hubp = fetcher * hubp_stride;
    at(engine, hubp + hubp_blank_offset).* = schedule.blank_offset;
    at(engine, hubp + hubp_next_start).* = schedule.next_start;
    at(engine, hubp + hubp_dst_dimensions).* = schedule.dst_dimensions;
    at(engine, hubp + hubp_after_scaler).* = schedule.after_scaler;
    at(engine, hubp + hubp_reference_to_pixel).* = schedule.reference_to_pixel;
    at(engine, hubp + hubp_prefetch).* = schedule.prefetch;
    at(engine, hubp + hubp_prefetch_chroma).* = schedule.prefetch_chroma;
    at(engine, hubp + hubp_vblank).* = schedule.vblank;
    at(engine, hubp + hubp_line_delivery).* = schedule.line_delivery;
    at(engine, hubp + hubp_line_delivery_prefetch).* = schedule.line_delivery_prefetch;
    at(engine, hubp + hubp_qos).* = schedule.qos;
    at(engine, hubp + hubp_global_ttu).* = schedule.global_ttu;
    at(engine, hubp + hubp_surface_ttu).* = schedule.surface_ttu;
    at(engine, hubp + hubp_surface_ttu_prefetch).* = schedule.surface_ttu_prefetch;
    if (schedule.two_planes) {
        at(engine, hubp + hubp_chroma_ttu).* = schedule.chroma_ttu;
        at(engine, hubp + hubp_chroma_ttu_prefetch).* = schedule.chroma_ttu_prefetch;
    }
}

/// The timing generator's global sync for the fetchers on it, as the
/// vendor writes it for a group of pipes (program_global_sync with
/// calculate_vready_offset_for_group): its start and its update's window
/// from the picture's schedule, its ready the latest any of the
/// fetchers' is; and whether they are ready after the vertical sync, by
/// that latest ready.
pub const Sync = struct {
    vstartup: u32,
    vupdate: u32,
    vready: u32,
    ready_after_sync: bool,
};

pub fn syncOf(timings: rtg.RtgTimings, picture: *const Schedule, others: []const Schedule) Sync {
    var vready = picture.vready;
    for (others) |one| vready = @max(vready, one.vready);
    const lengths = lengthsOf(timings);
    const setup: i64 = (picture.vupdate & 0xffff) + (picture.vupdate >> high_shift) + vready;
    return .{
        .vstartup = picture.vstartup,
        .vupdate = picture.vupdate,
        .vready = vready,
        .ready_after_sync = setup <= (@as(i64, lengths.v_blank_end) - picture.vstartup) * @as(i64, lengths.h_total),
    };
}

/// The timing generator of `pipe` told `sync`, and each of `fetchers`
/// whether it is ready after the vertical sync: taken at the pipe's next
/// update, so written under its update lock.
pub fn writeSync(engine: dcn.Engine, pipe: u32, fetchers: []const u32, sync: Sync) void {
    const base = pipe * otg_stride;
    at(engine, base + otg_vstartup).* = sync.vstartup;
    at(engine, base + otg_vupdate).* = sync.vupdate;
    at(engine, base + otg_vready).* = sync.vready;
    for (fetchers) |fetcher| {
        const control = at(engine, fetcher * hubp_stride + hubp_control);
        control.* = (control.* & ~hubp_ready_after_sync) | (if (sync.ready_after_sync) hubp_ready_after_sync else 0);
    }
}

/// The lines before the picture timing generator `pipe` starts its
/// fetchers at, as it runs.
pub fn vstartupOf(engine: dcn.Engine, pipe: u32) u32 {
    return at(engine, pipe * otg_stride + otg_vstartup).* & vstartup_most;
}

/// The fetcher's turn of its surface: its rotation - none or half a
/// turn - and its horizontal mirror, as `turnOf` says them.
const rotation_shift = 8;
const rotation_mask: u32 = 0x3 << rotation_shift;
const half_turn: u32 = 2;
const h_mirror: u32 = 1 << 10;

/// How the fetcher reads its surface for a picture mirrored about each
/// axis (hubp2_program_rotation, get_vp_scan_direction): half a turn
/// reverses both of its scans and the mirror the horizontal one again,
/// so left to right is the mirror alone, top to bottom half a turn and
/// the mirror, and both half a turn.
pub const Turn = struct { half_turn: bool, mirror: bool };

pub fn turnOf(x: bool, y: bool) Turn {
    return .{ .half_turn = y, .mirror = x != y };
}

/// The fetcher `fetcher` told to read its surface mirrored about each
/// axis, from the pipe's next update on.
pub fn writeTurn(engine: dcn.Engine, fetcher: u32, x: bool, y: bool) void {
    const turn = turnOf(x, y);
    const config = at(engine, fetcher * hubp_stride + hubp_surface_config);
    var value = config.* & ~(rotation_mask | h_mirror);
    if (turn.half_turn) value |= half_turn << rotation_shift;
    if (turn.mirror) value |= h_mirror;
    config.* = value;
}

/// A timing generator's blank as the scaler holds it: each end in 14
/// bits.
fn scalerBlank(blank: u32) u32 {
    return (blank & side_most) | (((blank >> high_shift) & side_most) << high_shift);
}

/// The fetcher blanked - once it has no requests out, waited for up to
/// `wait_us` - or let go of (hubp2_set_blank). Its time-to-urgency is
/// left as the firmware set it.
pub fn blankFetcher(engine: dcn.Engine, fetcher: u32, blank: bool, wait_us: u64) void {
    const control = at(engine, fetcher * hubp_stride + hubp_control);
    if (!blank) {
        control.* &= ~hubp_blank;
        return;
    }
    const deadline = engine.sys.UptimeUs() + wait_us;
    while (control.* & hubp_idle == 0 and engine.sys.UptimeUs() < deadline) dcn.pause(engine.sys, 10);
    control.* |= hubp_blank;
}

/// The fetcher's control, its underflow noted since it was last cleared.
pub fn fetcherControl(engine: dcn.Engine, fetcher: u32) u32 {
    return at(engine, fetcher * hubp_stride + hubp_control).*;
}

/// The fetcher's note of an underflow cleared: its clear bit set and
/// taken back, so a later underflow is noted again.
pub fn clearUnderflow(engine: dcn.Engine, fetcher: u32) void {
    const control = at(engine, fetcher * hubp_stride + hubp_control);
    control.* |= hubp_underflow_clear;
    control.* &= ~hubp_underflow_clear;
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

/// The box's monitor's own mode, as its EDID names it.
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
    .flags = rtg.modes.RTGTM_HSYNC_HIGH,
};

/// The clocks at their top on the box, its frames' rows, the longest of
/// the watermarks the firmware left, the deep-sleep clock of the picture
/// alone and a wait of 32 us.
const top: Held = .{ .display_khz = 1_200_000, .pipes_khz = 1_200_000, .pitch = 2560, .watermark = 0x69C, .deep_sleep_hz = 17_357_812, .wait_ns = 32_000 };

test "the timing generator's registers are those the firmware wrote for its mode" {
    const mode = of(own, 2560, 1440, top) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0xA9F), mode.h_total);
    try testing.expectEqual(@as(u32, 0x00700A70), mode.h_blank);
    try testing.expectEqual(@as(u32, 0x00200000), mode.h_sync);
    try testing.expectEqual(@as(u32, 0), mode.h_sync_control);
    try testing.expectEqual(@as(u32, 0x5C8), mode.v_total);
    try testing.expectEqual(@as(u32, 0x002605C6), mode.v_blank);
    try testing.expectEqual(@as(u32, 0x00050000), mode.v_sync);
    try testing.expectEqual(@as(u32, 1), mode.v_sync_control);
    // The fetcher starts two lines earlier than the firmware's, so the
    // second front porch is one line.
    try testing.expectEqual(@as(u32, 0x05C60001), mode.vtg);
    try testing.expectEqual(@as(u32, 0x05A00A00), mode.size);
    try testing.expectEqual(@as(u32, 0x0A0005A0), mode.pattern_size);
}

test "a mode the pipe cannot make is refused" {
    var interlaced = own;
    interlaced.flags |= rtg.modes.RTGTM_INTERLACED;
    try testing.expectEqual(@as(?Mode, null), of(interlaced, 2560, 1440, top));
    // Larger than the frames.
    try testing.expectEqual(@as(?Mode, null), of(own, 1920, 1440, top));
    var unclocked = own;
    unclocked.pixel_clock_hz = 0;
    try testing.expectEqual(@as(?Mode, null), of(unclocked, 2560, 1440, top));
    // A blank too short for the fetcher's start.
    var short = own;
    short.v_front = 1;
    short.v_sync = 2;
    short.v_back = 3;
    try testing.expectEqual(@as(?Mode, null), of(short, 2560, 1440, top));
}

test "the schedule of the box's monitor's own mode, as the vendor's model works it out" {
    const schedule = (of(own, 2560, 1440, top) orelse return error.TestUnexpectedResult).schedule;
    // A nominal blank of 41 lines; the registers taken a quarter line in,
    // for 206 pixels, ready 289 after.
    try testing.expectEqual(@as(u32, 40), schedule.vstartup);
    try testing.expectEqual(@as(u32, 0x00CE02A8), schedule.vupdate);
    try testing.expectEqual(@as(u32, 289), schedule.vready);
    try testing.expect(!schedule.ready_after_sync);
    // The blank's end 11 reference cycles into the line, 38 lines in.
    try testing.expectEqual(@as(u32, 0x0026000B), schedule.blank_offset);
    try testing.expectEqual(@as(u32, 1479 * 4), schedule.next_start);
    try testing.expectEqual(@as(u32, 69199), schedule.dst_dimensions);
    try testing.expectEqual(@as(u32, 4), schedule.after_scaler);
    try testing.expectEqual(@as(u32, 0xCB87), schedule.reference_to_pixel);
    // Three and a quarter lines of prefetch at the scan's rate.
    try testing.expectEqual(@as(u32, 0x0D080000), schedule.prefetch);
    try testing.expectEqual(@as(u32, 0x0201), schedule.vblank);
    try testing.expectEqual(@as(u32, 254), schedule.line_delivery);
    try testing.expectEqual(@as(u32, 254), schedule.line_delivery_prefetch);
    try testing.expectEqual(@as(u32, 0x04390000), schedule.qos);
    try testing.expectEqual(@as(u32, 0x08001970), schedule.surface_ttu);
    try testing.expectEqual(@as(u32, 0x1970), schedule.surface_ttu_prefetch);
    // The watermark, the request's working out and 31 lines of margin.
    try testing.expectEqual(@as(u32, 0xE0000000 | (0x69C + 33 + 8379)), schedule.global_ttu);
}

test "a mode whose prefetch is read faster than it is scanned" {
    // CEA's 1920x1080 at 60: three lines of prefetch, two rows in 1.75.
    const cea: rtg.RtgTimings = .{
        .pixel_clock_hz = 148_500_000,
        .h_active = 1920,
        .h_front = 88,
        .h_sync = 44,
        .h_back = 148,
        .v_active = 1080,
        .v_front = 4,
        .v_sync = 5,
        .v_back = 36,
        .flags = rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH,
    };
    const held: Held = .{ .display_khz = 1_200_000, .pipes_khz = 1_200_000, .pitch = 1920, .watermark = 0x69C, .deep_sleep_hz = 10_673_437, .wait_ns = 32_000 };
    const schedule = (of(cea, 1920, 1080, held) orelse return error.TestUnexpectedResult).schedule;
    try testing.expectEqual(@as(u32, 44), schedule.vstartup);
    try testing.expectEqual(@as(u32, 0x00CA0226), schedule.vupdate);
    try testing.expectEqual(@as(u32, 285), schedule.vready);
    try testing.expectEqual(@as(u32, 0x0029001F), schedule.blank_offset);
    try testing.expectEqual(@as(u32, 1122 * 4), schedule.next_start);
    try testing.expectEqual(@as(u32, 91022), schedule.dst_dimensions);
    try testing.expectEqual(@as(u32, 0x14AFD), schedule.reference_to_pixel);
    try testing.expectEqual(@as(u32, 0x0C092492), schedule.prefetch);
    try testing.expectEqual(@as(u32, 310), schedule.line_delivery);
    try testing.expectEqual(@as(u32, 19), schedule.line_delivery_prefetch);
    try testing.expectEqual(@as(u32, 0x058E0000), schedule.qos);
    try testing.expectEqual(@as(u32, 0x0800295F), schedule.surface_ttu);
    try testing.expectEqual(@as(u32, 655), schedule.surface_ttu_prefetch);
}

test "a 4:2:0 picture's schedule, as the vendor's model works it out for its two planes" {
    // 1920 by 1080 as it is: two rows of each plane in two lines, each
    // plane's lines and requests at the rate its place is scanned.
    const shown: Fetch = .{
        .out_width = 1920,
        .luma = .{ .width = 1920, .surface = 1920, .pitch = 2048, .bytes = 1 },
        .chroma = .{ .width = 960, .surface = 960, .pitch = 1024, .bytes = 2, .h_ratio = ratio_one / 2, .v_ratio = ratio_one / 2 },
        .scaled = true,
    };
    const as_it_is = fetchSchedule(own, shown, top, 40) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0x0D080000), as_it_is.prefetch);
    try testing.expectEqual(ratio_one, as_it_is.prefetch_chroma);
    try testing.expectEqual(@as(u32, 190 | 190 << 16), as_it_is.line_delivery);
    try testing.expectEqual(@as(u32, 190 | 190 << 16), as_it_is.line_delivery_prefetch);
    try testing.expectEqual(@as(u32, 0x08000000 | 24423), as_it_is.surface_ttu);
    try testing.expectEqual(@as(u32, 0x08000000 | 24423), as_it_is.chroma_ttu);
    try testing.expectEqual(@as(u32, 24423), as_it_is.chroma_ttu_prefetch);
    try testing.expect(as_it_is.two_planes);
    // The scaler's delay, 46 + 27 + 50 cycles of the pipes' clock and
    // 119 of the display clock: 48 pixels, 4 reference cycles.
    try testing.expectEqual(@as(u32, 4), as_it_is.after_scaler);

    // 3840 by 2160 halved: the brightness's lines come twice as fast as
    // the glass's, read at four times the pipes' clock; four rows of it
    // and two of the colour in four lines.
    const halved: Fetch = .{
        .out_width = 1920,
        .luma = .{ .width = 3840, .surface = 3840, .pitch = 4096, .bytes = 1, .h_ratio = 2 * ratio_one, .v_ratio = 2 * ratio_one, .h_taps = 4, .v_taps = 4 },
        .chroma = .{ .width = 1920, .surface = 1920, .pitch = 2048, .bytes = 2 },
        .scaled = true,
    };
    const smaller = fetchSchedule(own, halved, top, 40) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 21 << 24 | ratio_one), smaller.prefetch);
    try testing.expectEqual(@as(u32, 20 | 190 << 16), smaller.line_delivery);
    try testing.expectEqual(@as(u32, 190 | 190 << 16), smaller.line_delivery_prefetch);
    try testing.expectEqual(@as(u32, 0x08000000 | 1228), smaller.surface_ttu);
    try testing.expectEqual(@as(u32, 12211), smaller.surface_ttu_prefetch);
    try testing.expectEqual(@as(u32, 0x08000000 | 12211), smaller.chroma_ttu);

    // 1280 by 720 doubled onto the whole glass, its rows as long as the
    // picture: three rows of each plane in three lines.
    const doubled: Fetch = .{
        .out_width = 2560,
        .luma = .{ .width = 1280, .surface = 1280, .pitch = 1280, .bytes = 1, .h_ratio = ratio_one / 2, .v_ratio = ratio_one / 2, .h_taps = 4, .v_taps = 4 },
        .chroma = .{ .width = 640, .surface = 640, .pitch = 640, .bytes = 2, .h_ratio = ratio_one / 4, .v_ratio = ratio_one / 4, .h_taps = 4, .v_taps = 4 },
        .scaled = true,
    };
    const larger = fetchSchedule(own, doubled, top, 40) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 17 << 24 | ratio_one), larger.prefetch);
    try testing.expectEqual(@as(u32, 254 | 254 << 16), larger.line_delivery);
    try testing.expectEqual(@as(u32, 0x08000000 | 52103), larger.surface_ttu);
    try testing.expectEqual(@as(u32, 0x08000000 | 52103), larger.chroma_ttu);
}
