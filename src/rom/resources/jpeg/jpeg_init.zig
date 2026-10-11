// SPDX-License-Identifier: MPL-2.0
//! jpeg.resource's ROM tag, and the init routine it names: the codec
//! clocked and out of reset, the 2D-DMA channel it is fed through claimed
//! from dma.resource, and the servers on its two interrupts - the
//! codec's, for a file it cannot decode, and the receive side's, for the
//! end of the picture.
//!
//! On a chip without the codec (the host the tests run on) the resource
//! is made all the same, without the codec: ExamineJPEG works, DecodeJPEG
//! answers JPEGERR_NO_ENGINE.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;
const dmares = sdk.resources.dma;
const hardware = sdk.hardware;
const ExecBase = sdk.interface.exec.ExecBase;
const jpeg_lvo = @import("jpeg_lvo.zig");
const JpegBase = @import("jpeg_base.zig").JpegBase;

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = types.JPEGNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "10.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Whether the chip has the codec.
pub const on_chip = hardware.chip == .esp32p4;

fn jpegBase(lib: *exec.Library) *JpegBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the lock, and on the chip the codec, its channel and its
/// interrupts.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const jb = jpegBase(lib);
    lib.revision = RESOURCE_REVISION;
    jb.sys_base = sys_base;
    sys_base.InitSemaphore(&jb.lock);
    jb.dma = null;
    jb.descriptors = @splat(0);
    jb.waiter = null;
    jb.waiter_mask = 0;
    jb.errors = 0;
    jb.ended = 0;
    jb.hooked = false;
    if (comptime on_chip) startCodec(jb, sys_base);
    return lib;
}

/// The codec's channel claimed, the codec clocked, its interrupts
/// hooked. Without the channel the codec stays off.
fn startCodec(jb: *JpegBase, sys: *ExecBase) void {
    const codec = @import("codec/_codec.zig");
    const db: *dmares.DmaBase = @ptrCast(@alignCast(sys.OpenResource(dmares.DMANAME) orelse return));
    if (db.AllocDMAChannel(dmares.DMA2D_CHANNEL0 + codec.channel, RESOURCE_NAME) != null) return;
    jb.dma = db;
    hardware.system.enable(.jpeg);
    jb.codec_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = RESOURCE_NAME },
        .data = jb,
        .code = &codecServer,
    };
    jb.dma_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = RESOURCE_NAME },
        .data = jb,
        .code = &dmaServer,
    };
    sys.AddIntServer(hardware.intbits.INTB_JPEG, &jb.codec_int);
    sys.AddIntServer(hardware.intbits.INTB_DMA2D_IN_CH0 + codec.channel, &jb.dma_int);
    jb.hooked = true;
}

/// The codec raised an error: noted, and the decode's task told.
fn codecServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const codec = @import("codec/_codec.zig");
    const jb: *JpegBase = @ptrCast(@alignCast(is_data.?));
    const raised = codec.takeErrors();
    if (raised == 0) return 0;
    jb.errors |= raised;
    if (jb.waiter) |task| jb.sys_base.Signal(task, jb.waiter_mask);
    return 1;
}

/// The receive side ended: noted, and the decode's task told.
fn dmaServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const codec = @import("codec/_codec.zig");
    const jb: *JpegBase = @ptrCast(@alignCast(is_data.?));
    const raised = hardware.dma2d.takeEnded(codec.channel);
    if (raised == 0) return 0;
    jb.ended = raised;
    if (jb.waiter) |task| jb.sys_base.Signal(task, jb.waiter_mask);
    return 1;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(JpegBase),
    .vectors = &jpeg_lvo.vectors,
    .vector_count = jpeg_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 60: after dma.resource (70), whose 2D-DMA channel 0 it
/// claims.
pub export const jpeg_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &jpeg_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 60,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
