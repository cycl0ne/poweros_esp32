// SPDX-License-Identifier: MPL-2.0
//! What the display calls share: which of a board's buffers are marked as
//! shown.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const _board = @import("../board/_board.zig");

/// The board's buffers marked as the display now shows them: `shown`
/// marked RTGBMF_SHOWING - so none of them can be freed - and every other
/// buffer of the board not; `front`, the one that covers the display's
/// bottom, is what BoardDisplayBitMap answers. A change of picture is
/// counted.
pub fn markShowing(board: *rtg.RtgBoard, shown: []const *rtg.RtgBitMap, front: ?*rtg.RtgBitMap) void {
    var node = board.bitmaps.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const bm: *rtg.RtgBitMap = @fieldParentPtr("node", n);
        bm.flags &= ~rtg.bitmaps.RTGBMF_SHOWING;
    }
    for (shown) |bm| bm.flags |= rtg.bitmaps.RTGBMF_SHOWING;
    board.showing = front;
    if (front != null) {
        board.info.flags |= rtg.boards.RTGBF_SHOWING;
        _board.privateOf(board).buffer_swaps +%= 1;
    } else {
        board.info.flags &= ~rtg.boards.RTGBF_SHOWING;
    }
}
