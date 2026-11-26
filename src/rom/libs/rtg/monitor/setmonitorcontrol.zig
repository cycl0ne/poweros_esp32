// SPDX-License-Identifier: MPL-2.0
//! SetMonitorControl: A monitor's own control set over its DDC.
//!
//! The message is DDC/CI's (`_ddcci.zig`); the bus is the driver's,
//! reached through its hook.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const ddcci = @import("_ddcci.zig");

/// Sets one of a monitor's own controls over its DDC.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMonitorControl(rb: *RtgBase, code: u32, value: u32, transfer: *utility.Hook) i32
/// ```
///
/// SINCE: 1.44. LVO -340.
///
/// INPUTS:
/// - `code` - the control, by MCCS's code: `RTGVCP_BRIGHTNESS`,
///   `RTGVCP_CONTRAST` or another below 256.
/// - `value` - what it is set to, at most the largest
///   `GetMonitorControl` answers for it.
/// - `transfer` - the driver's hook, called with null as its object and
///   an `RtgDdcTransfer` as its message, the setting written. It answers
///   `RTGERR_OK` once the bytes went, `RTGERR_IO` where the monitor did
///   not answer.
///
/// RESULT:
/// `RTGERR_OK` once the monitor took the message; `RTGERR_BAD_ARG` for a
/// code past 255 or a value past 65535, and nothing is sent; otherwise
/// what the hook answered.
///
/// BEHAVIOR:
/// The setting is seven bytes written to the monitor at 0x37: the host's
/// address, the length, the opcode, the control, the value high byte
/// first, and the checksum. The monitor does not answer it; the 50 ms
/// it wants before it is spoken to again are waited out (`RtgDelay`),
/// whatever the hook answered, so the next question finds it ready.
///
/// CONTEXT:
/// - Waits: yes, the 50 ms, and as long as the hook does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held; the driver keeps other talk on the
///   bus away, its own lock held around the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The transfer lives on this call's stack, for the hook's call alone.
///
/// NOTES:
/// A value past the control's largest is the monitor's to take or leave;
/// a driver works out its values from the largest it was answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMonitorControl`, `RtgDelay`
///
/// EXAMPLES:
/// ```zig
/// var value: u32 = 0;
/// var most: u32 = 0;
/// if (rb.GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most) == rtg.errors.RTGERR_OK) {
///     _ = rb.SetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, (percent * most + 50) / 100, &hook);
/// }
/// ```
pub fn SetMonitorControl(rb: *RtgBase, code: u32, value: u32, transfer: *utility.Hook) i32 {
    if (code > 0xFF or value > 0xFFFF) return err.RTGERR_BAD_ARG;
    var setting = ddcci.setTo(@intCast(code), @intCast(value));
    const sent = ddcci.move(rb, transfer, false, &setting);
    rb.driverIface().RtgDelay(ddcci.set_us);
    return sent;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;
const Monitor = @import("getmonitorcontrol.zig").Monitor;

test "SetMonitorControl: the setting written, 50 ms waited out" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();
    const sent = fixture.FakeTimer.sent;
    var monitor: Monitor = .{};
    var hook: utility.Hook = .{ .entry = &Monitor.transfer, .data = &monitor };

    try testing.expectEqual(err.RTGERR_OK, fixture.driverBase(rb).SetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, 50, &hook));
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A }, monitor.written[0..monitor.written_count]);
    try testing.expectEqual(@as(u32, 0x37), monitor.address);
    try testing.expectEqual(sent + 1, fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u64, 50_000), fixture.FakeTimer.last_micros);

    // Not answering: the hook's answer, and the wait all the same.
    monitor.deaf = true;
    try testing.expectEqual(err.RTGERR_IO, fixture.driverBase(rb).SetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, 50, &hook));
    try testing.expectEqual(sent + 2, fixture.FakeTimer.sent);
    // Past MCCS's codes and values: nothing sent.
    const transfers = monitor.transfers;
    try testing.expectEqual(err.RTGERR_BAD_ARG, fixture.driverBase(rb).SetMonitorControl(0x100, 1, &hook));
    try testing.expectEqual(err.RTGERR_BAD_ARG, fixture.driverBase(rb).SetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, 0x1_0000, &hook));
    try testing.expectEqual(transfers, monitor.transfers);
    try fixture.tearDown(rb);
}
