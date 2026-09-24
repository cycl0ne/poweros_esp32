// SPDX-License-Identifier: MIT
//! expansion.library: the board this machine is, and the parts soldered on
//! it.
//!
//! The board is described, not discovered: a GPIO pad cannot say what it
//! is wired to. So each board's ROM carries a description - the system tag
//! list (systemtags.zig), in a ROM tag of its own - and this library reads
//! it at start and hands each part out as a BoardPart. A module asks for
//! its part by kind and chip and reads the rest from the part's tags; it
//! carries no board facts of its own, so the same module serves every
//! board that has its part.

pub const boardpin = @import("boardpin.zig");
pub const systemtags = @import("systemtags.zig");

pub const BoardPart = @import("boardpart.zig").BoardPart;
pub const BoardPin = boardpin.BoardPin;

/// The name to open it by.
pub const EXPANSIONNAME = "expansion.library";
/// The ROM tag the system tag list is in.
pub const SYSTEM_RESIDENT = "system";
