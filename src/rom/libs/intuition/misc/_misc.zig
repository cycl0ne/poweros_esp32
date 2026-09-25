// SPDX-License-Identifier: MPL-2.0
//! What the beep, the alerts and the clock share: a wait of so many
//! microseconds on timer.device, and an alert's hold on the input.
//!
//! timer.device is opened the first time something waits, into a request
//! each wait copies with a reply port on its caller's own stack: any task
//! may be the one waiting.
//!
//! An alert, while it is up, takes every input event: a press of a button
//! is its answer - the left one yes, the right one no - and nothing else
//! reaches a window. A touch has only the one button, so a press on the
//! right half of the display counts as the right button.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// An alert's state, in the base.
pub const AlertState = extern struct {
    /// Up: the input is the alert's.
    active: bool = false,
    /// Its answer: none yet, yes or no.
    answer: Answer = .none,
    pad: [2]u8 = .{ 0, 0 },
    /// Where the right half of the display begins, for a touch.
    half: i32 = 0,
};

pub const Answer = enum(u8) { none, yes, no };

/// A frame of a 60 Hz panel, what an alert's time-out counts in.
pub const frame_us = 16_667;

/// Wait `us` microseconds, or not at all when timer.device cannot be had.
pub fn wait(ib: *IntuitionBase, us: u64) void {
    const sys = ib.sys_base;
    if (!ib.timer_open) {
        ib.timer_io = .{};
        ib.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &ib.timer_io.node, 0) != 0) return;
        ib.timer_open = true;
    }
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return;
    defer sys.FreeSignal(bit);
    var port: exec.MsgPort = .{ .sig_bit = @intCast(bit), .sig_task = sys.FindTask(null) };
    port.msg_list.init(.message);
    var io = ib.timer_io;
    io.node.message.reply_port = &port;
    io.node.command = timer.TR_ADDREQUEST;
    io.time = timer.TimeVal.fromMicros(us);
    _ = sys.DoIO(&io.node);
}

/// timer.device given back, if it was opened.
pub fn close(ib: *IntuitionBase) void {
    if (ib.timer_open) ib.sys_base.CloseDevice(&ib.timer_io.node);
    ib.timer_open = false;
}

/// An input event while an alert is up: a press answers it, and nothing
/// goes anywhere else. On the input task.
pub fn alertInput(ib: *IntuitionBase, e: *const InputEvent) void {
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return;
    const alert = &ib.alert;
    if (alert.answer != .none) return;
    if (e.code == ie.IECODE_LBUTTON) {
        alert.answer = if (e.x >= alert.half) .no else .yes;
    } else if (e.code == ie.IECODE_RBUTTON) {
        alert.answer = .no;
    }
}
