// SPDX-License-Identifier: MPL-2.0
//! videodec.resource's ROM tag, and the init routine it names: the
//! JH7110's WAVE511 found among the board's parts and the server on its
//! interrupt. The chip is woken, and its firmware read and started, by
//! the first OpenVideoDecoder, so its power domain stays off until a
//! video is decoded.
//!
//! On a chip or board without the decoder (the host the tests run on) the
//! resource is made all the same, without it: VideoDecCodecs answers 0,
//! OpenVideoDecoder VDERR_NO_ENGINE.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.videodec;
const hardware = sdk.hardware;
const ExecBase = sdk.interface.exec.ExecBase;
const videodec_lvo = @import("videodec_lvo.zig");
const base = @import("videodec_base.zig");
const VideoDecBase = base.VideoDecBase;
const Decoder = @import("decoder/_decoder.zig").Decoder;
const wave511 = @import("codec/_wave511.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = types.VIDEODECNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "29.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The decoder the chip may have: the JH7110's WAVE511 - where the board
/// lists it - or none.
pub const Engine = enum { none, wave511 };
pub const engine: Engine = switch (hardware.chip) {
    .rv64sbi => .wave511,
    else => .none,
};

fn videoDecBase(lib: *exec.Library) *VideoDecBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the lock, and on the JH7110 the decoder's part and its
/// interrupt.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const vb = videoDecBase(lib);
    lib.revision = RESOURCE_REVISION;
    vb.sys_base = sys_base;
    sys_base.InitSemaphore(&vb.lock);
    vb.vpu = 0;
    vb.vpu_irq = 0;
    vb.state = base.STATE_ASLEEP;
    vb.codecs = 0;
    vb.firmware = 0;
    vb.code_block = null;
    vb.code_block_size = 0;
    vb.code = 0;
    vb.decoders = @splat(null);
    vb.hooked = false;
    if (comptime engine == .wave511) findVdec(vb, sys_base);
    return lib;
}

/// The JH7110's decoder found on the board and its interrupt hooked; it
/// stays asleep until the first decoder is opened.
fn findVdec(vb: *VideoDecBase, sys: *ExecBase) void {
    const part = wave511.find(sys) orelse return;
    vb.vpu = part.regs;
    vb.vpu_irq = part.irq;
    vb.codecs = types.VDCODEC_H264 | types.VDCODEC_H265;
    vb.server = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = RESOURCE_NAME },
        .data = vb,
        .code = &vdecServer,
    };
    sys.AddIntServer(part.irq, &vb.server);
    vb.hooked = true;
}

/// The decoder finished a command, or raised something else: what it
/// raised cleared, and each instance whose sequence or picture is done
/// told.
fn vdecServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const vb: *VideoDecBase = @ptrCast(@alignCast(is_data.?));
    if (vb.state != base.STATE_RUNNING) return 0;
    const raised = wave511.takeInterrupt(vb.vpu);
    if (raised.reason == 0) return 0;
    for (vb.decoders, 0..) |slot, id| {
        const d: *Decoder = @ptrCast(@alignCast(slot orelse continue));
        const bit = @as(u32, 1) << @intCast(id);
        var done: u32 = 0;
        if (raised.seq_done & bit != 0) done |= wave511.INT_INIT_SEQ;
        if (raised.pic_done & bit != 0) done |= wave511.INT_DEC_PIC;
        if (done == 0) continue;
        d.raised |= done;
        vb.sys_base.SignalWaitable(&d.done);
    }
    return 1;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(VideoDecBase),
    .vectors = &videodec_lvo.vectors,
    .vector_count = videodec_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 60: after expansion.library (102), which has the
/// JH7110's part.
pub export const videodec_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &videodec_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 60,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
