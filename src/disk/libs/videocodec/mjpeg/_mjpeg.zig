// SPDX-License-Identifier: MIT
//! Motion JPEG decoded by the library itself: each packet a JPEG picture
//! whole, unpacked by jpeg.datatype's decoder (built in as the inner
//! module `jpegdecode`) into a plane for each of its components - which
//! is the frame, as it is, for a picture whose colour is halved both
//! ways.
//!
//! **The planes** of the frame lent in a slot are that slot's memory,
//! made at its first frame and made again when the pictures' size or
//! sampling changes. A picture with its colour halved across only (4:2:2)
//! is shown every other colour row, by a chroma pitch of two rows; one
//! with its colour at full size (4:4:4) has it averaged two by two into
//! planes of half the size; a grey one has colour planes of 128, the
//! middle, which are filled once.
//!
//! The colours are JFIF's: BT.601, the whole byte.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const jpeg = @import("jpegdecode");
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

/// How a picture keeps its colour, as far as the frame cares.
const Sampling = enum(u8) { grey = 1, halved, across, full };

/// A slot's planes: one block of memory, and what it was made for.
const Planes = struct {
    memory: ?[*]u8 = null,
    size: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    sampling: u8 = 0,
};

pub const Mjpeg = struct {
    /// The decoder's tables and the block it works on: too large for a
    /// stack.
    work: ?*jpeg.Work = null,
    planes: [_stream.held_frames]Planes = @splat(.{}),
};

/// The decoder's work made. VCERR_OK, or VCERR_NOMEMORY.
pub fn open(s: *Stream) i32 {
    s.engine = .{ .mjpeg = .{} };
    const memory = s.sys.AllocVec(@sizeOf(jpeg.Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return vc.VCERR_NOMEMORY;
    s.engine.mjpeg.work = @ptrCast(@alignCast(memory));
    return vc.VCERR_OK;
}

pub fn close(s: *Stream) void {
    const m = &s.engine.mjpeg;
    s.sys.FreeVec(m.work);
    for (&m.planes) |*planes| s.sys.FreeVec(planes.memory);
    m.* = .{};
}

/// The next picture decoded into `slot`'s planes and lent in `frame`:
/// VCERR_OK, VCERR_END after the last, or why not. A picture that is not
/// right is passed over and said to be (VCERR_CORRUPT).
pub fn decode(s: *Stream, frame: *vc.VideoFrame, slot: u32) i32 {
    const m = &s.engine.mjpeg;
    const work = m.work.?;
    var packet: media.MediaPacket = .{};
    while (true) {
        const read = _stream.nextPacket(s, &packet);
        if (read != media.MERR_OK) return _stream.fromMedia(read);
        if (packet.pts >= s.shown_from) break;
    }
    const bytes = packet.data.?[0..packet.size];
    work.* = .{};
    jpeg.readHeaders(bytes, work) catch |failure| return switch (failure) {
        jpeg.Error.Unsupported => vc.VCERR_UNSUPPORTED,
        else => vc.VCERR_CORRUPT,
    };
    const sampling = samplingOf(work) orelse return vc.VCERR_UNSUPPORTED;
    const planes = &m.planes[slot];
    const made = make(s, planes, work, sampling);
    if (made != vc.VCERR_OK) return made;
    jpeg.readScan(bytes, work) catch return vc.VCERR_CORRUPT;

    const luma = &work.component[0];
    const half_width = (work.width + 1) / 2;
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
                halve(&work.component[1], extra.cb, half_width, (work.height + 1) / 2);
                halve(&work.component[2], extra.cr, half_width, (work.height + 1) / 2);
            }
            picture.cb = extra.cb;
            picture.cr = extra.cr;
            picture.c_pitch = half_width;
        },
    }
    frame.* = .{ .picture = picture, .width = work.width, .height = work.height, .time = packet.pts };
    return vc.VCERR_OK;
}

/// Nothing to give back: the planes stay the slot's for its next frame.
pub fn release(s: *Stream, slot: u32) void {
    _ = s;
    _ = slot;
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
    return @as(usize, (work.width + 1) / 2) * ((work.height + 1) / 2);
}

/// The slot's planes made for the picture, or kept when they were made
/// for one of its size and sampling; each component given its own.
/// VCERR_OK, or VCERR_NOMEMORY.
fn make(s: *Stream, planes: *Planes, work: *jpeg.Work, sampling: Sampling) i32 {
    var size: usize = 0;
    for (work.component[0..work.count]) |*component| {
        component.stride = jpeg.planeStride(work, component);
        component.lines = jpeg.planeLines(work, component);
        size += @as(usize, component.stride) * component.lines;
    }
    if (sampling == .full or sampling == .grey) size += 2 * halfPlane(work);
    const same = planes.memory != null and planes.width == work.width and planes.height == work.height and
        planes.sampling == @intFromEnum(sampling) and planes.size >= size;
    if (!same) {
        s.sys.FreeVec(planes.memory);
        planes.* = .{};
        const memory = s.sys.AllocVec(size, exec.MEMF_ANY) orelse return vc.VCERR_NOMEMORY;
        planes.* = .{
            .memory = @ptrCast(memory),
            .size = size,
            .width = work.width,
            .height = work.height,
            .sampling = @intFromEnum(sampling),
        };
    }
    var at: usize = 0;
    for (work.component[0..work.count]) |*component| {
        component.plane = planes.memory.? + at;
        at += @as(usize, component.stride) * component.lines;
    }
    // A grey picture's colour: the middle, filled once.
    if (!same and sampling == .grey) s.sys.SetMem(planes.memory.? + at, 128, 2 * halfPlane(work));
    return vc.VCERR_OK;
}

/// The two colour planes of half the size, behind the components'.
fn extraPlanes(planes: *const Planes, work: *const jpeg.Work) struct { cb: [*]u8, cr: [*]u8 } {
    var at: usize = 0;
    for (work.component[0..work.count]) |component| at += @as(usize, component.stride) * component.lines;
    const memory = planes.memory.?;
    return .{ .cb = memory + at, .cr = memory + at + halfPlane(work) };
}

/// A colour plane at full size averaged two by two into `into`, `width`
/// by `height` of half the size. The plane runs in whole blocks, past
/// the picture's edge, so every pair has its second.
fn halve(component: *const jpeg.Component, into: [*]u8, width: u32, height: u32) void {
    const stride = component.stride;
    for (0..height) |y| {
        const top = component.plane + 2 * y * stride;
        const bottom = top + stride;
        const out = into + y * width;
        for (0..width) |x| {
            const sum = @as(u32, top[2 * x]) + top[2 * x + 1] + bottom[2 * x] + bottom[2 * x + 1];
            out[x] = @intCast((sum + 2) / 4);
        }
    }
}
