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
//! **What the mouse does comes from sources.** A driver of a mouse - a USB
//! mouse, a tablet, the emulator's window - opens the device with
//! `MOUSEF_SOURCE` and hands it what its mouse did with `MOUSE_ADDEVENT`;
//! readers see one mouse however many there are. A button held on two
//! mice is down once, and goes up when the last of them lets it go; a
//! source that closes lets go of every button it still holds. The device
//! opens with no source at all, and its readers then simply wait.
//!
//! Requests are `IOStdReq`s: io_Data and io_Length say where the answer
//! goes, and io_Actual how many bytes of it were written.

const devices = @import("../libs/exec/devices.zig");

/// The name to open it by. One unit, 0.
pub const MOUSENAME = "mouse.device";

/// OpenDevice's flags: the open is a source, a mouse's driver handing the
/// device what it did with `MOUSE_ADDEVENT`. Its request then names a
/// unit of its own (io_Unit), which keeps the buttons this source holds
/// down; it may still read like any other open.
pub const MOUSEF_SOURCE: u32 = 1 << 0;

/// Wait for the mouse and take what it did: io_Data an array of
/// `InputEvent`, io_Length its size in bytes, a whole number of them. It
/// returns when at least one thing happened, with as many events as there
/// are and fit.
pub const MOUSE_READEVENT: u16 = devices.CMD_NONSTD + 0;
/// Where the pointer is and which buttons are down: io_Data a `MouseState`.
/// Does not wait.
pub const MOUSE_READSTATE: u16 = devices.CMD_NONSTD + 1;
/// What a source's mouse did, on a request opened with `MOUSEF_SOURCE`
/// only (any other gets IOERR_NOCMD): io_Data an array of `InputEvent`s
/// of class IECLASS_RAWMOUSE, io_Length its size in bytes, a whole number
/// of them; other classes are passed over. Each event is a position and
/// a button at once:
///   - `x` and `y`: where the pointer is now, or with
///     IEQUALIFIER_RELATIVEMOUSE in `qualifier` how far it went (0 and 0:
///     it did not move); with `subclass` IESUBCLASS_TABLET, how far
///     across its tablet, 0 to IETABLET_MAX (devices/inputevent), which
///     the readers' events then carry too;
///   - `code`: IECODE_LBUTTON, IECODE_RBUTTON or IECODE_MBUTTON, with
///     IECODE_UP_PREFIX when it was let go, or IECODE_NOBUTTON for a move
///     alone; IECODE_WHEEL for the wheel, `x` and `y` its notches right
///     and down, as readers get it.
/// The other qualifier bits and the time are not read - the device makes
/// both. A button the source says is down when it already holds it, or up
/// when it does not, changes nothing. Answered at once; io_Actual the
/// bytes taken.
pub const MOUSE_ADDEVENT: u16 = devices.CMD_NONSTD + 2;

/// The mouse now.
pub const MouseState = extern struct {
    /// Where a mouse that says where it is last put the pointer; 0 and 0
    /// until one has.
    x: i32 = 0,
    y: i32 = 0,
    /// IEQUALIFIER_LEFTBUTTON, IEQUALIFIER_RBUTTON and IEQUALIFIER_MIDBUTTON
    /// for the buttons down, on any of the mice, and
    /// IEQUALIFIER_RELATIVEMOUSE when the last move said how far it went
    /// rather than where to.
    qualifier: u32 = 0,
};
