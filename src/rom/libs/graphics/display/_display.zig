// SPDX-License-Identifier: MPL-2.0
//! The machine's display, brought up by this library's init: the first
//! board rtg.library has, showing its first picture.
//!
//! Which display a machine has, and which driver drives it, is
//! rtg.library's to find: it offers each of the machine's displays - a
//! panel of the board's list, a function on PCI - to the drivers that
//! say they take such a thing (`BindRtgDrivers`), and the driver that
//! takes one brings it up and makes a board of it. A board that lists
//! more than one way to a screen - an HDMI bridge ahead of the panel on
//! the same link - has each offered in the list's order: a driver
//! declines a part whose screen is not there, a bridge without a monitor
//! behind it. The first board of rtg.library's walk is the machine's
//! display; a buffer out of its display memory is the picture, cleared to
//! black and shown. Nothing is drawn before this: the kernel's output
//! until then is exec's raw port.
//!
//! The order is the panel's and none of it is optional:
//!
//!   1. the board, whose driver has let the panel out of reset and taken
//!      its memory, its two DMA channels and the buffers it is really fed
//!      from;
//!   2. a buffer of the mode the board is to come up in, the first
//!      picture drawn into it, and the whole of it written back out of
//!      the cache while nothing is reading it;
//!   3. showing that buffer in that mode, one step: it programs the pads,
//!      the timings and the clock, and starts the pixel stream.
//!
//! Step 2 before step 3 is the point of the order: a 1.2 MB write-back
//! landing on top of a running stream is enough to starve it.
//!
//! The board is rtg.library's, and found again as it was found here: the
//! View (`rastport/_rastport.zig`) asks for the first board rtg lists.
//!
//! A machine whose ROM has no driver for its display has no board at
//! this library's init: its driver is loaded from the disk later
//! (rtg.library's `LoadRtgDrivers`), and the board it makes shows
//! nothing. Such a display is brought up the same way the first time the
//! display is asked for (`light`).

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const RtgBase = sdk.interface.rtg.RtgBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const GraphicsBase = @import("../graphics_base.zig").GraphicsBase;

/// The size of the screen the machine runs, as the board's list gives it;
/// 0 each way where it gives none.
const Screen = struct { width: u32 = 0, height: u32 = 0 };

/// The machine's screen size, as expansion.library's system tags say it.
/// None when expansion.library is not there.
fn readScreen(gb: *GraphicsBase) Screen {
    const sys = gb.sys_base;
    const ub = gb.utility_base;
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return .{};
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const root = eb.SystemTags();
    return .{
        .width = @truncate(ub.GetTagData(st.SYSTAG_ScreenWidth, 0, root)),
        .height = @truncate(ub.GetTagData(st.SYSTAG_ScreenHeight, 0, root)),
    };
}

/// What was brought up: the picture's size and its bytes.
const Shown = struct { width: u32, height: u32, bytes: usize };

/// A board, from nothing shown to a picture. Null if any step fails; what
/// was taken for it is given back, and the board stays as its driver made
/// it.
fn bringUp(rb: *RtgBase, which: *rtg.RtgBoard, screen: Screen) ?Shown {
    // The board's mode of the screen's size, which is what says which way
    // up a panel that can be turned runs; its default where it has none of
    // that size, or the list gives no size.
    const width = if (screen.width != 0) screen.width else rtg.RTG_ANY;
    const height = if (screen.height != 0) screen.height else rtg.RTG_ANY;
    const any = rtg.RTG_ANY;
    var mode: rtg.RtgMode = .{};
    const mode_id = if (rb.FindBoardMode(which, width, height, any, any) != 0)
        rb.BestBoardMode(which, width, height, any, any, &mode)
    else
        rb.BestBoardMode(which, any, any, any, any, &mode);
    if (mode_id == 0) return null;

    const picture = rb.AllocBitMap(
        which,
        mode.width,
        mode.height,
        @intFromEnum(mode.format),
        rtg.bitmaps.RTGBMF_DISPLAYABLE | rtg.bitmaps.PIXMAPF_SCREEN,
    ) orelse return null;

    // The first picture, black, handed on while nothing is reading it:
    // RefreshRect is each board's own way to the glass - a write-back
    // out of the cache, a send over the bus, the emulator's doorbell.
    const pixels: [*]u8 = @ptrCast(picture.pixels.?);
    @memset(pixels[0 .. @as(usize, picture.pitch) * picture.height], 0);
    _ = rb.RefreshRect(picture, null);

    // The mode and the picture in it, as one step.
    const whole = [_]rtg.RtgBand{.{ .bitmap = picture }};
    if (rb.ShowBoard(which, mode_id, &whole, whole.len) != rtg.errors.RTGERR_OK) {
        rb.FreeBitMap(picture);
        return null;
    }
    return .{
        .width = mode.width,
        .height = mode.height,
        .bytes = @as(usize, picture.pitch) * picture.height,
    };
}

/// The machine's display given its first picture, where it shows none:
/// the first board of rtg.library's walk, made after this library's
/// init. What `openDisplay` does at the init, done when the display is
/// first asked for.
///
/// INPUTS:
/// - `gb` - the library's base.
/// - `board` - the first board, which shows nothing.
///
/// RESULT:
/// The buffer the board shows then, or null: for a board that is in a
/// mode already - what it shows is somebody's - and where it could not
/// be brought up: no mode, no room for a picture, or its driver
/// refused.
///
/// CONTEXT:
/// In a task: bringing a display up may wait. Nothing is held: two tasks
/// that ask for a display for the first time at the same moment each
/// make a picture, and the one shown last is the display's - the other
/// stays its task's, unshown. The base has no lock for a thing done
/// once a board.
pub fn light(gb: *GraphicsBase, board: *rtg.RtgBoard) ?*rtg.RtgBitMap {
    const sys = gb.sys_base;
    const rb = gb.rtg_base;
    if (rb.BoardDisplayBitMap(board)) |shown| return shown;
    // Only a board that is in no mode was never brought up: one that is
    // in a mode and shows no whole buffer - bands, or nothing for the
    // moment - is somebody's, and is left as it is.
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (info.mode_id != 0) return null;
    // Where it cannot be brought up, another task may have done it
    // meanwhile and taken the room.
    const shown = bringUp(rb, board, readScreen(gb)) orelse return rb.BoardDisplayBitMap(board);
    exec.kprintf(sys, "graphics.library: %dx%d on %s, %d KiB a picture\n", .{
        shown.width,
        shown.height,
        board.node.name.?,
        @as(u32, @intCast(shown.bytes / 1024)),
    });
    return rb.BoardDisplayBitMap(board);
}

/// Brings the machine's display up and shows a black picture on it.
///
/// INPUTS:
/// - `gb` - the library's base, with utility.library and rtg.library
///   already open in it.
///
/// RESULT:
/// None. A machine with no display, or one whose panel will not come up,
/// is not a machine that cannot boot: the library runs on without a View,
/// and `CreateRastPortTagList(null)` answers null.
///
/// BEHAVIOR:
/// It runs last in `init`, after rtg.library (24) has put the drivers of
/// the ROM on its list. It has rtg.library offer the machine's displays
/// to them, takes the first board of the walk, and says on the raw port
/// what it brought up.
///
/// CONTEXT:
/// - Waits: yes. A panel is held in reset for tens of milliseconds, and
///   its driver waits that out.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, because of the wait.
/// - Process: a Task will do. The exec task runs it at cold start.
pub fn openDisplay(gb: *GraphicsBase) void {
    const rb = gb.rtg_base;
    _ = rb.BindRtgDrivers();
    const which = rb.NextBoard(null) orelse return;
    const shown = bringUp(rb, which, readScreen(gb)) orelse return;
    exec.kprintf(gb.sys_base, "graphics.library: %dx%d on %s, %d KiB a picture\n", .{
        shown.width,
        shown.height,
        which.node.name.?,
        @as(u32, @intCast(shown.bytes / 1024)),
    });
}
