// SPDX-License-Identifier: MPL-2.0
//! RunPanelSequence: A panel's bring-up checked whole, then walked.
//!
//! The bytes are a board list's (`RTGA_InitSequence`), a step after
//! another: the command, the number of its parameters, the milliseconds
//! to wait after it, then the parameters. The library knows the steps;
//! how a command reaches the panel - a bus, a DSI host - is the driver's
//! hook.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;

/// The bytes a step has before its parameters.
const step_head = 3;

/// Whether `bytes` is whole steps and nothing else.
///
/// INPUTS:
/// - `bytes` - the sequence.
fn whole(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes.len - at < step_head) return false;
        const length = step_head + @as(usize, bytes[at + 1]);
        if (bytes.len - at < length) return false;
        at += length;
    }
    return true;
}

/// Sends a panel's bring-up, step by step, each with its wait.
///
/// SYNOPSIS:
/// ```zig
/// fn RunPanelSequence(rb: *RtgBase, sequence: [*]const u8, length: u32, send: *utility.Hook) i32
/// ```
///
/// SINCE: 1.40. LVO -328.
///
/// INPUTS:
/// - `sequence` - the steps, as `RTGA_InitSequence` points at them: the
///   command, the number of its parameters, the milliseconds to wait
///   after it, then the parameters.
/// - `length` - their bytes, `RTGA_InitLength`; 0 sends nothing.
/// - `send` - the driver's hook, called for each step with null as its
///   object and an `RtgPanelStep` as its message. It answers
///   `RTGERR_OK` once the step has gone, or the error that stopped it.
///
/// RESULT:
/// `RTGERR_OK`, every step sent and waited for. `RTGERR_BAD_TAGS` for
/// bytes that are not whole steps - a step's parameters running past the
/// end, a step cut short - and nothing is sent. Otherwise the first
/// answer of `send` that is not `RTGERR_OK`.
///
/// BEHAVIOR:
/// The whole sequence is looked at before its first step is sent, so a
/// panel is never left half brought up by a sequence that is written
/// wrong. Then each step is handed to `send` in order, and after each
/// that has a wait the task waits that many milliseconds (`RtgDelay`).
/// A step `send` refuses ends the walk: the steps after it are not sent,
/// and its wait is not waited.
///
/// CONTEXT:
/// - Waits: yes, for each step's wait, and as long as `send` does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are the caller's and only read. The step `send` is handed
/// lives on this call's stack for the hook's call alone.
///
/// NOTES:
/// A panel whose bring-up begins with a reset gets that from its driver
/// first: the reset line, or the command where there is none, and the
/// part's settling time (`RTGA_ResetMillis`, `RTGA_SettleMillis`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtgDelay`, `TxParam`
///
/// EXAMPLES:
/// ```zig
/// fn sendStep(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
///     const panel: *Panel = @ptrCast(@alignCast(hook.data.?));
///     const step: *const rtg.RtgPanelStep = @ptrCast(@alignCast(message.?));
///     const code = panel.rtg_base.TxParam(panel.io, @intCast(step.command), step.params, step.count);
///     return @bitCast(@as(isize, code));
/// }
///
/// var hook: utility.Hook = .{ .entry = &sendStep, .data = panel };
/// const code = rb.RunPanelSequence(bring_up.ptr, @intCast(bring_up.len), &hook);
/// ```
pub fn RunPanelSequence(rb: *RtgBase, sequence: [*]const u8, length: u32, send: *utility.Hook) i32 {
    const bytes = sequence[0..length];
    if (!whole(bytes)) return err.RTGERR_BAD_TAGS;
    var at: usize = 0;
    while (at < bytes.len) {
        const count = bytes[at + 1];
        var step: rtg.RtgPanelStep = .{
            .command = bytes[at],
            .count = count,
            .params = if (count != 0) bytes[at + step_head ..].ptr else null,
            .delay_ms = bytes[at + 2],
        };
        const answer = rb.utility_base.CallHookPkt(send, null, &step);
        const code: i32 = @bitCast(@as(u32, @truncate(answer)));
        if (code != err.RTGERR_OK) return code;
        if (step.delay_ms != 0) rb.driverIface().RtgDelay(step.delay_ms * 1000);
        at += step_head + @as(usize, count);
    }
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

/// What the tests' hook was handed: the steps' commands, their
/// parameters one after another, and the step it refuses (counted from
/// 1; 0 refuses none).
const Panel = struct {
    commands: [8]u32 = undefined,
    params: [16]u8 = undefined,
    steps: u32 = 0,
    param_bytes: u32 = 0,
    refuse_at: u32 = 0,

    fn send(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const panel: *Panel = @ptrCast(@alignCast(hook.data.?));
        if (object != null) return @bitCast(@as(isize, err.RTGERR_BAD_ARG));
        const step: *const rtg.RtgPanelStep = @ptrCast(@alignCast(message.?));
        panel.steps += 1;
        if (panel.steps == panel.refuse_at) return @bitCast(@as(isize, err.RTGERR_IO));
        panel.commands[panel.steps - 1] = step.command;
        if (step.count != 0) {
            @memcpy(panel.params[panel.param_bytes..][0..step.count], step.params.?[0..step.count]);
            panel.param_bytes += step.count;
        } else if (step.params != null) {
            return @bitCast(@as(isize, err.RTGERR_BAD_ARG));
        }
        return 0;
    }
};

test "RunPanelSequence: each step handed on in order, its wait waited by the clock" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    // Three steps as a board's list holds them: a command with one
    // parameter, one with none and a wait of 120 ms, one with four.
    const bytes = [_]u8{ 0xF1, 1, 0, 0x00 } ++ [_]u8{ 0x11, 0, 120 } ++ [_]u8{ 0x2A, 4, 0, 0x00, 0x00, 0x01, 0x3F };
    var panel: Panel = .{};
    var hook: utility.Hook = .{ .entry = &Panel.send, .data = &panel };
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();
    const sent = fixture.FakeTimer.sent;

    try testing.expectEqual(err.RTGERR_OK, fixture.driverBase(rb).RunPanelSequence(&bytes, bytes.len, &hook));
    try testing.expectEqual(@as(u32, 3), panel.steps);
    try testing.expectEqualSlices(u32, &.{ 0xF1, 0x11, 0x2A }, panel.commands[0..3]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x01, 0x3F }, panel.params[0..panel.param_bytes]);
    // One wait, the second step's, slept on timer.device.
    try testing.expectEqual(sent + 1, fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u64, 120_000), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 1), fixture.Sleep.sleeps);

    // Nothing to send is done at once.
    try testing.expectEqual(err.RTGERR_OK, fixture.driverBase(rb).RunPanelSequence(&bytes, 0, &hook));
    try testing.expectEqual(@as(u32, 3), panel.steps);
    try fixture.tearDown(rb);
}

test "RunPanelSequence: a sequence written wrong sends nothing; a step refused ends the walk" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    var panel: Panel = .{};
    var hook: utility.Hook = .{ .entry = &Panel.send, .data = &panel };

    // A whole step, then four parameters promised and three there; then
    // a step cut short before its count.
    const runs_past = [_]u8{ 0x11, 0, 0 } ++ [_]u8{ 0x2A, 4, 0, 1, 2, 3 };
    try testing.expectEqual(err.RTGERR_BAD_TAGS, fixture.driverBase(rb).RunPanelSequence(&runs_past, runs_past.len, &hook));
    const cut_short = [_]u8{ 0x11, 0, 0 } ++ [_]u8{0x29};
    try testing.expectEqual(err.RTGERR_BAD_TAGS, fixture.driverBase(rb).RunPanelSequence(&cut_short, cut_short.len, &hook));
    try testing.expectEqual(@as(u32, 0), panel.steps);

    // The second of three refused: its answer, and the third not sent.
    const three = [_]u8{ 0x01, 0, 0 } ++ [_]u8{ 0x11, 0, 0 } ++ [_]u8{ 0x29, 0, 0 };
    panel.refuse_at = 2;
    try testing.expectEqual(err.RTGERR_IO, fixture.driverBase(rb).RunPanelSequence(&three, three.len, &hook));
    try testing.expectEqual(@as(u32, 2), panel.steps);
    try testing.expectEqual(@as(u32, 0x01), panel.commands[0]);
    try fixture.tearDown(rb);
}
