// SPDX-License-Identifier: MIT
//! GetVideoDecoder: what decodes a film's pictures.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const _ahead = @import("../ahead/_ahead.zig");

/// Where a module's name says it is in LIBS:codecs/.
const in_codecs = "codecs/";

/// Says which codec module decodes a film's pictures: the machine's video
/// decoder or the processor, and the module by name and version.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoDecoder(base: *VideoCodecBase, stream: *vc.VideoStream, info: *vc.VideoDecoderInfo) void
/// ```
///
/// SINCE: 1.13. LVO -72.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `info`: where it goes.
///
/// RESULT:
/// None; `info` is filled in.
///
/// BEHAVIOR:
/// `kind` is what the module's tag says it is: `VCMOD_CHIP`, a chip's
/// decoder - chip.vcodec, through videodec.resource - or
/// `VCMOD_SOFTWARE`, one that decodes on the processor. `version` and
/// `revision` are the module's as it is loaded, and `name` its file in
/// LIBS:codecs/, cut at 31 characters. It is the module decoding now: a
/// chip's that refuses the stream as its first frame is asked for hands
/// it on to the next module, and from then on that one is named. A
/// stream opened without its pictures' decoder has none: `info` is
/// cleared, `kind` 0.
///
/// CONTEXT:
/// - Waits: only while a frame is decoded ahead (VCA_DecodeAhead), for it
///   to be done: the module may be changed under it.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `info` is the caller's.
///
/// NOTES:
/// Asked before the first frame, the answer is the module that took the
/// stream when it was opened; one that refuses it later is not known
/// yet.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetVideoStreamInfo`, `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// var decoder: vc.VideoDecoderInfo = .{};
/// vcb.GetVideoDecoder(film, &decoder);
/// const by_chip = decoder.kind == sdk.vcodec.VCMOD_CHIP;
/// ```
pub fn GetVideoDecoder(_: *VideoCodecBase, stream: *vc.VideoStream, info: *vc.VideoDecoderInfo) void {
    const s = _stream.of(stream);
    info.* = .{};
    if (s.ahead) |ahead| _ahead.hold(ahead);
    defer if (s.ahead) |ahead| _ahead.letGo(ahead);
    const decoder = &s.decoder;
    const lib = decoder.lib orelse return;
    const module = &decoder.candidates[decoder.current];
    info.kind = module.kind;
    info.version = lib.version;
    info.revision = lib.revision;
    var length: usize = 0;
    while (length < module.name.len and module.name[length] != 0) length += 1;
    var name: []const u8 = module.name[0..length];
    if (name.len >= in_codecs.len and same(name[0..in_codecs.len], in_codecs)) name = name[in_codecs.len..];
    const kept = @min(name.len, info.name.len - 1);
    @memcpy(info.name[0..kept], name[0..kept]);
}

fn same(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
