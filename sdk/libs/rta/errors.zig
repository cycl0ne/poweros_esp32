// SPDX-License-Identifier: MIT
//! What a call answers when it could not do what was asked.
//!
//! Every call that can fail returns one of these directly. The few that
//! return a pointer leave it in RtaLastError instead, and RtaErrorText
//! turns any of them into words.

pub const RTAERR_OK: i32 = 0;
/// No driver of that name is registered, or none that makes that kind of
/// thing.
pub const RTAERR_NO_DRIVER: i32 = -1;
/// A tag that is needed was not there, or one carried something it could
/// not carry.
pub const RTAERR_BAD_TAGS: i32 = -2;
pub const RTAERR_NO_MEMORY: i32 = -3;
/// The sink or the transport has not got that operation.
pub const RTAERR_NOT_SUPPORTED: i32 = -4;
/// The output is not there: a part that does not answer, a line the chip
/// cannot reach, no DMA channel left.
pub const RTAERR_NO_OUTPUT: i32 = -5;
/// Something else has it: a sink that is already playing, a transport a
/// sink still names, a pad another driver holds.
pub const RTAERR_IN_USE: i32 = -6;
pub const RTAERR_BAD_ARG: i32 = -7;
/// The sink is not playing.
pub const RTAERR_NOT_RUNNING: i32 = -8;
/// The sink has no such mode, or the line cannot be clocked for it.
pub const RTAERR_BAD_MODE: i32 = -9;
/// The bus a part is set up over did not answer.
pub const RTAERR_IO: i32 = -10;
/// The way in is not there: a part that does not answer, a line without a
/// pad for the data in, no DMA channel left. Since 1.3.
pub const RTAERR_NO_INPUT: i32 = -11;

/// The lowest code that has a text. RtaErrorText answers "unknown error"
/// below it.
pub const RTAERR_LAST: i32 = RTAERR_NO_INPUT;
