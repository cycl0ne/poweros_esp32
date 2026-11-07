// SPDX-License-Identifier: MPL-2.0
//! A decoder on an AMD graphics device's video decoder: what
//! OpenVideoDecoder hands out there - a stream the decoder knows by its
//! number, and the context the firmware keeps for it in the device's
//! memory, handed over with every message of the stream.
//!
//! The stream is made with a message when the decoder is opened, and
//! ended with one when it is closed (`codec/_vcn.zig`). Its pictures are
//! not decoded yet: feeding it and asking for a frame answer
//! VDERR_UNSUPPORTED.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const types = sdk.resources.videodec;
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;
const vcn = @import("../codec/_vcn.zig");

/// The size a stream is made for: the largest a picture of it may be,
/// until its own size is read from it.
const made_width = 1920;
const made_height = 1088;

pub const Session = struct {
    vb: *VideoDecBase,
    /// Its place in the base's table of open decoders.
    slot: u32,
    codec: u32,
    /// The decoder's number for the stream, and the context kept for it.
    stream: u32 = 0,
    context: amdgpu.GPUMemory = .{},
    /// Made on the decoder, and to be ended there.
    made: bool = false,

    pub fn of(h: *types.VideoDecoder) *Session {
        return @ptrCast(@alignCast(h));
    }

    pub fn handle(s: *Session) *types.VideoDecoder {
        return @ptrCast(s);
    }

    /// The stream made on the decoder, its context taken and cleared:
    /// false where there is no room or the decoder did not answer - and
    /// then the decoder is taken as dead. The caller holds the resource's
    /// lock.
    pub fn make(s: *Session) bool {
        const vb = s.vb;
        const sys = vb.sys_base;
        const gpu = vb.vcn.gpu orelse return false;
        if (!gpu.AllocGPUMemory(vcn.session_bytes, 4096, &s.context)) {
            exec.kprintf(sys, "%s: no room for a stream's context on the AMD video decoder\n", .{types.VIDEODECNAME});
            return false;
        }
        var offset: u32 = 0;
        while (offset < vcn.session_bytes) : (offset += 8) {
            const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(s.context.cpu)) + offset);
            to.* = 0;
        }
        vb.vcn.streams +%= 1;
        s.stream = vb.vcn.streams;
        var message: [16]u32 = undefined;
        const words = vcn.createMessage(&message, s.stream, vcn.streamKind(s.codec), made_width, made_height);
        if (!vcn.send(sys, &vb.vcn, message[0..words], s.context.device, "does not answer a stream's making")) {
            vb.state = base.STATE_DEAD;
            return false;
        }
        s.made = true;
        exec.kprintf(sys, "%s: the AMD video decoder made stream %d (fence %d)\n", .{ types.VIDEODECNAME, s.stream, vb.vcn.sequence });
        return true;
    }

    /// The stream ended on the decoder and its context given back. A
    /// decoder that does not answer keeps the context, which it may still
    /// write, and is taken as dead. The caller holds the resource's lock.
    pub fn end(s: *Session) void {
        const vb = s.vb;
        const sys = vb.sys_base;
        const gpu = vb.vcn.gpu orelse return;
        if (s.made) {
            var message: [8]u32 = undefined;
            const words = vcn.destroyMessage(&message, s.stream);
            s.made = false;
            if (!vcn.send(sys, &vb.vcn, message[0..words], s.context.device, "does not answer a stream's end")) {
                vb.state = base.STATE_DEAD;
                return;
            }
            exec.kprintf(sys, "%s: the AMD video decoder ended stream %d (fence %d)\n", .{ types.VIDEODECNAME, s.stream, vb.vcn.sequence });
        }
        if (s.context.bytes != 0) gpu.FreeGPUMemory(&s.context);
    }
};
