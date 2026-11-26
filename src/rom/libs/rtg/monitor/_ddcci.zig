// SPDX-License-Identifier: MPL-2.0
//! A monitor's own controls over its DDC (VESA's DDC/CI), as
//! `GetMonitorControl` and `SetMonitorControl` speak them: the messages
//! and their checksums, the answer read, and a transfer handed to the
//! driver's hook.
//!
//! The monitor is at 0x37 on the bus. A message to it starts with the
//! host's address, 0x51, then its length with the top bit set, its
//! opcode and what follows it, and ends with a checksum: every byte
//! XORed into 0x6E, the monitor's address as written. Its answer starts
//! with 0x6E and its checksum begins with 0x50, the host's address as
//! read. The monitor wants 40 ms to answer and 50 ms after a control is
//! set before it is spoken to again.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;

/// The monitor's place on the bus, and the host's in a message.
pub const address: u32 = 0x37;
const host: u8 = 0x51;

/// The opcodes: a control asked for, its answer, a control set.
const get: u8 = 0x01;
const reply: u8 = 0x02;
const set: u8 = 0x03;

/// Where each checksum starts: the monitor's address written, the host's
/// answered to.
const written_sum: u8 = 0x6E;
const answer_sum: u8 = 0x50;

/// The time the monitor wants to answer, and after a control is set.
pub const answer_us: u32 = 40_000;
pub const set_us: u32 = 50_000;

/// How long a question, an answer and a setting are.
pub const question_bytes = 5;
pub const answer_bytes = 11;
pub const setting_bytes = 7;

/// What a message's checksum makes of `from` and its bytes: each XORed
/// in.
///
/// INPUTS:
/// - `from` - where the sum starts.
/// - `bytes` - what it sums.
fn checksum(from: u8, bytes: []const u8) u8 {
    var sum = from;
    for (bytes) |byte| sum ^= byte;
    return sum;
}

/// The message that asks for control `code`: from the host, two bytes
/// long, the opcode and the control, and the checksum.
///
/// INPUTS:
/// - `code` - the control.
pub fn askFor(code: u8) [question_bytes]u8 {
    var message = [question_bytes]u8{ host, 0x80 | 2, get, code, 0 };
    message[4] = checksum(written_sum, message[0..4]);
    return message;
}

/// The message that sets control `code` to `value`, high byte first.
///
/// INPUTS:
/// - `code` - the control.
/// - `value` - what it is set to.
pub fn setTo(code: u8, value: u16) [setting_bytes]u8 {
    var message = [setting_bytes]u8{ host, 0x80 | 4, set, code, @truncate(value >> 8), @truncate(value), 0 };
    message[6] = checksum(written_sum, message[0..6]);
    return message;
}

/// A control's value as the monitor answers it, and its largest.
pub const Control = struct { value: u16, most: u16 };

/// The monitor's answer about control `code` into `into`: from the
/// monitor, eight bytes long, a reply about that control, its largest
/// value and its value, with a checksum that adds up. RTGERR_OK;
/// RTGERR_NOT_SUPPORTED where it says it has not got the control, or
/// that it reaches no further than 0; RTGERR_IO for anything else - a
/// monitor that was not ready, a checksum that does not add up - and
/// `into` is left.
///
/// INPUTS:
/// - `answer` - the bytes read.
/// - `code` - the control asked for.
/// - `into` - where its value and its largest go.
pub fn answerOf(answer: *const [answer_bytes]u8, code: u8, into: *Control) i32 {
    if (answer[0] != written_sum or answer[1] != 0x80 | 8) return err.RTGERR_IO;
    if (answer[2] != reply or answer[4] != code) return err.RTGERR_IO;
    if (checksum(answer_sum, answer[0..10]) != answer[10]) return err.RTGERR_IO;
    if (answer[3] != 0) return err.RTGERR_NOT_SUPPORTED;
    const most = @as(u16, answer[6]) << 8 | answer[7];
    if (most == 0) return err.RTGERR_NOT_SUPPORTED;
    into.* = .{ .value = @as(u16, answer[8]) << 8 | answer[9], .most = most };
    return err.RTGERR_OK;
}

/// `bytes` written to the monitor, or read from it, by the driver's hook
/// `transfer`: what the hook answered.
///
/// INPUTS:
/// - `rb` - the library.
/// - `transfer` - the driver's hook.
/// - `reading` - whether the bytes are read into.
/// - `bytes` - the bytes.
pub fn move(rb: *RtgBase, transfer: *utility.Hook, reading: bool, bytes: []u8) i32 {
    var message: rtg.RtgDdcTransfer = .{
        .address = address,
        .read = @intFromBool(reading),
        .bytes = bytes.ptr,
        .count = @intCast(bytes.len),
    };
    const answer = rb.utility_base.CallHookPkt(transfer, null, &message);
    return @bitCast(@as(u32, @truncate(answer)));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "DDC/CI: the messages and the answers" {
    // The brightness asked for, and set to 50: the checksum starts from
    // the monitor's address, 0x6E.
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x82, 0x01, 0x10, 0xAC }, &askFor(0x10));
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A }, &setTo(0x10, 50));
    // The answer: 50 of 100, its checksum from the host's 0x50.
    var answer = [answer_bytes]u8{ 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
    var got: Control = .{ .value = 0, .most = 0 };
    try testing.expectEqual(err.RTGERR_OK, answerOf(&answer, 0x10, &got));
    try testing.expectEqual(@as(u16, 50), got.value);
    try testing.expectEqual(@as(u16, 100), got.most);
    // About another control.
    try testing.expectEqual(err.RTGERR_IO, answerOf(&answer, 0x12, &got));
    // A checksum that does not add up.
    answer[10] ^= 1;
    try testing.expectEqual(err.RTGERR_IO, answerOf(&answer, 0x10, &got));
    // A control the monitor has not got, its checksum right.
    answer[3] = 1;
    try testing.expectEqual(err.RTGERR_NOT_SUPPORTED, answerOf(&answer, 0x10, &got));
    // Not ready: the null message.
    const nothing = [answer_bytes]u8{ 0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(err.RTGERR_IO, answerOf(&nothing, 0x10, &got));
}
