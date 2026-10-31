// SPDX-License-Identifier: MIT
//! vp8.vcodec's decoder: VP8 decoded in software by the decoder built in
//! as `vp8core` (core.zig here), which takes the stream a frame at a time
//! and shows each frame as it comes, but those it hides.
//!
//! **A packet sent** is a frame, which is decoded at once; the frame it
//! shows waits until it is asked for, and while it waits another packet
//! is refused (VCERR_FULL). A frame hidden - an alternate reference, for
//! the frames after it - shows nothing. One marked VCPKT_DROP, due before
//! what is shown, is decoded for the frames after it and not handed out.
//! A frame that is not right is passed over: the references stay as they
//! were. There is no setup.
//!
//! **The frames** are each frame copied into the planes of the slot it is
//! lent in, I420 as the decoder has it. The planes are made where a
//! display's video layer reads them - below 4 GiB on the 64-bit machines
//! where there is room there - each plane and each of its rows starting
//! on 16 bytes, and written out of the caches once the picture is in
//! them. The colours are BT.601, the one space VP8 has; the whole byte
//! when the key frame's clamping bit is set, as ffmpeg reads it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const ExecBase = sdk.interface.exec.ExecBase;
const vp8 = @import("vp8core");
const module = @import("../module.zig");
const Base = module.Base;

/// Where the planes are made: below 4 GiB on the 64-bit machines, where
/// a display reads them; anywhere on the others, where only the processor
/// does.
const planes_memory: u32 = if (@sizeOf(usize) == 8) exec.MEMF_DMA else exec.MEMF_ANY;
/// What each plane and each of its rows starts on.
const plane_alignment = 16;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "VP80".
const frame_mark: u32 = 0x5650_3830;

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
    core: *vp8.Decoder,
    /// The frames lent out, by slot, and their planes.
    held: u32,
    lent: [vcodec.VCODEC_MOST_HELD]bool = @splat(false),
    planes: [vcodec.VCODEC_MOST_HELD]Planes = @splat(.{}),
    /// The frame decoded and not yet handed out - the decoder's, until it
    /// decodes the next - and when it is shown.
    waiting: ?*const vp8.Frame = null,
    time: i64 = 0,
    /// The end of the track was sent.
    ended: bool = false,
    /// A frame was handed out: one the decoder cannot decode is passed
    /// over from then on, rather than refused for another module.
    started: bool = false,
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

/// The pictures' size as shown, once a key frame said it; VP8 says no
/// rate.
pub fn GetVCodecInfo(_: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) i32 {
    const m = of(decoder);
    if (m.core.width == 0) return vc.VCERR_NEED_DATA;
    info.* = .{ .width = m.core.width, .height = m.core.height, .depth = 8 };
    return vc.VCERR_OK;
}

/// The decoder made, for VP8.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    var code: i32 = vc.VCERR_OK;
    const decoder = open(base.sys_base, params, &code);
    if (err) |out| out.* = code;
    return decoder;
}

fn open(sys: *ExecBase, params: *const vcodec.VCodecParams, code: *i32) ?*vcodec.VCodecDecoder {
    if (params.codec != vc.VCODEC_VP8) return failed(code, vc.VCERR_NOCODEC);
    if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) return failed(code, vc.VCERR_UNSUPPORTED);
    const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(code, vc.VCERR_NOMEMORY);
    const m: *Decoder = @ptrCast(@alignCast(memory));
    const env: vp8.Env = .{ .ctx = @ptrCast(sys), .alloc = Memory.alloc, .free = Memory.free };
    const core = vp8.Decoder.create(env) orelse {
        sys.FreeVec(m);
        return failed(code, vc.VCERR_NOMEMORY);
    };
    m.* = .{ .sys = sys, .core = core, .held = params.held };
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
    m.core.destroy();
    for (&m.planes) |*planes| sys.FreeVec(planes.memory);
    sys.FreeVec(m);
}

/// A frame decoded, the one it shows kept until it is asked for; the end
/// noted.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const m = of(decoder);
    if (m.waiting != null) return vc.VCERR_FULL;
    if (packet.flags & vcodec.VCPKT_END != 0) {
        m.ended = true;
        return vc.VCERR_OK;
    }
    const data = packet.data orelse return vc.VCERR_CORRUPT;
    const shown = m.core.decodeFrame(data[0..packet.size]) catch |failure| return switch (failure) {
        error.NoMemory => vc.VCERR_NOMEMORY,
        error.Unsupported => if (m.started) vc.VCERR_OK else vc.VCERR_UNSUPPORTED,
        else => vc.VCERR_OK,
    };
    if (packet.flags & vcodec.VCPKT_DROP != 0) return vc.VCERR_OK;
    if (shown) |f| {
        m.waiting = f;
        m.time = packet.time;
    }
    return vc.VCERR_OK;
}

/// The frame waiting copied into a free slot's planes and lent in
/// `frame`.
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const m = of(decoder);
    const slot = module.freeSlot(&m.lent, m.held) orelse return vc.VCERR_BUSY;
    const f = m.waiting orelse return if (m.ended) vc.VCERR_END else vc.VCERR_NEED_DATA;
    m.waiting = null;
    const made = copyOut(m, f, frame, slot);
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

/// The frame waiting dropped and the references with it, for a seek: the
/// decoder starts again at the next key frame.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const m = of(decoder);
    m.core.reset();
    m.waiting = null;
    m.ended = false;
}

/// Frame `f` copied into `slot`'s planes, the part shown, and lent in
/// `frame`.
fn copyOut(m: *Decoder, f: *const vp8.Frame, frame: *vc.VideoFrame, slot: u32) i32 {
    const width = m.core.width;
    const height = m.core.height;
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
    for (0..3) |p| {
        const w = if (p == 0) width else half_width;
        const h = if (p == 0) height else half_height;
        for (0..h) |r| m.sys.CopyMem(f.planes[p] + r * f.stride[p], into[p] + r * pitch[p], w);
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
            .colors = rtg.RTGYUV_BT601 | if (m.core.full_range) rtg.RTGYUV_FULL else 0,
        },
        .width = width,
        .height = height,
        .time = m.time,
    };
    return vc.VCERR_OK;
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
