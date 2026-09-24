// SPDX-License-Identifier: MIT
//! input.device: every input the machine has, as one stream of InputEvents
//! passed down a chain of handlers.
//!
//! The device takes the keys from keyboard.device and the fingers from
//! touch.device, repeats a held key, adds a timer event ten times a second,
//! stamps each event with the system time and hands it to the handlers
//! from the highest priority down. A handler gets the events, may change,
//! add or remove any of them, and returns what the next handler is to see;
//! returning null ends the walk. Everything that wants input - the windowing
//! system, a hotkey program, a screen blanker - is a handler.
//!
//! Handlers run on the device's own task, one event list at a time, so a
//! handler is never called twice at once and never while it is being added
//! or removed. It must not wait for anything: every other handler, and all
//! input, waits for it.

const devices = @import("../libs/exec/devices.zig");
const inputevent = @import("inputevent.zig");
const InputEvent = inputevent.InputEvent;

/// The name to open it by. One unit, 0.
pub const INPUTNAME = "input.device";

/// Put a handler on the chain: io_Data an `exec.Interrupt` whose `code` is
/// an `InputHandlerFn`, `data` what the handler is handed, `node.pri` its
/// place (higher first). The device keeps the structure until
/// IND_REMHANDLER.
pub const IND_ADDHANDLER: u16 = devices.CMD_NONSTD + 0;
/// Take a handler off the chain: io_Data the same `exec.Interrupt`. When
/// the request comes back the handler is not running and will not run again.
pub const IND_REMHANDLER: u16 = devices.CMD_NONSTD + 1;
/// Send one event down the chain as though a device had made it: io_Data an
/// `InputEvent`, io_Length its size. `next` is ignored and the time is set;
/// the event is the chain's to change, so its contents afterwards are not
/// what was sent.
pub const IND_WRITEEVENT: u16 = devices.CMD_NONSTD + 2;
/// How long a key is held before it repeats: a `timer.TimeRequest` whose
/// `time` is the new threshold. 0.8 s to begin with.
pub const IND_SETTHRESH: u16 = devices.CMD_NONSTD + 3;
/// How often a held key repeats: a `timer.TimeRequest` whose `time` is the
/// new period. 0.1 s to begin with.
pub const IND_SETPERIOD: u16 = devices.CMD_NONSTD + 4;

/// A handler: the events, and the Interrupt's `data`; it returns the events
/// the next handler is to see, or null for none.
pub const InputHandlerFn = *const fn (events: ?*InputEvent, data: ?*anyopaque) callconv(.c) ?*InputEvent;

/// The base, for PeekQualifier: io_Device of an open request.
pub const InputBase = @import("../interface/input.zig").InputBase;
