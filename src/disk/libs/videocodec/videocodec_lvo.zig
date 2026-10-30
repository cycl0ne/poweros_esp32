// SPDX-License-Identifier: MIT
//! videocodec.library's jump table: every `lvo<Name>` wrapper, the table
//! of them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const vc = sdk.videocodec;
const utility = sdk.utility;
const vec = exec.vec;
const VideoCodecBase = @import("videocodec_base.zig").VideoCodecBase;
const videocodec_init = @import("videocodec_init.zig");

const OpenVideoStream = @import("stream/openvideostream.zig").OpenVideoStream;
const CloseVideoStream = @import("stream/closevideostream.zig").CloseVideoStream;
const GetVideoStreamInfo = @import("stream/getvideostreaminfo.zig").GetVideoStreamInfo;
const DecodeVideoFrame = @import("stream/decodevideoframe.zig").DecodeVideoFrame;
const ReleaseVideoFrame = @import("stream/releasevideoframe.zig").ReleaseVideoFrame;
const DecodeVideoSound = @import("stream/decodevideosound.zig").DecodeVideoSound;
const SeekVideo = @import("stream/seekvideo.zig").SeekVideo;
const IdentifyVideo = @import("identify/identifyvideo.zig").IdentifyVideo;
const VideoErrorText = @import("text/videoerrortext.zig").VideoErrorText;
const GetVideoStreamAttrs = @import("stream/getvideostreamattrs.zig").GetVideoStreamAttrs;
const GetVideoTrack = @import("stream/getvideotrack.zig").GetVideoTrack;
const SelectVideoTrack = @import("stream/selectvideotrack.zig").SelectVideoTrack;
const GetVideoSubtitle = @import("stream/getvideosubtitle.zig").GetVideoSubtitle;

/// videocodec.library's interface, as the SDK generates it from
/// sdk/fd/videocodec_lib.fd.
const interface = sdk.interface.videocodec;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("videocodec.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "videocodec.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("stream/openvideostream.zig"),
    @embedFile("stream/closevideostream.zig"),
    @embedFile("stream/getvideostreaminfo.zig"),
    @embedFile("stream/decodevideoframe.zig"),
    @embedFile("stream/releasevideoframe.zig"),
    @embedFile("stream/decodevideosound.zig"),
    @embedFile("stream/seekvideo.zig"),
    @embedFile("identify/identifyvideo.zig"),
    @embedFile("text/videoerrortext.zig"),
    @embedFile("stream/getvideostreamattrs.zig"),
    @embedFile("stream/getvideotrack.zig"),
    @embedFile("stream/selectvideotrack.zig"),
    @embedFile("stream/getvideosubtitle.zig"),
};

fn lvoOpenVideoStream(base: *VideoCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*vc.VideoStream {
    return OpenVideoStream(base, tags, err);
}
fn lvoCloseVideoStream(base: *VideoCodecBase, stream: ?*vc.VideoStream) callconv(.c) void {
    return CloseVideoStream(base, stream);
}
fn lvoGetVideoStreamInfo(base: *VideoCodecBase, stream: *vc.VideoStream, info: *vc.VideoStreamInfo) callconv(.c) void {
    return GetVideoStreamInfo(base, stream, info);
}
fn lvoDecodeVideoFrame(base: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) callconv(.c) i32 {
    return DecodeVideoFrame(base, stream, frame);
}
fn lvoReleaseVideoFrame(base: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) callconv(.c) void {
    return ReleaseVideoFrame(base, stream, frame);
}
fn lvoDecodeVideoSound(base: *VideoCodecBase, stream: *vc.VideoStream, buffer: [*]i16, frames: u32) callconv(.c) i32 {
    return DecodeVideoSound(base, stream, buffer, frames);
}
fn lvoSeekVideo(base: *VideoCodecBase, stream: *vc.VideoStream, time: i64) callconv(.c) i64 {
    return SeekVideo(base, stream, time);
}
fn lvoIdentifyVideo(base: *VideoCodecBase, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    return IdentifyVideo(base, bytes, length);
}
fn lvoVideoErrorText(base: *VideoCodecBase, code: i32) callconv(.c) [*:0]const u8 {
    return VideoErrorText(base, code);
}
fn lvoGetVideoStreamAttrs(base: *VideoCodecBase, stream: *vc.VideoStream, tags: ?[*]const utility.TagItem) callconv(.c) u32 {
    return GetVideoStreamAttrs(base, stream, tags);
}
fn lvoGetVideoTrack(base: *VideoCodecBase, stream: *vc.VideoStream, number: u32, track: *media.MediaTrack) callconv(.c) i32 {
    return GetVideoTrack(base, stream, number, track);
}
fn lvoSelectVideoTrack(base: *VideoCodecBase, stream: *vc.VideoStream, track: u32, time: i64) callconv(.c) i32 {
    return SelectVideoTrack(base, stream, track, time);
}
fn lvoGetVideoSubtitle(base: *VideoCodecBase, stream: *vc.VideoStream, time: i64, subtitle: *vc.VideoSubtitle) callconv(.c) i32 {
    return GetVideoSubtitle(base, stream, time, subtitle);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(videocodec_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenVideoStream),
    vec(lvoCloseVideoStream),
    vec(lvoGetVideoStreamInfo),
    vec(lvoDecodeVideoFrame),
    vec(lvoReleaseVideoFrame),
    vec(lvoDecodeVideoSound),
    vec(lvoSeekVideo),
    vec(lvoIdentifyVideo),
    vec(lvoVideoErrorText),
    vec(lvoGetVideoStreamAttrs),
    vec(lvoGetVideoTrack),
    vec(lvoSelectVideoTrack),
    vec(lvoGetVideoSubtitle),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("videocodec_lvo.zig"), LVO, &.{});
}
