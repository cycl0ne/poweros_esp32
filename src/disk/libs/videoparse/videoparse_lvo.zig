// SPDX-License-Identifier: MIT
//! videoparse.library's jump table: every `lvo<Name>` wrapper, the table
//! of them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const vec = exec.vec;
const VideoParseBase = @import("videoparse_base.zig").VideoParseBase;
const videoparse_init = @import("videoparse_init.zig");

const OpenVideoParser = @import("parser/openvideoparser.zig").OpenVideoParser;
const CloseVideoParser = @import("parser/closevideoparser.zig").CloseVideoParser;
const ParseVideoPacket = @import("parser/parsevideopacket.zig").ParseVideoPacket;
const NextVideoEvent = @import("parser/nextvideoevent.zig").NextVideoEvent;
const ReleaseVideoSlot = @import("parser/releasevideoslot.zig").ReleaseVideoSlot;
const ResetVideoParser = @import("parser/resetvideoparser.zig").ResetVideoParser;

/// videoparse.library's interface, as the SDK generates it from
/// sdk/fd/videoparse_lib.fd.
const interface = sdk.interface.videoparse;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("videoparse.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "videoparse.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("parser/openvideoparser.zig"),
    @embedFile("parser/closevideoparser.zig"),
    @embedFile("parser/parsevideopacket.zig"),
    @embedFile("parser/nextvideoevent.zig"),
    @embedFile("parser/releasevideoslot.zig"),
    @embedFile("parser/resetvideoparser.zig"),
};

fn lvoOpenVideoParser(base: *VideoParseBase, codec: u32, setup: ?[*]const u8, bytes: u32, tags: ?[*]const utility.TagItem, err: ?*i32) callconv(.c) ?*vp.VideoParser {
    return OpenVideoParser(base, codec, setup, bytes, tags, err);
}
fn lvoCloseVideoParser(base: *VideoParseBase, parser: ?*vp.VideoParser) callconv(.c) void {
    return CloseVideoParser(base, parser);
}
fn lvoParseVideoPacket(base: *VideoParseBase, parser: *vp.VideoParser, packet: *const vp.VideoPacket) callconv(.c) i32 {
    return ParseVideoPacket(base, parser, packet);
}
fn lvoNextVideoEvent(base: *VideoParseBase, parser: *vp.VideoParser, event: *vp.VideoEvent) callconv(.c) i32 {
    return NextVideoEvent(base, parser, event);
}
fn lvoReleaseVideoSlot(base: *VideoParseBase, parser: *vp.VideoParser, slot: u32) callconv(.c) void {
    return ReleaseVideoSlot(base, parser, slot);
}
fn lvoResetVideoParser(base: *VideoParseBase, parser: *vp.VideoParser) callconv(.c) void {
    return ResetVideoParser(base, parser);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(videoparse_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenVideoParser),
    vec(lvoCloseVideoParser),
    vec(lvoParseVideoPacket),
    vec(lvoNextVideoEvent),
    vec(lvoReleaseVideoSlot),
    vec(lvoResetVideoParser),
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
    try exec.libraries.checkForwarding(@embedFile("videoparse_lvo.zig"), LVO, &.{});
}
