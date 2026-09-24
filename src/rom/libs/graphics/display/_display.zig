// SPDX-License-Identifier: MPL-2.0
//! The machine's display, brought up by this library's init: the board's
//! panel, or the emulator's virtual display, made into an rtg board and
//! showing its first picture.
//!
//! It asks expansion.library for the board's panel part, whose tags are
//! what rtg.library's drivers are told - the geometry, the timings or the
//! bus, the pads and the control lines - and hands them to rtg.library,
//! which finds the driver that can drive such a thing and brings it up: a
//! panel on LCD_CAM to the "rgb" driver, one on SPI to the "qspi"
//! transport and the "dcs" controller on it, the emulator's display to the
//! "qemu" driver. What comes back is a board with display memory; a buffer
//! out of that memory is the picture, cleared to black and shown. Nothing
//! is drawn before this: the kernel's output until then is exec's raw port.
//!
//! The order is the panel's and none of it is optional:
//!
//!   1. the board, which lets the panel out of reset and takes its memory,
//!      its two DMA channels and the buffers it is really fed from;
//!   2. the mode, which programs the pads, the timings and the clock;
//!   3. a buffer, the first picture drawn into it, and the whole of it
//!      written back out of the cache while nothing is reading it;
//!   4. showing that buffer, which starts the pixel stream.
//!
//! Step 3 before step 4 is the point of the split: a 1.2 MB write-back
//! landing on top of a running stream is enough to starve it.
//!
//! The board is rtg.library's once it is made, and found again by name;
//! the View (`rastport/_rastport.zig`) finds it as the first board rtg
//! lists.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const tags = rtg.tags;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const RtgBase = sdk.interface.rtg.RtgBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const GraphicsBase = @import("../graphics_base.zig").GraphicsBase;

/// What the display's board is called, which is how everything finds it
/// again.
const BOARD_NAME = sdk.graphics.DISPLAY_BOARD;

/// What the machine says about its display: the screen it runs, and the
/// panel part if it has one.
const Machine = struct {
    width: u32 = 0,
    height: u32 = 0,
    panel: ?*const expansion.BoardPart = null,
    bus: u32 = st.BUS_NONE,
    /// The panel is the emulator's display, which owns its own pixels.
    emulated: bool = false,
};

/// The machine's display, as expansion.library describes it. Empty when
/// expansion.library is not there or names no panel.
fn readMachine(gb: *GraphicsBase) Machine {
    const sys = gb.sys_base;
    const ub = gb.utility_base;
    var machine: Machine = .{};
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return machine;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const root = eb.SystemTags();
    machine.width = @truncate(ub.GetTagData(st.SYSTAG_ScreenWidth, 0, root));
    machine.height = @truncate(ub.GetTagData(st.SYSTAG_ScreenHeight, 0, root));
    if (eb.FindBoardPart(null, st.PARTKIND_PANEL, st.CHIP_ANY)) |part| {
        machine.panel = part;
        machine.bus = @truncate(ub.GetTagData(st.PART_Bus, st.BUS_NONE, part.tags));
        machine.emulated = part.chip == st.CHIP_QEMU_DISPLAY;
    }
    return machine;
}

/// Which display this machine turned out to have.
const Found = struct { which: *rtg.RtgBoard, emulated: bool };

/// The machine's panel, made into a board called BOARD_NAME whichever
/// driver drives it, so everything past this point is the same and nothing
/// else here has to know which it got. Null when the machine has no panel
/// or its driver will not take it.
fn createBoard(rb: *RtgBase, machine: *const Machine) ?Found {
    const part = machine.panel orelse return null;
    const panel_tags = @intFromPtr(part.tags);
    const named = [_]TagItem{
        .{ .tag = tags.RTGA_BoardName, .data = @intFromPtr(BOARD_NAME) },
        .{ .tag = sdk.utility.TAG_MORE, .data = panel_tags },
    };
    switch (machine.bus) {
        // A panel on LCD_CAM: its tags are the RGB driver's, and this adds
        // only the name everything finds the board by.
        st.BUS_LCD => if (rb.CreateBoardTagList("rgb", &named)) |which| {
            return .{ .which = which, .emulated = false };
        },
        // A controller on a QSPI bus: the bus first, from the same tags,
        // then the controller on it with the bus it was given.
        st.BUS_SPI => if (rb.CreateTransportTagList("qspi", part.tags)) |io| {
            const on_bus = [_]TagItem{
                .{ .tag = tags.RTGA_BoardName, .data = @intFromPtr(BOARD_NAME) },
                .{ .tag = tags.RTGA_Transport, .data = @intFromPtr(io) },
                .{ .tag = sdk.utility.TAG_MORE, .data = panel_tags },
            };
            if (rb.CreateBoardTagList("dcs", &on_bus)) |which| return .{ .which = which, .emulated = false };
            rb.DeleteTransport(io);
        },
        // The emulator's display: memory and a doorbell.
        st.BUS_MEMORY => if (rb.CreateBoardTagList("qemu", &named)) |which| {
            return .{ .which = which, .emulated = machine.emulated };
        },
        else => {},
    }
    return null;
}

/// The panel, from nothing to a picture. Null and nothing taken if any
/// step fails.
fn bringUp(rb: *RtgBase, machine: *const Machine) ?Found {
    const found = createBoard(rb, machine) orelse return null;
    const which = found.which;
    // The board's mode of the screen's size, which is what says which way
    // up a panel that can be turned runs; its default when it has only one.
    const mode = rb.FindBoardMode(which, machine.width, machine.height, 0) orelse
        rb.FindBoardMode(which, 0, 0, 0) orelse
        return giveBack(rb, which);
    if (rb.SetBoardMode(which, mode) != rtg.errors.RTGERR_OK) return giveBack(rb, which);

    const picture = rb.AllocBitMap(
        which,
        mode.width,
        mode.height,
        @intFromEnum(mode.format),
        rtg.bitmaps.RTGBMF_DISPLAYABLE | rtg.bitmaps.PIXMAPF_SCREEN,
    ) orelse return giveBack(rb, which);

    // The first picture, black, handed on while nothing is reading it:
    // RefreshBitMap is each driver's own way to the glass - a write-back
    // out of the cache, a send over the bus, the emulator's doorbell.
    const pixels: [*]u8 = @ptrCast(picture.pixels.?);
    @memset(pixels[0 .. @as(usize, picture.pitch) * picture.height], 0);
    _ = rb.RefreshBitMap(picture, 0, 0);

    if (rb.ShowBitMap(which, picture, 0, 0) != rtg.errors.RTGERR_OK) {
        rb.FreeBitMap(picture);
        return giveBack(rb, which);
    }
    _ = rb.SetBoardBrightness(which, 100);
    return found;
}

fn giveBack(rb: *RtgBase, which: *rtg.RtgBoard) ?Found {
    const bus = which.transport;
    rb.DeleteBoard(which);
    // A bus made for this board goes with it.
    if (bus) |io| rb.DeleteTransport(io);
    return null;
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
/// It runs last in `init`, after the drivers' residents (21 to 23) have
/// added their drivers to rtg.library (24), and says on the raw port what
/// it brought up.
///
/// CONTEXT:
/// - Waits: yes. A panel is held in reset for tens of milliseconds, and
///   its driver waits that out.
/// - Interrupts: no.
/// - Forbid: not held, and it must not be, because of the wait.
/// - Process: a Task will do. The exec task runs it at cold start.
pub fn openDisplay(gb: *GraphicsBase) void {
    const machine = readMachine(gb);
    const found = bringUp(gb.rtg_base, &machine) orelse return;
    if (found.emulated) {
        // The emulator's display owns its own pixels, so there is no
        // framebuffer of this machine's to report.
        exec.kprintf(gb.sys_base, "graphics.library: %dx%d virtual display\n", .{
            machine.width,
            machine.height,
        });
    } else {
        exec.kprintf(gb.sys_base, "graphics.library: %dx%d panel, %d KiB in PSRAM\n", .{
            machine.width,
            machine.height,
            machine.width * machine.height * 2 / 1024,
        });
    }
}
