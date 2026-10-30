// SPDX-License-Identifier: MIT
//! H.264 and H.265 through the chip's decoder, videodec.resource.
//!
//! The decoder is fed a picture at a time and asked for frames in the
//! order they are shown; it says when it needs more (VDERR_NEED_DATA).
//! So a frame asked for is taken from the decoder, and while it needs
//! data the track's next packet is turned into Annex B form
//! (`annexb.zig`) - with the parameter sets in front when it is a key
//! picture - and fed, with its time. At the end of the track the decoder
//! is told so, and hands out the frames it still holds back.
//!
//! A packet the decoder has no room for yet stays `pending` and is fed
//! after the next frame is taken. A frame is the decoder's buffer, lent
//! out as it is; its NV12 planes are the frame's picture.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const rtg = sdk.rtg;
const vc = sdk.videocodec;
const utility = sdk.utility;
const videodec = sdk.resources.videodec;
const VideoDecBase = videodec.VideoDecBase;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const annexb = @import("annexb.zig");

/// The least the decoder keeps fed - its own default - and how many of
/// the largest packets at least; a Matroska file says not how large its
/// largest is, and gets room for four of 2 MiB.
const stream_bytes: usize = 2 * 1024 * 1024;
const packets_kept = 4;

pub const Chip = struct {
    vb: ?*VideoDecBase = null,
    decoder: ?*videodec.VideoDecoder = null,
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
    /// The decoder was told the track ended.
    fed_end: bool = false,
    /// The frames lent out, by slot.
    frames: [_stream.held_frames]videodec.VideoDecFrame = @splat(.{}),
};

/// The decoder opened for the track's codec, its setup read. VCERR_OK,
/// or why not.
pub fn open(s: *Stream) i32 {
    s.engine = .{ .chip = .{} };
    const c = &s.engine.chip;
    const found = s.sys.OpenResource(videodec.VIDEODECNAME) orelse return vc.VCERR_NOCODEC;
    const vb: *VideoDecBase = @ptrCast(@alignCast(found));
    const codec: u32 = if (s.codec == vc.VCODEC_H265) videodec.VDCODEC_H265 else videodec.VDCODEC_H264;
    if (vb.VideoDecCodecs() & codec == 0) return vc.VCERR_NOCODEC;
    c.vb = vb;

    const config: []const u8 = if (s.picture.config) |bytes| bytes[0..s.picture.config_size] else &.{};
    const setup = (if (codec == videodec.VDCODEC_H265) annexb.hevcSetup(config, null) else annexb.avcSetup(config, null)) orelse
        return vc.VCERR_CORRUPT;
    c.length_size = setup.length_size;
    if (setup.header_size != 0) {
        const memory = s.sys.AllocVec(setup.header_size, exec.MEMF_ANY) orelse return vc.VCERR_NOMEMORY;
        c.header = @ptrCast(memory);
        c.header_size = setup.header_size;
        const out = c.header.?[0..setup.header_size];
        _ = if (codec == videodec.VDCODEC_H265) annexb.hevcSetup(config, out) else annexb.avcSetup(config, out);
    }

    var err: u32 = videodec.VDERR_OK;
    const largest: usize = if (s.picture.max_packet != 0) s.picture.max_packet else stream_bytes;
    const kept = @max(stream_bytes, largest * packets_kept + c.header_size);
    c.decoder = vb.OpenVideoDecoder(codec, &[_]utility.TagItem{
        .{ .tag = videodec.VDA_StreamSize, .data = kept },
        .{ .tag = videodec.VDA_HeldFrames, .data = _stream.held_frames },
        .{},
    }, &err) orelse return fromChip(err);
    return vc.VCERR_OK;
}

/// The decoder closed, with the frames still lent; the buffers freed.
pub fn close(s: *Stream) void {
    const c = &s.engine.chip;
    if (c.decoder) |decoder| c.vb.?.CloseVideoDecoder(decoder);
    s.sys.FreeVec(c.header);
    s.sys.FreeVec(c.buffer);
    c.* = .{};
}

/// The next frame to be shown into `frame`, lent in `slot`: VCERR_OK,
/// VCERR_END after the last, or why not.
pub fn decode(s: *Stream, frame: *vc.VideoFrame, slot: u32) i32 {
    const c = &s.engine.chip;
    const vb = c.vb.?;
    const decoder = c.decoder.?;
    var got: videodec.VideoDecFrame = .{};
    while (true) {
        switch (vb.DecodeVideoFrame(decoder, &got)) {
            videodec.VDERR_OK => {
                const time: i64 = @bitCast(got.time);
                if (time < s.shown_from) {
                    vb.ReleaseVideoFrame(decoder, &got);
                    continue;
                }
                c.frames[slot] = got;
                lend(frame, &got, time);
                // A packet that found no room goes in now there is some.
                if (c.pending != 0) _ = feedPending(c);
                return vc.VCERR_OK;
            },
            videodec.VDERR_NEED_DATA => {
                const fed = feed(s);
                if (fed != vc.VCERR_OK) return fed;
            },
            videodec.VDERR_END => return vc.VCERR_END,
            else => |code| return fromChip(code),
        }
    }
}

/// A frame lent out given back to the decoder.
pub fn release(s: *Stream, slot: u32) void {
    const c = &s.engine.chip;
    c.vb.?.ReleaseVideoFrame(c.decoder.?, &c.frames[slot]);
    c.frames[slot] = .{};
}

/// What was fed and not yet shown dropped, for a seek: the decoder
/// starts again at the next key picture.
pub fn flush(s: *Stream) void {
    const c = &s.engine.chip;
    c.vb.?.FlushVideoDecoder(c.decoder.?);
    c.pending = 0;
    c.fed_end = false;
}

/// The picture's size and rate as the decoder reads them from the
/// stream, once it has.
pub fn streamInfo(s: *Stream, info: *vc.VideoStreamInfo) void {
    const c = &s.engine.chip;
    var asked: videodec.VideoDecInfo = .{};
    if (c.vb.?.GetVideoDecoderInfo(c.decoder.?, &asked) != videodec.VDERR_OK) return;
    if (asked.width != 0) {
        info.width = asked.width;
        info.height = asked.height;
    }
    if (info.rate_num == 0 and asked.rate_num != 0) {
        info.rate_num = asked.rate_num;
        info.rate_den = asked.rate_den;
    }
}

/// The decoder's frame as the program's: its NV12 planes, BT.709 for a
/// picture 720 rows high or more and BT.601 below, as video is made.
fn lend(frame: *vc.VideoFrame, got: *const videodec.VideoDecFrame, time: i64) void {
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
        .time = time,
    };
}

/// The track's next packet fed, or the decoder told the track ended.
/// VCERR_OK, or why not.
fn feed(s: *Stream) i32 {
    const c = &s.engine.chip;
    if (c.pending != 0) {
        // It found no room, and the decoder needs data: it can take no
        // more than it has. Passed over, rather than asked about forever.
        const fed = feedPending(c);
        if (fed == videodec.VDERR_FULL) {
            c.pending = 0;
            return vc.VCERR_CORRUPT;
        }
        return fromChip(fed);
    }
    if (c.fed_end) return vc.VCERR_END;
    var packet: media.MediaPacket = .{};
    const read = _stream.nextPacket(s, &packet);
    if (read == media.MERR_END) {
        c.fed_end = true;
        return fromChip(c.vb.?.FeedVideoDecoder(c.decoder.?, null, 0, 0, videodec.VDFEED_END));
    }
    if (read != media.MERR_OK) return _stream.fromMedia(read);
    const units = packet.data.?[0..packet.size];
    const size = annexb.convertedSize(units, c.length_size) orelse return vc.VCERR_CORRUPT;
    const key = packet.flags & media.MPKT_KEY != 0;
    const whole = size + if (key) c.header_size else 0;
    if (whole > c.buffer_size) {
        s.sys.FreeVec(c.buffer);
        c.buffer_size = 0;
        const memory = s.sys.AllocVec(whole, exec.MEMF_ANY) orelse {
            c.buffer = null;
            return vc.VCERR_NOMEMORY;
        };
        c.buffer = @ptrCast(memory);
        c.buffer_size = whole;
    }
    const out = c.buffer.?[0..whole];
    var at: usize = 0;
    if (key and c.header_size != 0) {
        s.sys.CopyMem(c.header.?, out.ptr, c.header_size);
        at = c.header_size;
    }
    at += annexb.convert(units, c.length_size, out[at..], Copy{ .sys = s.sys });
    c.pending = at;
    c.pending_time = packet.pts;
    const fed = feedPending(c);
    // No room yet: it goes in after the next frame is taken.
    if (fed == videodec.VDERR_FULL) return vc.VCERR_OK;
    return fromChip(fed);
}

fn feedPending(c: *Chip) u32 {
    const fed = c.vb.?.FeedVideoDecoder(c.decoder.?, c.buffer.?, @intCast(c.pending), @bitCast(c.pending_time), 0);
    if (fed == videodec.VDERR_OK) c.pending = 0;
    return fed;
}

/// The units copied by exec, whose copy each board has its own of.
const Copy = struct {
    sys: *sdk.interface.exec.ExecBase,
    pub fn bytes(copy: Copy, from: []const u8, into: []u8) void {
        if (from.len != 0) copy.sys.CopyMem(from.ptr, into.ptr, from.len);
    }
};

/// A videodec.resource answer as the library's.
pub fn fromChip(code: u32) i32 {
    return switch (code) {
        videodec.VDERR_OK => vc.VCERR_OK,
        videodec.VDERR_END => vc.VCERR_END,
        videodec.VDERR_NO_ENGINE => vc.VCERR_NOCODEC,
        videodec.VDERR_UNSUPPORTED => vc.VCERR_UNSUPPORTED,
        videodec.VDERR_NO_MEMORY => vc.VCERR_NOMEMORY,
        videodec.VDERR_BUSY => vc.VCERR_BUSY,
        else => vc.VCERR_CORRUPT,
    };
}
