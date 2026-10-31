// SPDX-License-Identifier: MIT
//! vp9.vcodec's decoder: VP9 decoded in software by the decoder built in
//! as `vp9core` (core.zig here), which takes the stream a packet at a
//! time and shows the frame each packet shows.
//!
//! **A packet sent** is a frame or a superframe of several - most often a
//! hidden one, a reference for the frames after it, and one shown. The
//! decoder decodes all of it at once; the frame it shows waits until it
//! is asked for, and while one waits another packet is refused
//! (VCERR_FULL). One marked VCPKT_DROP, due before what is shown, is
//! decoded for the frames after it and not handed out. A frame that is
//! not right is passed over, and so is every frame after it until a key
//! frame or an intra-only one. There is no setup.
//!
//! **The cores**: with more than one, the decoder has a worker task on
//! each (module.zig's `Team`): the decoder reads each frame - its headers
//! and all its blocks - as its packet comes, and the frames read wait in
//! turn for whichever worker is free, which puts the frame together and
//! filters it while the next packets are read: up to twice as many
//! frames at once as there are workers, each superblock row waiting for
//! the lines of the references its blocks read. While another frame can
//! be read a packet is taken before a frame is handed out, as long as no
//! more frames wait than there are workers; a frame still being decoded
//! is waited for.
//!
//! **The frames** are each frame copied into the planes of the slot it is
//! lent in, I420 in 8 bits as every frame is: deeper samples are rounded
//! to 8 bits, colour at full height is averaged two rows by two (4:2:2),
//! at full width two columns by two (4:4:0) and at full size two by two
//! (4:4:4). A frame coded as RGB - green, blue and red in place of the
//! brightness and the colours - is made YUV by BT.709's matrix, the
//! whole byte. The planes are made where a display's video layer reads
//! them - below 4 GiB on the 64-bit machines where there is room there -
//! each plane and each of its rows starting on 16 bytes, and written out
//! of the caches once the picture is in them. The colours are what the
//! frame says, BT.601 (or SMPTE 170) or BT.709 (or SMPTE 240, and BT.2020
//! as the nearest there is), and when it says neither BT.709 for
//! pictures 720 rows high or more; the whole byte when it says so.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const ExecBase = sdk.interface.exec.ExecBase;
const vp9 = @import("vp9core");
const module = @import("../module.zig");
const Base = module.Base;

/// Where the planes are made: below 4 GiB on the 64-bit machines, where
/// a display reads them; anywhere on the others, where only the processor
/// does.
const planes_memory: u32 = if (@sizeOf(usize) == 8) exec.MEMF_DMA else exec.MEMF_ANY;
/// What each plane and each of its rows starts on.
const plane_alignment = 16;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "VP90".
const frame_mark: u32 = 0x5650_3930;

/// The workers, on every core.
const Team = module.Team(vp9.Cores);

/// VP9's colour spaces (7.2.2).
const CS_BT_601 = 1;
const CS_BT_709 = 2;
const CS_SMPTE_170 = 3;
const CS_SMPTE_240 = 4;
const CS_BT_2020 = 5;
const CS_RGB = 7;

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
    core: *vp9.Decoder,
    /// The frames lent out, by slot, and their planes.
    held: u32,
    lent: [vcodec.VCODEC_MOST_HELD]bool = @splat(false),
    planes: [vcodec.VCODEC_MOST_HELD]Planes = @splat(.{}),
    /// The end of the track was sent: what the decoder holds is out.
    ended: bool = false,
    /// A frame was handed out: one the decoder cannot decode is passed
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

/// The pictures' size and depth, once a frame was decoded; VP9 says no
/// rate.
pub fn GetVCodecInfo(_: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) i32 {
    const m = of(decoder);
    if (m.core.width == 0) return vc.VCERR_NEED_DATA;
    info.* = .{ .width = m.core.width, .height = m.core.height, .depth = m.core.st.color.bit_depth };
    return vc.VCERR_OK;
}

/// The decoder made, for VP9.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    var code: i32 = vc.VCERR_OK;
    const decoder = open(base.sys_base, params, &code);
    if (err) |out| out.* = code;
    return decoder;
}

fn open(sys: *ExecBase, params: *const vcodec.VCodecParams, code: *i32) ?*vcodec.VCodecDecoder {
    if (params.codec != vc.VCODEC_VP9) return failed(code, vc.VCERR_NOCODEC);
    if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) return failed(code, vc.VCERR_UNSUPPORTED);
    const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(code, vc.VCERR_NOMEMORY);
    const m: *Decoder = @ptrCast(@alignCast(memory));
    const env: vp9.Env = .{ .ctx = @ptrCast(sys), .alloc = Memory.alloc, .free = Memory.free };
    const core = vp9.Decoder.create(env) orelse {
        sys.FreeVec(m);
        return failed(code, vc.VCERR_NOMEMORY);
    };
    m.* = .{ .sys = sys, .core = core, .held = params.held };
    m.team.start(sys, "vp9.vcodec worker");
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
    for (&m.planes) |*planes| sys.FreeVec(planes.memory);
    sys.FreeVec(m);
}

/// A packet read, the frame begun on a worker or decoded; the end of the
/// track hands out the frames still being decoded.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const m = of(decoder);
    if (m.core.next() != null) return vc.VCERR_FULL;
    if (packet.flags & vcodec.VCPKT_END != 0) {
        m.core.flush();
        m.ended = true;
        return vc.VCERR_OK;
    }
    const data = packet.data orelse return vc.VCERR_CORRUPT;
    const drop = packet.flags & vcodec.VCPKT_DROP != 0;
    m.core.decodeFrame(data[0..packet.size], packet.time, drop) catch |failure| return switch (failure) {
        error.NoMemory => vc.VCERR_NOMEMORY,
        error.Unsupported => if (m.started) vc.VCERR_OK else vc.VCERR_UNSUPPORTED,
        else => vc.VCERR_OK,
    };
    return vc.VCERR_OK;
}

/// The next frame to be shown copied into a free slot's planes and lent
/// in `frame`.
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const m = of(decoder);
    const slot = module.freeSlot(&m.lent, m.held) orelse return vc.VCERR_BUSY;
    const s = m.core.next() orelse return if (m.ended) vc.VCERR_END else vc.VCERR_NEED_DATA;
    const made = copyOut(m, s, frame, slot);
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

/// Everything decoded and not yet shown dropped, the references with it,
/// for a seek: the decoder starts again at the next key frame.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const m = of(decoder);
    m.core.reset();
    m.ended = false;
}

/// The frame `s` shows copied into `slot`'s planes, as I420 in 8 bits,
/// and lent in `frame`.
fn copyOut(m: *Decoder, s: vp9.Shown, frame: *vc.VideoFrame, slot: u32) i32 {
    const f = s.frame;
    const width = f.width;
    const height = f.height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const y_pitch = aligned(width);
    const c_pitch = aligned(half_width);
    const luma: usize = @as(usize, y_pitch) * height;
    const chroma: usize = @as(usize, c_pitch) * half_height;
    const planes = &m.planes[slot];
    if (!make(m.sys, planes, luma + 2 * chroma, width, height)) return vc.VCERR_NOMEMORY;
    const into = [3][*]u8{ planes.start, planes.start + luma, planes.start + luma + chroma };
    const pitch = [3]u32{ y_pitch, c_pitch, c_pitch };
    var colors: u8 = switch (f.color_space) {
        CS_BT_601, CS_SMPTE_170 => rtg.RTGYUV_BT601,
        CS_BT_709, CS_SMPTE_240, CS_BT_2020, CS_RGB => rtg.RTGYUV_BT709,
        else => if (height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
    };
    if (f.full_range) colors |= rtg.RTGYUV_FULL;
    if (f.color_space == CS_RGB) {
        if (f.alloc_bytes == 1) fromRgb(u8, f, into, pitch) else fromRgb(u16, f, into, pitch);
    } else if (f.alloc_bytes == 1 and f.ss_x == 1 and f.ss_y == 1) {
        // As it is: a row at a time, by exec's copy.
        for (0..3) |p| {
            const w = if (p == 0) width else half_width;
            const h = if (p == 0) height else half_height;
            for (0..h) |r| m.sys.CopyMem(f.planes[p] + r * f.stride[p], into[p] + r * pitch[p], w);
        }
    } else {
        const across: u32 = if (f.ss_x == 0) 2 else 1;
        const down: u32 = if (f.ss_y == 0) 2 else 1;
        if (f.alloc_bytes == 1) {
            average(u8, f, 0, into[0], y_pitch, width, height, 1, 1);
            for (1..3) |p| average(u8, f, p, into[p], c_pitch, half_width, half_height, across, down);
        } else {
            average(u16, f, 0, into[0], y_pitch, width, height, 1, 1);
            for (1..3) |p| average(u16, f, p, into[p], c_pitch, half_width, half_height, across, down);
        }
    }
    if (planes_memory & exec.MEMF_DMA != 0) m.sys.CacheClearE(planes.start, @intCast(planes.size), exec.CACRF_ClearD);
    frame.* = .{
        .picture = .{
            .y = into[0],
            .cb = into[1],
            .cr = into[2],
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

/// `width` by `height` samples of plane `p` into `into`, its rows `pitch`
/// apart: each the average of `across` by `down` of the plane's, rounded
/// to 8 bits. Where a block of them runs past the plane's edge - an odd
/// size - the plane's last row or column is taken again.
fn average(comptime T: type, f: *const vp9.Frame, p: usize, into: [*]u8, pitch: u32, width: u32, height: u32, across: u32, down: u32) void {
    const samples = f.plane(T, p);
    const stride = f.stride[p];
    const sx: u5 = if (p > 0) f.ss_x else 0;
    const sy: u5 = if (p > 0) f.ss_y else 0;
    const last_x = ((f.width + (@as(u32, 1) << sx) - 1) >> sx) - 1;
    const last_y = ((f.height + (@as(u32, 1) << sy) - 1) >> sy) - 1;
    const shift: u5 = @intCast(f.bit_depth - 8 + ((across * down) >> 1));
    const round: u32 = (@as(u32, 1) << shift) >> 1;
    for (0..height) |r| {
        const y = @as(u32, @intCast(r)) * down;
        const row0 = samples + y * stride;
        const row1 = samples + @min(y + down - 1, last_y) * stride;
        const out = into + r * pitch;
        if (across == 1) {
            for (0..width) |c| {
                const sum = @as(u32, row0[c]) + if (down == 2) @as(u32, row1[c]) else 0;
                out[c] = @intCast(@min((sum + round) >> shift, 255));
            }
        } else {
            for (0..width) |c| {
                const x = @as(u32, @intCast(c)) * 2;
                const x1 = @min(x + 1, last_x);
                const sum = @as(u32, row0[x]) + row0[x1] + row1[x] + row1[x1];
                out[c] = @intCast(@min((sum + round) >> shift, 255));
            }
        }
    }
}

/// An RGB frame - green, blue and red, each at full size - made YUV by
/// BT.709's matrix, the whole byte; each colour sample of four pixels'
/// average.
fn fromRgb(comptime T: type, f: *const vp9.Frame, into: [3][*]u8, pitch: [3]u32) void {
    const g = f.plane(T, 0);
    const b = f.plane(T, 1);
    const r = f.plane(T, 2);
    const stride = f.stride[0];
    const shift: u5 = @intCast(f.bit_depth - 8);
    // In 1/65536ths: Y = 0.2126 R + 0.7152 G + 0.0722 B, and the colours
    // (B - Y) / 1.8556 and (R - Y) / 1.5748 about 128.
    for (0..f.height) |y| {
        for (0..f.width) |x| {
            const i = y * stride + x;
            const lum = (13933 * @as(i32, r[i]) + 46871 * @as(i32, g[i]) + 4732 * @as(i32, b[i])) >> shift;
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
                sr += r[i];
                sg += g[i];
                sb += b[i];
            }
            // The four pixels' sums, in 1/65536ths of a sample, at 8 bits.
            const lum = (13933 * sr + 46871 * sg + 4732 * sb) >> shift;
            const bb = (sb << 16) >> shift;
            const rr = (sr << 16) >> shift;
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
