// SPDX-License-Identifier: MIT
//! What a call answers when it could not do what was asked.
//!
//! Every call that can fail returns one of these directly. The few that
//! return a pointer leave it in RtgLastError instead, and RtgErrorText
//! turns any of them into words.

pub const RTGERR_OK: i32 = 0;
/// No driver of that name is registered.
pub const RTGERR_NO_DRIVER: i32 = -1;
/// A tag that is needed was not there, or one carried something it could
/// not carry.
pub const RTGERR_BAD_TAGS: i32 = -2;
pub const RTGERR_NO_MEMORY: i32 = -3;
/// The board has not got that operation. Its RTGBC_ bit is clear, and the
/// caller does the work itself.
pub const RTGERR_NOT_SUPPORTED: i32 = -4;
/// There is no display: the hardware is not there, or nobody has brought
/// it up.
pub const RTGERR_NO_DISPLAY: i32 = -5;
/// Something else has it, or something of the caller's still holds it.
pub const RTGERR_IN_USE: i32 = -6;
pub const RTGERR_BAD_ARG: i32 = -7;
/// Entirely outside the buffer.
pub const RTGERR_BOUNDS: i32 = -8;
pub const RTGERR_TIMEOUT: i32 = -9;
/// The board is in no mode yet.
pub const RTGERR_NO_MODE: i32 = -10;
/// Not a pixel format this board, or this operation, can do.
pub const RTGERR_BAD_FORMAT: i32 = -11;
/// The board has no such mode.
pub const RTGERR_BAD_MODE: i32 = -12;
/// The buffer is not one the board can be given to show.
pub const RTGERR_NOT_DISPLAYABLE: i32 = -13;
/// The bus said nothing came back, or answered with a fault of its own.
pub const RTGERR_IO: i32 = -14;
/// A transfer ran to its end, but the memory behind it fell behind the
/// bus part way: the bus kept its clock and sent what its empty FIFO
/// held, so some of the bytes that arrived are not the caller's.
pub const RTGERR_UNDERRUN: i32 = -15;

/// The lowest code that has a text. RtgErrorText answers "unknown error"
/// below it.
pub const RTGERR_LAST: i32 = RTGERR_UNDERRUN;
