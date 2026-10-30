// SPDX-License-Identifier: MIT
//! media.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const utility = sdk.utility;
const vec = exec.vec;
const MediaBase = @import("media_base.zig").MediaBase;
const media_init = @import("media_init.zig");

const OpenMedia = @import("file/openmedia.zig").OpenMedia;
const CloseMedia = @import("file/closemedia.zig").CloseMedia;
const GetMediaInfo = @import("file/getmediainfo.zig").GetMediaInfo;
const GetMediaTrack = @import("file/getmediatrack.zig").GetMediaTrack;
const ReadMediaPacket = @import("file/readmediapacket.zig").ReadMediaPacket;
const SeekMedia = @import("file/seekmedia.zig").SeekMedia;
const IdentifyMedia = @import("identify/identifymedia.zig").IdentifyMedia;
const MediaErrorText = @import("text/mediaerrortext.zig").MediaErrorText;
const GetMediaAttrs = @import("file/getmediaattrs.zig").GetMediaAttrs;

/// media.library's interface, as the SDK generates it from
/// sdk/fd/media_lib.fd.
const interface = sdk.interface.media;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("media.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "media.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("file/openmedia.zig"),
    @embedFile("file/closemedia.zig"),
    @embedFile("file/getmediainfo.zig"),
    @embedFile("file/getmediatrack.zig"),
    @embedFile("file/readmediapacket.zig"),
    @embedFile("file/seekmedia.zig"),
    @embedFile("identify/identifymedia.zig"),
    @embedFile("text/mediaerrortext.zig"),
    @embedFile("file/getmediaattrs.zig"),
};

fn lvoOpenMedia(base: *MediaBase, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*media.MediaFile {
    return OpenMedia(base, tags, err);
}
fn lvoCloseMedia(base: *MediaBase, file: ?*media.MediaFile) callconv(.c) void {
    return CloseMedia(base, file);
}
fn lvoGetMediaInfo(base: *MediaBase, file: *media.MediaFile, info: *media.MediaInfo) callconv(.c) void {
    return GetMediaInfo(base, file, info);
}
fn lvoGetMediaTrack(base: *MediaBase, file: *media.MediaFile, track: u32, info: *media.MediaTrack) callconv(.c) i32 {
    return GetMediaTrack(base, file, track, info);
}
fn lvoReadMediaPacket(base: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) callconv(.c) i32 {
    return ReadMediaPacket(base, file, track, packet);
}
fn lvoSeekMedia(base: *MediaBase, file: *media.MediaFile, track: u32, time: i64) callconv(.c) i32 {
    return SeekMedia(base, file, track, time);
}
fn lvoIdentifyMedia(base: *MediaBase, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    return IdentifyMedia(base, bytes, length);
}
fn lvoMediaErrorText(base: *MediaBase, code: i32) callconv(.c) [*:0]const u8 {
    return MediaErrorText(base, code);
}
fn lvoGetMediaAttrs(base: *MediaBase, file: *media.MediaFile, tags: ?[*]const utility.TagItem) callconv(.c) u32 {
    return GetMediaAttrs(base, file, tags);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(media_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenMedia),
    vec(lvoCloseMedia),
    vec(lvoGetMediaInfo),
    vec(lvoGetMediaTrack),
    vec(lvoReadMediaPacket),
    vec(lvoSeekMedia),
    vec(lvoIdentifyMedia),
    vec(lvoMediaErrorText),
    vec(lvoGetMediaAttrs),
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
    try exec.libraries.checkForwarding(@embedFile("media_lvo.zig"), LVO, &.{});
}
