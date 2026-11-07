// SPDX-License-Identifier: MIT
//! OpenVideoParser: a parser made for a stream, its setup read.

const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");
const Parser = _parser.Parser;
const h264 = @import("../h264/_h264.zig");
const hevc = @import("../hevc/_hevc.zig");
const vp9 = @import("../vp9/_vp9.zig");
const av1 = @import("../av1/_av1.zig");
const CloseVideoParser = @import("closevideoparser.zig").CloseVideoParser;

/// Makes a parser for a video stream, and reads its track's setup.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenVideoParser(base: *VideoParseBase, codec: u32, setup: ?[*]const u8, bytes: u32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*vp.VideoParser
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `codec`: what the stream is: VPCODEC_H264, VPCODEC_HEVC,
///   VPCODEC_VP9 (SINCE 1.1) or VPCODEC_AV1 (SINCE 1.2).
/// - `setup`, `bytes`: the track's setup as its container holds it - an
///   MP4's `avcC`, `hvcC` or `av1C`, a Matroska track's CodecPrivate - or
///   null (or 0 bytes) for a stream in Annex B form, its parameter sets
///   among its units. A VP9 track's is not read: its frames say
///   everything.
/// - `tags`: `VPA_Slots`, the slots the caller keeps beyond the stream's
///   own (pictures it has lent out, or reads on cores of its own after
///   the stream let go of them; at most 32, default 0); `VPA_MaxWidth`
///   and `VPA_MaxHeight`, the largest picture taken, in samples (default
///   8192 each).
/// - `err`: where why it failed goes (VPERR_*), or null.
///
/// RESULT:
/// The parser, or null - and `err` says why: VPERR_UNSUPPORTED for a
/// codec the library does not read or more than 32 slots of the caller's,
/// VPERR_CORRUPT for a setup that is not right, VPERR_NOMEMORY.
///
/// BEHAVIOR:
/// An `avcC` or `hvcC` says how many bytes each unit's length takes in
/// the packets, and its parameter sets are read now; without one, each
/// packet's units follow start codes. The parameter sets are kept by
/// their ids, as many as the stream has (H.264's 32 sequence and 256
/// picture parameter sets, HEVC's 16 and 64), and a later one with the
/// same id takes the earlier one's place. An `av1C`'s sequence header is
/// read now, and one that is not right passed by: the packets of the key
/// frames carry it again; the packets are OBUs, each with its size.
///
/// The slots go from 0 to 17 plus `VPA_Slots`: sixteen frames the stream
/// may hold, the picture being decoded, and a first field waiting for its
/// second (H.264) - HEVC's sixteen pictures hold the one being decoded,
/// and two more stand for references the stream names and lacks. VP9's
/// go from 0 to 8 plus `VPA_Slots`: the eight reference slots' pictures
/// and the frame being decoded; AV1's from 0 to 9 plus `VPA_Slots`, one
/// more for the frame shown last, held until its temporal unit ends.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The parser is the caller's, given back with `CloseVideoParser`. The
/// setup's bytes are read during the call and are not kept.
///
/// NOTES:
/// An H.264 parser takes some 265 KiB, most of it the 256 picture
/// parameter sets; an HEVC parser some 330 KiB, most of it the sixteen
/// sequence parameter sets with their reference picture sets and the 64
/// picture parameter sets. Each takes as much again as the largest unit
/// for its unescaped copy. A VP9 parser takes some 26 KiB, an AV1
/// parser some 11 KiB, and nothing for their frames, which they read
/// where they are.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseVideoParser`, `ParseVideoPacket`, `NextVideoEvent`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const parser = vpb.OpenVideoParser(vp.VPCODEC_H264, track.setup, track.setup_bytes, &[_]utility.TagItem{
///     .{ .tag = vp.VPA_Slots, .data = 4 },
///     .{},
/// }, &err) orelse return err;
/// defer vpb.CloseVideoParser(parser);
/// ```
pub fn OpenVideoParser(base: *VideoParseBase, codec: u32, setup: ?[*]const u8, bytes: u32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*vp.VideoParser {
    const sys = base.sys_base;
    const ub = base.utility_base;
    if (codec != vp.VPCODEC_H264 and codec != vp.VPCODEC_HEVC and codec != vp.VPCODEC_VP9 and codec != vp.VPCODEC_AV1)
        return failed(err, vp.VPERR_UNSUPPORTED);
    const slots: u32 = @truncate(ub.GetTagData(vp.VPA_Slots, 0, tags));
    if (slots > 32) return failed(err, vp.VPERR_UNSUPPORTED);
    const max_width: u32 = @truncate(ub.GetTagData(vp.VPA_MaxWidth, 8192, tags));
    const max_height: u32 = @truncate(ub.GetTagData(vp.VPA_MaxHeight, 8192, tags));

    // Cleared: every field of a parser starts at zero but these.
    const memory = sys.AllocVec(@sizeOf(Parser), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(err, vp.VPERR_NOMEMORY);
    const p: *Parser = @ptrCast(@alignCast(memory));
    p.base = base;
    p.codec = codec;
    p.extra_slots = slots;
    p.max_width_mbs = (max_width + 15) / 16;
    p.max_height_mbs = (max_height + 15) / 16;
    const handle: *vp.VideoParser = @ptrCast(p);
    switch (codec) {
        vp.VPCODEC_H264 => p.h264 = h264.create(p),
        vp.VPCODEC_HEVC => p.hevc = hevc.create(p),
        vp.VPCODEC_VP9 => p.vp9 = vp9.create(p),
        else => p.av1 = av1.create(p),
    }
    if (p.h264 == null and p.hevc == null and p.vp9 == null and p.av1 == null) {
        CloseVideoParser(base, handle);
        return failed(err, vp.VPERR_NOMEMORY);
    }
    // A VP9 track's setup says nothing its frames do not.
    if (setup) |data| {
        if (p.av1) |st| {
            av1.setup(st, data[0..bytes]);
        } else if (bytes != 0 and codec != vp.VPCODEC_VP9) {
            const read = if (p.h264) |st| h264.setup(p, st, data[0..bytes]) else hevc.setup(p, p.hevc.?, data[0..bytes]);
            read catch |e| {
                CloseVideoParser(base, handle);
                return failed(err, _parser.codeOf(e));
            };
        }
    }
    if (err) |e| e.* = vp.VPERR_OK;
    return handle;
}

fn failed(err: ?*i32, code: i32) ?*vp.VideoParser {
    if (err) |e| e.* = code;
    return null;
}
