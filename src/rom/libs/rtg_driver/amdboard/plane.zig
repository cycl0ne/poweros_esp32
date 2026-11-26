// SPDX-License-Identifier: MPL-2.0
//! A plane: one of the engine's pipes beside the picture's - its
//! fetcher, its scaler and its stage of the blender - lit on the
//! picture's timing generator, reading a surface of its own in the
//! device's memory and laid over the picture by the blender with its
//! pixels' alpha. A pipe is the engine's number n throughout: fetcher n,
//! scaler n, blender stage n, buffer n.
//!
//! **Lit from cold** as the vendor's driver lights one
//! (dcn20_enable_plane, dcn20_update_dchubp_dpp, dcn20_update_mpcc):
//! its fetcher's and its scaler's clocks, and its share of the hub's
//! buffer, as large as the picture's fetcher has, which the hub applies
//! once the fetcher runs; then, with the timing generator's update locked
//! so the pipe takes all of it at one update (optc3_lock), the fetcher
//! tied to that timing generator, its requests sized as the picture's
//! fetcher's, its schedule worked out for its width
//! (`mode.planeSchedule`), its surface - 32-bit ARGB in linear rows -
//! with its viewport, turn and address (`place`); the scaler taking its
//! colours as the picture's scaler does, with their alpha, passing them
//! through unscaled into the plane's place on the picture (its `RECOUT`)
//! with the line buffer keeping the alpha; and its blender stage put at
//! the top of the output's tree, its pixels taken as premultiplied and
//! laid over what is below (`MPCC_ALPHA_BLND_MODE` per pixel), the
//! picture below shown whole where the plane has none. Unlocked, the
//! share is waited for - up to 30 ms, as the vendor waits for it before
//! the hub's compressed buffer may grow - and a plane without it is
//! taken down again.
//!
//! **Taken down** the other way (dcn10_plane_atomic_disconnect,
//! dcn20_plane_atomic_disable): its stage out of the tree, under the
//! lock; waited for until the stage is idle; the fetcher blanked, the
//! clocks off and its buffer given back.
//!
//! **Several at one update.** The parts of lighting and taking down
//! that are written under the lock (`lit`, `writePlace`, `release`) are
//! the caller's to put together under one (`lock`): planes lit, moved
//! and taken down, and the picture's own fetcher given another place,
//! all taken by the pipe at one update. A plane laid over by its pixels'
//! alpha goes at the top of the tree as it is lit; one laid whole - a
//! band of a screen, by its global alpha alone, so the pixels' own
//! alpha is not looked at - is put in the tree by the caller, which
//! writes the whole tree at once (`stack`): nothing read back of it is
//! what the pipe takes at the update.
//!
//! **Its place** (`placeOf`): the part of the surface on the glass, and
//! where that goes. On an axis the picture is mirrored about the plane is
//! mirrored with it: its place is mirrored on the glass, and its fetcher
//! reads the same part of the surface the other way round
//! (`mode.writeTurn`, calculate_init_and_vp's flipped scan).
//!
//! **A band** (`bandOf`) is a buffer's rows on a run of the picture's
//! lines, its first row at a line of its own, the buffer as wide as the
//! picture or a whole number of times narrower. A narrower one is
//! scaled by its scaler (`Scale`) by that number both ways, each pixel
//! repeated: one tap each way, so a pixel of the picture is the buffer's
//! pixel it falls in, with nothing mixed (dpp1_dscl_set_scaler_manual_
//! scale with no filter). The scaler's first output pixel lies at its
//! `init` less one in the input it reads, each next one the ratio
//! further on - the vendor's 1 + ratio/2 for one tap lays the middle of
//! the first pixel there; 1 lays its top left, which is the pixel it
//! falls in. A band whose top lies part way into a row starts that far
//! on, and on an axis the plane is mirrored about the scaler reads the
//! rows last first, so it starts where the last line shown falls
//! instead. A ratio that is no whole number mixes pixels in the
//! picture the library makes, which this scaler does not: such a band
//! has no place.
//!
//! **A film's frame** (`lightFilm`) is a plane of NV12 - its brightness
//! and its colour each a surface of their own, each read from the 256
//! bytes its first row starts in with a viewport that starts part way
//! into them - as the vendor's driver lights one for video: the
//! fetcher's two planes' requests and its share of the hub's buffer, half
//! of it the colour's; the converter's samples expanded with zeros below,
//! the pipe's cursor off; the scaler scaling each way on its own
//! (`video.scalingOf`), its line buffer laid out for 4:2:0, and its
//! filters - as many of the vendor's taps as the scale takes
//! (`coefficients.filterOf`) - loaded only where they are not those it
//! holds, into the set it does not read, which it then reads from; and
//! the colour matrix after the scaler making red, green and blue of the
//! samples, written into its set not read too. Under the picture the
//! film's stage is the bottom of the tree, its pixels passed through, and
//! the picture's keyer makes the key's colours clear (`keyPicture`) - its
//! mode 3, sixteen bits a channel - its stage blending the picture over
//! the film by each pixel's alpha; `unkeyPicture` puts the picture back.
//! Over it the film's stage lies right above the picture's, laid whole
//! by its global alpha. A frame, place or scaling shown anew is written
//! under the lock (`moveFilm`); taken down (`darkenFilm`), the picture is
//! put back and the stage taken out at one update, and the pipe shut.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");
const mode = @import("mode.zig");
const video = @import("video.zig");
const coefficients = @import("coefficients.zig");
const cursor = @import("cursor.zig");

// --- the registers, in 32-bit words from the engine's third address ---------------

/// The fetcher's: its surface's format and turn, how its rows are laid,
/// its viewports, the size of its requests, its control and clocks, a
/// debug word the vendor sets as it lights one, its rows' length, its
/// address, and how a new address is taken. A stride apart per pipe.
const hubp_surface_config = 0x05e5;
const hubp_tiling = 0x05e7;
const hubp_viewport_start = 0x05e9;
const hubp_viewport = 0x05ea;
const hubp_second_viewport_start = 0x05ed;
const hubp_second_viewport = 0x05ee;
const hubp_request_size = 0x05f1;
const hubp_control = 0x05f3;
const hubp_clocks = 0x05f4;
const hubp_debug = 0x05f7;
const hubp_pitch = 0x0607;
const hubp_address = 0x060a;
const hubp_address_high = 0x060b;
const hubp_flip_control = 0x061b;
const hubp_stride = 0xdc;

/// In the fetcher's control: blanked, tied to which timing generator,
/// and whether that one's ready falls at or after its vertical sync.
const hubp_blank: u32 = 1 << 0;
const vtg_shift = 4;
const vtg_mask: u32 = 0xf << vtg_shift;
const ready_after_sync: u32 = 1 << 8;
/// Its clocks on; the debug word lit (hubp3_init); the surface's format
/// 32-bit ARGB, in its low seven bits; a flip taken at once, not at the
/// next update, and the address held back meanwhile.
const hubp_clock_on: u32 = 1 << 0;
const debug_lit: u32 = 1 << 26;
const format_argb8888: u32 = 8;
const format_mask: u32 = 0x7f;
const flip_now: u32 = 1 << 1;
const update_lock: u32 = 1 << 0;
const flip_pending: u32 = 1 << 8;
const address_high_mask: u32 = 0xffff;
const pitch_mask: u32 = 0x3fff;

/// The scaler's: its clocks, the colours' format and how they are taken,
/// its mode, its control and self-calibration, the timing generator's
/// blanks as it is told them, its place on the picture, the picture's
/// size, how its line buffer is laid, and its colour management's
/// bypass. A stride apart per pipe.
const dpp_control = 0x0cc5;
const cnvc_format = 0x0ccf;
const cnvc_control = 0x0cd0;
const dscl_control = 0x0cfd;
const dscl_autocal = 0x0d0c;
const dscl_h_blank = 0x0d0f;
const dscl_v_blank = 0x0d10;
const dscl_recout_start = 0x0d11;
const dscl_recout_size = 0x0d12;
const dscl_mpc_size = 0x0d13;
const lb_data_format = 0x0d14;
const lb_memory = 0x0d15;
const cm_control = 0x0d20;
const dpp_stride = 0x16b;

/// Its clock on; the colours' alpha kept, by the converter and by the
/// line buffer; the line buffer in its first layout with as many
/// partitions as it has (dpp1_dscl_set_lb).
const dpp_clock_on: u32 = 1 << 4;
const cnvc_alpha: u32 = 1 << 8;
const lb_alpha: u32 = 1 << 4;
/// Its scaling: the number of taps each way, the 2-tap filter's own
/// coefficients, replication, the ratios and where the first output
/// pixel lies, luma and chroma alike, and the mode that scales RGB.
const scl_tap_control = 0x0cfc;
const scl_2tap_control = 0x0cfe;
const scl_replicate = 0x0cff;
const scl_h_ratio = 0x0d00;
const scl_h_init = 0x0d01;
const scl_h_ratio_c = 0x0d02;
const scl_h_init_c = 0x0d03;
const scl_v_ratio = 0x0d04;
const scl_v_init = 0x0d05;
const scl_v_init_bottom = 0x0d06;
const scl_v_ratio_c = 0x0d07;
const scl_v_init_c = 0x0d08;
const scl_v_init_bottom_c = 0x0d09;
const scl_mode = 0x0cfb;
const scl_mode_mask: u32 = 0x7;
const scaling_rgb: u32 = 1;
/// Ratios and places in 24 bits of a pixel.
const scale_bits = 24;
const scale_one: u64 = 1 << scale_bits;
const lb_partitions: u32 = 63 << 8;

/// The hub's buffer, a pipe's share each, in its 64 KiB segments, and
/// the share applied.
const det_control = 0x04bb;
const det_mask: u32 = 0x7;
const det_current_shift = 8;

/// The timing generator's update lock - which one it locks, set, and
/// that it holds - a stride apart per timing generator.
const otg_lock = 0x1b8a;
const otg_global_control2 = 0x1b91;
const otg_stride = 0x80;
const lock_select_shift = 25;
const lock_select_mask: u32 = 0x7 << lock_select_shift;
const lock_set: u32 = 1 << 0;
const lock_held: u32 = 1 << 8;

// --- the blender's, from its own address ---------------------------------------------

/// A stage: the scaler on top, the stage below, the output it is part
/// of, how it blends, the output whose update it waits for, its gains,
/// and whether it is idle. A stride apart per stage; each output's top
/// stage four words apart.
const mpcc_top = 0x0000;
const mpcc_bottom = 0x0001;
const mpcc_output = 0x0002;
const mpcc_control = 0x0003;
const mpcc_lock_select = 0x0005;
const mpcc_top_gain = 0x0006;
const mpcc_bottom_inside = 0x0007;
const mpcc_bottom_outside = 0x0008;
const mpcc_status = 0x000d;
const mpcc_stride = 0x20;
const mpc_out_mux = 0x0580;
const mpc_out_stride = 4;
const mux_mask: u32 = 0xf;

/// None, in a stage's selects; idle in its status.
const none: u32 = 0xf;
const mpcc_idle: u32 = 1 << 0;

/// A stage blending its pixels over the one below, each by its own
/// alpha, premultiplied, at the background's 12 bits, with neither its
/// global alpha nor its gain taking anything off (mpc2_update_blending,
/// dcn20_update_mpcc); and the full gain, 1.0 in 1.12.
const top_bottom_blending: u32 = 3;
const blend_per_pixel: u32 = 0 << 4;
const alpha_premultiplied: u32 = 1 << 6;
const background_12_bits: u32 = 4 << 8;
const blend_global: u32 = 2 << 4;
const global_alpha_whole: u32 = 0xff << 16;
const global_gain_whole: u32 = 0xff << 24;
const gain_whole: u32 = 0x1f000;

/// How long the hub may take to apply a buffer's share, and a stage to
/// go idle once out of its tree, in microseconds (the vendor's waits).
const det_wait_us: u64 = 30_000;
const idle_wait_us: u64 = 100_000;
const lock_wait_us: u64 = 10;

// --- where a plane goes ---------------------------------------------------------------

/// What a plane shows and where: its surface - the device's address, its
/// rows `pitch` pixels apart - the part of it read, from (`view_x`,
/// `view_y`) on, `width` by `height`, and that part's top left on the
/// glass; the picture's turn, which the plane takes too; and how it is
/// scaled, null for not at all.
pub const Place = struct {
    address: u64 = 0,
    pitch: u32 = 0,
    view_x: u32 = 0,
    view_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    out_x: u32 = 0,
    out_y: u32 = 0,
    mirror_x: bool = false,
    mirror_y: bool = false,
    scale: ?Scale = null,
};

/// A scaler's work: the ratio of the part read to its place, the same
/// both ways, and where each way the first output pixel lies in what it
/// reads, in 24 bits of a pixel; and the size of its place on the glass.
pub const Scale = struct {
    ratio: u32,
    init_x: u32,
    init_y: u32,
    out_width: u32,
    out_height: u32,
};

/// A band as a plane: its place, the line its buffer's first row is at,
/// and how many times the buffer is narrower than the picture - 1 for
/// as wide: where a picture's place falls in the buffer's pixels, which
/// the pipe's cursor is laid in.
pub const Band = struct {
    place: Place,
    origin: u32,
    times: u32,
};

/// Where a band of a buffer `buffer_width` by `buffer_height` goes as a
/// plane on a picture `glass_width` by `glass_height` mirrored about the
/// axes said: shown on the picture's lines `first` up to `end`, its
/// first row at line `origin`, each line showing the row its distance
/// from `origin` falls in at the band's scale. Its address and rows are
/// left for the caller. Null where none of its rows is on those lines,
/// and for a buffer wider than the picture or a whole number of times
/// narrower by no whole number.
pub fn bandOf(first: u32, end: u32, origin: u32, buffer_width: u32, buffer_height: u32, glass_width: u32, glass_height: u32, mirror_x: bool, mirror_y: bool) ?Band {
    if (buffer_width == 0 or buffer_height == 0 or buffer_width > glass_width) return null;
    if (glass_width % buffer_width != 0) return null;
    const times = glass_width / buffer_width;
    // The lines it shows: from its origin on, as far as its rows reach.
    const reach = @as(u64, origin) + @as(u64, buffer_height) * times;
    const top = @max(first, origin);
    const bottom: u32 = @intCast(@min(@as(u64, @min(end, glass_height)), reach));
    if (top >= bottom) return null;
    const row = (top - origin) / times;
    const last = (bottom - 1 - origin) / times;
    var place = Place{
        .view_y = row,
        .width = buffer_width,
        .height = last - row + 1,
        .out_y = if (mirror_y) glass_height - bottom else top,
        .mirror_x = mirror_x,
        .mirror_y = mirror_y,
    };
    if (times != 1) {
        // Down: part way into its first row where the top lies, or - read
        // last first - into its last where the bottom lies.
        const into = if (mirror_y) times - 1 - (bottom - 1 - origin) % times else (top - origin) % times;
        place.scale = .{
            .ratio = @intCast((scale_one + times - 1) / times),
            .init_x = @intCast(scale_one),
            .init_y = @intCast(scale_one + (@as(u64, into) * scale_one + times - 1) / times),
            .out_width = glass_width,
            .out_height = bottom - top,
        };
    }
    return .{ .place = place, .origin = origin, .times = times };
}

/// Where a surface `width` by `height` goes on a picture `glass_width`
/// by `glass_height` with its top left at (`left`, `top`) of the picture
/// - which is mirrored about the axes said - as a plane: its address and
/// rows left for the caller; null where none of it is on the glass.
pub fn placeOf(left: i32, top: i32, width: u32, height: u32, glass_width: u32, glass_height: u32, mirror_x: bool, mirror_y: bool) ?Place {
    const across = axisOf(left, width, glass_width, mirror_x) orelse return null;
    const down = axisOf(top, height, glass_height, mirror_y) orelse return null;
    return .{
        .view_x = across.view,
        .view_y = down.view,
        .width = across.size,
        .height = down.size,
        .out_x = across.out,
        .out_y = down.out,
        .mirror_x = mirror_x,
        .mirror_y = mirror_y,
    };
}

/// One axis of `placeOf`: the part of the surface on the glass - from
/// `view`, `size` long - and where it goes; mirrored, the surface runs
/// the other way from the glass's far side.
fn axisOf(start: i32, size: u32, length: u32, mirrored: bool) ?struct { view: u32, size: u32, out: u32 } {
    const first: i64 = @max(-@as(i64, start), 0);
    const end: i64 = @min(@as(i64, size), @as(i64, length) - start);
    if (end <= first) return null;
    const seen: u32 = @intCast(end - first);
    const out: i64 = if (mirrored) @as(i64, length) - start - end else start + first;
    return .{ .view = @intCast(first), .size = seen, .out = @intCast(out) };
}

// --- the writes --------------------------------------------------------------------------

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

fn blended(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.blender) + offset) * 4);
}

/// Whether planes can be lit on this engine: its blender is reached.
pub fn reached(engine: dcn.Engine) bool {
    return engine.blender != 0;
}

/// The timing generator `pipe`'s update locked: what is written to the
/// pipes it drives meanwhile is taken at one update once it is unlocked.
pub fn lock(engine: dcn.Engine, pipe: u32) void {
    const control = at(engine, otg_global_control2 + pipe * otg_stride);
    control.* = (control.* & ~lock_select_mask) | (pipe << lock_select_shift);
    const held = at(engine, otg_lock + pipe * otg_stride);
    held.* = lock_set;
    const deadline = engine.sys.UptimeUs() + lock_wait_us;
    while (held.* & lock_held == 0 and engine.sys.UptimeUs() < deadline) {}
}

pub fn unlock(engine: dcn.Engine, pipe: u32) void {
    at(engine, otg_lock + pipe * otg_stride).* = 0;
}

/// Pipe `index` lit as a plane over output `output`'s picture, driven by
/// timing generator `pipe`, at `place` with `schedule`, the picture
/// `picture_size` (width low) and its fetcher `picture`'s requests and
/// scaler copied: false where the hub has not applied the plane's share
/// of its buffer 30 ms after, and the caller takes it down again.
pub fn light(engine: dcn.Engine, index: u32, pipe: u32, output: u32, picture: u32, picture_size: u32, schedule: *const mode.Schedule, where: *const Place) bool {
    prepare(engine, index, picture);
    lock(engine, pipe);
    lit(engine, index, pipe, output, picture, picture_size, schedule, where, .per_pixel);
    unlock(engine, pipe);
    return settled(engine, index, picture);
}

/// How a plane is laid over what is below it: by its pixels' alpha, put
/// at the top of the tree as it is lit; or whole, by its global alpha,
/// put in the tree by the caller (`stack`).
pub const Blend = enum { per_pixel, whole };

/// The first part of lighting pipe `index`: its fetcher's and its
/// scaler's clocks, and its share of the hub's buffer, as the picture's
/// fetcher `picture` has - which the hub applies once the fetcher runs.
/// Not under the lock.
pub fn prepare(engine: dcn.Engine, index: u32, picture: u32) void {
    const hubp = index * hubp_stride;
    const dpp = index * dpp_stride;
    at(engine, hubp + hubp_clocks).* |= hubp_clock_on;
    at(engine, hubp + hubp_debug).* = debug_lit;
    at(engine, dpp + dpp_control).* |= dpp_clock_on;
    const share = at(engine, det_control + picture).* & det_mask;
    const det = at(engine, det_control + index);
    det.* = (det.* & ~det_mask) | share;
}

/// The last part, once the lock is let go: whether the share was
/// applied within 30 ms, as the vendor waits for it before the hub's
/// compressed buffer may grow. False: the caller takes the plane down.
pub fn settled(engine: dcn.Engine, index: u32, picture: u32) bool {
    const share = at(engine, det_control + picture).* & det_mask;
    const det = at(engine, det_control + index);
    const deadline = engine.sys.UptimeUs() + det_wait_us;
    while ((det.* >> det_current_shift) & det_mask != share) {
        if (engine.sys.UptimeUs() >= deadline) return false;
        dcn.pause(engine.sys, 100);
    }
    return true;
}

/// `light`'s writes under the timing generator's lock: pipe `index` a
/// plane of output `output`, laid as `blend` says.
pub fn lit(engine: dcn.Engine, index: u32, pipe: u32, output: u32, picture: u32, picture_size: u32, schedule: *const mode.Schedule, where: *const Place, blend: Blend) void {
    const hubp = index * hubp_stride;
    const dpp = index * dpp_stride;
    const own_hubp = picture * hubp_stride;
    const own_dpp = picture * dpp_stride;
    // The fetcher: tied to the timing generator, as ready as the
    // picture's, its requests as the picture's fetcher's, its schedule,
    // its surface.
    const control = at(engine, hubp + hubp_control);
    const own_ready = at(engine, own_hubp + hubp_control).* & ready_after_sync;
    control.* = (control.* & ~(vtg_mask | ready_after_sync)) | (pipe << vtg_shift) | own_ready;
    at(engine, hubp + hubp_request_size).* = at(engine, own_hubp + hubp_request_size).*;
    mode.writeSchedule(engine, index, schedule);
    at(engine, hubp + hubp_tiling).* = at(engine, own_hubp + hubp_tiling).*;
    const config = at(engine, hubp + hubp_surface_config);
    config.* = (config.* & ~format_mask) | format_argb8888;
    const flip = at(engine, hubp + hubp_flip_control);
    flip.* &= ~(flip_now | update_lock);
    // One plane: none of the hub's buffer kept for a colour plane, as a
    // film's plane on this pipe had.
    const back = at(engine, hubp + hubp_return);
    back.* &= ~plane1_mask;
    writePlace(engine, index, where);

    // The scaler: the picture's colours with their alpha, passed through
    // into the plane's place - no keyer and no colour matrix after the
    // scaler, which a film's plane on this pipe had.
    at(engine, dpp + cnvc_format).* = format_argb8888;
    at(engine, dpp + cnvc_control).* = at(engine, own_dpp + cnvc_control).* | cnvc_alpha;
    at(engine, dpp + keyer_control).* = 0;
    at(engine, dpp + cm_post_csc).* = 0;
    at(engine, dpp + dscl_autocal).* = 0;
    at(engine, dpp + dscl_control).* = 0;
    at(engine, dpp + dscl_h_blank).* = at(engine, own_dpp + dscl_h_blank).*;
    at(engine, dpp + dscl_v_blank).* = at(engine, own_dpp + dscl_v_blank).*;
    at(engine, dpp + dscl_mpc_size).* = picture_size;
    at(engine, dpp + lb_data_format).* = lb_alpha;
    at(engine, dpp + lb_memory).* = lb_partitions;
    at(engine, dpp + cm_control).* = at(engine, own_dpp + cm_control).*;

    // Its stage at the top of the output's tree, or right above the one
    // named.
    const stage = index * mpcc_stride;
    const mux = blended(engine, mpc_out_mux + output * mpc_out_stride);
    blended(engine, stage + mpcc_top).* = index;
    blended(engine, stage + mpcc_output).* = output;
    blended(engine, stage + mpcc_lock_select).* = output;
    const how = switch (blend) {
        .per_pixel => blend_per_pixel,
        .whole => blend_global,
    };
    blended(engine, stage + mpcc_control).* = top_bottom_blending | how | alpha_premultiplied | background_12_bits | global_alpha_whole | global_gain_whole;
    blended(engine, stage + mpcc_top_gain).* = gain_whole;
    blended(engine, stage + mpcc_bottom_inside).* = gain_whole;
    blended(engine, stage + mpcc_bottom_outside).* = gain_whole;
    if (blend == .per_pixel) {
        blended(engine, stage + mpcc_bottom).* = mux.* & mux_mask;
        mux.* = (mux.* & ~mux_mask) | index;
    }

    control.* &= ~hubp_blank;
}

/// Output `output`'s tree written whole, from the top down: the stage
/// `over` where there is one - the overlay's plane - then `stages` in
/// order, then `under`, the picture's, at its bottom. The timing
/// generator's update is locked.
pub fn stack(engine: dcn.Engine, output: u32, over: ?u32, stages: []const u32, under: u32) void {
    var below = under;
    var left = stages.len;
    while (left > 0) {
        left -= 1;
        blended(engine, stages[left] * mpcc_stride + mpcc_bottom).* = below;
        below = stages[left];
    }
    const mux = blended(engine, mpc_out_mux + output * mpc_out_stride);
    if (over) |top| {
        blended(engine, top * mpcc_stride + mpcc_bottom).* = below;
        below = top;
    }
    mux.* = (mux.* & ~mux_mask) | below;
}

/// The stage of output `output`'s tree whose bottom is `stage`; null
/// where it is the top, or in no tree.
fn aboveOf(engine: dcn.Engine, output: u32, stage: u32) ?u32 {
    var above = blended(engine, mpc_out_mux + output * mpc_out_stride).* & mux_mask;
    var steps: u32 = 0;
    while (above != none and steps < 4) : (steps += 1) {
        const next = blended(engine, above * mpcc_stride + mpcc_bottom).* & mux_mask;
        if (next == stage) return above;
        above = next;
    }
    return null;
}

/// Plane `index` moved: what it reads and where it goes, with its
/// schedule for its width, taken at the pipe's next update.
pub fn move(engine: dcn.Engine, index: u32, pipe: u32, schedule: *const mode.Schedule, where: *const Place) void {
    lock(engine, pipe);
    defer unlock(engine, pipe);
    mode.writeSchedule(engine, index, schedule);
    writePlace(engine, index, where);
}

/// The fetcher's viewport, turn, rows and address, and the scaler's
/// place on the picture. The timing generator's update is locked.
pub fn writePlace(engine: dcn.Engine, index: u32, where: *const Place) void {
    const hubp = index * hubp_stride;
    const dpp = index * dpp_stride;
    const start = where.view_x | where.view_y << 16;
    const size = where.width | where.height << 16;
    at(engine, hubp + hubp_viewport_start).* = start;
    at(engine, hubp + hubp_viewport).* = size;
    at(engine, hubp + hubp_second_viewport_start).* = start;
    at(engine, hubp + hubp_second_viewport).* = size;
    mode.writeTurn(engine, index, where.mirror_x, where.mirror_y);
    const pitch = at(engine, hubp + hubp_pitch);
    pitch.* = (pitch.* & ~pitch_mask) | ((where.pitch - 1) & pitch_mask);
    sdk.hardware.barrier.full();
    at(engine, hubp + hubp_address_high).* = @truncate(where.address >> 32 & address_high_mask);
    at(engine, hubp + hubp_address).* = @truncate(where.address);
    at(engine, dpp + dscl_recout_start).* = where.out_x | where.out_y << 16;
    if (where.scale) |scale| {
        at(engine, dpp + dscl_recout_size).* = scale.out_width | scale.out_height << 16;
    } else {
        at(engine, dpp + dscl_recout_size).* = size;
    }
    writeScale(engine, index, where.scale);
}

/// The scaler of pipe `index` scaling as `scale` says - one tap each way,
/// luma and chroma alike, no filter of two taps, nothing replicated - or
/// in its bypass for null. The timing generator's update is locked.
fn writeScale(engine: dcn.Engine, index: u32, scale: ?Scale) void {
    const dpp = index * dpp_stride;
    const scaling = at(engine, dpp + scl_mode);
    const how = scale orelse {
        scaling.* &= ~(scl_mode_mask | chroma_coef);
        return;
    };
    at(engine, dpp + scl_tap_control).* = 0;
    at(engine, dpp + scl_2tap_control).* = 0;
    at(engine, dpp + scl_replicate).* = 0;
    for ([_]u32{ scl_h_ratio, scl_h_ratio_c, scl_v_ratio, scl_v_ratio_c }) |ratio| at(engine, dpp + ratio).* = how.ratio;
    at(engine, dpp + scl_h_init).* = how.init_x;
    at(engine, dpp + scl_h_init_c).* = how.init_x;
    at(engine, dpp + scl_v_init).* = how.init_y;
    at(engine, dpp + scl_v_init_c).* = how.init_y;
    // A field's second, one ratio on: the vendor's, unused by a picture
    // not interlaced.
    at(engine, dpp + scl_v_init_bottom).* = how.init_y + how.ratio;
    at(engine, dpp + scl_v_init_bottom_c).* = how.init_y + how.ratio;
    scaling.* = (scaling.* & ~(scl_mode_mask | chroma_coef)) | scaling_rgb;
}

/// Plane `index` taken down: out of output `output`'s tree at the pipe's
/// next update, and once its stage is idle the fetcher blanked, its and
/// the scaler's clocks off and its share of the hub's buffer given back.
pub fn darken(engine: dcn.Engine, index: u32, pipe: u32, output: u32) void {
    {
        lock(engine, pipe);
        defer unlock(engine, pipe);
        unlink(engine, index, output);
    }
    shut(engine, index);
}

/// The first part of taking plane `index` down, under the timing
/// generator's lock: its stage out of output `output`'s tree, the stage
/// above it - or the output - blending what it blended over.
pub fn unlink(engine: dcn.Engine, index: u32, output: u32) void {
    const below = blended(engine, index * mpcc_stride + mpcc_bottom).* & mux_mask;
    const mux = blended(engine, mpc_out_mux + output * mpc_out_stride);
    if (mux.* & mux_mask == index) {
        mux.* = (mux.* & ~mux_mask) | below;
    } else if (aboveOf(engine, output, index)) |over| {
        const select = blended(engine, over * mpcc_stride + mpcc_bottom);
        select.* = (select.* & ~mux_mask) | below;
    }
    release(engine, index);
}

/// Stage `index` in no tree: its scaler, the stage below, its output and
/// the output it waits for none - what is left of taking it out once the
/// tree no longer holds it (`stack`). The timing generator's update is
/// locked.
pub fn release(engine: dcn.Engine, index: u32) void {
    const stage = index * mpcc_stride;
    blended(engine, stage + mpcc_top).* = none;
    blended(engine, stage + mpcc_bottom).* = none;
    blended(engine, stage + mpcc_output).* = none;
    blended(engine, stage + mpcc_lock_select).* = none;
}

/// The last part, once the lock is let go: waited for until its stage is
/// idle, the fetcher blanked, its and the scaler's clocks off and its
/// share of the hub's buffer given back.
pub fn shut(engine: dcn.Engine, index: u32) void {
    const stage = index * mpcc_stride;
    const deadline = engine.sys.UptimeUs() + idle_wait_us;
    while (blended(engine, stage + mpcc_status).* & mpcc_idle == 0 and engine.sys.UptimeUs() < deadline) dcn.pause(engine.sys, 100);
    const hubp = index * hubp_stride;
    at(engine, hubp + hubp_control).* |= hubp_blank;
    at(engine, hubp + hubp_clocks).* &= ~hubp_clock_on;
    at(engine, index * dpp_stride + dpp_control).* &= ~dpp_clock_on;
    at(engine, det_control + index).* &= ~det_mask;
}

/// Whether plane `index` has taken the address it was last given: none
/// is pending at its next update.
pub fn taken(engine: dcn.Engine, index: u32) bool {
    return at(engine, index * hubp_stride + hubp_flip_control).* & flip_pending == 0;
}

/// Whether pipe `index` is free for a plane: its blender stage in no
/// tree and its fetcher blanked.
pub fn isFree(engine: dcn.Engine, index: u32) bool {
    if (blended(engine, index * mpcc_stride + mpcc_top).* & mux_mask != none) return false;
    return at(engine, index * hubp_stride + hubp_control).* & hubp_blank != 0;
}

// --- a film's frame ------------------------------------------------------------------

/// The fetcher's for a picture's second plane - a film's colour - and for
/// what it reads of both: the colour's viewports, the size of its
/// requests, its rows' length and its address; how the fetcher expands
/// its requests; and where the colour's part of its share of the hub's
/// buffer starts, in KiB (DET_BUF_PLANE1_BASE_ADDRESS). A stride apart
/// per pipe.
const hubp_viewport_start_c = 0x05eb;
const hubp_viewport_c = 0x05ec;
const hubp_second_viewport_start_c = 0x05ef;
const hubp_second_viewport_c = 0x05f0;
const hubp_request_size_c = 0x05f2;
const hubp_pitch_c = 0x0608;
const hubp_address_c = 0x060c;
const hubp_address_high_c = 0x060d;
const hubp_expansion = 0x0629;
const hubp_return = 0x066c;
const plane1_shift = 4;
const plane1_mask: u32 = 0x1ff << plane1_shift;
/// A segment of the hub's buffer, in KiB.
const det_segment_kib: u32 = 64;
/// A film's surface - 4:2:0 YCbCr, the colour's samples in pairs, Cb
/// first - in the fetcher's code and the converter's alike: 64, the
/// code the engine reads Cb first by; 65 reads Cr first.
const format_nv12: u32 = 64;

/// The converter's for a film: its samples expanded with zeros below, a
/// sample a fraction of 256 as the colour matrices take it; an alpha of
/// its own, whole; the samples to the channels in order
/// (dpp3_cnv_setup). Its alpha neither divided out nor in again.
const cnvc_film: u32 = 0x2400_0101;
const cnvc_dealpha = 0x0cde;
const cnvc_realpha = 0x0cee;

/// The colour keyer: on, and how it takes the colours it keys; and the
/// range of each channel it keys, the least in the low half of its
/// register and the most in the high.
const keyer_control = 0x0cd7;
const keyer_alpha = 0x0cd8;
const keyer_red = 0x0cd9;
const keyer_green = 0x0cda;
const keyer_blue = 0x0cdb;
const keyer_on: u32 = 1 << 0;
const keyer_mode_shift = 4;
const keyer_any_alpha: u32 = 0xffff << 16;

/// The scaler's filters: where in its coefficients a write goes - the
/// filter, from its first phase and pair on - and two of a phase's
/// weights written, each in 14 bits with its write bit; in its mode, the
/// set of coefficients it reads from the next update on, the one it
/// reads now, and that the colour has filters of its own; each way's
/// filter of two taps the scaler's own (dpp1_dscl_set_scl_filter).
const scl_coef_select = 0x0cf9;
const scl_coef_data = 0x0cfa;
const coef_filter_shift = 16;
const coef_weight_mask: u32 = 0x3fff;
const coef_even_on: u32 = 1 << 15;
const coef_odd_shift = 16;
const coef_odd_on: u32 = 1 << 31;
const coef_select: u32 = 1 << 8;
const coef_current: u32 = 1 << 12;
const chroma_coef: u32 = 1 << 16;
const two_taps_across: u32 = 1 << 0;
const two_taps_down: u32 = 1 << 16;
/// The filters as the coefficients name them (SCL_COEF_*_FILTER).
const filter_luma_down: u32 = 0;
const filter_luma_across: u32 = 1;
const filter_chroma_down: u32 = 2;
const filter_chroma_across: u32 = 3;
/// The power of the scaler's coefficients' memory: forced, and as it is;
/// how long it is waited for once on (dpp1_power_on_dscl).
const dscl_power = 0x0d17;
const dscl_power_state = 0x0d18;
const lut_power_mask: u32 = 0x3;
const lut_wait_us: u64 = 5;
/// The line buffer's layout for 4:2:0 pictures (LB_MEMORY_CONFIG_3).
const lb_config_420: u32 = 3;
/// A ratio's or an init's 19 bits of a pixel moved into the scaler's 24.
const scale_shift = scale_bits - video.fraction_bits;

/// The colour matrix after the scaler (CM_POST_CSC): which of its two
/// sets it reads from the next update on - none for 0 - and, above, the
/// one it reads now; each set's six words, two weights to a word.
const cm_post_csc = 0x0d21;
const cm_post_csc_a = 0x0d22;
const cm_post_csc_b = 0x0d28;
const csc_words = 6;
const csc_mode_mask: u32 = 0x3;
const csc_current_shift = 2;
const csc_set_a: u32 = 1;
const csc_set_b: u32 = 2;

/// A stage that shows its scaler's pixels alone, at the bottom of a tree
/// (MPCC_BLEND_MODE_TOP_LAYER_PASSTHROUGH).
const top_layer_passthrough: u32 = 1;

/// A film's frame as a plane: the device's addresses of its brightness
/// and of its colour, each on 256 bytes, and how many of the plane's
/// elements - pixels, pairs of colour samples - lie there before the
/// frame's first column; each plane's rows' length in its elements; what
/// its scaler is told (`video.scalingOf`); and the picture's turn, which
/// the plane takes too.
pub const Film = struct {
    luma: u64,
    chroma: u64,
    luma_x: u32 = 0,
    chroma_x: u32 = 0,
    luma_pitch: u32,
    chroma_pitch: u32,
    scaling: video.Scaling,
    mirror_x: bool = false,
    mirror_y: bool = false,
};

/// Where a film's plane lies: under the picture, seen where the picture's
/// keyer takes its colours to nothing, or over it.
pub const Layer = enum { under, over };

/// The colours the picture's keyer takes to nothing - each channel's
/// least and most, as the keyer reads it - and its mode.
pub const Key = struct {
    red: [2]u16,
    green: [2]u16,
    blue: [2]u16,
    mode: u32,
};

/// What the picture's converter and stage were before a film under it
/// was seen through it (`keyPicture`), which `unkeyPicture` puts back.
pub const Unkeyed = struct {
    keyer: u32 = 0,
    line_buffer: u32 = 0,
    control: u32 = 0,
};

/// Pipe `index` lit with a film's frame `film` on output `output`'s
/// picture, driven by timing generator `pipe`, as `layer` says - under
/// the picture, seen where the picture's keyer takes the colours `key`
/// names to nothing, `was` then holding what `unkeyPicture` puts back -
/// with `schedule`, its colours made by `matrix`, and `loaded` the filters
/// its scaler holds from then on. The picture's fetcher `picture` has its
/// requests and its share of the hub's buffer copied, the picture is
/// `picture_size` (width low). False, as `light`, where the hub gives the
/// plane no share of its buffer, and the caller takes it down.
pub fn lightFilm(engine: dcn.Engine, index: u32, pipe: u32, output: u32, picture: u32, picture_size: u32, schedule: *const mode.Schedule, film: *const Film, matrix: *const [12]u16, loaded: *?video.Filters, layer: Layer, key: *const Key, was: *Unkeyed) bool {
    prepare(engine, index, picture);
    loaded.* = null;
    lock(engine, pipe);
    litFilm(engine, index, pipe, picture, picture_size, schedule, film, matrix, loaded);
    stageFilm(engine, index, output, picture, layer);
    if (layer == .under) was.* = keyPicture(engine, picture, index, key);
    unlock(engine, pipe);
    return settled(engine, index, picture);
}

/// `lightFilm`'s writes to pipe `index`'s fetcher and scaler, under the
/// timing generator's lock.
fn litFilm(engine: dcn.Engine, index: u32, pipe: u32, picture: u32, picture_size: u32, schedule: *const mode.Schedule, film: *const Film, matrix: *const [12]u16, loaded: *?video.Filters) void {
    const hubp = index * hubp_stride;
    const dpp = index * dpp_stride;
    const own_hubp = picture * hubp_stride;
    const own_dpp = picture * dpp_stride;
    // The fetcher: tied to the timing generator, as ready as the
    // picture's, both planes' requests sized and expanded as the
    // picture's, half its share of the hub's buffer the colour's - the
    // vendor's split where a swath of the brightness is no more than half
    // again one of the colour, as a linear frame's is (extract_rq_regs) -
    // its schedule and its surface.
    const control = at(engine, hubp + hubp_control);
    const own_ready = at(engine, own_hubp + hubp_control).* & ready_after_sync;
    control.* = (control.* & ~(vtg_mask | ready_after_sync)) | (pipe << vtg_shift) | own_ready;
    const requests = at(engine, own_hubp + hubp_request_size).*;
    at(engine, hubp + hubp_request_size).* = requests;
    at(engine, hubp + hubp_request_size_c).* = requests;
    at(engine, hubp + hubp_expansion).* = at(engine, own_hubp + hubp_expansion).*;
    const share = at(engine, det_control + picture).* & det_mask;
    const back = at(engine, hubp + hubp_return);
    back.* = (back.* & ~plane1_mask) | ((share * det_segment_kib / 2) << plane1_shift & plane1_mask);
    mode.writeSchedule(engine, index, schedule);
    at(engine, hubp + hubp_tiling).* = at(engine, own_hubp + hubp_tiling).*;
    const config = at(engine, hubp + hubp_surface_config);
    config.* = (config.* & ~format_mask) | format_nv12;
    const flip = at(engine, hubp + hubp_flip_control);
    flip.* &= ~(flip_now | update_lock);
    cursor.off(engine, index);

    // The converter: the samples as they are, with no keyer; the colour
    // matrix after the scaler making red, green and blue of them.
    at(engine, dpp + cnvc_format).* = format_nv12;
    at(engine, dpp + cnvc_control).* = cnvc_film;
    at(engine, dpp + cnvc_dealpha).* = 0;
    at(engine, dpp + cnvc_realpha).* = 0;
    at(engine, dpp + keyer_control).* = 0;
    at(engine, dpp + dscl_h_blank).* = at(engine, own_dpp + dscl_h_blank).*;
    at(engine, dpp + dscl_v_blank).* = at(engine, own_dpp + dscl_v_blank).*;
    at(engine, dpp + dscl_mpc_size).* = picture_size;
    at(engine, dpp + cm_control).* = at(engine, own_dpp + cm_control).*;
    writeMatrix(engine, index, matrix);
    writeFilm(engine, index, film, loaded);
    control.* &= ~hubp_blank;
}

/// A film's stage in output `output`'s tree, laid whole by its global
/// alpha as the vendor lays a plane without alpha of its own: under the
/// picture's stage `picture`, at the bottom, its pixels passed through -
/// the picture's stage blending over it (`keyPicture`) - or right above
/// it, covering what is below where the film lies. Under the timing
/// generator's lock.
fn stageFilm(engine: dcn.Engine, index: u32, output: u32, picture: u32, layer: Layer) void {
    const stage = index * mpcc_stride;
    blended(engine, stage + mpcc_top).* = index;
    blended(engine, stage + mpcc_output).* = output;
    blended(engine, stage + mpcc_lock_select).* = output;
    blended(engine, stage + mpcc_top_gain).* = gain_whole;
    blended(engine, stage + mpcc_bottom_inside).* = gain_whole;
    blended(engine, stage + mpcc_bottom_outside).* = gain_whole;
    const whole = background_12_bits | global_alpha_whole | global_gain_whole;
    switch (layer) {
        .under => {
            blended(engine, stage + mpcc_control).* = top_layer_passthrough | blend_global | whole;
            blended(engine, stage + mpcc_bottom).* = none;
        },
        .over => {
            blended(engine, stage + mpcc_control).* = top_bottom_blending | blend_global | whole;
            blended(engine, stage + mpcc_bottom).* = picture;
            if (aboveOf(engine, output, picture)) |over| {
                const select = blended(engine, over * mpcc_stride + mpcc_bottom);
                select.* = (select.* & ~mux_mask) | index;
            } else {
                const mux = blended(engine, mpc_out_mux + output * mpc_out_stride);
                mux.* = (mux.* & ~mux_mask) | index;
            }
        },
    }
}

/// The picture's stage `picture` blending its pixels over the film's
/// stage `film` below it, each by its own alpha and not premultiplied -
/// so that a pixel whose alpha the keyer takes to nothing shows the film
/// alone, and the key colour is not added to it - its keyer on for the
/// colours `key` names and its line buffer keeping the alpha. What was
/// there is answered, for `unkeyPicture`. Under the timing generator's
/// lock.
pub fn keyPicture(engine: dcn.Engine, picture: u32, film: u32, key: *const Key) Unkeyed {
    const dpp = picture * dpp_stride;
    const stage = picture * mpcc_stride;
    const was: Unkeyed = .{
        .keyer = at(engine, dpp + keyer_control).*,
        .line_buffer = at(engine, dpp + lb_data_format).*,
        .control = blended(engine, stage + mpcc_control).*,
    };
    at(engine, dpp + keyer_alpha).* = keyer_any_alpha;
    at(engine, dpp + keyer_red).* = rangeOf(key.red);
    at(engine, dpp + keyer_green).* = rangeOf(key.green);
    at(engine, dpp + keyer_blue).* = rangeOf(key.blue);
    at(engine, dpp + keyer_control).* = keyer_on | key.mode << keyer_mode_shift;
    at(engine, dpp + lb_data_format).* = was.line_buffer | lb_alpha;
    blended(engine, stage + mpcc_control).* = top_bottom_blending | blend_per_pixel | background_12_bits | global_alpha_whole | global_gain_whole;
    blended(engine, stage + mpcc_bottom).* = film;
    return was;
}

fn rangeOf(range: [2]u16) u32 {
    return range[0] | @as(u32, range[1]) << 16;
}

/// The picture's converter and stage `picture` as `was` had them, the
/// stage below it none. Under the timing generator's lock.
pub fn unkeyPicture(engine: dcn.Engine, picture: u32, was: Unkeyed) void {
    const dpp = picture * dpp_stride;
    const stage = picture * mpcc_stride;
    at(engine, dpp + keyer_control).* = was.keyer;
    at(engine, dpp + lb_data_format).* = was.line_buffer;
    blended(engine, stage + mpcc_control).* = was.control;
    blended(engine, stage + mpcc_bottom).* = none;
}

/// Plane `index` showing `film` anew - another frame, place or scaling -
/// with `schedule`, and its colours made by `matrix` where it is not
/// null, all of it taken at the pipe's next update.
pub fn moveFilm(engine: dcn.Engine, index: u32, pipe: u32, schedule: *const mode.Schedule, film: *const Film, matrix: ?*const [12]u16, loaded: *?video.Filters) void {
    lock(engine, pipe);
    defer unlock(engine, pipe);
    mode.writeSchedule(engine, index, schedule);
    if (matrix) |weights| writeMatrix(engine, index, weights);
    writeFilm(engine, index, film, loaded);
}

/// A film's plane `index` taken down: out of output `output`'s tree at
/// the pipe's next update - the picture `picture` as `was` had it, where
/// the film was under it - and once its stage is idle the pipe shut
/// (`shut`).
pub fn darkenFilm(engine: dcn.Engine, index: u32, pipe: u32, output: u32, picture: u32, layer: Layer, was: Unkeyed) void {
    {
        lock(engine, pipe);
        defer unlock(engine, pipe);
        switch (layer) {
            .under => {
                unkeyPicture(engine, picture, was);
                release(engine, index);
            },
            .over => unlink(engine, index, output),
        }
    }
    shut(engine, index);
}

/// The fetcher's viewports, turn, rows and addresses for `film`, and its
/// scaler's place on the picture and its scaling. Under the timing
/// generator's lock.
fn writeFilm(engine: dcn.Engine, index: u32, film: *const Film, loaded: *?video.Filters) void {
    const hubp = index * hubp_stride;
    const dpp = index * dpp_stride;
    const scaling = &film.scaling;
    const across = scaling.across;
    const down = scaling.down;
    const start = (film.luma_x + across.start) | down.start << 16;
    const size = across.size | down.size << 16;
    const start_c = (film.chroma_x + across.start_c) | down.start_c << 16;
    const size_c = across.size_c | down.size_c << 16;
    at(engine, hubp + hubp_viewport_start).* = start;
    at(engine, hubp + hubp_viewport).* = size;
    at(engine, hubp + hubp_second_viewport_start).* = start;
    at(engine, hubp + hubp_second_viewport).* = size;
    at(engine, hubp + hubp_viewport_start_c).* = start_c;
    at(engine, hubp + hubp_viewport_c).* = size_c;
    at(engine, hubp + hubp_second_viewport_start_c).* = start_c;
    at(engine, hubp + hubp_second_viewport_c).* = size_c;
    mode.writeTurn(engine, index, film.mirror_x, film.mirror_y);
    const pitch = at(engine, hubp + hubp_pitch);
    pitch.* = (pitch.* & ~pitch_mask) | ((film.luma_pitch - 1) & pitch_mask);
    const pitch_c = at(engine, hubp + hubp_pitch_c);
    pitch_c.* = (pitch_c.* & ~pitch_mask) | ((film.chroma_pitch - 1) & pitch_mask);
    sdk.hardware.barrier.full();
    // The colour's address before the brightness's, by which the fetcher
    // takes both (hubp2_program_surface_flip_and_addr).
    at(engine, hubp + hubp_address_high_c).* = @truncate(film.chroma >> 32 & address_high_mask);
    at(engine, hubp + hubp_address_c).* = @truncate(film.chroma);
    at(engine, hubp + hubp_address_high).* = @truncate(film.luma >> 32 & address_high_mask);
    at(engine, hubp + hubp_address).* = @truncate(film.luma);
    at(engine, dpp + dscl_recout_start).* = scaling.out_x | scaling.out_y << 16;
    at(engine, dpp + dscl_recout_size).* = scaling.out_width | scaling.out_height << 16;
    writeFilmScale(engine, index, scaling, loaded);
}

/// The scaler of pipe `index` scaling a 4:2:0 picture as `scaling` says
/// (dpp1_dscl_set_scaler_manual_scale): its coefficients' memory on, no
/// self-calibration and the edge pixels repeated, its mode, the line
/// buffer in its 4:2:0 layout without alpha, each plane's ratios, inits
/// and taps, and the filters those take (`writeFilters`). Under the
/// timing generator's lock.
fn writeFilmScale(engine: dcn.Engine, index: u32, scaling: *const video.Scaling, loaded: *?video.Filters) void {
    const dpp = index * dpp_stride;
    const power = at(engine, dpp + dscl_power);
    power.* &= ~lut_power_mask;
    const deadline = engine.sys.UptimeUs() + lut_wait_us;
    while (at(engine, dpp + dscl_power_state).* & lut_power_mask != 0 and engine.sys.UptimeUs() < deadline) {}
    at(engine, dpp + dscl_autocal).* = 0;
    at(engine, dpp + dscl_control).* = 0;
    const scaler_mode = at(engine, dpp + scl_mode);
    scaler_mode.* = (scaler_mode.* & ~scl_mode_mask) | scaling.mode;
    at(engine, dpp + lb_data_format).* = 0;
    at(engine, dpp + lb_memory).* = lb_config_420 | lb_partitions;
    if (scaling.mode == video.mode_bypass) return;
    const across = scaling.across;
    const down = scaling.down;
    at(engine, dpp + scl_h_ratio).* = across.ratio << scale_shift;
    at(engine, dpp + scl_h_ratio_c).* = across.ratio_c << scale_shift;
    at(engine, dpp + scl_v_ratio).* = down.ratio << scale_shift;
    at(engine, dpp + scl_v_ratio_c).* = down.ratio_c << scale_shift;
    at(engine, dpp + scl_h_init).* = across.init << scale_shift;
    at(engine, dpp + scl_h_init_c).* = across.init_c << scale_shift;
    at(engine, dpp + scl_v_init).* = down.init << scale_shift;
    at(engine, dpp + scl_v_init_c).* = down.init_c << scale_shift;
    // A field's second, a ratio on: the vendor's, unused by a picture not
    // interlaced.
    at(engine, dpp + scl_v_init_bottom).* = (down.init + down.ratio) << scale_shift;
    at(engine, dpp + scl_v_init_bottom_c).* = (down.init_c + down.ratio_c) << scale_shift;
    at(engine, dpp + scl_tap_control).* = (down.taps - 1) | (across.taps - 1) << 4 | (down.taps_c - 1) << 8 | (across.taps_c - 1) << 12;
    at(engine, dpp + scl_replicate).* = 0;
    writeFilters(engine, index, scaling, loaded);
}

/// The filters `scaling` takes: a way of two taps for both planes on the
/// scaler's own; the others loaded into the set of coefficients the
/// scaler does not read now, and switched to at the next update with the
/// colour's own filters - where one of them is not what it holds
/// (`loaded`), as the vendor loads them (dpp1_dscl_set_scl_filter).
fn writeFilters(engine: dcn.Engine, index: u32, scaling: *const video.Scaling, loaded: *?video.Filters) void {
    const dpp = index * dpp_stride;
    const wanted = video.filtersOf(scaling.*);
    at(engine, dpp + scl_2tap_control).* = (if (wanted.two_taps_across) two_taps_across else 0) | (if (wanted.two_taps_down) two_taps_down else 0);
    if (wanted.two_taps_across and wanted.two_taps_down) return;
    if (!wanted.updates(loaded.*)) return;
    const scaler_mode = at(engine, dpp + scl_mode);
    const reading = scaler_mode.*;
    if (!wanted.two_taps_across) {
        if (wanted.luma_across) |table| loadFilter(engine, dpp, filter_luma_across, scaling.across.taps, table);
        if (wanted.chroma_across) |table| loadFilter(engine, dpp, filter_chroma_across, scaling.across.taps_c, table);
    }
    if (!wanted.two_taps_down) {
        if (wanted.luma_down) |table| loadFilter(engine, dpp, filter_luma_down, scaling.down.taps, table);
        if (wanted.chroma_down) |table| loadFilter(engine, dpp, filter_chroma_down, scaling.down.taps_c, table);
    }
    const other: u32 = if (reading & coef_current != 0) 0 else coef_select;
    scaler_mode.* = (reading & ~(coef_select | chroma_coef)) | other | chroma_coef;
    loaded.* = wanted;
}

/// Filter `filter`'s weights for `taps` taps loaded from `table`, phase
/// after phase, each phase's in pairs - the second of the last pair 0
/// where the taps are odd (dpp1_dscl_set_scaler_filter); where in the
/// coefficients goes on by itself from the first.
fn loadFilter(engine: dcn.Engine, dpp: u32, filter: u32, taps: u32, table: []const u16) void {
    at(engine, dpp + scl_coef_select).* = filter << coef_filter_shift;
    const data = at(engine, dpp + scl_coef_data);
    const pairs = (taps + 1) / 2;
    for (0..coefficients.phases) |phase| {
        for (0..pairs) |pair| {
            const first = phase * taps + 2 * pair;
            const even: u32 = table[first] & coef_weight_mask;
            const odd: u32 = if (2 * pair + 1 < taps) table[first + 1] & coef_weight_mask else 0;
            data.* = even | coef_even_on | odd << coef_odd_shift | coef_odd_on;
        }
    }
}

/// The colour matrix after pipe `index`'s scaler made `matrix`
/// (`coefficients.matrixOf`): written into the set it does not read now
/// and switched to at the pipe's next update (dpp3_program_post_csc).
/// Under the timing generator's lock.
fn writeMatrix(engine: dcn.Engine, index: u32, matrix: *const [12]u16) void {
    const dpp = index * dpp_stride;
    const control = at(engine, dpp + cm_post_csc);
    const reading = (control.* >> csc_current_shift) & csc_mode_mask;
    const set = if (reading != csc_set_a) csc_set_a else csc_set_b;
    const first: u32 = if (set == csc_set_a) cm_post_csc_a else cm_post_csc_b;
    for (0..csc_words) |word| {
        at(engine, dpp + first + @as(u32, @intCast(word))).* = matrix[2 * word] | @as(u32, matrix[2 * word + 1]) << 16;
    }
    control.* = set;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// The row or column of its input a scaler told `init` and `ratio` reads
/// for its output pixel `out`: where that lies, less one, in whole pixels.
fn scaled(init: u32, ratio: u32, out: u32) u32 {
    return @intCast(((@as(u64, init) + @as(u64, out) * ratio) >> scale_bits) - 1);
}

/// The buffer's row a band shows on line `line` of the picture, as the
/// library composes it, and as its plane reads it - the scaler's rows
/// counted from the viewport's first, the last first on a mirrored axis.
fn rowsAgree(band: Band, glass_height: u32, line: u32) bool {
    const place = band.place;
    const composed = (line - band.origin) / band.times;
    const lines = if (place.scale) |scale| scale.out_height else place.height;
    // Its line on the glass, and how many lines into its place that is.
    const glass = if (place.mirror_y) glass_height - 1 - line else line;
    const into = glass - place.out_y;
    if (into >= lines) return false;
    const read = if (place.scale) |scale| scaled(scale.init_y, scale.ratio, into) else into;
    const row = if (place.mirror_y) place.view_y + place.height - 1 - read else place.view_y + read;
    return row == composed;
}

test "a band's place: unscaled, scaled a whole number of times, mirrored, and none" {
    // A screen pulled down to line 500 over another, the picture 2560 by
    // 1440: its rows from 0 on lines 500 to the bottom.
    const pulled = bandOf(500, 1440, 500, 2560, 1440, 2560, 1440, false, false).?;
    try testing.expectEqual(@as(u32, 0), pulled.place.view_y);
    try testing.expectEqual(@as(u32, 940), pulled.place.height);
    try testing.expectEqual(@as(u32, 500), pulled.place.out_y);
    try testing.expect(pulled.place.scale == null);
    // The screen behind it, its lines above.
    const behind = bandOf(0, 500, 0, 2560, 1440, 2560, 1440, false, true).?;
    try testing.expectEqual(@as(u32, 500), behind.place.height);
    try testing.expectEqual(@as(u32, 940), behind.place.out_y);
    // Scrolled: its row 100 on line 300.
    const scrolled = bandOf(300, 1440, 200, 2560, 1440, 2560, 1440, false, false).?;
    try testing.expectEqual(@as(u32, 100), scrolled.place.view_y);
    try testing.expectEqual(@as(u32, 1140), scrolled.place.height);
    // Its first row below the band's first line: black above.
    const lower = bandOf(600, 1440, 800, 2560, 1440, 2560, 1440, false, false).?;
    try testing.expectEqual(@as(u32, 800), lower.place.out_y);
    try testing.expectEqual(@as(u32, 640), lower.place.height);
    // Rows that end before the band does.
    const short = bandOf(0, 1440, 0, 2560, 400, 2560, 1440, false, false).?;
    try testing.expectEqual(@as(u32, 400), short.place.height);
    // None of it on its lines; a buffer wider than the picture; a ratio
    // no whole number.
    try testing.expect(bandOf(0, 500, 600, 2560, 1440, 2560, 1440, false, false) == null);
    try testing.expect(bandOf(0, 1440, 0, 2600, 1440, 2560, 1440, false, false) == null);
    try testing.expect(bandOf(0, 1440, 0, 1920, 1080, 2560, 1440, false, false) == null);

    // Half as wide, from line 901 with its first row at 900: rows from 0,
    // half a row in, twice the size on the glass.
    const half = bandOf(901, 1440, 900, 1280, 720, 2560, 1440, false, false).?;
    const scale = half.place.scale.?;
    try testing.expectEqual(@as(u32, 1 << 23), scale.ratio);
    try testing.expectEqual(@as(u32, 1 << 24), scale.init_x);
    try testing.expectEqual(@as(u32, 3 << 23), scale.init_y);
    try testing.expectEqual(@as(u32, 2560), scale.out_width);
    try testing.expectEqual(@as(u32, 539), scale.out_height);
    try testing.expectEqual(@as(u32, 1280), half.place.width);
    try testing.expectEqual(@as(u32, 0), half.place.view_y);
    try testing.expectEqual(@as(u32, 270), half.place.height);

    // Each line of each of these the row the library composes, and each
    // column the column, mirrored or not, two, four and five times.
    const cases = [_][5]u32{
        .{ 901, 1440, 900, 1280, 720 },
        .{ 701, 1440, 650, 640, 360 },
        .{ 0, 1439, 3, 640, 50 },
        .{ 2, 1000, 0, 512, 300 },
        .{ 100, 1440, 0, 640, 360 },
    };
    const width: u32 = 2560;
    for (cases) |one| {
        for ([_]bool{ false, true }) |mirrored| {
            const band = bandOf(one[0], one[1], one[2], one[3], one[4], width, 1440, mirrored, mirrored).?;
            var line = @max(one[0], one[2]);
            const lines = if (band.place.scale) |s| s.out_height else band.place.height;
            while (line < @max(one[0], one[2]) + lines) : (line += 1) {
                try testing.expect(rowsAgree(band, 1440, line));
            }
            const across = band.place.scale orelse continue;
            var column: u32 = 0;
            while (column < width) : (column += 1) {
                // The scaler's columns, the last first where mirrored; the
                // composed picture is mirrored on the glass the same way.
                const read = scaled(across.init_x, across.ratio, column);
                const source = if (mirrored) band.place.width - 1 - read else read;
                const glass = if (mirrored) width - 1 - column else column;
                try testing.expectEqual(glass / band.times, source);
            }
        }
    }
}

test "a plane's place: the part on the glass, where it goes, and mirrored" {
    // Whole on the glass.
    const whole = placeOf(100, 50, 160, 120, 2560, 1440, false, false) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Place{ .width = 160, .height = 120, .out_x = 100, .out_y = 50 }, whole);
    // Partly off the top left: the surface read from as far in.
    const corner = placeOf(-10, -20, 160, 120, 2560, 1440, false, false) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Place{ .view_x = 10, .view_y = 20, .width = 150, .height = 100 }, corner);
    // Partly off the bottom right.
    const far = placeOf(2500, 1400, 160, 120, 2560, 1440, false, false) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Place{ .width = 60, .height = 40, .out_x = 2500, .out_y = 1400 }, far);
    // Mirrored left to right: the same part of the surface, its place
    // from the glass's far side - off the picture's left, so off the
    // glass's right.
    const mirrored = placeOf(-10, 50, 160, 120, 2560, 1440, true, false) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Place{ .view_x = 10, .width = 150, .height = 120, .out_x = 2410, .out_y = 50, .mirror_x = true }, mirrored);
    // Both: off the picture's bottom right, so off the glass's top left.
    const turned = placeOf(2500, 1400, 160, 120, 2560, 1440, true, true) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Place{ .width = 60, .height = 40, .mirror_x = true, .mirror_y = true }, turned);
    // Off the glass altogether.
    try testing.expectEqual(@as(?Place, null), placeOf(2560, 0, 160, 120, 2560, 1440, false, false));
    try testing.expectEqual(@as(?Place, null), placeOf(0, -120, 160, 120, 2560, 1440, false, false));
}
