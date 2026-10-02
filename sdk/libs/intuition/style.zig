// SPDX-License-Identifier: MIT
//! Styles: the look of the pieces of a gadget, given as data.
//!
//! A style is a tag list. `STYLE_Part` and `STYLE_State` say which entry
//! the tags after them belong to - which piece of a gadget, in which
//! condition - and every other `STYLE_` tag is a property of that entry:
//! its background, its border, its corners, its text, the room inside it.
//!
//! ```zig
//! const flat = [_]TagItem{
//!     .{ .tag = STYLE_Part, .data = PART_MAIN },
//!     .{ .tag = STYLE_State, .data = STATE_NORMAL },
//!     .{ .tag = STYLE_Border, .data = BORDER_FLAT },
//!     .{ .tag = STYLE_BorderPen, .data = screens.SHADOWPEN },
//!     .{ .tag = STYLE_Radius, .data = 6 },
//!     .{ .tag = STYLE_State, .data = STATE_PRESSED },
//!     .{ .tag = STYLE_BackgroundRGB, .data = 0xFF2A5D8F },
//!     .{},
//! };
//! ```
//!
//! **Where a style is given.** A screen takes one when it is opened
//! (`SA_Style`), and a gadget may carry one of its own (`GA_Style`) that
//! says only what differs. intuition reads a list once, when it is given,
//! and keeps what it read; the caller's list may go away afterwards, and
//! drawing never walks a tag list.
//!
//! **Which value is used.** Within one list the first value met for a
//! part, a state and a property wins, `TAG_MORE` included - so a list
//! overrides whatever it chains to. Across lists, for one property:
//!
//! 1. the most particular state first: the exact combination of states
//!    when the list names it, then each state by the order disabled,
//!    pressed, checked, focused, hovered, and normal last;
//! 2. for each state, the gadget's own style, then its screen's, then the
//!    system's default;
//! 3. within each, the exact part, then the one it falls back to.
//!
//! So a list that says only what a normal button looks like leaves a
//! pressed one to the default's pressed look, and one that names
//! `PART_TRACK` styles every track, a class's own included.
//!
//! **A pen or a colour.** Every property that is a colour has two tags: the
//! one ending in `Pen` takes a screen pen index (`screens.SHINEPEN` and its
//! like), so a style written in pens follows its screen's colours; the one
//! ending in `RGB` takes a colour of its own, 0xAARRGGBB.
//!
//! **A tag that is not known is passed over**, so a style written for a
//! newer system still works on an older one, and a new property is only
//! ever a new tag.

const utility = @import("../utility/utility.zig");

/// A style as intuition keeps it once given: what `DrawPart` and
/// `GetStyleAttr` read. Only intuition knows what is in it.
pub const Style = opaque {};

// --- parts ------------------------------------------------------------------

/// A gadget's body and its border: a button, a field, a list's box, a
/// check box's box.
pub const PART_MAIN: u32 = 0;
/// A framed group's border, and the title in its edge.
pub const PART_GROUP: u32 = 1;
/// What shows a value: a bar's level, a check mark, a radio's dot, a
/// gauge's arc.
pub const PART_INDICATOR: u32 = 2;
/// What is dragged: a slider's knob, a scroller's.
pub const PART_KNOB: u32 = 3;
/// What a knob or a level runs in.
pub const PART_TRACK: u32 = 4;
/// What is chosen: a list's line, the chosen tab, marked text.
pub const PART_SELECTION: u32 = 5;
/// A window's title bar and its gadgets, a screen's bar, a menu's bar.
pub const PART_TITLE: u32 = 6;

/// The part a class's own part falls back to is its low byte.
pub const PART_BASE_MASK: u32 = 0xFF;

/// A part of a class's own, which a style may name exactly and which
/// otherwise looks like `base`. `n` from 1, numbered by the class.
pub inline fn classPart(base: u32, n: u32) u32 {
    return (base & PART_BASE_MASK) | n << 8;
}

// --- states -----------------------------------------------------------------

/// None of the other states.
pub const STATE_NORMAL: u32 = 0;
/// The pointer is over it and nothing is pressed.
pub const STATE_HOVERED: u32 = 1 << 0;
/// It is being pushed.
pub const STATE_PRESSED: u32 = 1 << 1;
/// It is on: a ticked box, the chosen tab, a toggle that is down.
pub const STATE_CHECKED: u32 = 1 << 2;
/// The keyboard goes to it.
pub const STATE_FOCUSED: u32 = 1 << 3;
/// It cannot be used.
pub const STATE_DISABLED: u32 = 1 << 4;

/// The single states in the order the most particular wins, when a style
/// names no entry for the exact combination a gadget is in.
pub const state_order = [_]u32{ STATE_DISABLED, STATE_PRESSED, STATE_CHECKED, STATE_FOCUSED, STATE_HOVERED };

/// A look part of the way from one state to another: a transition in
/// progress (`STYLE_Transition`), as the state `DrawPart` and
/// `GetStyleAttr` take. Made with `mixState`; every property is then the
/// two states' mixed, colours channel by channel.
pub const STATE_MIXED: u32 = 1 << 31;

/// The state that is `amount` of the way from `from` to `to`: 0 is `from`,
/// 255 is `to`. Both are plain `STATE_` bits.
pub fn mixState(from: u32, to: u32, amount: u8) u32 {
    return STATE_MIXED | (to & 0xFF) | (from & 0xFF) << 8 | @as(u32, amount) << 16;
}

/// The parts of a mixed state.
pub fn mixFrom(state: u32) u32 {
    return (state >> 8) & 0xFF;
}
pub fn mixTo(state: u32) u32 {
    return state & 0xFF;
}
pub fn mixAmount(state: u32) u8 {
    return @truncate(state >> 16);
}

// --- the tags ---------------------------------------------------------------

pub const STYLE_Dummy = utility.TAG_USER + 0x3A000;

/// The part the properties after it belong to: a `PART_` number, or a
/// class's own (`classPart`). Until the first, `PART_MAIN`.
pub const STYLE_Part = STYLE_Dummy + 0x01;
/// The state they belong to: `STATE_` bits, one or several together.
/// Until the first, `STATE_NORMAL`. A new `STYLE_Part` starts again at
/// `STATE_NORMAL`.
pub const STYLE_State = STYLE_Dummy + 0x02;

/// What fills the inside: a screen pen index.
pub const STYLE_Background = STYLE_Dummy + 0x10;
/// What fills the inside: 0xAARRGGBB.
pub const STYLE_BackgroundRGB = STYLE_Dummy + 0x11;
/// What fills the inside: a `*const graphics.FillStyle` - a gradient or a
/// tile, laid across the part's own box. Copied when the style is read, so
/// the caller's may go. One property with the two above: whichever of the
/// three is found first is the background.
pub const STYLE_BackgroundFill = STYLE_Dummy + 0x12;

/// What kind of border: `BORDER_`.
pub const STYLE_Border = STYLE_Dummy + 0x20;
/// A flat border's colour: a screen pen index.
pub const STYLE_BorderPen = STYLE_Dummy + 0x21;
/// A flat border's colour: 0xAARRGGBB.
pub const STYLE_BorderRGB = STYLE_Dummy + 0x22;
/// The light side of a bevel: a screen pen index.
pub const STYLE_ShinePen = STYLE_Dummy + 0x23;
/// The light side of a bevel: 0xAARRGGBB.
pub const STYLE_ShineRGB = STYLE_Dummy + 0x24;
/// The dark side of a bevel: a screen pen index.
pub const STYLE_ShadowPen = STYLE_Dummy + 0x25;
/// The dark side of a bevel: 0xAARRGGBB.
pub const STYLE_ShadowRGB = STYLE_Dummy + 0x26;
/// How thick the border is, on all four sides. Sets `STYLE_BorderX` and
/// `STYLE_BorderY` both.
pub const STYLE_BorderWidth = STYLE_Dummy + 0x27;
/// How thick the left and right edges are, in pixels.
pub const STYLE_BorderX = STYLE_Dummy + 0x28;
/// How thick the top and bottom edges are, in pixels.
pub const STYLE_BorderY = STYLE_Dummy + 0x29;
/// Where a bevel's two colours meet: `JOINS_`.
pub const STYLE_Joins = STYLE_Dummy + 0x2A;
/// How far a ridge's or a groove's inner bevel sits inside the outer one,
/// in border thicknesses (0, the two against each other): the ground shows
/// between them.
pub const STYLE_BorderGap = STYLE_Dummy + 0x2B;

/// How far the corners are rounded, in pixels.
pub const STYLE_Radius = STYLE_Dummy + 0x30;

/// The colour of text drawn on it: a screen pen index.
pub const STYLE_TextPen = STYLE_Dummy + 0x40;
/// The colour of text drawn on it: 0xAARRGGBB.
pub const STYLE_TextRGB = STYLE_Dummy + 0x41;

/// Room between the border and what is inside, on all four sides. Sets
/// `STYLE_PaddingX` and `STYLE_PaddingY` both.
pub const STYLE_Padding = STYLE_Dummy + 0x50;
/// Room on the left and on the right, in pixels.
pub const STYLE_PaddingX = STYLE_Dummy + 0x51;
/// Room at the top and at the bottom, in pixels.
pub const STYLE_PaddingY = STYLE_Dummy + 0x52;

/// How much of it lands over what is behind: 255 all of it, 0 none.
pub const STYLE_Opacity = STYLE_Dummy + 0x60;
/// How long a change into this state takes, in milliseconds: the look goes
/// from the state before to this one over that time instead of at once -
/// a button that darkens as it is pressed and lightens as it is let go.
/// 0 (the default) changes at once. Run on motion.library's clock; a
/// gadget or screen that does not move (`GA_Animate`, `SA_Animate`)
/// changes at once whatever this says.
pub const STYLE_Transition = STYLE_Dummy + 0x61;

// --- what some of them take -------------------------------------------------

/// No border at all: the inside reaches the edge.
pub const BORDER_NONE: u32 = 0;
/// One colour, `STYLE_BorderPen`.
pub const BORDER_FLAT: u32 = 1;
/// Light at the top and left, dark at the bottom and right: standing out.
pub const BORDER_RAISED: u32 = 2;
/// Dark at the top and left, light at the bottom and right: sunk in.
pub const BORDER_RECESSED: u32 = 3;
/// A raised border with a recessed one just inside it, twice as thick.
pub const BORDER_RIDGE: u32 = 4;
/// A recessed border with a raised one just inside it, twice as thick.
pub const BORDER_GROOVE: u32 = 5;

/// A bevel's edges each stop short of the corner the other owns.
pub const JOINS_NONE: u32 = 0;
/// A bevel's two colours meet on the diagonal at the top-right and
/// bottom-left corners.
pub const JOINS_ANGLED: u32 = 1;

// --- DrawPart's flags -------------------------------------------------------

/// Draw the border turned the other way: raised as recessed, a ridge as a
/// groove. What a frame that is sunk by its own nature does with a style
/// written for things that stand out.
pub const DPF_INVERT: u32 = 1 << 0;
/// Draw the border alone and leave the inside as it is.
pub const DPF_EDGES_ONLY: u32 = 1 << 1;
