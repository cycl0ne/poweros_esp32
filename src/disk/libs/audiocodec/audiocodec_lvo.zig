// SPDX-License-Identifier: MIT
//! audiocodec.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const vec = exec.vec;
const AudioCodecBase = @import("audiocodec_base.zig").AudioCodecBase;
const audiocodec_init = @import("audiocodec_init.zig");

const OpenAudioStream = @import("stream/openaudiostream.zig").OpenAudioStream;
const CloseAudioStream = @import("stream/closeaudiostream.zig").CloseAudioStream;
const GetAudioStreamInfo = @import("stream/getaudiostreaminfo.zig").GetAudioStreamInfo;
const DecodeAudio = @import("stream/decodeaudio.zig").DecodeAudio;
const SeekAudio = @import("stream/seekaudio.zig").SeekAudio;
const IdentifyAudio = @import("identify/identifyaudio.zig").IdentifyAudio;
const AudioErrorText = @import("text/audioerrortext.zig").AudioErrorText;

/// audiocodec.library's interface, as the SDK generates it from
/// sdk/fd/audiocodec_lib.fd.
const interface = sdk.interface.audiocodec;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("audiocodec.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "audiocodec.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("stream/openaudiostream.zig"),
    @embedFile("stream/closeaudiostream.zig"),
    @embedFile("stream/getaudiostreaminfo.zig"),
    @embedFile("stream/decodeaudio.zig"),
    @embedFile("stream/seekaudio.zig"),
    @embedFile("identify/identifyaudio.zig"),
    @embedFile("text/audioerrortext.zig"),
};

fn lvoOpenAudioStream(base: *AudioCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*ac.AudioStream {
    return OpenAudioStream(base, tags, err);
}
fn lvoCloseAudioStream(base: *AudioCodecBase, stream: ?*ac.AudioStream) callconv(.c) void {
    return CloseAudioStream(base, stream);
}
fn lvoGetAudioStreamInfo(base: *AudioCodecBase, stream: *ac.AudioStream, info: *ac.AudioStreamInfo) callconv(.c) void {
    return GetAudioStreamInfo(base, stream, info);
}
fn lvoDecodeAudio(base: *AudioCodecBase, stream: *ac.AudioStream, buffer: [*]i16, frames: u32) callconv(.c) i32 {
    return DecodeAudio(base, stream, buffer, frames);
}
fn lvoSeekAudio(base: *AudioCodecBase, stream: *ac.AudioStream, frame: u32) callconv(.c) i32 {
    return SeekAudio(base, stream, frame);
}
fn lvoIdentifyAudio(base: *AudioCodecBase, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    return IdentifyAudio(base, bytes, length);
}
fn lvoAudioErrorText(base: *AudioCodecBase, code: i32) callconv(.c) [*:0]const u8 {
    return AudioErrorText(base, code);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(audiocodec_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenAudioStream),
    vec(lvoCloseAudioStream),
    vec(lvoGetAudioStreamInfo),
    vec(lvoDecodeAudio),
    vec(lvoSeekAudio),
    vec(lvoIdentifyAudio),
    vec(lvoAudioErrorText),
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
    try exec.libraries.checkForwarding(@embedFile("audiocodec_lvo.zig"), LVO, &.{});
}
