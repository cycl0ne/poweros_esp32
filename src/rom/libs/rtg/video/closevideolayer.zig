// SPDX-License-Identifier: MPL-2.0
//! CloseVideoLayer: a video layer given back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const privateOf = @import("../board/_board.zig").privateOf;

/// Gives a video layer back to its board.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseVideoLayer(rb: *RtgBase, layer: ?*rtg.RtgVideoLayer) void
/// ```
///
/// SINCE: 1.10. LVO -268.
///
/// INPUTS:
/// - `layer` - what `OpenVideoLayer` answered, or null, which does
///   nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing is shown on the layer from the next frame, and the board's
/// picture is seen whole again - its key colour as a colour. When this
/// returns the controller no longer reads the last picture shown, which
/// may then be given back to whoever lent it.
///
/// CONTEXT:
/// - Waits: for the next frame.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer is freed and must not be used again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoLayer`
///
/// EXAMPLES:
/// ```zig
/// rb.CloseVideoLayer(layer);
/// vcb.ReleaseVideoFrame(film, &shown);
/// ```
pub fn CloseVideoLayer(rb: *RtgBase, layer: ?*rtg.RtgVideoLayer) void {
    const gone = layer orelse return;
    const board = gone.board;
    board.ops.?.video_close.?(board, gone);
    _ = @atomicRmw(u32, &privateOf(board).video_layers, .Sub, 1, .monotonic);
    rb.sys_base.FreeVec(gone);
}
