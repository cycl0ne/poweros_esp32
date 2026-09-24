// SPDX-License-Identifier: MIT
//! Screens: a display, as intuition.library hands it out.
//!
//! A screen owns one display: its size is the display's, its pixels are
//! the display's own buffer, and a second screen on the same display is
//! refused. Everything drawn on it goes through a RastPort, and the
//! windows that will share it are layers over that same buffer, so a
//! screen is where graphics.library, layers.library and a display meet.
//!
//! A `Screen` is opaque. What a program wants to know about one it reads
//! with `GetScreenAttrs`, using the same `SA_` tags that configure one at
//! `OpenScreenTagList` - so what a screen is can change without any
//! program on the disk being built again.
//!
//! A **public** screen has a name, and any program may open windows on it
//! after `LockPubScreen`, which keeps it from closing underneath them. The
//! default public screen is the Workbench screen: `LockPubScreen(null)`
//! opens it if it is not open yet.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
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
/// The text in its title bar: a C string, not copied. None by default.
pub const SA_Title = SA_Dummy + 0x0008;
/// Open only: a `*u32` that is given one of the `OSERR_` codes when it
/// cannot be opened.
pub const SA_ErrorCode = SA_Dummy + 0x000A;
/// The font its title bar and windows use: a `*graphics.TextFont` the
/// caller keeps open for as long as the screen is. Pospaz 16 by default.
pub const SA_Font = SA_Dummy + 0x000B;
/// The name that makes it public; copied, at most `MAXPUBSCREENNAME`
/// characters. None by default, which keeps it private.
pub const SA_PubName = SA_Dummy + 0x000F;
/// Whether it has a title bar. True by default.
pub const SA_ShowTitle = SA_Dummy + 0x0016;
/// Open only: a `*const [NUMDRIPENS]graphics.Pen`, copied, in place of
/// the default pens.
pub const SA_Pens = SA_Dummy + 0x001A;
/// Read only: the screen's RastPort, over the whole display and under no
/// layer - what is drawn through it lands beneath every window.
pub const SA_RastPort = SA_Dummy + 0x0100;
/// Read only: the LayerInfo its windows are layers of.
pub const SA_LayerInfo = SA_Dummy + 0x0101;
/// Read only: how tall the title bar is, trim line included; 0 when it
/// has none.
pub const SA_BarHeight = SA_Dummy + 0x0102;

/// What went wrong, in `SA_ErrorCode`.
/// There is no display to open it on.
pub const OSERR_NOMONITOR: u32 = 1;
/// No memory.
pub const OSERR_NOMEM: u32 = 3;
/// A public screen of that name is already open.
pub const OSERR_PUBNOTUNIQUE: u32 = 5;
/// The display already shows a screen.
pub const OSERR_NOTAVAILABLE: u32 = 9;
/// The public name is longer than `MAXPUBSCREENNAME`.
pub const OSERR_BADNAME: u32 = 10;

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
