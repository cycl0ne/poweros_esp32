// SPDX-License-Identifier: MIT
//! mjpeg.vcodec's decoder: Motion JPEG decoded in software, each packet a
//! JPEG picture whole, unpacked by jpeg.datatype's decoder (built in as
//! the inner module `jpegdecode`) into a plane for each of its components
//! - which is the frame, as it is, for a picture whose colour is halved
//! both ways.
//!
//! **A packet sent** is copied, and decoded when the next frame is asked
//! for; another sent before that is refused (VCERR_FULL). Each picture
//! stands alone, so one marked VCPKT_DROP - due before what is shown - is
//! not decoded at all.
//!
//! **The planes** of the frame lent in a slot are that slot's memory,
//! made at its first frame and made again when the pictures' size or
//! sampling changes. A picture with its colour halved across only (4:2:2)
//! is shown every other colour row, by a chroma pitch of two rows; one
//! with its colour at full size (4:4:4) has it averaged two by two into
//! planes of half the size; a grey one has colour planes of 128, the
//! middle, which are filled once.
//!
//! The planes are made where a display's video layer reads them, as it
//! reads a decoder's frames (`ShowVideoFrame`): below 4 GiB on the 64-bit
//! machines where there is room there - anywhere otherwise, which a
//! layer refuses - each plane and each of its rows starting on 16 bytes,
//! and written out of the caches once the picture is in them.
//!
//! The colours are JFIF's: BT.601, the whole byte.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const ExecBase = sdk.interface.exec.ExecBase;
const jpeg = @import("jpegdecode");
const module = @import("../module.zig");
const Base = module.Base;

/// How a picture keeps its colour, as far as the frame cares.
const Sampling = enum(u8) { grey = 1, halved, across, full };

/// Where the planes are made: below 4 GiB on the 64-bit machines, where
/// a display reads them; anywhere on the others, where only the processor
/// does.
const planes_memory: u32 = if (@sizeOf(usize) == 8) exec.MEMF_DMA else exec.MEMF_ANY;
/// What each plane and each of its rows starts on.
const plane_alignment = 16;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "MJPG".
const frame_mark: u32 = 0x4D4A_5047;

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
/// the planes start in it - and what it was made for.
const Planes = struct {
    memory: ?[*]u8 = null,
    start: [*]u8 = undefined,
    size: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    sampling: u8 = 0,
};

const Decoder = struct {
    sys: *ExecBase,
    /// The decoder's tables and the block it works on: too large for a
    /// stack.
    work: *jpeg.Work,
    /// The frames lent out, by slot, and their planes.
    held: u32,
    lent: [vcodec.VCODEC_MOST_HELD]bool = @splat(false),
    planes: [vcodec.VCODEC_MOST_HELD]Planes = @splat(.{}),
    /// The picture sent and not yet decoded: its bytes copied, how many,
    /// how large that buffer is, and its time.
    packet: ?[*]u8 = null,
    packet_size: usize = 0,
    packet_room: usize = 0,
    pending: bool = false,
    time: i64 = 0,
    /// The end of the track was sent.
    ended: bool = false,
    /// The last picture's size, once there has been one.
    width: u32 = 0,
    height: u32 = 0,
};

fn of(decoder: *vcodec.VCodecDecoder) *Decoder {
    return @ptrCast(@alignCast(decoder));
}

/// The last picture's size; JPEG says no rate.
pub fn GetVCodecInfo(_: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) i32 {
    const m = of(decoder);
    if (m.width == 0) return vc.VCERR_NEED_DATA;
    info.* = .{ .width = m.width, .height = m.height, .depth = 8 };
    return vc.VCERR_OK;
}

/// The decoder's work made, for Motion JPEG.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    const sys = base.sys_base;
    var code: i32 = vc.VCERR_OK;
    const decoder: ?*vcodec.VCodecDecoder = made: {
        if (params.codec != vc.VCODEC_MJPEG) {
            code = vc.VCERR_NOCODEC;
            break :made null;
        }
        if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) {
            code = vc.VCERR_UNSUPPORTED;
            break :made null;
        }
        const work = sys.AllocVec(@sizeOf(jpeg.Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            code = vc.VCERR_NOMEMORY;
            break :made null;
        };
        const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(work);
            code = vc.VCERR_NOMEMORY;
            break :made null;
        };
        const m: *Decoder = @ptrCast(@alignCast(memory));
        m.* = .{ .sys = sys, .work = @ptrCast(@alignCast(work)), .held = params.held };
        break :made @ptrCast(m);
    };
    if (err) |out| out.* = code;
    return decoder;
}

/// The decoder's memory freed, the planes of the frames still lent too.
pub fn CloseVCodec(_: *Base, decoder: ?*vcodec.VCodecDecoder) void {
    const m = of(decoder orelse return);
    const sys = m.sys;
    sys.FreeVec(m.work);
    for (&m.planes) |*planes| sys.FreeVec(planes.memory);
    sys.FreeVec(m.packet);
    sys.FreeVec(m);
}

/// A picture copied, to be decoded when its frame is asked for; one due
/// before what is shown passed over; the end noted.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const m = of(decoder);
    if (m.pending) return vc.VCERR_FULL;
    if (packet.flags & vcodec.VCPKT_END != 0) {
        m.ended = true;
        return vc.VCERR_OK;
    }
    if (packet.flags & vcodec.VCPKT_DROP != 0) return vc.VCERR_OK;
    const data = packet.data orelse return vc.VCERR_CORRUPT;
    if (packet.size > m.packet_room) {
        m.sys.FreeVec(m.packet);
        m.packet_room = 0;
        const memory = m.sys.AllocVec(packet.size, exec.MEMF_ANY) orelse {
            m.packet = null;
            return vc.VCERR_NOMEMORY;
        };
        m.packet = @ptrCast(memory);
        m.packet_room = packet.size;
    }
    if (packet.size != 0) m.sys.CopyMem(data, m.packet.?, packet.size);
    m.packet_size = packet.size;
    m.time = packet.time;
    m.pending = true;
    return vc.VCERR_OK;
}

/// The picture sent decoded into a free slot's planes and lent in
/// `frame`. A picture that is not right is passed over and said to be
/// (VCERR_CORRUPT).
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const m = of(decoder);
    const slot = module.freeSlot(&m.lent, m.held) orelse return vc.VCERR_BUSY;
    if (!m.pending) return if (m.ended) vc.VCERR_END else vc.VCERR_NEED_DATA;
    m.pending = false;
    const made = decode(m, frame, slot);
    if (made != vc.VCERR_OK) return made;
    m.lent[slot] = true;
    frame.private = .{ slot + 1, frame_mark, 0 };
    m.width = frame.width;
    m.height = frame.height;
    return vc.VCERR_OK;
}

/// Nothing to give back but the slot: its planes stay its own for its
/// next frame.
pub fn ReleaseVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) void {
    const m = of(decoder);
    const slot = module.slotOf(&m.lent, frame, frame_mark) orelse return;
    m.lent[slot] = false;
}

/// The picture sent and not decoded forgotten, and the end.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const m = of(decoder);
    m.pending = false;
    m.ended = false;
}

/// The packet decoded into `slot`'s planes and lent in `frame`.
fn decode(m: *Decoder, frame: *vc.VideoFrame, slot: u32) i32 {
    const work = m.work;
    const bytes = m.packet.?[0..m.packet_size];
    work.* = .{};
    jpeg.readHeaders(bytes, work) catch |failure| return switch (failure) {
        jpeg.Error.Unsupported => vc.VCERR_UNSUPPORTED,
        else => vc.VCERR_CORRUPT,
    };
    const sampling = samplingOf(work) orelse return vc.VCERR_UNSUPPORTED;
    const planes = &m.planes[slot];
    const made = make(m.sys, planes, work, sampling);
    if (made != vc.VCERR_OK) return made;
    jpeg.readScan(bytes, work) catch return vc.VCERR_CORRUPT;

    const luma = &work.component[0];
    const half_width = (work.width + 1) / 2;
    const half_pitch = aligned(half_width);
    var picture: rtg.RtgYuv = .{
        .y = luma.plane,
        .cb = undefined,
        .y_pitch = luma.stride,
        .c_pitch = 0,
        .layout = rtg.RTGYUV_I420,
        .colors = rtg.RTGYUV_BT601 | rtg.RTGYUV_FULL,
    };
    switch (sampling) {
        .halved, .across => {
            picture.cb = work.component[1].plane;
            picture.cr = work.component[2].plane;
            picture.c_pitch = work.component[1].stride * @as(u32, if (sampling == .across) 2 else 1);
        },
        .full, .grey => {
            const extra = extraPlanes(planes, work);
            if (sampling == .full) {
                halve(&work.component[1], extra.cb, half_width, half_pitch, (work.height + 1) / 2);
                halve(&work.component[2], extra.cr, half_width, half_pitch, (work.height + 1) / 2);
            }
            picture.cb = extra.cb;
            picture.cr = extra.cr;
            picture.c_pitch = half_pitch;
        },
    }
    if (planes_memory & exec.MEMF_DMA != 0) m.sys.CacheClearE(planes.start, @intCast(planes.size), exec.CACRF_ClearD);
    frame.* = .{ .picture = picture, .width = work.width, .height = work.height, .time = m.time };
    return vc.VCERR_OK;
}

/// The picture's sampling, if the frame can be made of it: grey, or its
/// colour halved both ways, across only, or kept whole. It is the
/// brightness's blocks against the colour's that count: ffmpeg writes
/// 4:2:2 as two by two against one by two.
fn samplingOf(work: *const jpeg.Work) ?Sampling {
    if (work.count == 1) return .grey;
    if (work.count != 3) return null;
    const luma = work.component[0];
    const blue = work.component[1];
    const red = work.component[2];
    if (blue.across != red.across or blue.down != red.down) return null;
    if (luma.across % blue.across != 0 or luma.down % blue.down != 0) return null;
    const across = luma.across / blue.across;
    const down = luma.down / blue.down;
    if (across == 2 and down == 2) return .halved;
    if (across == 2 and down == 1) return .across;
    if (across == 1 and down == 1) return .full;
    return null;
}

/// How many bytes the colour planes of half the size take, each.
fn halfPlane(work: *const jpeg.Work) usize {
    return @as(usize, aligned((work.width + 1) / 2)) * ((work.height + 1) / 2);
}

/// The slot's planes made for the picture, or kept when they were made
/// for one of its size and sampling; each component given its own, its
/// rows a whole number of `plane_alignment` apart. VCERR_OK, or
/// VCERR_NOMEMORY.
fn make(sys: *ExecBase, planes: *Planes, work: *jpeg.Work, sampling: Sampling) i32 {
    var size: usize = 0;
    for (work.component[0..work.count]) |*component| {
        component.stride = aligned(jpeg.planeStride(work, component));
        component.lines = jpeg.planeLines(work, component);
        size += @as(usize, component.stride) * component.lines;
    }
    if (sampling == .full or sampling == .grey) size += 2 * halfPlane(work);
    const same = planes.memory != null and planes.width == work.width and planes.height == work.height and
        planes.sampling == @intFromEnum(sampling) and planes.size >= size;
    if (!same) {
        sys.FreeVec(planes.memory);
        planes.* = .{};
        const memory = sys.AllocVec(size + plane_alignment, placeFor(sys, size + plane_alignment)) orelse return vc.VCERR_NOMEMORY;
        const start = (@intFromPtr(memory) + plane_alignment - 1) & ~@as(usize, plane_alignment - 1);
        planes.* = .{
            .memory = @ptrCast(memory),
            .start = @ptrFromInt(start),
            .size = size,
            .width = work.width,
            .height = work.height,
            .sampling = @intFromEnum(sampling),
        };
    }
    var at: usize = 0;
    for (work.component[0..work.count]) |*component| {
        component.plane = planes.start + at;
        at += @as(usize, component.stride) * component.lines;
    }
    // A grey picture's colour: the middle, filled once.
    if (!same and sampling == .grey) sys.SetMem(planes.start + at, 128, 2 * halfPlane(work));
    return vc.VCERR_OK;
}

/// The two colour planes of half the size, behind the components'.
fn extraPlanes(planes: *const Planes, work: *const jpeg.Work) struct { cb: [*]u8, cr: [*]u8 } {
    var at: usize = 0;
    for (work.component[0..work.count]) |component| at += @as(usize, component.stride) * component.lines;
    return .{ .cb = planes.start + at, .cr = planes.start + at + halfPlane(work) };
}

/// A colour plane at full size averaged two by two into `into`, `width`
/// by `height` of half the size, its rows `pitch` apart. The plane runs
/// in whole blocks, past the picture's edge, so every pair has its
/// second.
fn halve(component: *const jpeg.Component, into: [*]u8, width: u32, pitch: u32, height: u32) void {
    const stride = component.stride;
    for (0..height) |y| {
        const top = component.plane + 2 * y * stride;
        const bottom = top + stride;
        const out = into + y * pitch;
        for (0..width) |x| {
            const sum = @as(u32, top[2 * x]) + top[2 * x + 1] + bottom[2 * x] + bottom[2 * x + 1];
            out[x] = @intCast((sum + 2) / 4);
        }
    }
}
