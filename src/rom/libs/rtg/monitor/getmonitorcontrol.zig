// SPDX-License-Identifier: MPL-2.0
//! GetMonitorControl: A monitor's own control asked for over its DDC.
//!
//! The question and the answer are DDC/CI's (`_ddcci.zig`); the bus is
//! the driver's, reached through its hook.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const ddcci = @import("_ddcci.zig");

/// Asks a monitor for one of its own controls over its DDC.
///
/// SYNOPSIS:
/// ```zig
/// fn GetMonitorControl(rb: *RtgBase, code: u32, transfer: *utility.Hook, value: *u32, most: *u32) i32
/// ```
///
/// SINCE: 1.44. LVO -336.
///
/// INPUTS:
/// - `code` - the control, by MCCS's code: `RTGVCP_BRIGHTNESS`,
///   `RTGVCP_CONTRAST` or another below 256.
/// - `transfer` - the driver's hook, called with null as its object and
///   an `RtgDdcTransfer` as its message for each transfer on the bus: the
///   question written, then the answer read. It answers `RTGERR_OK` once
///   the bytes went or came, `RTGERR_IO` where the monitor did not
///   answer.
/// - `value` - where the control's value goes.
/// - `most` - where its largest value goes.
///
/// RESULT:
/// `RTGERR_OK`, and both written. `RTGERR_NOT_SUPPORTED` for a control
/// the monitor says it has not got, or one whose largest value it says
/// is 0. `RTGERR_IO` where its answer is not one DDC/CI answers with -
/// a monitor that is not ready, a checksum that does not add up, an
/// answer about another control. `RTGERR_BAD_ARG` for a code past 255.
/// Otherwise what the hook answered. Neither is written but on
/// `RTGERR_OK`.
///
/// BEHAVIOR:
/// The question is five bytes written to the monitor at 0x37: the host's
/// address, the length, the opcode, the control and the checksum. The
/// monitor is given 40 ms to answer (`RtgDelay`), and its eleven bytes
/// are read: the length, the reply's opcode, whether it has the
/// control, the control, its kind, its largest value and its value, each
/// high byte first, and the checksum.
///
/// CONTEXT:
/// - Waits: yes, the 40 ms, and as long as the hook does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held; the driver keeps other talk on the
///   bus away, its own lock held around the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The transfers live on this call's stack, for the hook's call alone.
///
/// NOTES:
/// A monitor that does not take DDC/CI at all - or has it switched off
/// in its own menu - answers nothing, and the hook says `RTGERR_IO`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMonitorControl`, `RtgDelay`
///
/// EXAMPLES:
/// ```zig
/// fn transfer(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
///     const port: *Port = @ptrCast(@alignCast(hook.data.?));
///     const move: *const rtg.RtgDdcTransfer = @ptrCast(@alignCast(message.?));
///     const done = port.i2c(move.address, move.read != 0, move.bytes.?[0..move.count]);
///     return @bitCast(@as(isize, if (done) rtg.errors.RTGERR_OK else rtg.errors.RTGERR_IO));
/// }
///
/// var hook: utility.Hook = .{ .entry = &transfer, .data = port };
/// var value: u32 = 0;
/// var most: u32 = 0;
/// const code = rb.GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most);
/// ```
pub fn GetMonitorControl(rb: *RtgBase, code: u32, transfer: *utility.Hook, value: *u32, most: *u32) i32 {
    if (code > 0xFF) return err.RTGERR_BAD_ARG;
    var question = ddcci.askFor(@intCast(code));
    const asked = ddcci.move(rb, transfer, false, &question);
    if (asked != err.RTGERR_OK) return asked;
    rb.driverIface().RtgDelay(ddcci.answer_us);
    var answer: [ddcci.answer_bytes]u8 = @splat(0);
    const read = ddcci.move(rb, transfer, true, &answer);
    if (read != err.RTGERR_OK) return read;
    var control: ddcci.Control = .{ .value = 0, .most = 0 };
    const answered = ddcci.answerOf(&answer, @intCast(code), &control);
    if (answered != err.RTGERR_OK) return answered;
    value.* = control.value;
    most.* = control.most;
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

/// A monitor on the tests' bus: what it was written, and what it answers
/// when read - its brightness, 30 of 80 - unless it is to answer nothing,
/// or the null message of one that is not ready.
pub const Monitor = struct {
    written: [8]u8 = @splat(0),
    written_count: u32 = 0,
    transfers: u32 = 0,
    reads: u32 = 0,
    deaf: bool = false,
    not_ready: bool = false,
    address: u32 = 0,

    pub fn transfer(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const monitor: *Monitor = @ptrCast(@alignCast(hook.data.?));
        if (object != null) return @bitCast(@as(isize, err.RTGERR_BAD_ARG));
        const move: *const rtg.RtgDdcTransfer = @ptrCast(@alignCast(message.?));
        monitor.transfers += 1;
        monitor.address = move.address;
        if (monitor.deaf) return @bitCast(@as(isize, err.RTGERR_IO));
        const bytes = move.bytes.?[0..move.count];
        if (move.read == 0) {
            @memcpy(monitor.written[0..bytes.len], bytes);
            monitor.written_count = move.count;
            return 0;
        }
        monitor.reads += 1;
        const brightness = [ddcci.answer_bytes]u8{ 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x50, 0x00, 0x1E, 0xEA };
        const nothing = [ddcci.answer_bytes]u8{ 0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(bytes, if (monitor.not_ready) &nothing else &brightness);
        return 0;
    }
};

test "GetMonitorControl: the question written, 40 ms given, the answer read" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();
    const sent = fixture.FakeTimer.sent;
    var monitor: Monitor = .{};
    var hook: utility.Hook = .{ .entry = &Monitor.transfer, .data = &monitor };
    var value: u32 = 0;
    var most: u32 = 0;

    try testing.expectEqual(err.RTGERR_OK, fixture.driverBase(rb).GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most));
    try testing.expectEqual(@as(u32, 30), value);
    try testing.expectEqual(@as(u32, 80), most);
    try testing.expectEqual(@as(u32, 0x37), monitor.address);
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x82, 0x01, 0x10, 0xAC }, monitor.written[0..monitor.written_count]);
    try testing.expectEqual(sent + 1, fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u64, 40_000), fixture.FakeTimer.last_micros);

    // Asked for another control, it answers about the brightness.
    value = 0;
    try testing.expectEqual(err.RTGERR_IO, fixture.driverBase(rb).GetMonitorControl(rtg.modes.RTGVCP_CONTRAST, &hook, &value, &most));
    try testing.expectEqual(@as(u32, 0), value);
    // Not ready, and not answering: nothing written, the hook's answer.
    monitor.not_ready = true;
    try testing.expectEqual(err.RTGERR_IO, fixture.driverBase(rb).GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most));
    monitor.deaf = true;
    const reads = monitor.reads;
    try testing.expectEqual(err.RTGERR_IO, fixture.driverBase(rb).GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most));
    try testing.expectEqual(reads, monitor.reads);
    try testing.expectEqual(@as(u32, 0), value);
    // A code past MCCS's.
    try testing.expectEqual(err.RTGERR_BAD_ARG, fixture.driverBase(rb).GetMonitorControl(0x110, &hook, &value, &most));
    try fixture.tearDown(rb);
}
