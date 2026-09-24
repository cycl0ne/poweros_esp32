// SPDX-License-Identifier: MIT
//! What a board tells whoever asked to be told.
//!
//! An event goes to exec Interrupts on a list per board and per event,
//! highest ln_Pri first, and it runs in interrupt context: it does what an
//! interrupt may do and no more. Returning non-zero ends the chain, so a
//! server that has dealt with the event on its own behalf still returns 0
//! unless it means to keep the event from everyone below it.

/// A frame ended and the blanking is now: the moment to hand the board a
/// new buffer, or to draw where the display is not looking.
pub const RTGEV_VBLANK: u32 = 0;
/// A buffer handed to ShowBitMap is the one being displayed.
pub const RTGEV_SHOWN: u32 = 1;
/// A transport's pixels have gone out and the buffer they came from may be
/// used again.
pub const RTGEV_TX_DONE: u32 = 2;
pub const RTGEV_COUNT: usize = 3;

/// is_Code of a board's event server. `is_data` is the Interrupt's own,
/// and `board` is an *RtgBoard.
pub const RtgEventFn = *const fn (is_data: ?*anyopaque, board: *anyopaque, event: u32) callconv(.c) i32;
