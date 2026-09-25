// SPDX-License-Identifier: MIT
//! pointerclass: a mouse pointer a window can have.
//!
//! An object of pointerclass is an image and the place in it that is the
//! pointer's point. A window is given one with `WA_Pointer`, at
//! `OpenWindowTagList` or with `SetWindowPointerA`, and the pointer takes
//! it whenever that window is the active one. The picture is a surface
//! with an alpha channel - `rgba32`, `bgra32` or `argb1555`, as
//! graphics.library's `AllocBitMapTagList` makes one - no larger than
//! `rtg.boards.RTG_POINTER_MAX` each way: a pixel whose alpha is 128 or
//! more is the pointer's, anything less shows what is under it.
//!
//! The surface stays the caller's and is read each time the pointer takes
//! the object, so it must live as long as the object does. Disposing of
//! the object takes it off every window that had it, which gets the
//! default pointer back.
//!
//! ```zig
//! const arrow = it.NewObjectTagList(null, pointerclass.POINTERCLASS, &.{
//!     .{ .tag = pointerclass.POINTERA_BitMap, .data = @intFromPtr(picture) },
//!     .{ .tag = pointerclass.POINTERA_XOffset, .data = @bitCast(@as(isize, -7)) },
//!     .{ .tag = pointerclass.POINTERA_YOffset, .data = @bitCast(@as(isize, -7)) },
//!     .{},
//! });
//! ```

const utility = @import("../utility/utility.zig");

/// The name to make one by.
pub const POINTERCLASS = "pointerclass";

pub const POINTERA_Dummy = utility.TAG_USER + 0x3E000;
/// The picture: a `*rtg.Surface`, the caller's.
pub const POINTERA_BitMap = POINTERA_Dummy + 0x01;
/// Where the picture goes from the pointer's point, in pixels: the point
/// is its pixel (-XOffset, -YOffset), so both are 0 or less. 0, 0 - the
/// top left - when not given.
pub const POINTERA_XOffset = POINTERA_Dummy + 0x02;
pub const POINTERA_YOffset = POINTERA_Dummy + 0x03;
