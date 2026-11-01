// SPDX-License-Identifier: MIT
//! chip.vcodec's decoder: H.264 and H.265 through the board's chip,
//! videodec.resource.
//!
//! The chip is fed a picture at a time and asked for frames in the order
//! they are shown; it says when it needs more (VDERR_NEED_DATA), which is
//! when ReceiveVCodecFrame asks for a packet. A packet sent is turned into
//! Annex B form (`annexb.zig`) - with the parameter sets in front when it
//! is a key picture - and fed, with its time. At the end of the track the
//! chip is told so, and hands out the frames it still holds back.
//!
//! A packet the chip has no room for yet stays `pending` and is fed after
//! the next frame is taken; another packet sent meanwhile is refused
//! (VCERR_FULL). A frame is the chip's buffer, lent out as it is; its NV12
//! planes are the frame's picture.
//!
//! A track of a profile the chip has not - H.264 deeper than 8 bits or
//! with more colour than halved both ways, H.265's range extensions - is
//! refused when it opens (VCERR_UNSUPPORTED), for the software's module.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const utility = sdk.utility;
const videodec = sdk.resources.videodec;
const VideoDecBase = videodec.VideoDecBase;
const ExecBase = sdk.interface.exec.ExecBase;
const module = @import("../module.zig");
const Base = module.Base;
const annexb = @import("annexb.zig");

/// The least the chip keeps fed - its own default - and how many of the
/// largest packets at least; a Matroska file says not how large its
/// largest is, and gets room for four of 2 MiB.
const stream_bytes: usize = 2 * 1024 * 1024;
const packets_kept = 4;

/// What a frame's `private[1]` holds, so a frame that is not one of this
/// decoder's is passed by: "CHIP".
const frame_mark: u32 = 0x4348_4950;

const Decoder = struct {
    sys: *ExecBase,
    vb: *VideoDecBase,
    decoder: *videodec.VideoDecoder,
    codec: u32,
    /// How many bytes each unit's length takes in the track's packets.
    length_size: u8 = 4,
    /// The parameter sets in Annex B form, put in front of each key
    /// picture.
    header: ?[*]u8 = null,
    header_size: usize = 0,
    /// A packet in Annex B form, and how large that buffer is.
    buffer: ?[*]u8 = null,
    buffer_size: usize = 0,
    /// The bytes in `buffer` waiting to be fed, and their time.
    pending: usize = 0,
    pending_time: i64 = 0,
    /// The frames lent out, by slot.
    held: u32,
    lent: [vcodec.VCODEC_MOST_HELD]bool = @splat(false),
    frames: [vcodec.VCODEC_MOST_HELD]videodec.VideoDecFrame = @splat(.{}),
};

fn of(decoder: *vcodec.VCodecDecoder) *Decoder {
    return @ptrCast(@alignCast(decoder));
}

/// What the chip read from the stream: its size as shown, its rate, its
/// depth.
pub fn GetVCodecInfo(_: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) i32 {
    const c = of(decoder);
    var asked: videodec.VideoDecInfo = .{};
    if (c.vb.GetVideoDecoderInfo(c.decoder, &asked) != videodec.VDERR_OK or asked.width == 0) return vc.VCERR_NEED_DATA;
    info.* = .{
        .width = asked.width,
        .height = asked.height,
        .rate_num = asked.rate_num,
        .rate_den = asked.rate_den,
        .depth = asked.bit_depth,
    };
    return vc.VCERR_OK;
}

/// The chip's decoder opened for the track's codec, its setup read.
pub fn OpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
    var code: i32 = vc.VCERR_OK;
    const decoder = open(base.sys_base, params, &code);
    if (err) |out| out.* = code;
    return decoder;
}

fn open(sys: *ExecBase, params: *const vcodec.VCodecParams, code: *i32) ?*vcodec.VCodecDecoder {
    const codec: u32 = switch (params.codec) {
        vc.VCODEC_H264 => videodec.VDCODEC_H264,
        vc.VCODEC_H265 => videodec.VDCODEC_H265,
        else => return failed(code, vc.VCERR_NOCODEC),
    };
    if (params.held == 0 or params.held > vcodec.VCODEC_MOST_HELD) return failed(code, vc.VCERR_UNSUPPORTED);
    const found = sys.OpenResource(videodec.VIDEODECNAME) orelse return failed(code, vc.VCERR_NOCODEC);
    const vb: *VideoDecBase = @ptrCast(@alignCast(found));
    if (vb.VideoDecCodecs() & codec == 0) return failed(code, vc.VCERR_NOCODEC);

    const config: []const u8 = if (params.config) |bytes| bytes[0..params.config_size] else &.{};
    const setup = (if (codec == videodec.VDCODEC_H265) annexb.hevcSetup(config, null) else annexb.avcSetup(config, null)) orelse
        return failed(code, vc.VCERR_CORRUPT);
    // A profile the chip has not: the software's, at once.
    if (!annexb.chipTakes(codec == videodec.VDCODEC_H265, config)) return failed(code, vc.VCERR_UNSUPPORTED);
    const memory = sys.AllocVec(@sizeOf(Decoder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(code, vc.VCERR_NOMEMORY);
    const c: *Decoder = @ptrCast(@alignCast(memory));
    c.* = .{ .sys = sys, .vb = vb, .decoder = undefined, .codec = codec, .length_size = setup.length_size, .held = params.held };
    if (setup.header_size != 0) {
        const header = sys.AllocVec(setup.header_size, exec.MEMF_ANY) orelse {
            sys.FreeVec(c);
            return failed(code, vc.VCERR_NOMEMORY);
        };
        c.header = @ptrCast(header);
        c.header_size = setup.header_size;
        const out = c.header.?[0..setup.header_size];
        _ = if (codec == videodec.VDCODEC_H265) annexb.hevcSetup(config, out) else annexb.avcSetup(config, out);
    }

    var err: u32 = videodec.VDERR_OK;
    const largest: usize = if (params.max_packet != 0) params.max_packet else stream_bytes;
    const kept = @max(stream_bytes, largest * packets_kept + c.header_size);
    c.decoder = vb.OpenVideoDecoder(codec, &[_]utility.TagItem{
        .{ .tag = videodec.VDA_StreamSize, .data = kept },
        .{ .tag = videodec.VDA_HeldFrames, .data = params.held },
        .{},
    }, &err) orelse {
        sys.FreeVec(c.header);
        sys.FreeVec(c);
        return failed(code, fromChip(err));
    };
    return @ptrCast(c);
}

fn failed(code: *i32, why: i32) ?*vcodec.VCodecDecoder {
    code.* = why;
    return null;
}

/// The chip's decoder closed, with the frames still lent; the buffers
/// freed.
pub fn CloseVCodec(_: *Base, decoder: ?*vcodec.VCodecDecoder) void {
    const c = of(decoder orelse return);
    const sys = c.sys;
    c.vb.CloseVideoDecoder(c.decoder);
    sys.FreeVec(c.header);
    sys.FreeVec(c.buffer);
    sys.FreeVec(c);
}

/// A packet turned into Annex B form and fed - or held, when the chip
/// has no room yet; the end of the track told the chip.
pub fn SendVCodecPacket(_: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) i32 {
    const c = of(decoder);
    if (c.pending != 0) return vc.VCERR_FULL;
    if (packet.flags & vcodec.VCPKT_END != 0) return fromChip(c.vb.FeedVideoDecoder(c.decoder, null, 0, 0, videodec.VDFEED_END));
    const data = packet.data orelse return vc.VCERR_CORRUPT;
    const units = data[0..packet.size];
    const size = annexb.convertedSize(units, c.length_size) orelse return vc.VCERR_CORRUPT;
    const key = packet.flags & vcodec.VCPKT_KEY != 0;
    const whole = size + if (key) c.header_size else 0;
    if (whole > c.buffer_size) {
        c.sys.FreeVec(c.buffer);
        c.buffer_size = 0;
        const memory = c.sys.AllocVec(whole, exec.MEMF_ANY) orelse {
            c.buffer = null;
            return vc.VCERR_NOMEMORY;
        };
        c.buffer = @ptrCast(memory);
        c.buffer_size = whole;
    }
    const out = c.buffer.?[0..whole];
    var at: usize = 0;
    if (key and c.header_size != 0) {
        c.sys.CopyMem(c.header.?, out.ptr, c.header_size);
        at = c.header_size;
    }
    at += annexb.convert(units, c.length_size, out[at..], Copy{ .sys = c.sys });
    c.pending = at;
    c.pending_time = packet.time;
    const fed = feedPending(c);
    // No room yet: it goes in after the next frame is taken.
    if (fed == videodec.VDERR_FULL) return vc.VCERR_OK;
    return fromChip(fed);
}

/// The next frame to be shown, lent: the chip asked for one, and while it
/// needs data a packet held fed - or asked for.
pub fn ReceiveVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) i32 {
    const c = of(decoder);
    const slot = module.freeSlot(&c.lent, c.held) orelse return vc.VCERR_BUSY;
    var got: videodec.VideoDecFrame = .{};
    while (true) {
        switch (c.vb.DecodeVideoFrame(c.decoder, &got)) {
            videodec.VDERR_OK => {
                c.frames[slot] = got;
                c.lent[slot] = true;
                lend(frame, &got, slot);
                // A packet that found no room goes in now there is some.
                if (c.pending != 0) _ = feedPending(c);
                return vc.VCERR_OK;
            },
            videodec.VDERR_NEED_DATA => {
                if (c.pending == 0) return vc.VCERR_NEED_DATA;
                // It found no room, and the chip needs data: it can take
                // no more than it has. Passed over, rather than asked
                // about forever.
                const fed = feedPending(c);
                if (fed == videodec.VDERR_FULL) {
                    c.pending = 0;
                    return vc.VCERR_CORRUPT;
                }
                if (fed != videodec.VDERR_OK) return fromChip(fed);
            },
            videodec.VDERR_END => return vc.VCERR_END,
            else => |code| return fromChip(code),
        }
    }
}

/// A frame lent out given back to the chip.
pub fn ReleaseVCodecFrame(_: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) void {
    const c = of(decoder);
    const slot = module.slotOf(&c.lent, frame, frame_mark) orelse return;
    c.vb.ReleaseVideoFrame(c.decoder, &c.frames[slot]);
    c.frames[slot] = .{};
    c.lent[slot] = false;
}

/// What was fed and not yet shown dropped, for a seek: the chip starts
/// again at the next key picture.
pub fn FlushVCodec(_: *Base, decoder: *vcodec.VCodecDecoder) void {
    const c = of(decoder);
    c.vb.FlushVideoDecoder(c.decoder);
    c.pending = 0;
}

/// The chip's frame as the program's: its NV12 planes, BT.709 for a
/// picture 720 rows high or more and BT.601 below, as video is made.
fn lend(frame: *vc.VideoFrame, got: *const videodec.VideoDecFrame, slot: u32) void {
    frame.* = .{
        .picture = .{
            .y = got.y.?,
            .cb = got.cbcr.?,
            .y_pitch = got.pitch,
            .c_pitch = got.pitch,
            .layout = rtg.RTGYUV_NV12,
            .colors = if (got.height >= 720) rtg.RTGYUV_BT709 else rtg.RTGYUV_BT601,
        },
        .width = got.width,
        .height = got.height,
        .time = @bitCast(got.time),
        .private = .{ slot + 1, frame_mark, 0 },
    };
}

fn feedPending(c: *Decoder) u32 {
    const fed = c.vb.FeedVideoDecoder(c.decoder, c.buffer.?, @intCast(c.pending), @bitCast(c.pending_time), 0);
    if (fed == videodec.VDERR_OK) c.pending = 0;
    return fed;
}

/// The units copied by exec, whose copy each board has its own of.
const Copy = struct {
    sys: *ExecBase,
    pub fn bytes(copy: Copy, from: []const u8, into: []u8) void {
        if (from.len != 0) copy.sys.CopyMem(from.ptr, into.ptr, from.len);
    }
};

/// A videodec.resource answer as a module's.
fn fromChip(code: u32) i32 {
    return switch (code) {
        videodec.VDERR_OK => vc.VCERR_OK,
        videodec.VDERR_END => vc.VCERR_END,
        videodec.VDERR_NO_ENGINE => vc.VCERR_NOCODEC,
        videodec.VDERR_UNSUPPORTED => vc.VCERR_UNSUPPORTED,
        videodec.VDERR_NO_MEMORY => vc.VCERR_NOMEMORY,
        videodec.VDERR_BUSY => vc.VCERR_BUSY,
        videodec.VDERR_FULL => vc.VCERR_FULL,
        else => vc.VCERR_CORRUPT,
    };
}
