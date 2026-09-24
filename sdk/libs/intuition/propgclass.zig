// SPDX-License-Identifier: MIT
//! propgclass: a slider, and what a program says to one.
//!
//! A proportional gadget is a container with a knob in it. How big the knob
//! is says how much of a thing is in view, and where it sits says which
//! part. It is what a window's scroll bars are, and what a value picked
//! from a range is.
//!
//! There are two ways to say where it stands, and they are kept in step
//! with each other:
//!
//!   - **In things**: `PGA_Total` how many there are, `PGA_Visible` how
//!     many fit, `PGA_Top` which is the first in view. A program scrolling
//!     text counts lines, not fractions, so this is the one to use.
//!   - **As fractions**: `PGA_HorizPot` and `PGA_VertPot` where the knob
//!     is, `PGA_HorizBody` and `PGA_VertBody` how big it is, each a
//!     sixteen-bit fraction of `MAXPOT` / `MAXBODY`.
//!
//! Set either and the other follows. A gadget that is dragged tells its
//! target the new `PGA_Top` as it moves and once more when it is let go,
//! so a program hears it through `ICA_TARGET` - `ICTARGET_IDCMP` for
//! `IDCMP_IDCMPUPDATE` - without watching the pointer itself.

const utility = @import("../utility/utility.zig");

/// The name to make one by, or to subclass.
pub const PROPGCLASS = "propgclass";

pub const PGA_Dummy = utility.TAG_USER + 0x31000;

/// Which way the knob may move: `FREEHORIZ`, `FREEVERT`, or both.
pub const PGA_Freedom = PGA_Dummy + 0x01;
/// True draws no frame round the container, for a slider that sits in
/// something already framed.
pub const PGA_Borderless = PGA_Dummy + 0x02;
/// Where the knob is across the container, 0 to `MAXPOT`.
pub const PGA_HorizPot = PGA_Dummy + 0x03;
/// How wide the knob is, 0 to `MAXBODY`; also how far a click beside it
/// moves the knob.
pub const PGA_HorizBody = PGA_Dummy + 0x04;
/// Where the knob is down the container, 0 to `MAXPOT`.
pub const PGA_VertPot = PGA_Dummy + 0x05;
/// How tall the knob is, 0 to `MAXBODY`.
pub const PGA_VertBody = PGA_Dummy + 0x06;
/// How many things there are altogether.
pub const PGA_Total = PGA_Dummy + 0x07;
/// How many of them are in view at once.
pub const PGA_Visible = PGA_Dummy + 0x08;
/// Which of them is the first in view. This is what a drag changes and
/// what a target is told.
pub const PGA_Top = PGA_Dummy + 0x09;
/// True draws the knob with a lit and a shadowed edge rather than flat.
pub const PGA_NewLook = PGA_Dummy + 0x0A;

/// The knob's size is worked out from the body rather than given as an
/// image. This is how every slider here is drawn; the flag is kept because
/// the flags word is read back.
pub const AUTOKNOB: u16 = 0x0001;
/// The knob may move across.
pub const FREEHORIZ: u16 = 0x0002;
/// The knob may move down.
pub const FREEVERT: u16 = 0x0004;
/// No frame round the container.
pub const PROPBORDERLESS: u16 = 0x0008;
/// The knob has a lit and a shadowed edge.
pub const PROPNEWLOOK: u16 = 0x0010;
/// Set while the knob itself is being dragged.
pub const KNOBHIT: u16 = 0x0100;

/// A knob is never thinner than this, however little of a thing is in
/// view: one too small to see is one too small to catch.
pub const KNOBHMIN: i32 = 6;
pub const KNOBVMIN: i32 = 4;

/// The whole of a body, and the far end of a pot.
pub const MAXBODY: u32 = 0xFFFF;
pub const MAXPOT: u32 = 0xFFFF;

/// What a slider stands at, in things rather than fractions: how big the
/// knob is and where it sits.
///
/// `hidden` is what cannot be seen at once. With nothing hidden the knob
/// fills the container and does not move.
///
/// The body is measured with **one thing of overlap** when more than one is
/// in view, so that a click beside the knob leaves a thing of the old view
/// in the new one. A view of a single thing has no overlap to leave - it
/// would measure the knob as nothing, and a knob of no size cannot be paged
/// by - so a slider whose view is one thing is measured whole.
pub fn valuesOf(total: u32, visible: u32, top: u32) struct { body: u32, pot: u32, top: u32 } {
    const hidden = total -| visible;
    const at = @min(top, hidden);
    const overlap: u32 = if (visible > 1) 1 else 0;
    // hidden > 0 makes total > visible >= overlap, so the divisor stands.
    const body = if (hidden > 0)
        @min(MAXBODY, (@as(u64, visible - overlap) * MAXBODY) / (total - overlap))
    else
        MAXBODY;
    const pot = if (hidden > 0) @min(MAXPOT, (@as(u64, at) * MAXPOT) / hidden) else 0;
    return .{ .body = @intCast(body), .pot = @intCast(pot), .top = at };
}

/// Which thing is first in view, for a knob that stands at `pot`: the
/// fraction of what is hidden that is above the view, rounded to the
/// nearest thing. A knob at the far end names the last thing that can be
/// first, which is why this divides by `MAXPOT` and not by the next power
/// of two.
pub fn topOf(total: u32, visible: u32, pot: u32) u32 {
    const hidden = total -| visible;
    return @intCast((@as(u64, hidden) * pot + MAXPOT / 2) / MAXPOT);
}
