// SPDX-License-Identifier: MIT
//! keyboard.device: a keyboard, as raw keys.
//!
//! A key is its **rawkey** code - where it sits on the keyboard, not what
//! it means: 0x20 is the key left of S whatever letter is printed on it.
//! Turning a key into a character is a keymap's work, above this device.
//! `KBD_READEVENT` waits for keys and hands them out as `InputEvent`s of
//! class IECLASS_RAWKEY, the code with IECODE_UP_PREFIX when a key went up,
//! and the qualifiers as they are after it. `KBD_READMATRIX` says which keys
//! are down right now, a bit per rawkey.
//!
//! **The keys come from sources.** A driver of a keyboard - a USB keyboard,
//! one on I2C, the emulator's window - opens the device with `KBDF_SOURCE`
//! and hands it keys with `KBD_ADDEVENT`; the device makes the qualifiers,
//! the matrix and the events readers see, whichever keyboard a key came
//! from, so a reader sees one keyboard however many are plugged in. A key
//! held on two keyboards is down once, and goes up when the last of them
//! lets it go; a source that closes lets go of every key it still holds.
//! The device opens with no source at all, and its readers then simply
//! wait.
//!
//! Requests are `IOStdReq`s: io_Data and io_Length say where the answer
//! goes, and io_Actual how many bytes of it were written.

const devices = @import("../libs/exec/devices.zig");

/// The name to open it by. One unit, 0.
pub const KEYBOARDNAME = "keyboard.device";

/// OpenDevice's flags: the open is a source, a keyboard's driver handing
/// the device keys with `KBD_ADDEVENT`. Its request then names a unit of
/// its own (io_Unit), which keeps the keys this source holds down; it may
/// still read like any other open.
pub const KBDF_SOURCE: u32 = 1 << 0;

/// Wait for keys and take them: io_Data an array of `InputEvent`, io_Length
/// its size in bytes, a whole number of them. It returns when at least one
/// key went down or up, with as many events as there are and fit.
pub const KBD_READEVENT: u16 = devices.CMD_NONSTD + 0;
/// Which keys are down: io_Data a bitmap, bit (code % 8) of byte (code / 8)
/// for each rawkey, io_Length up to `MATRIX_BYTES`.
pub const KBD_READMATRIX: u16 = devices.CMD_NONSTD + 1;
/// Keys from a source, on a request opened with `KBDF_SOURCE` only (any
/// other gets IOERR_NOCMD): io_Data an array of `InputEvent`s, io_Length
/// its size in bytes, a whole number of them. An event of class
/// IECLASS_RAWKEY is a key, its `code` the rawkey with IECODE_UP_PREFIX
/// when it went up; its qualifiers and time are not read - the device
/// makes both, as for every key. Other classes are passed over. A key
/// the source says is down when it already holds it, or up when it does
/// not, changes nothing. Answered at once; io_Actual the bytes taken.
pub const KBD_ADDEVENT: u16 = devices.CMD_NONSTD + 2;
/// How many keyboards there are now: io_Actual the sources open - each
/// keyboard's driver, a USB keyboard's among them - and the emulator's
/// keyboard if it gives keys. Answered at once; what intuition asks
/// before it puts a keyboard on the screen.
pub const KBD_READSOURCES: u16 = devices.CMD_NONSTD + 3;

/// The highest rawkey code; the matrix has a bit for each up to it.
pub const HIGH_KEYCODE = 0x7F;
pub const MATRIX_BYTES = (HIGH_KEYCODE + 8) / 8;

// --- rawkeys a program is likely to test -----------------------------------------

pub const RAWKEY_GRAVE: u32 = 0x00;
pub const RAWKEY_BACKSLASH: u32 = 0x0D;
pub const RAWKEY_Q: u32 = 0x10;
pub const RAWKEY_A: u32 = 0x20;
pub const RAWKEY_Z: u32 = 0x31;
pub const RAWKEY_SPACE: u32 = 0x40;
pub const RAWKEY_BACKSPACE: u32 = 0x41;
pub const RAWKEY_TAB: u32 = 0x42;
pub const RAWKEY_KP_ENTER: u32 = 0x43;
pub const RAWKEY_RETURN: u32 = 0x44;
pub const RAWKEY_ESC: u32 = 0x45;
pub const RAWKEY_DEL: u32 = 0x46;
pub const RAWKEY_INSERT: u32 = 0x47;
pub const RAWKEY_PAGEUP: u32 = 0x48;
pub const RAWKEY_PAGEDOWN: u32 = 0x49;
pub const RAWKEY_KP_MINUS: u32 = 0x4A;
pub const RAWKEY_F11: u32 = 0x4B;
pub const RAWKEY_UP: u32 = 0x4C;
pub const RAWKEY_DOWN: u32 = 0x4D;
pub const RAWKEY_RIGHT: u32 = 0x4E;
pub const RAWKEY_LEFT: u32 = 0x4F;
/// F1 to F10 are 0x50 to 0x59.
pub const RAWKEY_F1: u32 = 0x50;
pub const RAWKEY_F10: u32 = 0x59;
pub const RAWKEY_HELP: u32 = 0x5F;
pub const RAWKEY_LSHIFT: u32 = 0x60;
pub const RAWKEY_RSHIFT: u32 = 0x61;
pub const RAWKEY_CAPSLOCK: u32 = 0x62;
pub const RAWKEY_CONTROL: u32 = 0x63;
pub const RAWKEY_LALT: u32 = 0x64;
pub const RAWKEY_RALT: u32 = 0x65;
pub const RAWKEY_LAMIGA: u32 = 0x66;
pub const RAWKEY_RAMIGA: u32 = 0x67;
pub const RAWKEY_F12: u32 = 0x6F;
pub const RAWKEY_HOME: u32 = 0x70;
pub const RAWKEY_END: u32 = 0x71;
