// SPDX-License-Identifier: MIT
//! hevc.vcodec's decoder: H.265 read by videoparse.library and decoded in
//! software by the decoder built in as `hevccore` (core.zig here), which
//! takes the library's events and gives its pictures out in the order the
//! library says they are shown.
//!
//! **The setup** - an MP4's hvcC, which a Matroska track's CodecPrivate
//! is as well - goes to the library's parser when the decoder opens: it
//! says how many bytes each unit's length takes in the packets, and holds
//! the parameter sets. A track without a setup has its packets in Annex B
//! form, the parameter sets among them.
//!
//! **A packet sent** is copied and handed to the parser, and its events
//! are decoded at once; the pictures it finishes wait in the decoder until
//! they are asked for, and while one waits another packet is refused
//! (VCERR_FULL). A packet of units after their lengths - an MP4's, a
//! Matroska track's - is an access unit, whose picture is whole at its
//! end. A unit that is not right is passed over: the decoder makes up
//! what it lacked. Where the parser has no slot left for a picture - the
//! pictures waiting to be shown hold them - the rest of the packet is
//! read once a frame was taken. The end of the track hands out the
//! pictures held back. Of a stream in layers the base layer is decoded.
//! Pictures as large as level 6.2 allows are taken. A picture handed out
//! takes the earliest time of those decoded and not yet shown, as the
//! chip's decoder gives them: the times rise even where the container
//! wrote each packet's decoding time (an MP4 without composition
//! offsets).
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
//! colour planes are 128. A picture coded as RGB - green, blue and red in
//! place of the brightness and the colours, the identity matrix - is made
//! YUV by BT.709's matrix, the whole byte. The planes are made where a
//! display's video layer reads them - below 4 GiB on the 64-bit machines
//! where there is room there - each plane and each of its rows starting
//! on 16 bytes, and written out of the caches once the picture is in
//! them. The colours are what the stream's VUI says, BT.601 (or FCC and
//! BT.470 BG) or BT.709 (or SMPTE 240, and BT.2020 as the nearest there
//! is), and when it says neither BT.709 for pictures 720 rows high or
//! more; the whole byte when it says so.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;
const hevc = @import("hevccore");
const module = @import("../module.zig");
const Base = module.Base;

/// Where the planes are made: below 4 GiB on the 64-bit machines, where
/// a display reads them; anywhere on the others, where only the processor
/// does.
const planes_memory: u32 = if (@sizeOf(usize) == 8) exec.MEMF_DMA else exec.MEMF_ANY;
/// What each plane and each of its rows starts on.
const plane_alignment = 16;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "H265".
const frame_mark: u32 = 0x4832_3635;

/// The largest picture taken, across and down: level 6.2's.
const max_size = 16888;

/// The workers, on every core.
const Team = module.Team(hevc.Cores);

/// The VUI's matrices (table E.5), those the colours are told by.
const MC_IDENTITY = 0;
const MC_BT_709 = 1;
const MC_FCC = 4;
const MC_BT_470_B_G = 5;
const MC_BT_601 = 6;
const MC_SMPTE_240 = 7;
const MC_BT_2020_NCL = 9;
const MC_BT_2020_CL = 10;

/// The VUI's transfer characteristics (table E.4), the two that are not a
/// television's curve: high dynamic range, which a screen has to be
/// mapped to rather than shown as it is.
const TR_PQ = 16;
const TR_HLG = 18;

/// The VUI's colour primaries (table E.3), those that are not BT.709's.
const CP_BT_2020 = 9;
const CP_P3_DCI = 11;
const CP_P3_D65 = 12;

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
    core: *hevc.Decoder,
    vpb: *VideoParseBase,
    parser: *vp.VideoParser,
    /// The packets have their units after their lengths (an hvcC came):
    /// each is an access unit.
    sized: bool = false,
    /// The packet being read, copied: the parser reads it on once a frame
    /// was taken where it ran out of slots (`reading`).
    packet: ?[*]u8 = null,
    packet_room: usize = 0,
    reading: bool = false,
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
        // A picture is a tick of the clock.
        info.rate_num = sps.time_scale;
        info.rate_den = sps.num_units_in_tick;
    }
    return vc.VCERR_OK;
}

/// The decoder made, for H.265, and given the setup's parameter sets.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    var code: i32 = vc.VCERR_OK;
    const decoder = open(base.sys_base, params, &code);
    if (err) |out| out.* = code;
    return decoder;
}

fn open(sys: *ExecBase, params: *const vcodec.VCodecParams, code: *i32) ?*vcodec.VCodecDecoder {
    if (params.codec != vc.VCODEC_H265) return failed(code, vc.VCERR_NOCODEC);
    if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) return failed(code, vc.VCERR_UNSUPPORTED);
    const lib = sys.OpenLibrary(vp.VIDEOPARSENAME, 1) orelse return failed(code, vc.VCERR_NOCODEC);
    const vpb: *VideoParseBase = @ptrCast(lib);
    const config = if (params.config_size != 0) params.config else null;
    const tags = [_]utility.TagItem{
        .{ .tag = vp.VPA_Slots, .data = hevc.own_slots },
        .{ .tag = vp.VPA_MaxWidth, .data = max_size },
        .{ .tag = vp.VPA_MaxHeight, .data = max_size },
        .{},
    };
    var why: i32 = vp.VPERR_OK;
    const parser = vpb.OpenVideoParser(vp.VPCODEC_HEVC, config, params.config_size, &tags, &why) orelse {
        sys.CloseLibrary(lib);
        return failed(code, switch (why) {
            vp.VPERR_NOMEMORY => vc.VCERR_NOMEMORY,
            vp.VPERR_UNSUPPORTED => vc.VCERR_UNSUPPORTED,
            else => vc.VCERR_CORRUPT,
        });
    };
    const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        vpb.CloseVideoParser(parser);
        sys.CloseLibrary(lib);
        return failed(code, vc.VCERR_NOMEMORY);
    };
    const m: *Decoder = @ptrCast(@alignCast(memory));
    const env: hevc.Env = .{ .ctx = @ptrCast(sys), .alloc = Memory.alloc, .free = Memory.free };
    const core = hevc.Decoder.create(env) orelse {
        sys.FreeVec(m);
        vpb.CloseVideoParser(parser);
        sys.CloseLibrary(lib);
        return failed(code, vc.VCERR_NOMEMORY);
    };
    m.* = .{ .sys = sys, .core = core, .vpb = vpb, .parser = parser, .sized = config != null, .held = params.held };
    m.team.start(sys, "hevc.vcodec worker");
    if (m.team.count != 0) core.useCores(&m.team.cores);
    return @ptrCast(m);
}

fn failed(code: *i32, why: i32) ?*vcodec.VCodecDecoder {
    code.* = why;
    return null;
}

/// The decoder freed, the planes of the frames still lent too.
pub fn CloseVCodec(_: *Base, decoder: ?*vcodec.VCodecDecoder) void {
    const m = of(decoder orelse return);
    const sys = m.sys;
    // The workers finish what they decode before they end.
    m.core.destroy();
    m.team.stop();
    m.vpb.CloseVideoParser(m.parser);
    sys.CloseLibrary(m.vpb.lib());
    for (&m.planes) |*planes| sys.FreeVec(planes.memory);
    sys.FreeVec(m.packet);
    sys.FreeVec(m);
}

/// A packet copied, handed to the parser and its events decoded; the
/// end of the track hands out the pictures held back.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const m = of(decoder);
    if (m.reading or m.core.next() != null) return vc.VCERR_FULL;
    var given: vp.VideoPacket = .{ .time = packet.time };
    if (packet.flags & vcodec.VCPKT_END != 0) {
        given.flags = vp.VPPKT_END;
        m.ended = true;
    } else {
        const data = packet.data orelse return vc.VCERR_CORRUPT;
        if (m.packet_room < packet.size) {
            m.sys.FreeVec(m.packet);
            m.packet = null;
            m.packet_room = 0;
            m.packet = @ptrCast(m.sys.AllocVec(packet.size, exec.MEMF_ANY) orelse return vc.VCERR_NOMEMORY);
            m.packet_room = packet.size;
        }
        m.sys.CopyMem(data, m.packet.?, packet.size);
        given.data = m.packet;
        given.bytes = packet.size;
        // A packet with lengths is an access unit: its picture is whole.
        if (m.sized) given.flags = vp.VPPKT_ACCESS_UNIT;
    }
    if (m.vpb.ParseVideoPacket(m.parser, &given) != vp.VPERR_OK) return vc.VCERR_FULL;
    m.reading = true;
    return read(m);
}

/// The packet's events decoded, until it is read through or the parser
/// waits for a slot the pictures waiting to be shown hold. A unit that is
/// not right is passed over; one the decoder cannot decode refuses the
/// track before its first frame, so that another module may take it.
fn read(m: *Decoder) i32 {
    var event: vp.VideoEvent = .{};
    while (true) {
        while (m.core.giveBack()) |slot| m.vpb.ReleaseVideoSlot(m.parser, slot);
        switch (m.vpb.NextVideoEvent(m.parser, &event)) {
            vp.VPERR_OK => m.core.event(&event) catch |failure| switch (failure) {
                error.NoMemory => return vc.VCERR_NOMEMORY,
                error.Unsupported => if (!m.started) return vc.VCERR_UNSUPPORTED,
                else => {},
            },
            vp.VPERR_NEED_DATA => {
                m.reading = false;
                return vc.VCERR_OK;
            },
            vp.VPERR_END => {
                m.reading = false;
                m.core.endOfStream();
                return vc.VCERR_OK;
            },
            // The workers' stores first; then the pictures waiting.
            vp.VPERR_FULL => if (!m.core.makeRoom()) return vc.VCERR_OK,
            vp.VPERR_UNSUPPORTED => if (!m.started) return vc.VCERR_UNSUPPORTED,
            vp.VPERR_NOMEMORY => return vc.VCERR_NOMEMORY,
            else => {},
        }
    }
}

/// The next picture to be shown copied into a free slot's planes and
/// lent in `frame`.
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const m = of(decoder);
    const slot = module.freeSlot(&m.lent, m.held) orelse return vc.VCERR_BUSY;
    var picture = m.core.next();
    if (picture == null and m.reading) {
        // The rest of the packet, now that a frame was taken.
        const got = read(m);
        if (got != vc.VCERR_OK) return got;
        picture = m.core.next();
    }
    const shown = picture orelse return if (m.ended and !m.reading) vc.VCERR_END else vc.VCERR_NEED_DATA;
    const made = copyOut(m, shown, frame, slot);
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
/// starts again at the next random access picture.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const m = of(decoder);
    m.vpb.ResetVideoParser(m.parser);
    m.core.reset();
    while (m.core.giveBack()) |slot| m.vpb.ReleaseVideoSlot(m.parser, slot);
    m.reading = false;
    m.ended = false;
}

/// The picture `s` copied into `slot`'s planes, as I420 at eight bits or
/// ten, and lent in `frame`: as its own sequence said, which is not the
/// active one for a picture of the sequence before.
///
/// A picture of more than eight bits is handed over at ten rather than
/// cut down to eight: a film of high dynamic range is mapped into the
/// screen's range when it is drawn, which stretches the dark half of it,
/// and eight bits of that show as bands in a sky.
fn copyOut(m: *Decoder, s: *const hevc.Store, frame: *vc.VideoFrame, slot: u32) i32 {
    const f = s.format;
    const width = f.width;
    const height = f.height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const wide = f.wide();
    // The identity matrix comes with colour at full size alone, and is
    // made the screen's colours here, in bytes.
    const rgb = f.matrix == MC_IDENTITY and f.chroma_format == 3;
    const deep = wide and !rgb;
    const unit: u32 = if (deep) 2 else 1;
    const y_pitch = aligned(width) * unit;
    const c_pitch = aligned(half_width) * unit;
    const luma: usize = @as(usize, y_pitch) * height;
    const chroma: usize = @as(usize, c_pitch) * half_height;
    const planes = &m.planes[slot];
    if (!make(m.sys, planes, luma + 2 * chroma, width, height)) return vc.VCERR_NOMEMORY;
    const into = [3][*]u8{ planes.start, planes.start + luma, planes.start + luma + chroma };
    const pitch = [3]u32{ y_pitch, c_pitch, c_pitch };

    if (rgb) {
        if (wide) fromRgb(u16, s, into, pitch) else fromRgb(u8, s, into, pitch);
    } else {
        const source: Source = .{ .s = s, .wide = wide, .deep = deep, .x0 = f.x, .y0 = f.y };
        source.copy(m.sys, 0, into[0], y_pitch, width, height, 1, 1, f.depth_y);
        switch (f.chroma_format) {
            // A grey picture's colour: the middle.
            0 => grey(m.sys, into[1], 2 * chroma, deep),
            else => |format| {
                const across: u32 = if (format == 3) 2 else 1;
                const down: u32 = if (format == 1) 1 else 2;
                const half: Source = .{ .s = s, .wide = wide, .deep = deep, .x0 = f.x * across / 2, .y0 = f.y * down / 2 };
                half.copy(m.sys, 1, into[1], c_pitch, half_width, half_height, across, down, f.depth_c);
                half.copy(m.sys, 2, into[2], c_pitch, half_width, half_height, across, down, f.depth_c);
            },
        }
    }
    if (planes_memory & exec.MEMF_DMA != 0) m.sys.CacheClearE(planes.start, @intCast(planes.size), exec.CACRF_ClearD);

    const matrix: u8 = switch (f.matrix) {
        MC_FCC, MC_BT_470_B_G, MC_BT_601 => rtg.RTGYUV_BT601,
        MC_IDENTITY, MC_BT_709, MC_SMPTE_240 => rtg.RTGYUV_BT709,
        MC_BT_2020_NCL, MC_BT_2020_CL => rtg.RTGYUV_BT2020,
        else => if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
    };
    const range: u8 = if (f.full_range or rgb) rtg.RTGYUV_FULL else rtg.RTGYUV_LIMITED;
    // An RGB picture is already the screen's colours; the curves are for
    // what a film carries.
    const transfer: u8 = if (rgb) rtg.RTGYUV_SDR else switch (f.transfer) {
        TR_PQ => rtg.RTGYUV_PQ,
        TR_HLG => rtg.RTGYUV_HLG,
        else => rtg.RTGYUV_SDR,
    };
    const primaries: u8 = if (rgb) rtg.RTGYUV_BT709 else switch (f.primaries) {
        CP_BT_2020 => rtg.RTGYUV_BT2020,
        CP_P3_D65, CP_P3_DCI => rtg.RTGYUV_P3,
        else => rtg.RTGYUV_BT709,
    };
    frame.* = .{
        .picture = .{
            .y = into[0],
            .cb = into[1],
            .cr = into[2],
            .y_pitch = y_pitch,
            .c_pitch = c_pitch,
            .layout = rtg.RTGYUV_I420,
            .matrix = matrix,
            .transfer = transfer,
            .primaries = primaries,
            .range = range,
            .depth = if (deep) 10 else 8,
            .peak = f.peak_nits,
        },
        .width = width,
        .height = height,
        .time = s.time,
    };
    return vc.VCERR_OK;
}

/// A plane of the decoder's picture, from its shown part's corner on.
const Source = struct {
    s: *const hevc.Store,
    wide: bool,
    /// The samples go out as words of ten bits rather than bytes of
    /// eight.
    deep: bool,
    x0: u32,
    y0: u32,

    /// `width` by `height` samples of plane `p` into `into`, its rows
    /// `pitch` bytes apart: each the average of `across` by `down` of the
    /// plane's, brought from `depth` bits to the eight or ten the frame
    /// carries. Where a block of them runs past the plane's edge - an odd
    /// size shown - the plane's last row or column is taken again.
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
        const bits: u5 = if (src.deep) 10 else 8;
        const up: u5 = if (depth < bits) bits - depth else 0;
        const shift: u5 = (if (depth > bits) depth - bits else 0) + @as(u5, @intCast((across * down) >> 1));
        const most: u32 = (@as(u32, 1) << bits) - 1;
        if (src.wide) {
            const samples: [*]const u16 = @ptrCast(@alignCast(s.planes[p]));
            if (src.deep)
                src.average(u16, u16, samples, p, into, pitch, width, height, across, down, up, shift, most)
            else
                src.average(u16, u8, samples, p, into, pitch, width, height, across, down, up, shift, most);
        } else if (src.deep) {
            src.average(u8, u16, s.planes[p], p, into, pitch, width, height, across, down, up, shift, most);
        } else {
            src.average(u8, u8, s.planes[p], p, into, pitch, width, height, across, down, up, shift, most);
        }
    }

    fn average(src: Source, comptime T: type, comptime O: type, samples: [*]const T, p: usize, into: [*]u8, pitch: u32, width: u32, height: u32, across: u32, down: u32, up: u5, shift: u5, most: u32) void {
        const s = src.s;
        const stride = s.stride[p];
        const last_x = s.width[p] - 1;
        const last_y = s.height[p] - 1;
        const round: u32 = (@as(u32, 1) << shift) >> 1;
        for (0..height) |r| {
            const y = src.y0 + @as(u32, @intCast(r)) * down;
            const row0 = samples + y * stride;
            const row1 = samples + @min(y + down - 1, last_y) * stride;
            const out: [*]O = @ptrCast(@alignCast(into + r * pitch));
            if (across == 1) {
                for (0..width) |c| {
                    const sum = @as(u32, row0[src.x0 + c]) + if (down == 2) @as(u32, row1[src.x0 + c]) else 0;
                    out[c] = @intCast(@min(((sum << up) + round) >> shift, most));
                }
            } else {
                for (0..width) |c| {
                    const x = src.x0 + @as(u32, @intCast(c)) * 2;
                    const x1 = @min(x + 1, last_x);
                    const sum = @as(u32, row0[x]) + row0[x1] + row1[x] + row1[x1];
                    out[c] = @intCast(@min(((sum << up) + round) >> shift, most));
                }
            }
        }
    }
};

/// A grey picture's chroma planes: the middle of the range, which is a
/// byte of 128 or a word of 512.
fn grey(sys: *ExecBase, into: [*]u8, bytes: usize, deep: bool) void {
    if (!deep) return sys.SetMem(into, 128, bytes);
    const words: [*]u16 = @ptrCast(@alignCast(into));
    for (0..bytes / 2) |i| words[i] = 512;
}

/// An RGB picture - green, blue and red, each at full size - made YUV by
/// BT.709's matrix, the whole byte; each colour sample of four pixels'
/// average.
fn fromRgb(comptime T: type, s: *const hevc.Store, into: [3][*]u8, pitch: [3]u32) void {
    const f = s.format;
    const g: [*]const T = @ptrCast(@alignCast(s.planes[0]));
    const b: [*]const T = @ptrCast(@alignCast(s.planes[1]));
    const r: [*]const T = @ptrCast(@alignCast(s.planes[2]));
    const stride = s.stride[0];
    const at0 = f.y * stride + f.x;
    const gs: u5 = f.depth_y - 8;
    const cs: u5 = f.depth_c - 8;
    // In 1/65536ths: Y = 0.2126 R + 0.7152 G + 0.0722 B, and the colours
    // (B - Y) / 1.8556 and (R - Y) / 1.5748 about 128.
    for (0..f.height) |y| {
        for (0..f.width) |x| {
            const i = at0 + y * stride + x;
            const lum = ((13933 * @as(i64, r[i]) + 4732 * @as(i64, b[i])) >> cs) + ((46871 * @as(i64, g[i])) >> gs);
            into[0][y * pitch[0] + x] = @intCast(@min((lum + 32768) >> 16, 255));
        }
    }
    const last_x = f.width - 1;
    const last_y = f.height - 1;
    for (0..(f.height + 1) / 2) |cy| {
        for (0..(f.width + 1) / 2) |cx| {
            const y0: usize = 2 * cy;
            const x0: usize = 2 * cx;
            const y1: usize = @min(y0 + 1, last_y);
            const x1: usize = @min(x0 + 1, last_x);
            var sr: i64 = 0;
            var sg: i64 = 0;
            var sb: i64 = 0;
            for ([_]usize{ y0 * stride + x0, y0 * stride + x1, y1 * stride + x0, y1 * stride + x1 }) |i| {
                sr += r[at0 + i];
                sg += g[at0 + i];
                sb += b[at0 + i];
            }
            // The four pixels' sums, in 1/65536ths of a sample, at 8 bits.
            const lum = ((13933 * sr + 4732 * sb) >> cs) + ((46871 * sg) >> gs);
            const bb = (sb << 16) >> cs;
            const rr = (sr << 16) >> cs;
            const cb = @divFloor((bb - lum) * 10000, 4 * 18556);
            const cr = @divFloor((rr - lum) * 10000, 4 * 15748);
            const o = cy * pitch[1] + cx;
            into[1][o] = @intCast(@max(0, @min(255, ((cb + 32768) >> 16) + 128)));
            into[2][o] = @intCast(@max(0, @min(255, ((cr + 32768) >> 16) + 128)));
        }
    }
}

/// The slot's planes made for `size` bytes, or kept when they were made
/// for a picture of this size; false when there is no memory.
fn make(sys: *ExecBase, planes: *Planes, size: usize, width: u32, height: u32) bool {
    if (planes.memory != null and planes.width == width and planes.height == height and planes.size >= size) return true;
    sys.FreeVec(planes.memory);
    planes.* = .{};
    const memory = sys.AllocVec(size + plane_alignment, placeFor(sys, size + plane_alignment)) orelse return false;
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
