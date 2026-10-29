// SPDX-License-Identifier: MPL-2.0
//! videodec.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const types = sdk.resources.videodec;
const vec = exec.vec;
const VideoDecBase = @import("videodec_base.zig").VideoDecBase;
const VideoDecCodecs = @import("decoder/videodeccodecs.zig").VideoDecCodecs;
const OpenVideoDecoder = @import("decoder/openvideodecoder.zig").OpenVideoDecoder;
const CloseVideoDecoder = @import("decoder/closevideodecoder.zig").CloseVideoDecoder;
const FeedVideoDecoder = @import("decoder/feedvideodecoder.zig").FeedVideoDecoder;
const DecodeVideoFrame = @import("decoder/decodevideoframe.zig").DecodeVideoFrame;
const ReleaseVideoFrame = @import("decoder/releasevideoframe.zig").ReleaseVideoFrame;
const GetVideoDecoderInfo = @import("decoder/getvideodecoderinfo.zig").GetVideoDecoderInfo;
const FlushVideoDecoder = @import("decoder/flushvideodecoder.zig").FlushVideoDecoder;

/// videodec.resource's interface, as the SDK generates it from
/// sdk/fd/videodec_lib.fd.
const interface = sdk.interface.videodec;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("videodec.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "videodec.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("decoder/videodeccodecs.zig"),
    @embedFile("decoder/openvideodecoder.zig"),
    @embedFile("decoder/closevideodecoder.zig"),
    @embedFile("decoder/feedvideodecoder.zig"),
    @embedFile("decoder/decodevideoframe.zig"),
    @embedFile("decoder/releasevideoframe.zig"),
    @embedFile("decoder/getvideodecoderinfo.zig"),
    @embedFile("decoder/flushvideodecoder.zig"),
};

fn lvoVideoDecCodecs(vb: *VideoDecBase) callconv(.c) u32 {
    return VideoDecCodecs(vb);
}
fn lvoOpenVideoDecoder(vb: *VideoDecBase, codec: u32, tags: ?[*]const utility.TagItem, err: ?*u32) callconv(.c) ?*types.VideoDecoder {
    return OpenVideoDecoder(vb, codec, tags, err);
}
fn lvoCloseVideoDecoder(vb: *VideoDecBase, decoder: ?*types.VideoDecoder) callconv(.c) void {
    CloseVideoDecoder(vb, decoder);
}
fn lvoFeedVideoDecoder(vb: *VideoDecBase, decoder: *types.VideoDecoder, data: ?[*]const u8, length: u32, time: u64, flags: u32) callconv(.c) u32 {
    return FeedVideoDecoder(vb, decoder, data, length, time, flags);
}
fn lvoDecodeVideoFrame(vb: *VideoDecBase, decoder: *types.VideoDecoder, frame: *types.VideoDecFrame) callconv(.c) u32 {
    return DecodeVideoFrame(vb, decoder, frame);
}
fn lvoReleaseVideoFrame(vb: *VideoDecBase, decoder: *types.VideoDecoder, frame: *types.VideoDecFrame) callconv(.c) void {
    ReleaseVideoFrame(vb, decoder, frame);
}
fn lvoGetVideoDecoderInfo(vb: *VideoDecBase, decoder: *types.VideoDecoder, info: *types.VideoDecInfo) callconv(.c) u32 {
    return GetVideoDecoderInfo(vb, decoder, info);
}
fn lvoFlushVideoDecoder(vb: *VideoDecBase, decoder: *types.VideoDecoder) callconv(.c) void {
    FlushVideoDecoder(vb, decoder);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoVideoDecCodecs),
    vec(lvoOpenVideoDecoder),
    vec(lvoCloseVideoDecoder),
    vec(lvoFeedVideoDecoder),
    vec(lvoDecodeVideoFrame),
    vec(lvoReleaseVideoFrame),
    vec(lvoGetVideoDecoderInfo),
    vec(lvoFlushVideoDecoder),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: this resource's own, from the first slot" {
    try testing.expectEqual(@as(usize, @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("videodec_lvo.zig"), LVO, &.{});
}
