// SPDX-License-Identifier: MIT
//! Windows: a rectangle of a screen that a program draws in without having
//! to know what is in front of it.
//!
//! A window is a layer of its screen's LayerInfo, with a border around it
//! that intuition.library draws - a frame, a title bar, and the images of
//! the border gadgets it asked for. A program draws through the window's
//! RastPort, whose (0,0) is the window's top-left corner, border included:
//! the part to draw in starts at the border's left and top widths.
//!
//! A `Window` is opaque, read with `GetWindowAttrs` using the same `WA_`
//! tags that open one.
//!
//! **IDCMP** is how a window talks back. A window opened with `WA_IDCMP`
//! has a message port, and intuition.library puts an `IntuiMessage` on it
//! for each thing in those flags that happens. The program takes each off
//! with GetMsg and hands it back with ReplyMsg - promptly, since each is
//! an allocation until it comes back.
//!
//! **Refresh.** A smart-refresh window keeps what is covered and gets it
//! back when uncovered; the program draws once. A simple-refresh window
//! keeps nothing: when a part of it is uncovered, intuition.library puts
//! the border back and sends `IDCMP_REFRESHWINDOW`, and the program
//! redraws between `BeginRefresh` and `EndRefresh` - which lets only the
//! uncovered part through, so it may simply draw everything.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");

/// A window. Read it with `GetWindowAttrs`.
pub const Window = opaque {};

// --- tags ---------------------------------------------------------------------
//
// Given to `OpenWindowTagList`, read back with `GetWindowAttrs`, where each
// ti_Data is a `*usize` the value is written to.

pub const WA_Dummy = utility.TAG_USER + 99;
/// Where, on its screen. 0, 0 by default.
pub const WA_Left = WA_Dummy + 0x01;
pub const WA_Top = WA_Dummy + 0x02;
/// How big, border included. 200 by 100 by default.
pub const WA_Width = WA_Dummy + 0x03;
pub const WA_Height = WA_Dummy + 0x04;
/// The pen this window's own furniture is drawn in - `0xAARRGGBB`, as every
/// pen here is. It defaults to the screen's `DETAILPEN`, so a window that
/// says nothing looks like the screen it is on.
pub const WA_DetailPen = WA_Dummy + 0x05;
/// The pen behind it: the screen's `BLOCKPEN` unless it says. A disabled
/// gadget in the window is ghosted in it.
pub const WA_BlockPen = WA_Dummy + 0x06;
/// The `IDCMP_` classes to be told about. 0, the default, gives the window
/// no message port.
pub const WA_IDCMP = WA_Dummy + 0x07;
/// Every flag at once, in place of a tag each: a word of `WFLG_` bits. The
/// separate tags are read after it, so one of them may still say otherwise,
/// and the bits a window does not get to choose are ignored.
pub const WA_Flags = WA_Dummy + 0x08;
/// The text in its title bar: a C string, not copied.
pub const WA_Title = WA_Dummy + 0x0B;
/// True: when the public screen named by `WA_PubScreenName` is not there,
/// open on the default one rather than not at all.
pub const WA_PubScreenFallBack = WA_Dummy + 0x17;
/// True: the part of the window inside the border is a layer of its own, so
/// the program's `(0, 0)` is that corner rather than the window's and it
/// never adds the border widths itself. Nothing it draws can reach the
/// border, and the border's gadgets are not on its list.
///
/// `WA_InnerWidth` and `WA_InnerHeight` read back the size of that part.
pub const WA_GimmeZeroZero = WA_Dummy + 0x2E;
/// A `*const WindowBox` the window flips to when its zoom gadget is used,
/// and back from. Asking for it is also what gives a window a zoom gadget,
/// which it otherwise has only when it has both a sizing and a depth one.
///
/// A box whose left and top are both -1 means "the same corner": only the
/// size changes.
pub const WA_Zoom = WA_Dummy + 0x1A;

/// Where a window is and how big, as `WA_Zoom` takes it.
pub const WindowBox = extern struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
};

/// True: the size gadget takes its room from the right border. This is
/// where it goes when a window says neither this nor `WA_SizeBBottom`, since
/// it has to be somewhere.
pub const WA_SizeBRight = WA_Dummy + 0x2B;
/// True: it takes its room from the bottom border instead. Both is allowed
/// and takes room from each.
pub const WA_SizeBBottom = WA_Dummy + 0x2C;
/// A `*utility.Hook` of the caller's, called to paint a part of the window
/// that has nothing in it yet - when it opens, when it grows, and when a
/// simple-refresh one is uncovered. `layers.LAYERS_NOBACKFILL` leaves such
/// a part exactly as it was. Without this the window is painted in its own
/// background pen.
pub const WA_BackFill = WA_Dummy + 0x1C;
/// A `*graphics.Surface` of the caller's for the window to draw into, which
/// may be larger than the window. The window then keeps everything drawn in
/// it, covered or not, and shows a part of it; `layers.ScrollLayer` moves
/// which part. The caller owns the surface and frees it after the window
/// closes.
pub const WA_SuperBitMap = WA_Dummy + 0x0E;
/// True: the right button belongs to the program - it arrives as
/// `IDCMP_MOUSEBUTTONS` instead of being taken for the menus.
pub const WA_RMBTrap = WA_Dummy + 0x27;
/// True: this window wants to hear the pointer move over it. Without it a
/// window is told only while one of its gadgets is being used.
pub const WA_ReportMouse = WA_Dummy + 0x23;
/// True: `IDCMP_CHANGEWINDOW` when this window's place in the depth order
/// changes, not only when it is moved or sized.
pub const WA_NotifyDepth = WA_Dummy + 0x32;
/// True: the window may be moved, and squeezed, to fit the screen. False -
/// the default when a place is asked for - means open it where it was asked
/// for or not at all.
pub const WA_AutoAdjust = WA_Dummy + 0x2D;
/// A `*Screen` to open on, which the caller keeps open.
pub const WA_CustomScreen = WA_Dummy + 0x0D;
/// The smallest and largest it may be sized to. Its opening size, and
/// the screen's, by default.
pub const WA_MinWidth = WA_Dummy + 0x0F;
pub const WA_MinHeight = WA_Dummy + 0x10;
pub const WA_MaxWidth = WA_Dummy + 0x11;
pub const WA_MaxHeight = WA_Dummy + 0x12;
/// How big inside the border, in place of WA_Width and WA_Height.
pub const WA_InnerWidth = WA_Dummy + 0x13;
pub const WA_InnerHeight = WA_Dummy + 0x14;
/// A public screen to open on, by name. The default public screen when
/// neither this nor WA_CustomScreen nor WA_PubScreen is given. A window
/// opened either way is a visitor: the screen cannot close, or go
/// private, until the window closes.
pub const WA_PubScreenName = WA_Dummy + 0x15;
/// A public screen to open on, by pointer, which the caller holds locked.
pub const WA_PubScreen = WA_Dummy + 0x16;
/// Border gadgets: each draws its image in the border and sizes the border
/// for it. The size gadget and the drag bar size and move the window while
/// the pointer holds them; the depth gadget sends it to the back when it is
/// in front and to the front when it is not; the close gadget sends
/// IDCMP_CLOSEWINDOW.
pub const WA_SizeGadget = WA_Dummy + 0x1E;
pub const WA_DragBar = WA_Dummy + 0x1F;
pub const WA_DepthGadget = WA_Dummy + 0x20;
pub const WA_CloseGadget = WA_Dummy + 0x21;
/// At the back of its screen, behind every ordinary window, and staying
/// there.
pub const WA_Backdrop = WA_Dummy + 0x22;
/// Do not send IDCMP_REFRESHWINDOW: intuition.library throws the damage
/// away itself after putting the border back.
pub const WA_NoCareRefresh = WA_Dummy + 0x24;
/// No border at all.
pub const WA_Borderless = WA_Dummy + 0x25;
/// Become the active window when it opens.
pub const WA_Activate = WA_Dummy + 0x26;
/// The first of a list of gadgets, linked as AddGList links them, added and
/// drawn when the window opens.
pub const WA_Gadgets = WA_Dummy + 0x09;
/// What the screen's title bar says while this window is the active one.
/// Without it, the screen's own title.
pub const WA_ScreenTitle = WA_Dummy + 0x0C;
/// Keep nothing that is covered; say so with IDCMP_REFRESHWINDOW. The
/// default is smart refresh.
pub const WA_SimpleRefresh = WA_Dummy + 0x29;
pub const WA_SmartRefresh = WA_Dummy + 0x2A;
/// An image object a checked item of this window's menus shows, in place
/// of the screen's `MENUCHECK` (DrawInfo `check_mark`). The caller keeps it
/// and disposes of it after the window closes.
pub const WA_Checkmark = WA_Dummy + 0x0A;
/// An image object an item's shortcut shows before its character, in place
/// of the screen's `AMIGAKEY` (DrawInfo `amiga_key`). The caller keeps it.
pub const WA_AmigaKey = WA_Dummy + 0x31;
/// True: the Help key pressed while this window's menus are shown ends
/// them with IDCMP_MENUHELP, for the item under the pointer, in place of
/// IDCMP_MENUPICK.
pub const WA_MenuHelp = WA_Dummy + 0x2F;
/// True: this window's menus are drawn in the screen's bar pens. Every
/// window's are, so the tag changes nothing; `WFLG_NEWLOOKMENUS` reads it
/// back.
pub const WA_NewLookMenus = WA_Dummy + 0x30;
// --- what a window is ------------------------------------------------------
//
// The bits `WA_Flags` carries, and what `GetWindowAttrs` reports. Each has a
// tag of its own as well, which is the ordinary way to ask for it; the word
// is for a program that keeps its window's description in one place.

/// It has a gadget for sizing.
pub const WFLG_SIZEGADGET: u32 = 0x00000001;
/// It has a bar to drag it by.
pub const WFLG_DRAGBAR: u32 = 0x00000002;
/// It has a gadget for depth arranging.
pub const WFLG_DEPTHGADGET: u32 = 0x00000004;
/// It has a gadget for closing.
pub const WFLG_CLOSEGADGET: u32 = 0x00000008;
/// The sizing gadget takes room from the right border.
pub const WFLG_SIZEBRIGHT: u32 = 0x00000010;
/// It takes room from the bottom border.
pub const WFLG_SIZEBBOTTOM: u32 = 0x00000020;

/// Which of the refresh kinds a window is, as two bits.
pub const WFLG_REFRESHBITS: u32 = 0x000000C0;
/// Covered pixels are kept for it. The default, and so zero.
pub const WFLG_SMART_REFRESH: u32 = 0x00000000;
/// Nothing is kept; it is told to draw again with IDCMP_REFRESHWINDOW.
pub const WFLG_SIMPLE_REFRESH: u32 = 0x00000040;
/// It keeps its own bitmap, which may be larger than the window.
pub const WFLG_SUPER_BITMAP: u32 = 0x00000080;

/// It sits behind every ordinary window.
pub const WFLG_BACKDROP: u32 = 0x00000100;
/// It wants to hear the pointer move over it.
pub const WFLG_REPORTMOUSE: u32 = 0x00000200;
/// Its interior is a layer of its own, so the program's (0,0) is the corner
/// inside the border.
pub const WFLG_GIMMEZEROZERO: u32 = 0x00000400;
/// No border at all.
pub const WFLG_BORDERLESS: u32 = 0x00000800;
/// It is the active window as soon as it opens.
pub const WFLG_ACTIVATE: u32 = 0x00001000;
/// The right button belongs to the program.
pub const WFLG_RMBTRAP: u32 = 0x00010000;
/// It would rather not be told to draw itself again.
pub const WFLG_NOCAREREFRESH: u32 = 0x00020000;
/// Asked for with WA_NewLookMenus.
pub const WFLG_NEWLOOKMENUS: u32 = 0x00200000;

/// The bits a program may set. `WA_Flags` keeps these and ignores the rest,
/// which belong to intuition.library and say what a window is doing rather
/// than what it is.
pub const WFLG_SETTABLE: u32 = WFLG_SIZEGADGET | WFLG_DRAGBAR | WFLG_DEPTHGADGET |
    WFLG_CLOSEGADGET | WFLG_SIZEBRIGHT | WFLG_SIZEBBOTTOM | WFLG_REFRESHBITS |
    WFLG_BACKDROP | WFLG_REPORTMOUSE | WFLG_GIMMEZEROZERO | WFLG_BORDERLESS |
    WFLG_ACTIVATE | WFLG_RMBTRAP | WFLG_NOCAREREFRESH | WFLG_NEWLOOKMENUS;

/// For either title of `SetWindowTitles`: leave it as it is. Null clears a
/// title instead.
pub const TITLE_UNCHANGED: ?[*:0]const u8 = @ptrFromInt(~@as(usize, 0));

/// Set by intuition.library, never by a program: it is showing its zoomed
/// box rather than the one it was opened with.
pub const WFLG_ZOOMED: u32 = 0x10000000;
/// It has a zoom gadget.
pub const WFLG_HASZOOM: u32 = 0x20000000;
/// Set by intuition.library, never by a program: this is the active window.
pub const WFLG_WINDOWACTIVE: u32 = 0x00002000;
/// Its menus are shown.
pub const WFLG_MENUSTATE: u32 = 0x00008000;
/// A requester is up in it.
pub const WFLG_INREQUEST: u32 = 0x00004000;
/// It is drawing itself again, between BeginRefresh and EndRefresh.
pub const WFLG_WINDOWREFRESH: u32 = 0x01000000;
/// One tick at a time: another is sent when this one is replied.
pub const WFLG_WINDOWTICKED: u32 = 0x04000000;

/// Read only: its RastPort, whose (0,0) is the window's top-left.
/// How many IDCMP_MOUSEMOVE messages may be waiting unreplied at once.
/// Past that the moves are dropped until the program catches up: the next
/// one says where the pointer is anyway, and a program too slow to keep up
/// would otherwise have its port grow without bound.
pub const WA_MouseQueue = WA_Dummy + 0x1B;
/// The same for a key held down repeating, and for the interim updates a
/// gadget sends while it is being dragged.
pub const WA_RptQueue = WA_Dummy + 0x1D;

/// What a window's queues hold when nothing asks for more.
pub const DEFAULTMOUSEQUEUE: u32 = 5;
pub const DEFAULTRPTQUEUE: u32 = 3;

pub const WA_RastPort = WA_Dummy + 0x100;
/// Read only: its message port, or 0 without IDCMP.
pub const WA_UserPort = WA_Dummy + 0x101;
/// Read only: the screen it is on.
pub const WA_Screen = WA_Dummy + 0x102;
/// Read only: the border's widths - where the part a program draws in
/// starts and ends.
pub const WA_BorderLeft = WA_Dummy + 0x103;
pub const WA_BorderTop = WA_Dummy + 0x104;
pub const WA_BorderRight = WA_Dummy + 0x105;
pub const WA_BorderBottom = WA_Dummy + 0x106;
/// Read only: 1 while it is the active window.
pub const WA_Active = WA_Dummy + 0x107;
/// Read only: the layer it is.
pub const WA_Layer = WA_Dummy + 0x108;
/// Read only: what needs drawing again, between BeginRefresh and
/// EndRefresh - a graphics.library region in the window's coordinates, to
/// be read (RegionRectangles) and not kept or changed; 0 outside a refresh.
/// Drawing is cut to it anyway, so a program may draw everything; this is
/// for one that would rather skip what is not in it.
pub const WA_Damage = WA_Dummy + 0x109;

// --- IDCMP ------------------------------------------------------------------------
//
// The classes an IntuiMessage can be.

/// The user is about to size it - its size gadget pressed, its zoom gadget
/// used: the sizing waits for the reply, for three seconds at most, and
/// cannot be refused. IDCMP_NEWSIZE says when it is over.
pub const IDCMP_SIZEVERIFY: u32 = 0x0000_0001;
/// Its size changed - or, for a window with IDCMP_SIZEVERIFY, the sizing it
/// was warned of is over, whatever came of it.
pub const IDCMP_NEWSIZE: u32 = 0x0000_0002;
/// A simple-refresh window has a part to redraw: BeginRefresh, draw,
/// EndRefresh. At most one is waiting at a time.
pub const IDCMP_REFRESHWINDOW: u32 = 0x0000_0004;
/// A button went down or up: `code` SELECTDOWN or SELECTUP for the select
/// button inside the window; MENUDOWN and MENUUP for the menu button in a
/// window with WA_RMBTrap, and MENUUP in one without when its menus were
/// cancelled or given up before they showed; MIDDLEDOWN or MIDDLEUP for
/// the middle one. The menu and middle buttons go to the active window
/// wherever the pointer is. A window sent IDCMP_MENUVERIFY `MENUWAITING`
/// gets MENUUP when those menus are gone.
pub const IDCMP_MOUSEBUTTONS: u32 = 0x0000_0008;
/// The pointer moved with no button held on a border gadget or the bar.
pub const IDCMP_MOUSEMOVE: u32 = 0x0000_0010;
/// A GA_Immediate gadget was pressed: `iaddress` the gadget.
pub const IDCMP_GADGETDOWN: u32 = 0x0000_0020;
/// A GA_RelVerify gadget finished the way that counts - a button let go
/// over it: `iaddress` the gadget, `code` its termination value.
pub const IDCMP_GADGETUP: u32 = 0x0000_0040;
/// Its menus were used: `code` the menu number of the first item picked,
/// or `MENUNULL` for none, each item's `next_select` the next one's (see
/// `sdk.intuition.menus`).
pub const IDCMP_MENUPICK: u32 = 0x0000_0100;
/// Menus are about to be shown: `code` `MENUHOT` when they are this
/// window's, which it may stop by replying with `code` set to
/// `MENUCANCEL`; `MENUWAITING` when they are another window's on the same
/// screen. They wait for the reply, for three seconds at most.
pub const IDCMP_MENUVERIFY: u32 = 0x0000_2000;
/// The Help key ended a session of this window's menus, with WA_MenuHelp:
/// `code` the menu number under the pointer - which may be a title, an item
/// with subitems, a disabled one or `MENUNULL`. Nothing was picked.
pub const IDCMP_MENUHELP: u32 = 0x0100_0000;
/// The close gadget was pressed and let go over it. The window is not
/// closed: that is the program's to do.
pub const IDCMP_CLOSEWINDOW: u32 = 0x0000_0200;
/// A key went down or up: `code` the rawkey (with IECODE_UP_PREFIX),
/// `qualifier` the qualifiers.
pub const IDCMP_RAWKEY: u32 = 0x0000_0400;
/// It became the active window.
pub const IDCMP_ACTIVEWINDOW: u32 = 0x0004_0000;
/// It stopped being the active window.
pub const IDCMP_INACTIVEWINDOW: u32 = 0x0008_0000;
/// Pointer movement as how far it went rather than where it is. Not sent
/// yet: a pointer that moves relatively, a mouse, is what would want it.
pub const IDCMP_DELTAMOVE: u32 = 0x0010_0000;
/// Ten times a second while the window is active; no second is sent until
/// the first is replied.
pub const IDCMP_INTUITICKS: u32 = 0x0040_0000;
/// A key that makes one character through the default keymap, as that
/// character (Latin-1) in `code`; a key that makes none or several - a
/// cursor key, a key going up - still comes as IDCMP_RAWKEY when that is
/// asked for.
pub const IDCMP_VANILLAKEY: u32 = 0x0020_0000;
/// A gadget with ICA_TARGET ICTARGET_IDCMP told the window what changed:
/// `iaddress` a tag list of the changed attributes, mapped through the
/// gadget's ICA_MAP, which is the message's and goes with its reply;
/// `code` the data of an `ICSPECIAL_CODE` in that list, or 0 without one.
pub const IDCMP_IDCMPUPDATE: u32 = 0x0080_0000;
/// It was moved or sized.
pub const IDCMP_CHANGEWINDOW: u32 = 0x0200_0000;
/// A requester went up in it (`Request`, or a double-click of the menu
/// button): `iaddress` the requester.
pub const IDCMP_REQSET: u32 = 0x0000_0080;
/// Its double-click requester is about to go up. Replying lets it; the
/// reply is waited for, for three seconds at most, and it cannot be
/// refused.
pub const IDCMP_REQVERIFY: u32 = 0x0000_0800;
/// A requester in it came down: `iaddress` the requester.
pub const IDCMP_REQCLEAR: u32 = 0x0000_1000;

/// IDCMP_MOUSEBUTTONS' codes: the select button, down and let go.
pub const SELECTDOWN: u32 = 0x68;
pub const SELECTUP: u32 = 0xE8;
/// The menu button - a mouse's right one - down and let go.
pub const MENUDOWN: u32 = 0x69;
pub const MENUUP: u32 = 0xE9;
/// The middle button, down and let go.
pub const MIDDLEDOWN: u32 = 0x6A;
pub const MIDDLEUP: u32 = 0xEA;

/// One thing that happened to a window.
pub const IntuiMessage = extern struct {
    /// Hand it back with ReplyMsg.
    msg: exec.Message = .{},
    /// Class: one `IDCMP_` bit.
    class: u32 = 0,
    /// Code: more about it, as the class says.
    code: u32 = 0,
    /// Qualifier: the keys and buttons held, as input.device had them.
    qualifier: u32 = 0,
    /// IAddress: what it is about, as the class says.
    iaddress: ?*anyopaque = null,
    /// Where the pointer was, in the window's coordinates.
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    /// When: the time of the input event that led to it, 0 before any.
    seconds: u32 = 0,
    micros: u32 = 0,
    /// IDCMPWindow: which window.
    window: ?*Window = null,
};
