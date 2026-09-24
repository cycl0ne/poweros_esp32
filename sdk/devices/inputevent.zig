// SPDX-License-Identifier: MIT
//! Input events: what the input devices hand out, and what a console and
//! the windowing system will take in.
//!
//! One structure for every kind of input, told apart by `class`: a key is
//! IECLASS_RAWKEY with the key's code, the mouse IECLASS_RAWMOUSE with its
//! buttons and movement. `qualifier` says which modifiers were held when it
//! happened - shift, control, alt, the command keys, and the mouse buttons -
//! so an event can be understood on its own, without the ones before it.
//!
//! Every field is 32 bits.

const timer = @import("timer.zig");

pub const InputEvent = extern struct {
    /// ie_NextEvent: the next event of the same read, or null for the last.
    next: ?*InputEvent = null,
    /// ie_Class: IECLASS_.
    class: u32 = IECLASS_NULL,
    /// ie_SubClass: more about the class; 0 for keys.
    subclass: u32 = 0,
    /// ie_Code: for a key its rawkey code, with IECODE_UP_PREFIX when it
    /// went up.
    code: u32 = 0,
    /// ie_Qualifier: IEQUALIFIER_ bits, as they are after this event.
    qualifier: u32 = 0,
    /// ie_X, ie_Y: where, for events that have a position. For
    /// IECLASS_RAWKEY, the two keys down before this one, the last first,
    /// each `IE_PREVKEY_VALID | rawkey << 8 | its qualifiers & 0xFF`, or 0
    /// for none - which is what a dead key changes the key after it by.
    x: i32 = 0,
    y: i32 = 0,
    /// ie_TimeStamp: when, as timer.device's system time.
    time: timer.TimeVal = .{},
    /// ie_EventAddress: what the event is about, when its class says so -
    /// the window, for the window events intuition writes.
    address: ?*anyopaque = null,
};

// --- classes ------------------------------------------------------------------

pub const IECLASS_NULL: u32 = 0x00;
/// A key went down or up.
pub const IECLASS_RAWKEY: u32 = 0x01;
/// The mouse moved or a button changed.
pub const IECLASS_RAWMOUSE: u32 = 0x02;
/// Something happened to a window: `code` says what and `address` is the
/// window. intuition writes these beside the IDCMP message it sends, so a
/// console on that window hears about it without taking the program's
/// messages.
pub const IECLASS_EVENT: u32 = 0x03;
/// Time passed: a tick for whoever wants one.
pub const IECLASS_TIMER: u32 = 0x06;
/// A window became active, or stopped being: `address` is the window.
pub const IECLASS_ACTIVEWINDOW: u32 = 0x11;
pub const IECLASS_INACTIVEWINDOW: u32 = 0x12;

/// IECLASS_EVENT's codes.
pub const IECODE_NEWSIZE: u32 = 0x02;
pub const IECODE_REFRESHWINDOW: u32 = 0x03;
/// The pointer went to a position, rather than moving by an amount: `x`
/// and `y` are display pixels, `code` a button as for IECLASS_RAWMOUSE
/// (IECODE_LBUTTON, with IECODE_UP_PREFIX when it was let go) or
/// IECODE_NOBUTTON when only the position changed.
pub const IECLASS_NEWPOINTERPOS: u32 = 0x13;
/// A finger on a touch panel: `subclass` is TOUCH_DOWN, TOUCH_MOVE or
/// TOUCH_UP (devices/touch), `code` the contact's id, `x` and `y` where it
/// is in the panel's pixels. Every finger is reported this way; the first
/// one down is also the pointer.
pub const IECLASS_TOUCH: u32 = 0x16;

// --- codes ---------------------------------------------------------------------

/// Set in a key's code when it went up.
pub const IECODE_UP_PREFIX: u32 = 0x80;
/// Set in a RAWKEY event's x or y when it holds a key down before it.
pub const IE_PREVKEY_VALID: u32 = 1 << 16;

/// The code without the up bit.
pub const IECODE_KEY_CODE_MASK: u32 = 0x7F;
/// The pointer's buttons, as codes of IECLASS_RAWMOUSE and
/// IECLASS_NEWPOINTERPOS, with IECODE_UP_PREFIX when let go.
pub const IECODE_LBUTTON: u32 = 0x68;
pub const IECODE_RBUTTON: u32 = 0x69;
pub const IECODE_MBUTTON: u32 = 0x6A;
/// No button changed: the event is about the position.
pub const IECODE_NOBUTTON: u32 = 0xFF;

// --- qualifiers ----------------------------------------------------------------

pub const IEQUALIFIER_LSHIFT: u32 = 0x0001;
pub const IEQUALIFIER_RSHIFT: u32 = 0x0002;
pub const IEQUALIFIER_CAPSLOCK: u32 = 0x0004;
pub const IEQUALIFIER_CONTROL: u32 = 0x0008;
pub const IEQUALIFIER_LALT: u32 = 0x0010;
pub const IEQUALIFIER_RALT: u32 = 0x0020;
/// The left and right command (Amiga) keys.
pub const IEQUALIFIER_LCOMMAND: u32 = 0x0040;
pub const IEQUALIFIER_RCOMMAND: u32 = 0x0080;
/// The key is on the numeric keypad.
pub const IEQUALIFIER_NUMERICPAD: u32 = 0x0100;
/// The key is repeating, held down.
pub const IEQUALIFIER_REPEAT: u32 = 0x0200;
pub const IEQUALIFIER_MIDBUTTON: u32 = 0x1000;
pub const IEQUALIFIER_RBUTTON: u32 = 0x2000;
pub const IEQUALIFIER_LEFTBUTTON: u32 = 0x4000;
pub const IEQUALIFIER_RELATIVEMOUSE: u32 = 0x8000;
