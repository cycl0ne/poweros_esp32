// SPDX-License-Identifier: MIT
//! canvas.gadget: a picture a program draws whenever it likes, shown and
//! kept by the gadget.
//!
//! The gadget holds a bitmap of `CANVAS_Width` by `CANVAS_Height` pixels
//! (the gadget's own size unless given), made with it in the display's
//! format and cleared, and hands out a RastPort onto it
//! (`CANVAS_RastPort`). The program draws into that RastPort with
//! graphics.library - before the window is open, between events, from
//! another task - and asks for the picture to be shown
//! (`QueueGadgetRefresh`): the gadget puts it into its box whenever it is
//! drawn, so being covered and uncovered, or a window that is moved, needs
//! nothing of the program. A picture smaller than the box sits at its top
//! left on the gadget's background.
//!
//! Pressed, it tells its target where (`CANVAS_X`, `CANVAS_Y`, in the
//! picture's pixels) as the pointer moves, interim, and once more when it
//! is let go - all a program that draws with the pointer needs.
//!
//!   const canvas = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &.{
//!       .{ .tag = cv.CANVAS_Width, .data = 200 },
//!       .{ .tag = cv.CANVAS_Height, .data = 120 },
//!       .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
//!       .{},
//!   });
//!   var rp: usize = 0;
//!   _ = ib.GetAttr(cv.CANVAS_RastPort, canvas, &rp);
//!   gb.RectFill(@ptrFromInt(rp), &.{ .max_x = 200, .max_y = 120 });
//!   ib.QueueGadgetRefresh(canvas);
//!
//! **A picture that follows its box.** Set `CANVAS_Width` and
//! `CANVAS_Height` to 0 with `SetGadgetAttrsTagList` and the picture is
//! made anew as big as the gadget's box, keeping what fits of the old one;
//! a program that draws the whole of what the window shows does that when
//! its window is sized (`IDCMP_NEWSIZE`) and draws again. The RastPort is a
//! new one then, with the old one's font and pens: read `CANVAS_RastPort`
//! again. The program must not be drawing into the old one meanwhile - from
//! another task of its own, say - since it is gone when the call returns.
//!
//!   _ = ib.SetGadgetAttrsTagList(canvas, window, &.{
//!       .{ .tag = cv.CANVAS_Width, .data = 0 },
//!       .{ .tag = cv.CANVAS_Height, .data = 0 },
//!       .{},
//!   });
//!   _ = ib.GetAttr(cv.CANVAS_RastPort, canvas, &rp);

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CANVAS_LIBRARY = "gadgets/canvas.gadget";
pub const CANVAS_CLASS = "canvas.gadget";

pub const CANVAS_Dummy = gadgets.GADGETS_Dummy + 24 * gadgets.GADGETS_Step;
/// The picture's size in pixels. Made: the gadget's size, or 160 by 120,
/// when left out or 0 - and that is what it asks a layout for from then
/// on. Set: the picture made anew at that size, 0 for the gadget's box,
/// what fits of the old one kept and the rest cleared; `CANVAS_RastPort`
/// and `CANVAS_BitMap` are new ones then. Read: the picture's size now.
pub const CANVAS_Width = CANVAS_Dummy + 0x01;
pub const CANVAS_Height = CANVAS_Dummy + 0x02;
/// `*graphics.RastPort` onto the picture: the gadget's, until the picture
/// is made anew at another size or the gadget goes. Read only.
pub const CANVAS_RastPort = CANVAS_Dummy + 0x03;
/// `*rtg.Surface`, the picture itself: a bitmap. Read only.
pub const CANVAS_BitMap = CANVAS_Dummy + 0x04;
/// Where the pointer is pressed or moved to, in the picture's pixels. Told,
/// and read: the last place told.
pub const CANVAS_X = CANVAS_Dummy + 0x05;
pub const CANVAS_Y = CANVAS_Dummy + 0x06;
