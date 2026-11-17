// SPDX-License-Identifier: MPL-2.0
//! GetBoardInfo: Fill in `info`, of which `size` bytes are there - pass
//! @sizeOf(RtgBoardInfo).

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const frames = @import("../frame/_frame.zig");
const copyOut = _board.copyOut;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Reads what a board is and what state it is in.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardInfo(_: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `board` - the board.
/// - `info` - where the answer goes.
/// - `size` - how many bytes `info` has: `@sizeOf(RtgBoardInfo)`.
///
/// RESULT:
/// How many bytes were written. A caller built against an older SDK with a
/// smaller structure gets that much; check the count before trusting a
/// field near the end.
///
/// BEHAVIOR:
/// The display memory still free and its largest piece are read fresh;
/// the rest is what the board already says about itself: the mode it is
/// in, its power state (`power`), the brightness the library keeps for
/// its backlight and how many levels that has (`brightness`,
/// `brightness_steps`), and how its picture is mirrored (`mirror_x`,
/// `mirror_y`) - which is what whoever turns a touch on the glass into a
/// place in the picture reads.
///
/// A monitor keeps a brightness of its own, which its buttons change
/// too: a board whose driver reads it asks the monitor at every call,
/// while the board has a display and is not asleep, and `brightness` is
/// what it answered. Where it does not answer, `brightness` is what was
/// last heard or set - 100 before anything was.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock - through a show,
///   which may last a frame - and while a monitor is asked its
///   brightness, some tenth of a second.
/// - Interrupts: no.
/// - Locks: takes the board's lock while it reads what is free of the
///   display memory and asks the monitor. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardStats`, `GetBoardModes`
///
/// EXAMPLES:
/// ```zig
/// var info: rtg.RtgBoardInfo = .{};
/// _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
/// ```
pub fn GetBoardInfo(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) u32 {
    const private = privateOf(board);
    // The display memory's free pieces are a list the board's lock holds
    // still.
    _board.obtain(rb, board);
    board.info.memory_free = private.arena.free_bytes;
    board.info.memory_largest = private.arena.largest(rb.sys_base);
    // Whether its driver says its frames, as they come.
    if (frames.come(&private.frames)) {
        board.info.caps |= rtg.boards.RTGBC_VBLANK;
    } else {
        board.info.caps &= ~@as(u32, rtg.boards.RTGBC_VBLANK);
    }
    // A display that keeps a brightness of its own is asked what it is
    // at; one that does not answer leaves what was last heard.
    if (board.ops) |ops| {
        if (ops.brightness) |read| {
            const there = board.info.flags & rtg.boards.RTGBF_NO_DISPLAY == 0;
            const awake = board.info.power != rtg.boards.RTGPWR_ASLEEP;
            if (there and awake and board.info.caps & rtg.boards.RTGBC_BRIGHTNESS != 0) {
                const now = read(board);
                if (now >= 0) board.info.brightness = @min(@as(u32, @intCast(now)), 100);
            }
        }
    }
    _board.release(rb, board);
    return copyOut(rtg.RtgBoardInfo, &board.info, info, size);
}
