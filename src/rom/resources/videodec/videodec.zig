// SPDX-License-Identifier: MPL-2.0
//! videodec.resource: the chip's video decoder - the JH7110's WAVE511
//! (the VisionFive 2's) - a stream fed a picture at a time and its frames
//! handed out in the order they are shown.
//!
//! OpenVideoDecoder makes an instance on the chip, waking it and starting
//! its firmware for the first; FeedVideoDecoder copies a picture into the
//! instance's ring; DecodeVideoFrame has the chip decode until a frame is
//! due and lends it; ReleaseVideoFrame gives it back; FlushVideoDecoder
//! drops what is queued; CloseVideoDecoder ends the instance. The chip's
//! commands go one caller at a time, under the resource's semaphore; the
//! chip answers the queued ones (a sequence, a picture) on its interrupt,
//! whose server signals the instance's waitable.
//!
//! The chip is `codec/_wave511.zig`; a decoder's ring, times, frames and
//! waits `decoder/_decoder.zig`; each call is a file of its own under
//! `decoder/`. The jump table is videodec_lvo.zig, the ROM tag and init
//! videodec_init.zig, the base videodec_base.zig. This file holds the
//! names the rest of the kernel reaches the resource by, and the tests of
//! it working as a whole - on the host, without the chip.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.videodec;

const videodec_base = @import("videodec_base.zig");
const videodec_init = @import("videodec_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from videodec.resource.
comptime {
    _ = &videodec_init.videodec_resource_tag;
}

/// The resource's base.
pub const VideoDecBase = videodec_base.VideoDecBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = videodec_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const videodec_resource_tag = videodec_init.videodec_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const VideoDecCodecs = @import("decoder/videodeccodecs.zig").VideoDecCodecs;
const OpenVideoDecoder = @import("decoder/openvideodecoder.zig").OpenVideoDecoder;
const CloseVideoDecoder = @import("decoder/closevideodecoder.zig").CloseVideoDecoder;

test {
    _ = videodec_base;
    _ = videodec_init;
    _ = @import("videodec_lvo.zig");
    _ = @import("codec/_wave511.zig");
    _ = @import("decoder/_decoder.zig");
}

fn setUp() !*VideoDecBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &videodec_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(vb: *VideoDecBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&vb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &vb.lib);
    try kexec.expectNoLeaks();
}

test "without the chip: no codecs, and a decoder is refused for any" {
    const vb = try setUp();
    defer kexec.deinit();

    try testing.expectEqual(@as(u32, 0), VideoDecCodecs(vb));
    var err: u32 = 99;
    try testing.expectEqual(@as(?*types.VideoDecoder, null), OpenVideoDecoder(vb, types.VDCODEC_H264, null, &err));
    try testing.expectEqual(types.VDERR_NO_ENGINE, err);
    try testing.expectEqual(@as(?*types.VideoDecoder, null), OpenVideoDecoder(vb, types.VDCODEC_H265, null, null));
    CloseVideoDecoder(vb, null);
    try tearDown(vb);
}
