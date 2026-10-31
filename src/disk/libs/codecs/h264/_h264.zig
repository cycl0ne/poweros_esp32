// SPDX-License-Identifier: MIT
//! h264.vcodec's decoder: H.264 decoded in software by the decoder built
//! in as `h264core` (core.zig here), which takes the stream unit by unit
//! and gives its pictures out in the order they are shown.
//!
//! **The setup** - an MP4's avcC, which a Matroska track's CodecPrivate
//! is as well - says how many bytes each unit's length takes in the
//! packets, and holds the parameter sets, which the decoder is given when
//! it opens. A track without a setup has its packets in Annex B form, the
//! parameter sets among them.
//!
//! **A packet sent** is decoded at once, each of its units in turn; the
//! pictures it finishes wait in the decoder until they are asked for, and
//! while one waits another packet is refused (VCERR_FULL). A packet of
//! units after their lengths - an MP4's, a Matroska track's - is an
//! access unit, whose picture is whole at its end. A unit that is not
//! right is passed over: the decoder makes up what it lacked. The end of
//! the track hands out the pictures held back.
//!
//! **The cores**: with more than one, the decoder has a worker task on
//! each, a step below the caller's priority - which gets a core at once
//! to hand over packets and take pictures - and a picture is decoded by
//! a worker while the next packets are taken: as many pictures at once
//! as there are workers, each waiting for the rows of the pictures it
//! refers to. While a worker is free a packet is taken before a picture
//! is handed out, as long as no more pictures wait than there are
//! workers; a picture still being decoded is waited for. Each one waits
//! by a waitable of its own; the workers end with the decoder.
//!
//! **The frames** are each picture copied into the planes of the slot it
//! is lent in, I420 in 8 bits as every frame is: deeper samples are
//! rounded to 8 bits, colour at full height is averaged two rows by two
//! (4:2:2) and colour at full size two by two (4:4:4); a grey picture's
//! colour planes are 128, filled once. The planes are made where a
//! display's video layer reads them - below 4 GiB on the 64-bit machines
//! where there is room there - each plane and each of its rows starting
//! on 16 bytes, and written out of the caches once the picture is in
//! them. The colours are what the stream's VUI says, BT.709 or BT.601,
//! and when it says neither BT.709 for pictures 720 rows high or more.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const ExecBase = sdk.interface.exec.ExecBase;
const h264 = @import("h264core");
const module = @import("../module.zig");
const Base = module.Base;

/// Where the planes are made: below 4 GiB on the 64-bit machines, where
/// a display reads them; anywhere on the others, where only the processor
/// does.
const planes_memory: u32 = if (@sizeOf(usize) == 8) exec.MEMF_DMA else exec.MEMF_ANY;
/// What each plane and each of its rows starts on.
const plane_alignment = 16;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "H264".
const frame_mark: u32 = 0x4832_3634;

/// The workers, on every core.
const Team = module.Team(h264.Cores);

/// `planes_memory` where it has room for `bytes`, any memory otherwise:
/// asked for only where there is room, since a request that fails runs
/// the low-memory handlers.
fn placeFor(sys: *ExecBase, bytes: usize) u32 {
    if (planes_memory == exec.MEMF_ANY) return exec.MEMF_ANY;
    return if (sys.AvailMem(planes_memory | exec.MEMF_LARGEST) >= bytes) planes_memory else exec.MEMF_ANY;
}

fn aligned(bytes: u32) u32 {
    return (bytes + plane_alignment - 1) & ~@as(u32, plane_alignment - 1);
}

/// A slot's planes: one block of memory - as AllocVec gave it, and where
/// the planes start in it - and the picture size they were made for.
const Planes = struct {
    memory: ?[*]u8 = null,
    start: [*]u8 = undefined,
    size: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const Decoder = struct {
    sys: *ExecBase,
    core: *h264.Decoder,
    /// How many bytes each unit's length takes in the packets; 0 for
    /// Annex B.
    length_size: u8 = 4,
    /// The frames lent out, by slot, and their planes.
    held: u32,
    lent: [vcodec.VCODEC_MOST_HELD]bool = @splat(false),
    planes: [vcodec.VCODEC_MOST_HELD]Planes = @splat(.{}),
    /// The end of the track was sent: what the decoder held back is out.
    ended: bool = false,
    /// A frame was handed out: a unit the decoder cannot decode is passed
    /// over from then on, rather than refused for another module.
    started: bool = false,
    team: Team = .{},
};

fn of(decoder: *vcodec.VCodecDecoder) *Decoder {
    return @ptrCast(@alignCast(decoder));
}

/// The decoder's memory, from AllocVec, on the 16 bytes it asks for:
/// AllocVec's blocks are on 16 on the 64-bit machines; on the others one
/// is asked for 16 bytes larger, and the block's own start kept in front
/// of what is handed out.
const Memory = struct {
    const direct = exec.MEM_BLOCKSIZE >= 16;

    fn alloc(ctx: *anyopaque, len: usize, clear: bool) ?[*]u8 {
        const sys: *ExecBase = @ptrCast(@alignCast(ctx));
        const flags = exec.MEMF_ANY | (if (clear) exec.MEMF_CLEAR else 0);
        if (direct) return @ptrCast(sys.AllocVec(len, flags) orelse return null);
        const block = sys.AllocVec(len + 16, flags) orelse return null;
        const at = (@intFromPtr(block) + 16) & ~@as(usize, 15);
        @as(*usize, @ptrFromInt(at - @sizeOf(usize))).* = @intFromPtr(block);
        return @ptrFromInt(at);
    }

    fn free(ctx: *anyopaque, memory: [*]u8, _: usize) void {
        const sys: *ExecBase = @ptrCast(@alignCast(ctx));
        if (direct) return sys.FreeVec(memory);
        const block = @as(*const usize, @ptrFromInt(@intFromPtr(memory) - @sizeOf(usize))).*;
        sys.FreeVec(@ptrFromInt(block));
    }
};

/// The pictures' size as shown, their rate as the VUI says it, their
/// depth: once the first picture began.
pub fn GetVCodecInfo(_: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) i32 {
    const m = of(decoder);
    const sps = m.core.active_sps orelse return vc.VCERR_NEED_DATA;
    info.* = .{ .width = sps.croppedWidth(), .height = sps.croppedHeight(), .depth = sps.bit_depth_luma };
    if (sps.timing and sps.num_units_in_tick != 0 and sps.time_scale != 0) {
        // A frame is two ticks of the clock.
        info.rate_num = sps.time_scale;
        info.rate_den = 2 * sps.num_units_in_tick;
    }
    return vc.VCERR_OK;
}

/// The decoder made, for H.264, and given the setup's parameter sets.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    var code: i32 = vc.VCERR_OK;
    const decoder = open(base.sys_base, params, &code);
    if (err) |out| out.* = code;
    return decoder;
}

fn open(sys: *ExecBase, params: *const vcodec.VCodecParams, code: *i32) ?*vcodec.VCodecDecoder {
    if (params.codec != vc.VCODEC_H264) return failed(code, vc.VCERR_NOCODEC);
    if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) return failed(code, vc.VCERR_UNSUPPORTED);
    const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(code, vc.VCERR_NOMEMORY);
    const m: *Decoder = @ptrCast(@alignCast(memory));
    const env: h264.Env = .{ .ctx = @ptrCast(sys), .alloc = Memory.alloc, .free = Memory.free };
    const core = h264.Decoder.create(env, .{}) orelse {
        sys.FreeVec(m);
        return failed(code, vc.VCERR_NOMEMORY);
    };
    m.* = .{ .sys = sys, .core = core, .held = params.held };
    if (params.config != null and params.config_size != 0) {
        m.length_size = setup(m, params.config.?[0..params.config_size]) orelse {
            core.destroy();
            sys.FreeVec(m);
            return failed(code, vc.VCERR_CORRUPT);
        };
    } else m.length_size = 0;
    m.team.start(sys, "h264.vcodec worker");
    if (m.team.count != 0) core.useCores(&m.team.cores);
    return @ptrCast(m);
}

fn failed(code: *i32, why: i32) ?*vcodec.VCodecDecoder {
    code.* = why;
    return null;
}

/// An avcC record (ISO 14496-15 5.3.3) read: its SPS and PPS given to the
/// decoder, and how many bytes each unit's length takes. Null for a
/// record that is not one.
fn setup(m: *Decoder, config: []const u8) ?u8 {
    // version, profile, compatibility, level, then the length size.
    if (config.len < 7 or config[0] != 1) return null;
    const length_size = (config[4] & 3) + 1;
    if (length_size == 3) return null;
    var at: usize = 5;
    // The SPS (a count of five bits), then the PPS (a count of eight),
    // each unit after a two-byte length.
    var count: usize = config[at] & 0x1F;
    at += 1;
    for (0..2) |list| {
        if (list == 1) {
            if (at >= config.len) return null;
            count = config[at];
            at += 1;
        }
        for (0..count) |_| {
            if (at + 2 > config.len) return null;
            const length = (@as(usize, config[at]) << 8) | config[at + 1];
            at += 2;
            if (length > config.len - at) return null;
            // One the decoder cannot read leaves it to the stream's own.
            m.core.decodeUnit(config[at..][0..length], 0) catch {};
            at += length;
        }
    }
    return length_size;
}

/// The decoder freed, the planes of the frames still lent too.
pub fn CloseVCodec(_: *Base, decoder: ?*vcodec.VCodecDecoder) void {
    const m = of(decoder orelse return);
    const sys = m.sys;
    // The workers finish what they decode before they end.
    m.core.destroy();
    m.team.stop();
    for (&m.planes) |*planes| sys.FreeVec(planes.memory);
    sys.FreeVec(m);
}

/// A packet's units decoded; the end of the track hands out the pictures
/// held back.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const m = of(decoder);
    if (m.core.next() != null) return vc.VCERR_FULL;
    if (packet.flags & vcodec.VCPKT_END != 0) {
        m.core.flush();
        m.ended = true;
        return vc.VCERR_OK;
    }
    const data = packet.data orelse return vc.VCERR_CORRUPT;
    const bytes = data[0..packet.size];
    if (m.length_size == 0) {
        var units = h264.nal.AnnexB{ .data = bytes };
        while (units.next()) |unit| {
            const fed = feed(m, unit, packet.time);
            if (fed != vc.VCERR_OK) return fed;
        }
        return vc.VCERR_OK;
    }
    const size = m.length_size;
    var at: usize = 0;
    while (at < bytes.len) {
        if (size > bytes.len - at) return vc.VCERR_CORRUPT;
        var length: usize = 0;
        for (bytes[at..][0..size]) |byte| length = (length << 8) | byte;
        at += size;
        if (length > bytes.len - at) return vc.VCERR_CORRUPT;
        const fed = feed(m, bytes[at..][0..length], packet.time);
        if (fed != vc.VCERR_OK) return fed;
        at += length;
    }
    // A packet with lengths is an access unit: its picture is whole.
    m.core.endPicture();
    return vc.VCERR_OK;
}

/// One unit decoded. One that is not right is passed over; one the
/// decoder cannot decode refuses the track before its first frame, so
/// that another module may take it.
fn feed(m: *Decoder, unit: []const u8, time: i64) i32 {
    m.core.decodeUnit(unit, time) catch |failure| return switch (failure) {
        error.NoMemory => vc.VCERR_NOMEMORY,
        error.Unsupported => if (m.started) vc.VCERR_OK else vc.VCERR_UNSUPPORTED,
        else => vc.VCERR_OK,
    };
    return vc.VCERR_OK;
}

/// The next picture to be shown copied into a free slot's planes and
/// lent in `frame`.
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const m = of(decoder);
    const slot = module.freeSlot(&m.lent, m.held) orelse return vc.VCERR_BUSY;
    const picture = m.core.next() orelse return if (m.ended) vc.VCERR_END else vc.VCERR_NEED_DATA;
    const made = copyOut(m, picture, frame, slot);
    m.core.release();
    if (made != vc.VCERR_OK) return made;
    m.lent[slot] = true;
    m.started = true;
    frame.private = .{ slot + 1, frame_mark, 0 };
    return vc.VCERR_OK;
}

/// Nothing to give back but the slot: its planes stay its own for its
/// next frame.
pub fn ReleaseVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) void {
    const m = of(decoder);
    const slot = module.slotOf(&m.lent, frame, frame_mark) orelse return;
    m.lent[slot] = false;
}

/// Everything decoded and not yet shown dropped, for a seek: the decoder
/// starts again at the next key picture.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const m = of(decoder);
    m.core.reset();
    m.ended = false;
}

/// The picture `s` copied into `slot`'s planes, as I420 in 8 bits, and
/// lent in `frame`.
fn copyOut(m: *Decoder, s: *const h264.Store, frame: *vc.VideoFrame, slot: u32) i32 {
    const sps = m.core.active_sps.?;
    const width = sps.croppedWidth();
    const height = sps.croppedHeight();
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const y_pitch = aligned(width);
    const c_pitch = aligned(half_width);
    const luma: usize = @as(usize, y_pitch) * height;
    const chroma: usize = @as(usize, c_pitch) * half_height;
    const planes = &m.planes[slot];
    const fresh = make(m.sys, planes, luma + 2 * chroma, width, height) orelse return vc.VCERR_NOMEMORY;
    const y = planes.start;
    const cb = y + luma;
    const cr = cb + chroma;

    const source: Source = .{ .s = s, .wide = m.core.wide, .x0 = sps.cropX(), .y0 = sps.cropY() };
    source.copy(m.sys, 0, y, y_pitch, width, height, 1, 1, m.core.depth_y);
    switch (sps.chroma_format_idc) {
        // A grey picture's colour: the middle, filled when the planes
        // were made.
        0 => if (fresh) m.sys.SetMem(cb, 128, 2 * chroma),
        else => |format| {
            const across: u32 = if (format == 3) 2 else 1;
            const down: u32 = if (format == 1) 1 else 2;
            // Separate colour planes are each coded as the brightness is.
            const depth = if (sps.separate_colour_plane) m.core.depth_y else m.core.depth_c;
            const half: Source = .{ .s = s, .wide = m.core.wide, .x0 = source.x0 * across / 2, .y0 = source.y0 * down / 2 };
            half.copy(m.sys, 1, cb, c_pitch, half_width, half_height, across, down, depth);
            half.copy(m.sys, 2, cr, c_pitch, half_width, half_height, across, down, depth);
        },
    }
    if (planes_memory & exec.MEMF_DMA != 0) m.sys.CacheClearE(planes.start, @intCast(planes.size), exec.CACRF_ClearD);

    var colors: u8 = switch (sps.matrix) {
        1 => rtg.RTGYUV_BT709,
        5, 6 => rtg.RTGYUV_BT601,
        else => if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
    };
    if (sps.full_range) colors |= rtg.RTGYUV_FULL;
    frame.* = .{
        .picture = .{
            .y = y,
            .cb = cb,
            .cr = cr,
            .y_pitch = y_pitch,
            .c_pitch = c_pitch,
            .layout = rtg.RTGYUV_I420,
            .colors = colors,
        },
        .width = width,
        .height = height,
        .time = s.time,
    };
    return vc.VCERR_OK;
}

/// A plane of the decoder's picture, from its shown part's corner on.
const Source = struct {
    s: *const h264.Store,
    wide: bool,
    x0: u32,
    y0: u32,

    /// `width` by `height` samples of plane `p` into `into`, its rows
    /// `pitch` apart: each the average of `across` by `down` of the
    /// plane's, rounded to 8 bits from `depth`. Where a block of them
    /// runs past the plane's edge - an odd size shown - the plane's last
    /// row or column is taken again.
    fn copy(src: Source, sys: *ExecBase, p: usize, into: [*]u8, pitch: u32, width: u32, height: u32, across: u32, down: u32, depth: u5) void {
        const s = src.s;
        const stride = s.stride[p];
        if (!src.wide and across == 1 and down == 1) {
            // As it is: a row at a time, by exec's copy.
            for (0..height) |r| {
                const from = s.planes[p] + (src.y0 + r) * stride + src.x0;
                sys.CopyMem(from, into + r * pitch, width);
            }
            return;
        }
        const shift: u5 = @intCast(depth - 8 + @as(u5, @intCast((across * down) >> 1)));
        if (src.wide) {
            const samples: [*]const u16 = @ptrCast(@alignCast(s.planes[p]));
            src.average(u16, samples, p, into, pitch, width, height, across, down, shift);
        } else src.average(u8, s.planes[p], p, into, pitch, width, height, across, down, shift);
    }

    fn average(src: Source, comptime T: type, samples: [*]const T, p: usize, into: [*]u8, pitch: u32, width: u32, height: u32, across: u32, down: u32, shift: u5) void {
        const s = src.s;
        const stride = s.stride[p];
        const last_x = s.width[p] - 1;
        const last_y = s.height[p] - 1;
        const round: u32 = (@as(u32, 1) << shift) >> 1;
        for (0..height) |r| {
            const y = src.y0 + @as(u32, @intCast(r)) * down;
            const row0 = samples + y * stride;
            const row1 = samples + @min(y + down - 1, last_y) * stride;
            const out = into + r * pitch;
            if (across == 1) {
                for (0..width) |c| {
                    const sum = @as(u32, row0[src.x0 + c]) + if (down == 2) @as(u32, row1[src.x0 + c]) else 0;
                    out[c] = @intCast(@min((sum + round) >> shift, 255));
                }
            } else {
                for (0..width) |c| {
                    const x = src.x0 + @as(u32, @intCast(c)) * 2;
                    const x1 = @min(x + 1, last_x);
                    const sum = @as(u32, row0[x]) + row0[x1] + row1[x] + row1[x1];
                    out[c] = @intCast(@min((sum + round) >> shift, 255));
                }
            }
        }
    }
};

/// The slot's planes made for `size` bytes, or kept when they were made
/// for a picture of this size: whether they were made now. Null when
/// there is no memory.
fn make(sys: *ExecBase, planes: *Planes, size: usize, width: u32, height: u32) ?bool {
    if (planes.memory != null and planes.width == width and planes.height == height and planes.size >= size) return false;
    sys.FreeVec(planes.memory);
    planes.* = .{};
    const memory = sys.AllocVec(size + plane_alignment, placeFor(sys, size + plane_alignment)) orelse return null;
    const start = (@intFromPtr(memory) + plane_alignment - 1) & ~@as(usize, plane_alignment - 1);
    planes.* = .{
        .memory = @ptrCast(memory),
        .start = @ptrFromInt(start),
        .size = size,
        .width = width,
        .height = height,
    };
    return true;
}
