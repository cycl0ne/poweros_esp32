// SPDX-License-Identifier: MIT
//! Requesters: the easy requester - a window that says something and asks
//! for an answer with a row of buttons - and the requester a program puts
//! inside a window of its own (`Requester`).
//!
//! What it says and what the buttons say are formats, as RawDoFmt reads
//! them (`%d %u %x %c` 32 bits, with `l` 64, `%s` a C string), taking their
//! values from one stream: the message's first, then the buttons'. The
//! message's lines are separated by `\n` and the buttons by `|`, after the
//! formatting, so a value may add either.
//!
//!   const ask = requesters.EasyStruct{
//!       .title = "Volume Request",
//!       .text_format = "Please insert volume %s in any drive.",
//!       .gadget_format = "Retry|Cancel",
//!   };
//!   while (findVolume(name) == null and
//!       requesters.EasyRequest(ib, null, ask, null, .{name}) != 0) {}

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const layers = @import("../layers/layers.zig");
const windows = @import("windows.zig");
const classes = @import("classes.zig");
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;

/// What an easy requester says.
pub const EasyStruct = extern struct {
    /// @sizeOf(EasyStruct), so that one that grows can tell the old from
    /// the new.
    struct_size: u32 = @sizeOf(EasyStruct),
    /// None yet: 0.
    flags: u32 = 0,
    /// The window's title; null takes the reference window's, or else
    /// "System Request".
    title: ?[*:0]const u8 = null,
    /// The message, lines separated by `\n`.
    text_format: [*:0]const u8,
    /// The buttons, left to right, separated by `|`. At least one.
    gadget_format: [*:0]const u8,
};

// --- a requester in a window ----------------------------------------------------

/// A box a program puts inside one of its windows with `Request`, holding
/// gadgets of its own: while one is up the window's own gadgets are not
/// pressed, only the frontmost requester's are, until `EndRequest` - or a
/// gadget of it made with `GA_EndGadget` - takes it down. Requesters stack,
/// the newest in front.
///
/// Its face is drawn in three steps: the box filled with `back_fill`, then
/// `image` - one image object, a chain of them through `IA_NextImage`, such
/// as a frame with words in it - and then the gadgets. The program keeps
/// the structure, the gadgets and the image, and must leave them alone
/// while the requester is up. Clear one with `InitRequester` before filling
/// it in.
pub const Requester = extern struct {
    /// OlderRequest: the requester up before this one in the same window.
    /// intuition.library's own.
    older: ?*Requester = null,
    /// LeftEdge, TopEdge, Width, Height: where in the window and how big -
    /// from the window's corner, or from the interior's in a GimmeZeroZero
    /// window. It is cut at the window's inner edges.
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// RelLeft, RelTop: with `POINTREL`, where it goes from the middle of
    /// the window - or, as a double-click requester, from the pointer.
    rel_left: i32 = 0,
    rel_top: i32 = 0,
    /// ReqGadget: the first of its gadgets, linked with `GA_Previous` as a
    /// window's are. Their boxes are measured from the requester's corner
    /// and against its size.
    gadgets: ?*classes.Object = null,
    /// Flags: `POINTREL`, `NOISYREQ`, `SIMPLEREQ`, `NOREQBACKFILL`, and the
    /// bits intuition.library keeps in it.
    flags: u32 = 0,
    /// BackFill: what the box is filled with before anything is drawn in
    /// it, as 0xAARRGGBB; 0 is the screen's background pen.
    back_fill: graphics.Pen = 0,
    /// ReqImage: what it looks like, drawn over the fill and under the
    /// gadgets, from its corner. Null draws nothing.
    image: ?*classes.Object = null,
    /// ReqLayer: the layer it is drawn in while it is up, or null while it
    /// is up but outside the window. intuition.library's own.
    layer: ?*layers.Layer = null,
    /// RWindow: the window it is up in. intuition.library's own.
    window: ?*windows.Window = null,
};

/// Placed at the middle of the window, moved by `rel_left` and `rel_top` -
/// under the pointer for a double-click requester - and kept inside it.
pub const POINTREL: u32 = 0x0001;
/// The window still hears the input the requester does not use: presses,
/// keys, the menu button.
pub const NOISYREQ: u32 = 0x0004;
/// Its layer keeps nothing it covers; it is drawn again when uncovered.
pub const SIMPLEREQ: u32 = 0x0010;
/// The box is not filled before the image is drawn.
pub const NOREQBACKFILL: u32 = 0x0040;
/// Some of it is outside the window. intuition.library's own.
pub const REQOFFWINDOW: u32 = 0x1000;
/// It is up. intuition.library's own.
pub const REQACTIVE: u32 = 0x2000;

// --- a requester from IntuiTexts ------------------------------------------------

/// The tags AutoRequestTagList and BuildSysRequestTagList take.
pub const SYSREQ_Dummy = utility.TAG_USER + 0x3B000;
/// `*const IntuiText`, required: what it says, each run of the chain a
/// line.
pub const SYSREQ_Body = SYSREQ_Dummy + 0x01;
/// `*const IntuiText`: the left button's text - yes, retry, go on. None
/// without it.
pub const SYSREQ_Positive = SYSREQ_Dummy + 0x02;
/// `*const IntuiText`, required: the right button's text - no, cancel.
pub const SYSREQ_Negative = SYSREQ_Dummy + 0x03;
/// BuildSysRequestTagList: IDCMP classes of the caller's own that answer
/// it too, as SysReqHandler's SYSREQ_IDCMP.
pub const SYSREQ_IDCMPFlags = SYSREQ_Dummy + 0x04;
/// AutoRequestTagList: IDCMP classes that answer it as the left button,
/// and as the right one.
pub const SYSREQ_PositiveFlags = SYSREQ_Dummy + 0x05;
pub const SYSREQ_NegativeFlags = SYSREQ_Dummy + 0x06;

/// SysReqHandler's and EasyRequestArgs's answer when one of the caller's
/// own IDCMP classes arrived; which one is where the IDCMP pointer points.
pub const SYSREQ_IDCMP: i32 = -1;
/// SysReqHandler's answer when nothing it read answered the requester.
pub const SYSREQ_PENDING: i32 = -2;

/// EasyRequestArgs with the values packed from a tuple, checked against
/// both formats at compile time. Answers 1, 2, ... for the buttons from the
/// left and 0 for the rightmost, or SYSREQ_IDCMP.
pub fn EasyRequest(ib: *IntuitionBase, window: ?*windows.Window, comptime easy: EasyStruct, idcmp_ptr: ?*u32, args: anytype) i32 {
    comptime exec.checkFormat(span(easy.text_format) ++ span(easy.gadget_format), @TypeOf(args));
    const stream = exec.fmtStream(args);
    const asked = easy;
    return ib.EasyRequestArgs(window, &asked, idcmp_ptr, &stream);
}

/// A C string known at compile time, as a slice.
fn span(comptime s: [*:0]const u8) []const u8 {
    comptime {
        var n: usize = 0;
        while (s[n] != 0) n += 1;
        return s[0..n];
    }
}
