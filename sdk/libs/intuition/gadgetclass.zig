// SPDX-License-Identifier: MIT
//! Gadgets: objects in a window that the pointer can press.
//!
//! A gadget is an object of gadgetclass or a class made from it. It has a
//! box in its window - `GA_Left`, `GA_Top`, `GA_Width`, `GA_Height`, or
//! the `GA_Rel` forms measured from the window's right and bottom edges -
//! and intuition.library drives it with the `GM_` methods:
//!
//!   - `GM_HITTEST`: is this point, relative to the box, the gadget's?
//!   - `GM_GOACTIVE`: the pointer pressed it. `GMR_MEACTIVE` asks for the
//!     input that follows; anything else ends it there.
//!   - `GM_HANDLEINPUT`: each event while it is active - the pointer's
//!     moves and release, keys, the tick - until it answers something other
//!     than `GMR_MEACTIVE`.
//!   - `GM_GOINACTIVE`: it is no longer active, because it said so or
//!     because it was taken away (`abort`).
//!   - `GM_RENDER`: draw yourself.
//!
//! What a gadget did reaches the program as `IDCMP_GADGETDOWN` (pressed,
//! with `GA_Immediate`) and `IDCMP_GADGETUP` (finished with `GMR_VERIFY`,
//! with `GA_RelVerify`). Both carry the gadget in `iaddress`, read with
//! `GetAttr(GA_ID, ...)`, and the gadget's termination value in `code`. A
//! gadget with `ICA_TARGET` also tells its target what changed, mapped
//! through `ICA_MAP`; `ICTARGET_IDCMP` makes that an `IDCMP_IDCMPUPDATE`.
//!
//! A class that draws gets its RastPort for a moment with `ObtainGIRPort`
//! and gives it back with `ReleaseGIRPort`, in the middle of which it holds
//! the window's layer.

const graphics = @import("../graphics/graphics.zig");
const utility = @import("../utility/utility.zig");
const classusr = @import("classusr.zig");
const ie = @import("../../devices/inputevent.zig");
const MethodID = classusr.MethodID;
const GadgetInfo = classusr.GadgetInfo;

// --- attributes -------------------------------------------------------------

pub const GA_Dummy = utility.TAG_USER + 0x30000;
/// Where the box is in its window, border included.
pub const GA_Left = GA_Dummy + 0x01;
/// Left, measured from the window's right edge: the box's left is the
/// window's width - 1 + this, so a negative value is inside the window.
pub const GA_RelRight = GA_Dummy + 0x02;
pub const GA_Top = GA_Dummy + 0x03;
/// Top, measured from the window's bottom edge, as GA_RelRight.
pub const GA_RelBottom = GA_Dummy + 0x04;
pub const GA_Width = GA_Dummy + 0x05;
/// Width, as the window's width plus this.
pub const GA_RelWidth = GA_Dummy + 0x06;
pub const GA_Height = GA_Dummy + 0x07;
/// Height, as the window's height plus this.
pub const GA_RelHeight = GA_Dummy + 0x08;
/// A label: a C string, not copied.
pub const GA_Text = GA_Dummy + 0x09;
/// An image object that is the gadget's look.
pub const GA_Image = GA_Dummy + 0x0A;
/// Not to be pressed: drawn as such, and GM_GOACTIVE is never sent.
pub const GA_Disabled = GA_Dummy + 0x0E;
/// A number the program chooses, to tell its gadgets apart.
pub const GA_ID = GA_Dummy + 0x10;
/// Whatever the program wants to keep with the gadget.
pub const GA_UserData = GA_Dummy + 0x11;
/// Drawn pressed.
pub const GA_Selected = GA_Dummy + 0x13;
/// Send IDCMP_GADGETDOWN when pressed.
pub const GA_Immediate = GA_Dummy + 0x15;
/// Send IDCMP_GADGETUP when it finishes and says so (GMR_VERIFY): for a
/// button, let go over it.
pub const GA_RelVerify = GA_Dummy + 0x16;
/// The gadget this one follows in a list: made with this, the new gadget is
/// linked in after it. A list made this way is what AddGList and WA_Gadgets
/// take.
pub const GA_Previous = GA_Dummy + 0x1F;
/// True: a press turns the gadget on or off and leaves it that way, rather
/// than selecting it only while the button is held. A box that is ticked or
/// not is this; a button that does something is not.
pub const GA_ToggleSelect = GA_Dummy + 0x1C;
/// Bool: in a requester, finishing the way that counts - a button let go
/// over it - also ends the requester, after the window has its
/// IDCMP_GADGETUP.
pub const GA_EndGadget = GA_Dummy + 0x14;
/// True: this gadget belongs to the border of a GimmeZeroZero window rather
/// than to the part inside it. It means nothing to any other window, whose
/// border and interior are one layer.
pub const GA_GZZGadget = GA_Dummy + 0x0F;
/// True: the gadget lives in that border of its window - a scroller down
/// the right edge, a row of buttons along the bottom. The border is made
/// wide enough to hold it when the window opens with it (`WA_Gadgets`),
/// it is drawn with the border each time the border is, and in a
/// GimmeZeroZero window it belongs to the border, as `GA_GZZGadget`.
/// A right or bottom one is placed with `GA_RelRight` / `GA_RelBottom`
/// so it stays at that edge as the window is sized.
pub const GA_RightBorder = GA_Dummy + 0x18;
pub const GA_LeftBorder = GA_Dummy + 0x19;
pub const GA_TopBorder = GA_Dummy + 0x1A;
pub const GA_BottomBorder = GA_Dummy + 0x1B;
/// Whether Tab moves the keyboard from one gadget to the next. A line of
/// text answers Tab with `GMR_NEXTACTIVE`, and the next gadget of the
/// window that has this set takes over.
pub const GA_TabCycle = GA_Dummy + 0x24;
/// The pens to draw with, for a class that wants them when it is made.
pub const GA_DrawInfo = GA_Dummy + 0x21;

// --- methods ----------------------------------------------------------------

/// `GpHitTest`; answer GMR_GADGETHIT if the point is the gadget's.
pub const GM_HITTEST: MethodID = 0;
/// `GpRender`: draw.
pub const GM_RENDER: MethodID = 1;
/// `GpInput`: pressed. Answer GMR_MEACTIVE for more input.
pub const GM_GOACTIVE: MethodID = 2;
/// `GpInput`: one event while active.
pub const GM_HANDLEINPUT: MethodID = 3;
/// `GpGoInactive`: no longer active.
pub const GM_GOINACTIVE: MethodID = 4;
/// `GpLayout`: work out where you are again, because the room you are
/// measured against has changed - the window was opened with you in it, or
/// it has just been resized.
pub const GM_LAYOUT: MethodID = 6;
/// `GpHitTest`: is this point one you have something to say about? Answered
/// while the pointer rests over a window whose program asked to be told.
pub const GM_HELPTEST: MethodID = 5;

/// GM_HELPTEST: nothing here worth saying anything about.
pub const GMR_NOHELPHIT: usize = 0;
/// GM_HELPTEST: this point is the gadget's, and the message says so with a
/// code of all ones.
pub const GMR_HELPHIT: usize = 0xFFFFFFFF;
/// GM_HELPTEST, or'd with a code of the gadget's own choosing in the low
/// sixteen bits, for a gadget with more than one part to talk about.
pub const GMR_HELPCODE: usize = 0x00010000;

/// GM_HITTEST: `mouse` is relative to the gadget's box.
pub const GpHitTest = extern struct {
    method_id: MethodID = GM_HITTEST,
    gadget_info: ?*GadgetInfo,
    mouse: graphics.Point,
};

/// GM_HITTEST's answer for a hit.
pub const GMR_GADGETHIT: usize = 0x04;

/// GM_RENDER.
pub const GpRender = extern struct {
    method_id: MethodID = GM_RENDER,
    gadget_info: ?*GadgetInfo,
    /// Obtained with ObtainGIRPort by whoever sends the message.
    rast_port: *graphics.RastPort,
    /// GREDRAW_: the whole of it, or only what changed.
    redraw: u32,
};

/// Draw all of it.
pub const GREDRAW_REDRAW: u32 = 1;
/// Draw what changed, such as the pressed state.
pub const GREDRAW_UPDATE: u32 = 2;

/// GM_GOACTIVE and GM_HANDLEINPUT.
pub const GpInput = extern struct {
    method_id: MethodID,
    gadget_info: ?*GadgetInfo,
    /// The event: the press for GM_GOACTIVE, then each one after.
    event: ?*const ie.InputEvent,
    /// Set with GMR_VERIFY: it becomes IDCMP_GADGETUP's code.
    termination: *i32,
    /// Where the pointer is, relative to the gadget's box.
    mouse: graphics.Point,
};

/// Keep sending input.
pub const GMR_MEACTIVE: usize = 0;
/// Done, and the event is used up.
pub const GMR_NOREUSE: usize = 1 << 1;
/// Done, and the event is to be handled as though no gadget had been
/// active - a press elsewhere that ended it, say.
pub const GMR_REUSE: usize = 1 << 2;
/// Done, and it finished the way that counts: IDCMP_GADGETUP for a
/// GA_RelVerify gadget.
pub const GMR_VERIFY: usize = 1 << 3;
/// Done, and the gadget after this one in the window's list that takes the
/// keyboard should have it - what Tab does in a line of text. Answered
/// instead of `GMR_NOREUSE` or `GMR_REUSE`, not as well.
pub const GMR_NEXTACTIVE: usize = 1 << 4;
/// The same, backwards: shifted Tab.
pub const GMR_PREVACTIVE: usize = 1 << 5;

/// GM_LAYOUT: the room this gadget is measured against has changed.
pub const GpLayout = extern struct {
    method_id: MethodID = GM_LAYOUT,
    gadget_info: ?*classusr.GadgetInfo = null,
    /// Nonzero when the window was opened with this gadget in it or it has
    /// just been added; zero when the window was resized under it.
    initial: u32 = 0,
};

/// GM_GOINACTIVE.
pub const GpGoInactive = extern struct {
    method_id: MethodID = GM_GOINACTIVE,
    gadget_info: ?*GadgetInfo,
    /// 1 when intuition took it away - the window closed, the gadget was
    /// removed - and 0 when it said it was done.
    abort: u32,
};

// --- strgclass: a line of text a person types ---------------------------------

pub const STRINGA_Dummy = utility.TAG_USER + 0x32000;
/// How much room the buffer has, the terminating NUL counted. A gadget
/// made with this and no buffer takes one of its own and gives it back.
pub const STRINGA_MaxChars = STRINGA_Dummy + 0x01;
/// The buffer itself, the caller's: what it holds is what the gadget
/// starts with, and what it holds afterwards is what was typed.
pub const STRINGA_Buffer = STRINGA_Dummy + 0x02;
/// Room to keep what the text was when it was activated, so that Escape
/// puts it back. One of its own if the gadget made its buffer.
pub const STRINGA_UndoBuffer = STRINGA_Dummy + 0x03;
/// Where the cursor is, counted in characters.
pub const STRINGA_BufferPos = STRINGA_Dummy + 0x05;
/// Which character is the first one shown, for a line longer than the box.
pub const STRINGA_DispPos = STRINGA_Dummy + 0x06;
/// The keymap the keys are read through. Null is the default one.
pub const STRINGA_AltKeyMap = STRINGA_Dummy + 0x07;
/// The font the text is drawn in. Not read yet: the text is drawn in the
/// RastPort's own.
pub const STRINGA_Font = STRINGA_Dummy + 0x08;
/// Two pens - the text's and the ground's - as a `[*]const graphics.Pen`,
/// drawn in while the gadget is not being typed into. A pen here is a
/// whole 0xAARRGGBB colour, so two do not fit in one value as two pen
/// numbers once did: the value is where they are.
pub const STRINGA_Pens = STRINGA_Dummy + 0x09;
/// The same two while it is being typed into; without them, `STRINGA_Pens`.
pub const STRINGA_ActivePens = STRINGA_Dummy + 0x0A;
/// True types over what is there rather than pushing it along.
pub const STRINGA_ReplaceMode = STRINGA_Dummy + 0x0D;
/// Where the text sits in its box: `GACT_STRINGLEFT`, `GACT_STRINGCENTER`
/// or `GACT_STRINGRIGHT`.
pub const STRINGA_Justification = STRINGA_Dummy + 0x10;
/// The text read as a number, for a gadget that holds one.
pub const STRINGA_LongVal = STRINGA_Dummy + 0x11;
/// The text itself, as a C string: what a program reads when the gadget
/// says it has finished.
pub const STRINGA_TextVal = STRINGA_Dummy + 0x12;

/// The text against the left edge of the box, the middle, or the right.
pub const GACT_STRINGLEFT: u32 = 0x0000;
pub const GACT_STRINGCENTER: u32 = 0x0200;
pub const GACT_STRINGRIGHT: u32 = 0x0400;

/// How much room a string gadget takes when it is told none.
pub const SG_DEFAULTMAXCHARS: u32 = 128;
