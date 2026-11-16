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
//!   2. the mode, which programs the pads, the timings and the clock;
//!   3. a buffer, the first picture drawn into it, and the whole of it
//!      written back out of the cache while nothing is reading it;
//!   4. showing that buffer, which starts the pixel stream.
//!
//! Step 3 before step 4 is the point of the split: a 1.2 MB write-back
//! landing on top of a running stream is enough to starve it.
//!
//! The board is rtg.library's, and found again as it was found here: the
//! View (`rastport/_rastport.zig`) asks for the first board rtg lists.

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
    var mode_id = rb.FindBoardMode(which, width, height, rtg.RTG_ANY, rtg.RTG_ANY);
    if (mode_id == 0) mode_id = rb.FindBoardMode(which, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY);
    if (mode_id == 0) return null;
    if (rb.SetBoardMode(which, mode_id) != rtg.errors.RTGERR_OK) return null;
    // What the board is in now, as it says it.
    var mode: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(which, &mode, @sizeOf(rtg.RtgBoardInfo));

    const picture = rb.AllocBitMap(
        which,
        mode.width,
        mode.height,
        @intFromEnum(mode.format),
        rtg.bitmaps.RTGBMF_DISPLAYABLE | rtg.bitmaps.PIXMAPF_SCREEN,
    ) orelse return null;

    // The first picture, black, handed on while nothing is reading it:
    // RefreshBitMap is each driver's own way to the glass - a write-back
    // out of the cache, a send over the bus, the emulator's doorbell.
    const pixels: [*]u8 = @ptrCast(picture.pixels.?);
    @memset(pixels[0 .. @as(usize, picture.pitch) * picture.height], 0);
    _ = rb.RefreshBitMap(picture, 0, 0);

    if (rb.ShowBitMap(which, picture, 0, 0) != rtg.errors.RTGERR_OK) {
        rb.FreeBitMap(picture);
        return null;
    }
    _ = rb.SetBoardBrightness(which, 100);
    return .{
        .width = mode.width,
        .height = mode.height,
        .bytes = @as(usize, picture.pitch) * picture.height,
    };
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
