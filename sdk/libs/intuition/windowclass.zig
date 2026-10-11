// SPDX-License-Identifier: MIT
//! windowclass: a window described rather than built.
//!
//! An object of windowclass holds what a window is to be - its `WA_` tags
//! and a layout of gadgets (`WINDOWA_Layout`) - and opens and closes the
//! window on request. Nothing in it is placed by hand: the layout fills the
//! window's interior, the window opens at the layout's nominal size unless
//! told otherwise, can be sized no smaller than the layout fits in, and
//! opens in the middle of its screen unless told where (`WA_Left`,
//! `WA_Top`, or `WA_Position`).
//!
//! `WM_OPEN` opens it, `WM_CLOSE` closes it and keeps the object to open
//! again, `DisposeObject` closes it and disposes of the layout and every
//! gadget in it. `WM_HANDLEINPUT` takes the window's next message, replies
//! to it, and answers what it was in one word: the class in the upper
//! half (`WMHI_*`), the gadget's `GA_ID`, the menu number or the key in
//! the lower - `WMHI_LASTMSG` when there is nothing more. A message of a
//! class it has no word for is replied and passed over.
//!
//! The window listens for `IDCMP_CLOSEWINDOW`, `IDCMP_GADGETUP`,
//! `IDCMP_GADGETDOWN`, `IDCMP_MENUPICK` and `IDCMP_VANILLAKEY` whatever it
//! is told; `WA_IDCMP` adds to them - `IDCMP_RAWKEY`, `IDCMP_NEWSIZE`,
//! `IDCMP_ACTIVEWINDOW`, `IDCMP_INACTIVEWINDOW`, `IDCMP_DISKINSERTED` and
//! `IDCMP_DISKREMOVED` have words of their own.
//!
//! A character typed is offered to the layout first: the gadget whose
//! `GA_Key` it is - the letter underlined in its label - is worked as a
//! press would work it, and what it did comes back as `WMHI_GADGETUP`
//! with that gadget's `GA_ID` and its code. A gadget that only takes the
//! keyboard, a line of text, is activated and nothing is reported. Only a
//! character no gadget answers to is handed on as `WMHI_VANILLAKEY`.
//!
//! What the word leaves out of a message is read from the object after
//! it: the keys held with it (`WINDOWA_Qualifier`) - so a program tells a
//! Shift-click or Shift and a cursor key from the plain one - and which
//! gadget it came from (`WINDOWA_GadgetID`), which is the one way to tell
//! apart the `WMHI_IDCMPUPDATE`s of several gadgets that tell the window.
//!
//! A window that scrolls what it shows asks for scroll bars in its borders
//! (`WINDOWA_VertScroller`, `WINDOWA_HorizScroller`): each is a
//! scroller.gadget made with the program's tags - its `GA_ID`, its target
//! and map, its numbers - and placed by the object, down the right border
//! or along the bottom one, from the window's edge to the sizing gadget in
//! the corner, its arrows sized to the border. The object makes them
//! when the window first opens, puts them back at every open, keeps the
//! window from being made smaller than their arrows, and disposes of them
//! with itself. The program reads a bar to set its numbers.
//!
//! ```zig
//! const win = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &.{
//!     .{ .tag = wn.WA_Title, .data = @intFromPtr("Hello") },
//!     .{ .tag = wn.WA_CloseGadget, .data = 1 },
//!     .{ .tag = wn.WA_DragBar, .data = 1 },
//!     .{ .tag = wn.WA_SizeGadget, .data = 1 },
//!     .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
//!     .{},
//! }) orelse return;
//! defer ib.DisposeObject(win);
//! var open = wc.WmOpen{};
//! const opened = ib.SendMessage(win, @ptrCast(&open));
//! if (opened == 0) return; // no window
//! const window: *intuition.Window = @ptrFromInt(opened);
//! while (true) {
//!     _ = ib.WaitIMsg(window, 0);
//!     var code: u32 = 0;
//!     var handle = wc.WmHandleInput{ .code = &code };
//!     while (true) {
//!         const got = ib.SendMessage(win, @ptrCast(&handle));
//!         if (got == wc.WMHI_LASTMSG) break;
//!         switch (got & wc.WMHI_CLASSMASK) {
//!             wc.WMHI_CLOSEWINDOW => return,
//!             wc.WMHI_GADGETUP => pressed(got & wc.WMHI_GADGETMASK),
//!             else => {},
//!         }
//!     }
//! }
//! ```

const utility = @import("../utility/utility.zig");
const MethodID = @import("classusr.zig").MethodID;

/// The name to make one by, or to subclass.
pub const WINDOWCLASS = "windowclass";

pub const WINDOWA_Dummy = utility.TAG_USER + 0x39000;
/// The layout of gadgets that fills the window: a `layoutgclass` object,
/// the window object's from then on. Made only.
pub const WINDOWA_Layout = WINDOWA_Dummy + 0x01;
/// Read only: the window while it is open, 0 while it is not.
pub const WINDOWA_Window = WINDOWA_Dummy + 0x02;
/// Read only: the signal the window's messages arrive on, as a mask for
/// `Wait` - 0 while it is not open. For a program waiting on several
/// windows, or on a window and something else.
pub const WINDOWA_SigMask = WINDOWA_Dummy + 0x03;
/// Read only: the qualifier of the message `WM_HANDLEINPUT` answered last
/// - the Shift, Control, Alt and Amiga keys and the mouse buttons held
/// with it (`inputevent.IEQUALIFIER_*`). An update a gadget tells while it
/// is still being worked, an interim `WMHI_IDCMPUPDATE`, carries
/// `IEQUALIFIER_REPEAT`; the one it tells as it finishes does not.
pub const WINDOWA_Qualifier = WINDOWA_Dummy + 0x04;
/// Read only: the `GA_ID` of the gadget the message `WM_HANDLEINPUT`
/// answered last came from - pressed or let go, worked by its key, or for
/// `WMHI_IDCMPUPDATE` the `GA_ID` in what it told - or `WINDOW_NOGADGET`
/// for a message no gadget sent.
pub const WINDOWA_GadgetID = WINDOWA_Dummy + 0x05;
/// A scroll bar down the right border (`WINDOWA_VertScroller`) or along
/// the bottom one (`WINDOWA_HorizScroller`). Made with: the tags the bar
/// is made with besides its place, size, freedom and arrows, which are the
/// object's - a `GA_ID`, `ICA_TARGET` and `ICA_MAP`, `SCROLLER_Total`,
/// `SCROLLER_Visible`, `SCROLLER_Top`; copied, so the list may go, though
/// what it points to may not. Null asks for a bar with none. The window
/// then has a sizing gadget with its room in that border
/// (`WA_SizeGadget`, `WA_SizeBRight`, `WA_SizeBBottom`), which is what
/// makes the border deep enough for a bar. Read: the bar, from the first
/// `WM_OPEN` on - 0 before, or when scroller.gadget could not be opened.
pub const WINDOWA_VertScroller = WINDOWA_Dummy + 0x06;
pub const WINDOWA_HorizScroller = WINDOWA_Dummy + 0x07;

/// What `WINDOWA_GadgetID` reads for a message that came from no gadget.
pub const WINDOW_NOGADGET: usize = ~@as(usize, 0);

// --- methods ----------------------------------------------------------------

pub const WM_Dummy: MethodID = 0x0700;
/// `WmHandleInput`: the next message, answered as a `WMHI_` word.
pub const WM_HANDLEINPUT: MethodID = 0x0701;
/// `WmOpen`: open the window; the answer is the `*Window`, or 0. Already
/// open, it answers the window it has.
pub const WM_OPEN: MethodID = 0x0702;
/// `WmClose`: close the window, keep the object. The answer is 1, or 0
/// when it was not open.
pub const WM_CLOSE: MethodID = 0x0703;

pub const WmOpen = extern struct {
    method_id: MethodID = WM_OPEN,
};

pub const WmClose = extern struct {
    method_id: MethodID = WM_CLOSE,
};

pub const WmHandleInput = extern struct {
    method_id: MethodID = WM_HANDLEINPUT,
    /// Where the message's `code` goes: a gadget's termination - what a
    /// slider or a line of text finished with - the menu number, the key.
    /// May be null.
    code: ?*u32 = null,
};

// --- WM_HANDLEINPUT's answer ----------------------------------------------------

/// Nothing more waiting.
pub const WMHI_LASTMSG: usize = 0;
pub const WMHI_CLASSMASK: usize = 0xFFFF_0000;
/// The gadget's `GA_ID`, for `WMHI_GADGETUP` and `WMHI_GADGETDOWN`.
pub const WMHI_GADGETMASK: usize = 0x0000_FFFF;
/// The menu number, for `WMHI_MENUPICK`; the key, for the key classes.
pub const WMHI_MENUMASK: usize = 0x0000_FFFF;
pub const WMHI_KEYMASK: usize = 0x0000_FFFF;

pub const WMHI_CLOSEWINDOW: usize = 1 << 16;
pub const WMHI_GADGETUP: usize = 2 << 16;
pub const WMHI_GADGETDOWN: usize = 3 << 16;
pub const WMHI_MENUPICK: usize = 4 << 16;
pub const WMHI_VANILLAKEY: usize = 5 << 16;
pub const WMHI_RAWKEY: usize = 6 << 16;
pub const WMHI_NEWSIZE: usize = 7 << 16;
pub const WMHI_ACTIVE: usize = 8 << 16;
pub const WMHI_INACTIVE: usize = 9 << 16;
/// A medium was put into a drive, or taken out of one. Neither says
/// which drive: a window that shows what is mounted looks at the device
/// list again.
pub const WMHI_DISKINSERTED: usize = 10 << 16;
pub const WMHI_DISKREMOVED: usize = 11 << 16;
/// The settings changed (`SetPrefs`): a window that draws something they
/// decide reads them again.
pub const WMHI_NEWPREFS: usize = 12 << 16;
/// A gadget whose `ICA_TARGET` is `ICTARGET_IDCMP` told the window that
/// something about it changed. The low bits are what `ICSPECIAL_CODE`
/// carried, and the attributes themselves are read from the gadget.
pub const WMHI_IDCMPUPDATE: usize = 13 << 16;
/// The wheel turned over the window and no gadget took it (the window
/// asked for `IDCMP_MOUSEWHEEL`). The low bits are the notches down, up
/// negative, as an i16's bits; the message's whole code - both directions,
/// `windows.wheelDown` and `wheelAcross` - goes where `code` points.
pub const WMHI_MOUSEWHEEL: usize = 14 << 16;
