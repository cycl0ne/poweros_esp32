// SPDX-License-Identifier: MIT
//! A function as the library keeps it, behind the HIDFunction its driver
//! holds: where its reports keep what they say (report/layout.zig), what
//! the device holds down, its LEDs, and its sources - the requests on
//! keyboard.device and mouse.device that its events are handed to; a
//! consumer control's media keys go to keyboard.device beside a
//! keyboard's.
//!
//! **Its sources** are opened by OpenHID with their flags for a source
//! (KBDF_SOURCE, MOUSEF_SOURCE), their replies going to the driver's port
//! (HIDA_ReplyPort) or one of the function's own, and closed by CloseHID -
//! which lets go of whatever keys or buttons the device still held.
//!
//! **The events** of one report are made in the function's own room and
//! handed to a source in one request, on the task that called HIDInput.

const sdk = @import("sdk");
const exec = sdk.exec;
const hid = sdk.hid;
const utility = sdk.utility;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const HIDBase = @import("../hid_base.zig").HIDBase;
const layout = @import("../report/layout.zig");
const report = @import("../report/report.zig");

/// The most events one report makes: every key of a boot keyboard let go
/// and as many pressed, with room over for a keyboard of bits.
pub const EVENTS_MOST = 64;

/// A function. Made by OpenHID in memory cleared, never as a whole.
pub const Function = struct {
    public: hid.HIDFunction,
    /// The first keyboard collection's layout, whose LEDs are the
    /// keyboard's; then the others', each in a report of its own.
    keyboard: layout.KeyboardLayout,
    more_keyboards: [layout.KEYBOARDS_MOST - 1]layout.KeyboardLayout,
    more_count: u8,
    /// What each keyboard report last held down, the first's first.
    held: [layout.KEYBOARDS_MOST]report.KeySet,
    mouse: layout.MouseLayout,
    consumer: layout.ConsumerLayout,
    /// What the last reports held down: the keyboard's keys - in any of
    /// its reports - the mouse's buttons, the consumer control's media
    /// keys.
    keys: report.KeySet,
    buttons: u8,
    media: report.KeySet,
    /// The keyboard's LEDs as last sent (bit 1: Caps Lock).
    leds: u8,
    /// Whether `port` is the function's own, deleted with it.
    own_port: bool,
    keyboard_source: exec.IOStdReq,
    mouse_source: exec.IOStdReq,
    port: ?*exec.MsgPort,
    /// The driver's hook for an output report.
    output: ?*utility.Hook,
    events: [EVENTS_MOST]ie.InputEvent,
};

pub fn functionOf(public: *hid.HIDFunction) *Function {
    return @alignCast(@fieldParentPtr("public", public));
}

/// A source opened on `source`: keyboard.device or mouse.device by its
/// name, with the flags that make the request a source's, replying to
/// `port`. False where the device does not open.
pub fn openSource(sys: *ExecBase, source: *exec.IOStdReq, name: [*:0]const u8, flags: u32, port: *exec.MsgPort) bool {
    source.* = .{};
    source.req.message.reply_port = port;
    source.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(name, 0, &source.req, flags) != 0) {
        source.req.device = null;
        return false;
    }
    return true;
}

/// A function given back: its sources closed - which lets go of the keys
/// and buttons the device held - its own port deleted, its memory freed.
pub fn release(base: *HIDBase, function: *Function) void {
    const sys = base.sys_base;
    if (function.keyboard_source.req.device != null) sys.CloseDevice(&function.keyboard_source.req);
    if (function.mouse_source.req.device != null) sys.CloseDevice(&function.mouse_source.req);
    if (function.own_port) {
        if (function.port) |port| sys.DeleteMsgPort(port);
    }
    sys.FreeMem(function, @sizeOf(Function));
}
