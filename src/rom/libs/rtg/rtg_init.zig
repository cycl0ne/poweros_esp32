// SPDX-License-Identifier: MPL-2.0
//! rtg.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident; exec builds the library
//! from the InitTable - the jump table is rtg_lvo.zig's - and calls
//! `init`, which opens utility.library, expansion.library and
//! timer.device, sets up the lists and locks, and puts the drivers of the
//! ROM on the driver list.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg_lvo = @import("rtg_lvo.zig");
const RtgBase = @import("rtg_base.zig").RtgBase;
const drivers = @import("driver/_driver.zig");

pub const LIBRARY_NAME = rtg.RTGNAME;
pub const LIBRARY_VERSION = 1;
/// 1: the pointer - SetBoardPointer, MoveBoardPointer, ShowBoardPointer.
/// 4: pixels laid over a buffer by the engine - BlendPixels, BlendRect,
/// ScalePixels.
/// 5: RefreshRect - a rectangle handed on, not its whole rows.
/// 6: buffers from system memory a DMA engine reaches (RTGRF_DMA_MEMORY).
/// 7: a buffer's `watch` hook told in place of the board, and RTGA_Compose
/// kept as RTGBF_COMPOSE - a composed screen's windows.
/// 9: CopyRects - several copies as one job of the engine.
/// 10: video layers - OpenVideoLayer, CloseVideoLayer, ShowVideoFrame,
/// MoveVideoLayer: a plane that shows a picture in YUV itself.
/// 11: RtgBoardStats.blanks - the display's frames begun.
/// 12: WaitVBlank's wait for a board's frames has a time limit, and
/// answers RTGERR_TIMEOUT past it.
/// 13: a board's lock around what changes the board - its buffers, what
/// is shown, its mode; RTGCTRL_RESET_STATS on a board with no control.
/// 14: ten calls nothing used are gone, their slots kept free; a call
/// that answers with a pointer answers null and keeps no reason.
/// 15: RtgFormatBits, RtgRowBytes and RtgCicp - a format's size and a
/// stream's colour numbers, asked of the library.
/// 16: two interfaces of the one table - what a driver calls
/// (AddRtgDriver, RemRtgDriver, SignalRtgEvent, TxParam, TxColor,
/// RxParam, GetRtgTagData) follows the programs' calls, in slots of its
/// own.
/// 17: a driver is a description (RtgDriverSpec) behind a ROM tag with no
/// init - the library puts the ROM's on its list itself, and makes each
/// driver's node and state; AddRtgDriver takes a description.
/// 18: devices - the board's panel parts and the display functions on
/// PCI - offered to the drivers that say they take them
/// (BindRtgDrivers); a driver makes its boards (CreateBoard) and opens
/// its bus (OpenTransport); GetRtgDrivers, GetRtgDevices, AddRtgDevice,
/// RemRtgDevice. A board is named by the library and never freed for a
/// program.
/// 19: modes are the library's - a driver adds them (AddBoardMode) from
/// timings it reads with ReadTimingTags, the library names and numbers
/// them, and a program is handed copies (GetBoardModes) and names a mode
/// by its number: FindBoardMode answers one, with a refresh and RTG_ANY,
/// BestBoardMode the nearest to a wish. NextBoardMode is gone.
/// 20: the monitor - a board with a connector says what is on it
/// (detect) and which timings it can make (check_mode), and the library
/// reads the EDID and makes the board's modes of it, again whenever the
/// driver says MonitorChanged; GetBoardMonitor, ReadBoardEDID; a task is
/// told of what changes (AddRtgNotify, RemRtgNotify,
/// RtgBoardInfo.changes).
/// 21: one step for what is on the glass - ShowBoard puts the board in a
/// mode and shows bands in it, the driver's one op is show, and the
/// library keeps the bands; ShowBitMap takes no offsets; a buffer lives
/// through a mode change. SetBoardMode and ShowBitMapBands are gone,
/// and a board is in no mode until it is first shown something.
/// 22: the library waits for a frame - a driver says FrameDone from its
/// frame interrupt, the library counts the frames (RtgBoardStats.blanks)
/// and WaitVBlank waits for them with its limit, by the clock on a board
/// that says none: it comes back on every board. The event servers
/// (AddRtgEventServer, RemRtgEventServer, SignalRtgEvent) and the op
/// wait_vblank are gone.
/// 23: the tasks that wait for a frame are on a list changed inside
/// Disable, not under a spinlock: the frame interrupt may find a task
/// holding any lock.
/// 24: the library composes - a display with a picture of its own has
/// its driver fill in update and fetch the picture's pixels with
/// ComposeLines: bands, an overlay and a pointer on a board whose driver
/// wrote none of them, shown direct for as long as nothing lies over the
/// picture (RtgBoardSpec.direct_bands, RTGSHOW_DIRECT). The ops for the
/// pointer, the overlay, the engine and the video layers are tables of
/// their own; a board's compose lock replaces the one pointer lock.
/// RefreshRect takes null for the whole buffer, and RefreshBitMap is
/// gone.
/// 25: a driver may say how many bands its display reads, and which ops
/// it has, until its attach answers (RtgBoard.direct_bands); an image
/// the library lays is taken from any memory.
/// 26: a board that is flipped between two frames has its pictures made
/// by the library: its driver fills in flip, and what is written is
/// noted as rectangles, which a task of the board's fetches into the
/// frame the display is not reading (RtgBoardOps.flip and frames,
/// RtgShow.frame, RTGFLIP_TAKEN, RTGBF_DIRECT_FLIP). CopyRect and
/// CopyRects into a buffer such a board shows wait while a picture is
/// made of it.
/// 27: a driver's flip is called without the board's compose lock, so
/// one that waits until the display has taken the frame holds up no
/// pointer's move.
/// 28: a band whose buffer is not the mode's size is scaled by the
/// ratio of the widths where the library composes the picture
/// (RTGBC_SCALE_BANDS, RTGBF_SCALES); a board whose monitor changed for
/// one without its mode shows what it showed in the new monitor's.
/// 29: SetBoardPower (on, blank, asleep; RtgBoardOps.power) in place of
/// SetBoardDisplay; MirrorBoard by the board's hardware for the axes it
/// turns and by the library for the rest (RTGBC_MIRROR_X,
/// RTGBC_MIRROR_Y); the library keeps the brightness, a backlight is
/// lit with the first picture (brightness_steps), and BoardBrightness
/// is gone.
/// 30: a monitor's own brightness is left as it is: the first picture
/// sets one only where the device's tags ask it.
/// 31: a monitor's brightness is read from it (RtgBoardOps.brightness):
/// GetBoardInfo asks, and SetBoardBrightness tells a monitor at once
/// even while its board is asleep.
/// 32: LockBitMap and UnlockBitMap: a writer of whole rectangles that is
/// not the board's engine holds off the picture a flipped board makes of
/// its buffers, as CopyRect and CopyRects do for an engine.
/// 33: SetBoardAudio and the op `audio` (RTGBC_AUDIO): a display's link
/// carries the sound its board is told, so the sound's driver asks the
/// board and reaches no register of the display's; BuildAviInfoFrame
/// and HdmiAudioClock for the drivers of such links.
/// 34: the settings (display.prefs): LoadBoardSettings,
/// SaveBoardSettings, GetBoardSettings, SetBoardSettings and
/// SetRtgDeviceDriver; an output's line names the mode it comes up in,
/// its mirror, its brightness, its colour range (RtgBoardInfo.color_range,
/// RTGBC_COLOR_RANGE), timings by hand and which board is the first, for
/// the monitor it names; a device's line goes in front of its tags.
/// 35: LoadRtgDrivers: the drivers in DEVS:gfxdrv/ that take a device no
/// driver has are loaded and bound, each read for what it takes first,
/// and one named in display.trying passed over; a driver that takes the
/// device a firmware's framebuffer lies behind is told so (RTGA_Adopt),
/// and the firmware's board is gone once it has made its own.
pub const LIBRARY_REVISION = 35;
const BUILD_DATE = "17.11.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The utility.library version the tag calls need.
const UTILITY_VERSION = 1;
/// The expansion.library version the drivers' questions need.
const EXPANSION_VERSION = 1;

/// The base around the Library header exec made.
///
/// INPUTS:
/// - `lib` - the Library header.
fn rtgBase(lib: *exec.Library) *RtgBase {
    return @fieldParentPtr("lib", lib);
}

/// LibInit: exec has copied the tag's name, version and ID string into the
/// base. Without utility.library there is no rtg.library - the tag lists
/// are how a board is configured, and they are utility's. timer.device is
/// opened here, once, for the waits that have a time limit: at the first
/// wait two tasks could both be the first. expansion.library is opened
/// for the drivers, which ask it about the board's parts, and the drivers
/// the ROM holds go on the list last, from their tags: nothing of a
/// driver runs here.
///
/// INPUTS:
/// - `lib` - the library as exec made it.
/// - `seg_list` - unused; a ROM module has none.
/// - `sys_base` - exec, kept in the base.
///
/// RESULT:
/// The library, or null if utility.library could not be opened. Without
/// timer.device it still starts, and a wait that needs a time limit is
/// refused; without expansion.library a driver finds none in its node.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking started.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const rb = rtgBase(lib);
    lib.revision = LIBRARY_REVISION;
    rb.sys_base = sys_base;
    rb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null);
    rb.expansion_base = @ptrCast(sys_base.OpenLibrary(sdk.expansion.EXPANSIONNAME, EXPANSION_VERSION));
    rb.pci_base = null;
    rb.devices_listed = false;
    rb.panel_serial = 0;
    sys_base.NewList(&rb.drivers);
    sys_base.NewList(&rb.devices);
    sys_base.NewList(&rb.boards);
    sys_base.NewList(&rb.transports);
    sys_base.InitSemaphore(&rb.driver_lock);
    sys_base.InitSemaphore(&rb.device_lock);
    sys_base.InitSemaphore(&rb.board_lock);
    sys_base.NewList(&rb.notifies);
    sys_base.InitSemaphore(&rb.notify_lock);
    rb.monitor_task = null;
    sys_base.NewList(&rb.output_lines);
    sys_base.NewList(&rb.device_lines);
    sys_base.InitSemaphore(&rb.settings_lock);
    rb.dos_base = null;
    rb.timer_io = .{};
    rb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &rb.timer_io.node, 0) != 0) {
        rb.timer_io.node.device = null;
    }
    drivers.addResidents(rb);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(RtgBase),
    .vectors = &rtg_lvo.vectors,
    .vector_count = rtg_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 24: after utility.library (103), expansion.library (102)
/// and timer.device (50), which it opens, and after the resources a
/// driver needs (dma 70, i2c 35, expander 30). A driver is started by
/// nothing: its first code runs when a board or a bus is asked of it.
pub export const rtg_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 24,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
