// SPDX-License-Identifier: MPL-2.0
//! CloseVideoDecoder: a decoder ended, its frames with it.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;

/// Closes a decoder OpenVideoDecoder made.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseVideoDecoder(vb: *VideoDecBase, decoder: ?*VideoDecoder) void
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `decoder` - the decoder; null is left alone.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A picture the chip is still decoding for it is waited for, what is
/// queued dropped, its instance ended on the chip, and its memory freed -
/// the stream's ring, the work buffer and every frame. The chip itself
/// keeps running, for the next decoder.
///
/// CONTEXT:
/// - Waits: yes, for the chip. - Interrupts: no.
/// - Locks: the resource's, around the chip. - Process: a Task will do.
///
/// OWNERSHIP:
/// The decoder is gone, and so are the frames it handed out, given back
/// or not: nothing may read them afterwards.
///
/// NOTES:
/// When the chip will not end the instance, its memory is kept, as the
/// chip may still write into it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoDecoder`
///
/// EXAMPLES:
/// ```zig
/// defer vb.CloseVideoDecoder(decoder);
/// ```
pub fn CloseVideoDecoder(vb: *VideoDecBase, decoder: ?*types.VideoDecoder) void {
    const handle = decoder orelse return;
    const sys = vb.sys_base;
    const d = Decoder.of(handle);
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    d.end();
    sys.Disable();
    vb.decoders[d.instance.id] = null;
    sys.Enable();
    sys.FreeMem(@ptrCast(d), @sizeOf(Decoder));
}
