// SPDX-License-Identifier: MIT
//! touch.device: a touch panel, as contacts.
//!
//! A touch panel is not a mouse. It has no pointer that stays where it was
//! left and no buttons: a finger lands somewhere, moves, and lifts, and
//! several can do so at once. So what this device hands out is contacts,
//! each with an id that stays the same from the moment it lands until it
//! lifts - which is all a program needs to follow one finger, or two for a
//! pinch.
//!
//! `TOUCH_READEVENT` is what most programs want: it waits until something
//! happens and then fills as many `TouchEvent`s as there are and as fit,
//! linked through `next`. `TOUCH_READSTATE` answers where every finger is
//! right now, without waiting. `TOUCH_GETINFO` says what the panel is.
//!
//! Coordinates are the panel's own, 0 to width-1 and 0 to height-1, which
//! on this board are the display's pixels.
//!
//! Requests are `IOStdReq`s: io_Data and io_Length say where the answer
//! goes, and io_Actual how many bytes of it were written.

const devices = @import("../libs/exec/devices.zig");
const timer = @import("timer.zig");

/// The name to open it by. One unit, 0.
pub const TOUCHNAME = "touch.device";

/// Wait for events and take them: io_Data an array of `TouchEvent`, io_Length
/// its size in bytes, a whole number of them. It returns when at least one
/// has happened, with as many as have and fit.
pub const TOUCH_READEVENT: u16 = devices.CMD_NONSTD + 0;
/// Where every finger is now: io_Data a `TouchState`. Does not wait.
pub const TOUCH_READSTATE: u16 = devices.CMD_NONSTD + 1;
/// What the panel is: io_Data a `TouchInfo`, io_Length how big the caller's
/// is. io_Actual is how much was written.
pub const TOUCH_GETINFO: u16 = devices.CMD_NONSTD + 2;

/// The most fingers it reports at once.
pub const TOUCH_MAX_CONTACTS = 5;

/// A finger landed.
pub const TOUCH_DOWN: u32 = 1;
/// A finger that is down moved, or pressed harder or softer.
pub const TOUCH_MOVE: u32 = 2;
/// A finger lifted. Its position is where it was last.
pub const TOUCH_UP: u32 = 3;

/// One thing that happened.
pub const TouchEvent = extern struct {
    /// The next event of the same read, or null for the last.
    next: ?*TouchEvent = null,
    /// TOUCH_DOWN, TOUCH_MOVE or TOUCH_UP.
    kind: u32 = 0,
    /// Which contact: the same from its DOWN to its UP, and free to be used
    /// for another finger after.
    id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    /// How much of the panel the finger covers, in the controller's units.
    size: u32 = 0,
    /// When, as timer.device's system time.
    time: timer.TimeVal = .{},
};

/// One finger that is down.
pub const TouchContact = extern struct {
    id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    size: u32 = 0,
};

/// Every finger that is down.
pub const TouchState = extern struct {
    /// How many of `contacts` are filled.
    count: u32 = 0,
    contacts: [TOUCH_MAX_CONTACTS]TouchContact = @splat(.{}),
    /// When the controller last reported.
    time: timer.TimeVal = .{},
};

/// What the panel is. It grows at the end; a caller passes the size of its
/// own and reads io_Actual for how much of it was filled.
pub const TouchInfo = extern struct {
    /// How many bytes were written, this field included.
    size: u32 = 0,
    max_contacts: u32 = 0,
    /// The range of the coordinates: 0 to width-1, 0 to height-1.
    width: u32 = 0,
    height: u32 = 0,
    /// The controller's product id, as it gives it ("911" and a NUL for a
    /// GT911).
    product: [4]u8 = .{ 0, 0, 0, 0 },
    /// Its firmware version.
    firmware: u32 = 0,
    /// The I2C address it answers at.
    address: u32 = 0,
};
