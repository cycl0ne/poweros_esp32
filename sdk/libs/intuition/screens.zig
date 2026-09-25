// SPDX-License-Identifier: MIT
//! Screens: a display, as intuition.library hands it out.
//!
//! A screen is a picture the size of its display, in a buffer of its own
//! in the display's memory. Several can be open on one display, as much
//! as that memory holds; the display shows the one at the front, whole,
//! and `ScreenToFront` / `ScreenToBack` change which by showing another
//! buffer - nothing is copied. Everything drawn on a screen goes through a
//! RastPort on its buffer, and its windows are layers over that same
//! buffer, so a screen is where graphics.library, layers.library and a
//! display meet.
//!
//! A `Screen` is opaque. What a program wants to know about one it reads
//! with `GetScreenAttrs`, using the same `SA_` tags that configure one at
//! `OpenScreenTagList` - so what a screen is can change without any
//! program on the disk being built again.
//!
//! A **public** screen has a name, and any program may open windows on it
//! after `LockPubScreen`, which keeps it from closing underneath them. It
//! opens private - found by no one - until its owner calls
//! `PubScreenStatus(screen, 0)`. The default public screen is the one
//! `SetDefaultPubScreen` chose, or else the Workbench screen:
//! `LockPubScreen(null)` opens that if it is not open yet. Every public
//! screen has a `PubScreenNode` on the list `LockPubScreenList` hands out.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const rtg = @import("../rtg/rtg.zig");
const classes = @import("classes.zig");
const Pen = graphics.Pen;

/// A screen. Read it with `GetScreenAttrs`.
pub const Screen = opaque {};

/// The default public screen's name.
pub const WBENCHNAME = "Workbench";

/// The longest public screen name, not counting its NUL.
pub const MAXPUBSCREENNAME = 31;

// --- tags ---------------------------------------------------------------------
//
// Given to `OpenScreenTagList`, read back with `GetScreenAttrs`, where each
// ti_Data is a `*usize` the value is written to.

pub const SA_Dummy = utility.TAG_USER + 32;
/// Read only: the screen's size, which is its display's.
pub const SA_Width = SA_Dummy + 0x0003;
pub const SA_Height = SA_Dummy + 0x0004;
/// Read only: bits per pixel of the display.
pub const SA_Depth = SA_Dummy + 0x0005;
/// Open only: the detail and block pens of its DrawInfo - what a window
/// on it draws its own pens from - in place of the defaults, before
/// `SA_Pens` has its say.
pub const SA_DetailPen = SA_Dummy + 0x0006;
pub const SA_BlockPen = SA_Dummy + 0x0007;
/// The text in its title bar: a C string, not copied. None by default.
/// Read back, what the bar shows now: the active window's screen title
/// while one of the screen's windows is active.
pub const SA_Title = SA_Dummy + 0x0008;
/// Open only: a `*u32` that is given one of the `OSERR_` codes when it
/// cannot be opened.
pub const SA_ErrorCode = SA_Dummy + 0x000A;
/// The font its title bar and windows use: a `*graphics.TextFont` the
/// caller keeps open for as long as the screen is. Pospaz 16 by default.
pub const SA_Font = SA_Dummy + 0x000B;
/// Open only: one of the system's fonts in place of `SA_Font` - 0 the
/// default font, 1 the preferred one. Both are the ROM font for now.
pub const SA_SysFont = SA_Dummy + 0x000C;
/// `CUSTOMSCREEN` or `PUBLICSCREEN`. A screen given `SA_PubName` is public
/// unless it says `CUSTOMSCREEN`. Read back, which it is.
pub const SA_Type = SA_Dummy + 0x000D;
/// The name that makes it public; copied, at most `MAXPUBSCREENNAME`
/// characters. None by default, which keeps it private.
pub const SA_PubName = SA_Dummy + 0x000F;
/// Open only: the signal bit its owner is sent when the last visitor -
/// a lock or a window opened on it by name - goes, so that it can try to
/// close again. None by default.
pub const SA_PubSig = SA_Dummy + 0x0010;
/// Open only: the task `SA_PubSig` goes to, a `*exec.Task`. The one
/// opening the screen by default.
pub const SA_PubTask = SA_Dummy + 0x0011;
/// Whether it has a title bar. True by default.
pub const SA_ShowTitle = SA_Dummy + 0x0016;
/// Open only: true to open behind the display's other screens rather than
/// in front of them - set up without being seen, then `ScreenToFront`.
pub const SA_Behind = SA_Dummy + 0x0017;
/// Open only: true for no title bar at all, as `SA_ShowTitle` false - a
/// screen whose program draws every pixel of it.
pub const SA_Quiet = SA_Dummy + 0x0018;
/// Open only: a `*const [NUMDRIPENS]graphics.Pen`, copied, in place of
/// the default pens.
pub const SA_Pens = SA_Dummy + 0x001A;
/// Open only: a `*utility.Hook` that paints the screen's background - what
/// shows where no window is - in place of the background pen. It is called
/// as a layer's backfill hook: the RastPort as the object and a
/// `layers.BackFillMsg` as the message.
pub const SA_BackFill = SA_Dummy + 0x0021;
/// Open only: true for the Workbench screen's pens and a font of its
/// height, when it is open; any tag given as well still has its say.
pub const SA_LikeWorkbench = SA_Dummy + 0x0027;
/// Read only: the screen's RastPort, over the whole display and under no
/// layer - what is drawn through it lands beneath every window.
pub const SA_RastPort = SA_Dummy + 0x0100;
/// Read only: the LayerInfo its windows are layers of.
pub const SA_LayerInfo = SA_Dummy + 0x0101;
/// Read only: how tall the title bar is, trim line included; 0 when it
/// has none.
pub const SA_BarHeight = SA_Dummy + 0x0102;
/// Read only: where the pointer is, in the screen's coordinates.
pub const SA_MouseX = SA_Dummy + 0x0103;
pub const SA_MouseY = SA_Dummy + 0x0104;
/// Read only: the borders a window opened on it gets - the top one with a
/// title bar, the right one without a size gadget - so a window can be
/// sized from the room it needs inside before it is opened.
pub const SA_WBorTop = SA_Dummy + 0x0105;
pub const SA_WBorLeft = SA_Dummy + 0x0106;
pub const SA_WBorRight = SA_Dummy + 0x0107;
pub const SA_WBorBottom = SA_Dummy + 0x0108;
/// Read only: the title bar's margins - above and below the text, and
/// left of it.
pub const SA_BarVBorder = SA_Dummy + 0x0109;
pub const SA_BarHBorder = SA_Dummy + 0x010A;
/// Read only: the title it shows when none of its windows is active,
/// `SA_Title` as it was opened with.
pub const SA_DefaultTitle = SA_Dummy + 0x010B;

/// `SA_Type`: a screen of its program's own, or a public one.
pub const PUBLICSCREEN: u32 = 0x0002;
pub const CUSTOMSCREEN: u32 = 0x000F;

/// What went wrong, in `SA_ErrorCode`.
/// There is no display to open it on.
pub const OSERR_NOMONITOR: u32 = 1;
/// No memory.
pub const OSERR_NOMEM: u32 = 3;
/// A public screen of that name is already open.
pub const OSERR_PUBNOTUNIQUE: u32 = 5;
/// The display's memory has no room for another screen's buffer.
pub const OSERR_NOTAVAILABLE: u32 = 9;
/// The public name is longer than `MAXPUBSCREENNAME`.
pub const OSERR_BADNAME: u32 = 10;

// --- double buffering ---------------------------------------------------------

/// One buffer of a screen, from `AllocScreenBuffer`: a picture the screen's
/// size in its display's memory, and a RastPort that draws in it. A program
/// draws its next frame through one while another is shown, then shows it
/// with `ChangeScreenBuffer` - the display flips at the start of a frame,
/// so nothing tears and nothing is copied.
pub const ScreenBuffer = extern struct {
    /// The buffer.
    bitmap: *rtg.RtgBitMap,
    /// Over the whole of it, under no layer.
    rast_port: *graphics.RastPort,
    /// The `SB_` flags it was made with.
    flags: u32,
};

/// `AllocScreenBuffer`: this one is the screen's own buffer, the one its
/// title bar, windows and menus are drawn in - nothing new is allocated.
pub const SB_SCREEN_BITMAP: u32 = 1;
/// `AllocScreenBuffer`: the new buffer starts as a copy of the screen's own
/// rather than black.
pub const SB_COPY_BITMAP: u32 = 2;

/// `ScreenDepth`: to the front of its display, or to the back.
pub const SDEPTH_TOFRONT: u32 = 0;
pub const SDEPTH_TOBACK: u32 = 1;

// --- public screens -----------------------------------------------------------

/// A public screen, on the list `LockPubScreenList` hands out. Read it
/// only while holding that list.
pub const PubScreenNode = extern struct {
    /// Its `name` is the screen's public name.
    node: exec.Node = .{},
    screen: *Screen,
    /// `PSNF_` bits.
    flags: u32 = PSNF_PRIVATE,
    /// Locks and visitor windows outstanding. It cannot close until 0.
    visitor_count: u32 = 0,
    /// Who is sent `sig_bit` when the count falls to 0; null for no one.
    sig_task: ?*exec.Task = null,
    sig_bit: u8 = 0,
};

/// Found by no one: `LockPubScreen` and a window opened on it by name
/// fail. A public screen starts so.
pub const PSNF_PRIVATE: u32 = 0x0001;

/// `SetPubScreenModes`: a window opened on a public screen by name brings
/// that screen to the front.
pub const POPPUBSCREEN: u32 = 0x0002;

// --- DrawInfo -----------------------------------------------------------------

/// The pens a screen draws its parts in, by what each is for. Each is a
/// graphics.library pen - 0xAARRGGBB, never an index.
pub const DETAILPEN = 0;
pub const BLOCKPEN = 1;
/// Text on the background.
pub const TEXTPEN = 2;
/// The bright edge of something raised.
pub const SHINEPEN = 3;
/// The dark edge of something raised.
pub const SHADOWPEN = 4;
/// The fill of an active window's border or a selected gadget.
pub const FILLPEN = 5;
/// Text over FILLPEN.
pub const FILLTEXTPEN = 6;
/// The screen's background.
pub const BACKGROUNDPEN = 7;
/// Text that stands out, on the background.
pub const HIGHLIGHTTEXTPEN = 8;
/// Text in the title bar and the menus.
pub const BARDETAILPEN = 9;
/// The title bar's and the menus' fill.
pub const BARBLOCKPEN = 10;
/// The line under the title bar.
pub const BARTRIMPEN = 11;
pub const NUMDRIPENS = 12;

/// The DrawInfo layout this SDK describes. Anything added later goes
/// after the fields here and raises it.
pub const DRI_VERSION: u32 = 2;

/// What a screen's parts are drawn with: `GetScreenDrawInfo` hands out the
/// screen's own. Read only.
pub const DrawInfo = extern struct {
    /// dri_Version: `DRI_VERSION` of the library that made it.
    version: u32 = DRI_VERSION,
    /// dri_NumPens: at least `NUMDRIPENS`.
    num_pens: u32 = NUMDRIPENS,
    /// dri_Pens: the pens, by the indexes above.
    pens: [*]const Pen,
    /// dri_Font: the screen's font.
    font: ?*graphics.TextFont = null,
    /// dri_Depth: bits per pixel of the display.
    depth: u32 = 0,
    /// dri_Flags: none defined.
    flags: u32 = 0,
    reserved: [4]usize = @splat(0),
    /// dri_CheckMark: the sysiclass `MENUCHECK` image a checked menu item
    /// shows, sized to the font. Version 2.
    check_mark: ?*classes.Object = null,
    /// dri_AmigaKey: the sysiclass `AMIGAKEY` image a menu item's shortcut
    /// shows, sized to the font. Version 2.
    amiga_key: ?*classes.Object = null,
};
