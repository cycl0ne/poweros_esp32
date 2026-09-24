// SPDX-License-Identifier: MIT
//! mouse.device: a mouse, as raw mouse events.
//!
//! `MOUSE_READEVENT` waits until the mouse moves or a button goes down or
//! up, and hands out `InputEvent`s of class IECLASS_RAWMOUSE: `code` the
//! button that changed - IECODE_LBUTTON, IECODE_RBUTTON or IECODE_MBUTTON,
//! with IECODE_UP_PREFIX when it went up - or IECODE_NOBUTTON for a move,
//! `x` and `y` where the pointer is, and the qualifiers IEQUALIFIER_LEFTBUTTON,
//! IEQUALIFIER_RBUTTON and IEQUALIFIER_MIDBUTTON for the buttons that are
//! down after it. A mouse that says how far it went rather than where it is
//! sets IEQUALIFIER_RELATIVEMOUSE, and `x` and `y` are then the distance.
//! `MOUSE_READSTATE` says where the pointer is and which buttons are down
//! right now.
//!
//! Requests are `IOStdReq`s: io_Data and io_Length say where the answer
//! goes, and io_Actual how many bytes of it were written.

const devices = @import("../libs/exec/devices.zig");

/// The name to open it by. One unit, 0.
pub const MOUSENAME = "mouse.device";

/// Wait for the mouse and take what it did: io_Data an array of
/// `InputEvent`, io_Length its size in bytes, a whole number of them. It
/// returns when at least one thing happened, with as many events as there
/// are and fit.
pub const MOUSE_READEVENT: u16 = devices.CMD_NONSTD + 0;
/// Where the pointer is and which buttons are down: io_Data a `MouseState`.
/// Does not wait.
pub const MOUSE_READSTATE: u16 = devices.CMD_NONSTD + 1;

/// The mouse now.
pub const MouseState = extern struct {
    /// Where the pointer is, for a mouse that knows; 0 for one that only
    /// says how far it went.
    x: i32 = 0,
    y: i32 = 0,
    /// IEQUALIFIER_LEFTBUTTON, IEQUALIFIER_RBUTTON and IEQUALIFIER_MIDBUTTON
    /// for the buttons down, and IEQUALIFIER_RELATIVEMOUSE for a mouse that
    /// says how far it went.
    qualifier: u32 = 0,
};
