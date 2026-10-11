// SPDX-License-Identifier: MPL-2.0
//! jpeg.resource: the ESP32-P4's JPEG codec, decoding a file into pixels.
//!
//! ExamineJPEG reads a file's headers and says whether the codec takes
//! it; DecodeJPEG writes the tables into the codec, has the 2D-DMA feed
//! it the scan and write the picture back, turned into red, green and
//! blue on the way, and waits for the end; FreeJPEGPicture gives the
//! picture back. One decode at a time, under the resource's semaphore.
//!
//! The headers are `header/_header.zig`, the codec and its channel
//! `codec/_codec.zig`; each call is a file of its own under `picture/`.
//! The jump table is jpeg_lvo.zig, the ROM tag and init jpeg_init.zig,
//! the base jpeg_base.zig. This file holds the names the rest of the
//! kernel reaches the resource by, and the tests of it working as a
//! whole - on the host, without the codec.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;

const jpeg_base = @import("jpeg_base.zig");
const jpeg_init = @import("jpeg_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from jpeg.resource.
comptime {
    _ = &jpeg_init.jpeg_resource_tag;
}

/// The resource's base.
pub const JpegBase = jpeg_base.JpegBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = jpeg_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const jpeg_resource_tag = jpeg_init.jpeg_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const ExamineJPEG = @import("picture/examinejpeg.zig").ExamineJPEG;
const DecodeJPEG = @import("picture/decodejpeg.zig").DecodeJPEG;
const FreeJPEGPicture = @import("picture/freejpegpicture.zig").FreeJPEGPicture;

test {
    _ = jpeg_base;
    _ = jpeg_init;
    _ = @import("jpeg_lvo.zig");
    _ = @import("header/_header.zig");
    _ = @import("picture/examinejpeg.zig");
    _ = @import("picture/decodejpeg.zig");
    _ = @import("picture/freejpegpicture.zig");
}

fn setUp() !*JpegBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &jpeg_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(jb: *JpegBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&jb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &jb.lib);
    try kexec.expectNoLeaks();
}

test "a file examined: what it is, what the decoded picture takes" {
    const jb = try setUp();
    defer kexec.deinit();

    const file = @embedFile("../../../disk/tests/datatypes/Garden.jpg");
    var info: types.JPEGInfo = .{};
    try testing.expectEqual(types.JPEGERR_OK, ExamineJPEG(jb, file, file.len, &info));
    try testing.expectEqual(@as(u32, 120), info.width);
    try testing.expectEqual(@as(u32, 80), info.height);
    try testing.expectEqual(types.JPEGSAMP_420, info.sampling);
    try testing.expectEqual(types.JPEGFMT_BGR24, info.format);
    try testing.expectEqual(@as(u32, 128 * 3), info.pitch);
    try testing.expectEqual(@as(u32, 128 * 3 * 80), info.bytes);

    try testing.expectEqual(types.JPEGERR_NOT_JPEG, ExamineJPEG(jb, "PNG", 3, &info));
    try testing.expectEqual(@as(u32, 0), info.width);
    try tearDown(jb);
}

test "without the codec a decode is refused, and leaves nothing to give back" {
    const jb = try setUp();
    defer kexec.deinit();

    const file = @embedFile("../../../disk/tests/datatypes/Grey.jpg");
    var picture: types.JPEGPicture = .{};
    try testing.expectEqual(types.JPEGERR_NO_ENGINE, DecodeJPEG(jb, file, file.len, &picture));
    try testing.expectEqual(@as(?[*]u8, null), picture.pixels);
    FreeJPEGPicture(jb, &picture);
    try testing.expectEqual(types.JPEGERR_CORRUPT, DecodeJPEG(jb, file, 40, &picture));
    try tearDown(jb);
}
