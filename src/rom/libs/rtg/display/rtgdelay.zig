// SPDX-License-Identifier: MPL-2.0
//! RtgDelay: Wait a number of microseconds, the CPU given away.
//!
//! A copy of the library's request to timer.device, answered to a port
//! on the waiting task's stack, so any task may wait at once. Where there
//! is no timer.device the time is spun away instead.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Waits `micros` microseconds.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgDelay(rb: *RtgBase, micros: u32) void
/// ```
///
/// SINCE: 1.40. LVO -332.
///
/// INPUTS:
/// - `micros` - how long, in microseconds; 0 comes back at once.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The task waits on timer.device's microsecond unit, and other tasks
/// have the CPU meanwhile. Where the library could not open timer.device,
/// and where no signal is free for the wait, the time is spun away by the
/// clock instead (`SpinUs`): the call never comes back early.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A signal is taken for the wait and given back. Nothing is allocated:
/// the request and its reply port are on the caller's stack.
///
/// NOTES:
/// What a driver waits for while it brings up its hardware: a reset held,
/// a part settling, a link coming up. A wait for a frame is `WaitVBlank`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RunPanelSequence`, `WaitVBlank`
///
/// EXAMPLES:
/// ```zig
/// rb.RtgDelay(10 * 1000); // the reset held for 10 ms
/// ```
pub fn RtgDelay(rb: *RtgBase, micros: u32) void {
    if (micros == 0) return;
    const sys = rb.sys_base;
    if (rb.timer_io.node.device == null) return sys.SpinUs(micros);
    const signal_bit = sys.AllocSignal(-1);
    if (signal_bit < 0) return sys.SpinUs(micros);
    defer sys.FreeSignal(signal_bit);
    var port: exec.MsgPort = .{ .sig_bit = @intCast(signal_bit), .sig_task = sys.FindTask(null) };
    port.msg_list.init(.message);
    var clock = rb.timer_io;
    clock.node.message.reply_port = &port;
    clock.node.command = timer.TR_ADDREQUEST;
    clock.time = timer.TimeVal.fromMicros(micros);
    _ = sys.DoIO(&clock.node);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "RtgDelay: slept on a copy of the library's request; nothing for no time" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();
    const opened = rb.timer_io;
    const sent = fixture.FakeTimer.sent;

    fixture.driverBase(rb).RtgDelay(2500);
    try testing.expectEqual(sent + 1, fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u64, 2500), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 1), fixture.Sleep.sleeps);
    try testing.expect(fixture.FakeTimer.waiting == null);
    try testing.expect(fixture.FakeTimer.last.? != &rb.timer_io.node);
    try testing.expectEqual(opened, rb.timer_io);

    fixture.driverBase(rb).RtgDelay(0);
    try testing.expectEqual(sent + 1, fixture.FakeTimer.sent);
    // Without timer.device the time is spun away on the chip's counter,
    // which the host has not got: not run here.
    try fixture.tearDown(rb);
}
