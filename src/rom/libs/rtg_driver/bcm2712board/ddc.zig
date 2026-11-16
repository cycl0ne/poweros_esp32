// SPDX-License-Identifier: MPL-2.0
//! The DDC of the BCM2712's first HDMI port: the I2C master the monitor
//! is asked over - its EDID, and with DDC/CI what it keeps itself, its
//! brightness - and told over, where it takes HDMI 2.0's scrambling.
//!
//! The master is a block of its own beside the HDMI controller's
//! (`bcm2712.zig`), which holds the port's other registers and brings
//! the port up; what is here only talks to the monitor. One task talks on
//! it at a time: the driver holds its port's lock around every call.

const bcm2712 = @import("bcm2712.zig");

/// The monitor's SCDC, on the DDC: the TMDS configuration - the bit
/// clock at a fortieth of the TMDS clock, the scrambling - and the
/// scrambler's status.
const SCDC_ADDRESS: u32 = 0x54;

const SCDC_TMDS_CONFIG: u8 = 0x20;

const SCDC_RATIO_40: u8 = 1 << 1;

const BSC_CHIP_ADDRESS = 0x00;

const BSC_DATA_IN = 0x04;

const BSC_CNT = 0x24;

const BSC_DATA_OUT = 0x30;

const BSC_CTL_INT_EN: u32 = 1 << 6;

const BSC_CTL_READ: u32 = 1;

const BSC_ENABLE: u32 = 1 << 0;

const BSC_DONE: u32 = 1 << 1;

const BSC_NOACK: u32 = 1 << 2;

/// What a piece of a transfer is to end and start with.
const COND_NOSTOP: u32 = 1 << 4;

const COND_NOSTART: u32 = 1 << 5;

const COND_RESTART: u32 = 1 << 6;

const bsc_chunk = 32;

const EDID_ADDRESS: u32 = 0x50;

/// The monitor's own controls over the DDC (VESA's DDC/CI): its address,
/// the host's in a message, the opcodes - a control asked for, its
/// answer, a control set - and the address each checksum starts from,
/// the monitor's when it is written to and the host's when it answers.
/// The monitor wants 40 ms to answer and 50 ms after a control is set.
const DDCCI_ADDRESS: u32 = 0x37;

const DDCCI_HOST: u8 = 0x51;

const DDCCI_GET: u8 = 0x01;

const DDCCI_REPLY: u8 = 0x02;

const DDCCI_SET: u8 = 0x03;

const DDCCI_WRITTEN_SUM: u8 = 0x6E;

const DDCCI_ANSWER_SUM: u8 = 0x50;

const ddcci_answer_us = 40_000;

const ddcci_set_us = 50_000;

/// MCCS's control for the brightness: the luminance.
pub const VCP_BRIGHTNESS: u8 = 0x10;

/// What each piece of a read of `length` bytes is to end and start with,
/// as Linux's brcmstb_i2c_xfer has a read after its write: the first
/// starts again after the write and keeps the bus, the ones after go on
/// without a start, the last ends with a stop.
fn readCondition(first: bool, last: bool) u32 {
    if (first and last) return 0;
    if (first) return COND_NOSTOP;
    if (last) return COND_NOSTART;
    return COND_NOSTART | COND_NOSTOP;
}

/// One piece of a transfer of `length` bytes started - written from
/// the data words, or read into them - ending and starting as
/// `condition` says. False when the target did not answer, or the
/// controller did not finish in 100 ms (brcmstb_send_i2c_cmd).
fn run(port: *const bcm2712.Port, condition: u32, read: bool, length: usize, waiter: anytype) bool {
    const control = bcm2712.BSC_CTL_97K | (if (read) BSC_CTL_READ else 0);
    bcm2712.at(port.blocks.ddc, bcm2712.BSC_CTLHI).* = bcm2712.BSC_CTLHI_WORDS;
    bcm2712.at(port.blocks.ddc, BSC_CNT).* = @intCast(length & 0x3F);
    bcm2712.at(port.blocks.ddc, bcm2712.BSC_CTL).* = control | BSC_CTL_INT_EN;
    bcm2712.at(port.blocks.ddc, bcm2712.BSC_IIC_ENABLE).* = condition | BSC_ENABLE;
    var waited: u32 = 0;
    while (bcm2712.at(port.blocks.ddc, bcm2712.BSC_IIC_ENABLE).* & BSC_DONE == 0 and waited < 100) : (waited += 1) waiter.wait(1000);
    const status = bcm2712.at(port.blocks.ddc, bcm2712.BSC_IIC_ENABLE).*;
    bcm2712.at(port.blocks.ddc, bcm2712.BSC_CTL).* = control;
    bcm2712.at(port.blocks.ddc, BSC_CNT).* = 0;
    bcm2712.at(port.blocks.ddc, bcm2712.BSC_IIC_ENABLE).* = 0;
    return status & BSC_DONE != 0 and status & BSC_NOACK == 0;
}

/// Up to 32 bytes written, four to a data word, the first in its low
/// byte.
fn send(port: *const bcm2712.Port, condition: u32, bytes: []const u8, waiter: anytype) bool {
    var i: usize = 0;
    while (i * 4 < bytes.len) : (i += 1) {
        var data: u32 = 0;
        for (0..4) |byte| {
            if (i * 4 + byte < bytes.len) data |= @as(u32, bytes[i * 4 + byte]) << @intCast(byte * 8);
        }
        bcm2712.at(port.blocks.ddc, BSC_DATA_IN + i * 4).* = data;
    }
    return run(port, condition, false, bytes.len, waiter);
}

/// Up to 32 bytes read into `into`.
fn receive(port: *const bcm2712.Port, condition: u32, into: []u8, waiter: anytype) bool {
    if (!run(port, condition, true, into.len, waiter)) return false;
    var i: usize = 0;
    while (i * 4 < into.len) : (i += 1) {
        const data = bcm2712.at(port.blocks.ddc, BSC_DATA_OUT + i * 4).*;
        for (0..4) |byte| {
            if (i * 4 + byte < into.len) into[i * 4 + byte] = @truncate(data >> @intCast(byte * 8));
        }
    }
    return true;
}

/// Block `number` of the monitor's EDID into `block` - 0 or 1, the two
/// halves of its first segment: the offset written to the EDID's address,
/// then the block read in pieces of 32 bytes. False when the monitor did
/// not answer. Only once `wake` has the DDC ready.
pub fn readEdid(port: *const bcm2712.Port, number: u8, block: *[128]u8, waiter: anytype) bool {
    if (!bcm2712.on_bcm2712 or number > 1) return false;
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = EDID_ADDRESS << 1;
    const offset = [1]u8{number * 128};
    if (!send(port, COND_RESTART | COND_NOSTOP, &offset, waiter)) return false;
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = EDID_ADDRESS << 1 | 1;
    var done: usize = 0;
    while (done < block.len) : (done += bsc_chunk) {
        const condition = readCondition(done == 0, done + bsc_chunk >= block.len);
        if (!receive(port, condition, block[done .. done + bsc_chunk], waiter)) return false;
    }
    return true;
}

/// SCDC register `offset` of the monitor's, read: the offset written,
/// then a byte read. Null when the monitor did not answer.
pub fn scdcRead(port: *const bcm2712.Port, offset: u8, waiter: anytype) ?u8 {
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1;
    if (!send(port, COND_RESTART | COND_NOSTOP, &.{offset}, waiter)) return null;
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1 | 1;
    var value = [1]u8{0};
    if (!receive(port, readCondition(true, true), &value, waiter)) return null;
    return value[0];
}

/// SCDC register `offset` written with `value`.
fn scdcWrite(port: *const bcm2712.Port, offset: u8, value: u8, waiter: anytype) bool {
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1;
    return send(port, 0, &.{ offset, value }, waiter);
}

/// The monitor told to take scrambled TMDS at a bit clock of a fortieth,
/// or the TMDS as it was (drm_scdc_set_high_tmds_clock_ratio, then
/// drm_scdc_set_scrambling): its TMDS configuration's two bits.
pub fn scdcScrambling(port: *const bcm2712.Port, on: bool, waiter: anytype) bool {
    const config = scdcRead(port, SCDC_TMDS_CONFIG, waiter) orelse return false;
    const both = SCDC_RATIO_40 | bcm2712.SCDC_SCRAMBLING;
    return scdcWrite(port, SCDC_TMDS_CONFIG, if (on) config | both else config & ~both, waiter);
}

/// A control's value as the monitor answers it, and its largest.
const Feature = struct { value: u16, most: u16 };

/// What a message's checksum makes of `from` and its bytes: each XORed
/// in.
fn checksum(from: u8, bytes: []const u8) u8 {
    var sum = from;
    for (bytes) |byte| sum ^= byte;
    return sum;
}

/// The message that asks for control `code`: from the host, two bytes
/// long, the opcode and the control, and the checksum.
fn askFor(code: u8) [5]u8 {
    var message = [5]u8{ DDCCI_HOST, 0x80 | 2, DDCCI_GET, code, 0 };
    message[4] = checksum(DDCCI_WRITTEN_SUM, message[0..4]);
    return message;
}

/// The message that sets control `code` to `value`, high byte first.
fn setTo(code: u8, value: u16) [7]u8 {
    var message = [7]u8{ DDCCI_HOST, 0x80 | 4, DDCCI_SET, code, @truncate(value >> 8), @truncate(value), 0 };
    message[6] = checksum(DDCCI_WRITTEN_SUM, message[0..6]);
    return message;
}

/// The monitor's answer about control `code`: from the monitor, eight
/// bytes long, a reply that it has the control, its largest value and
/// its value, and a checksum that adds up. Null for anything else - a
/// monitor that has not got the control, or was not ready.
fn answerOf(answer: *const [11]u8, code: u8) ?Feature {
    if (answer[0] != DDCCI_WRITTEN_SUM or answer[1] != 0x80 | 8) return null;
    if (answer[2] != DDCCI_REPLY or answer[3] != 0 or answer[4] != code) return null;
    if (checksum(DDCCI_ANSWER_SUM, answer[0..10]) != answer[10]) return null;
    const most = @as(u16, answer[6]) << 8 | answer[7];
    if (most == 0) return null;
    return .{ .value = @as(u16, answer[8]) << 8 | answer[9], .most = most };
}

/// The monitor's control `code`, asked for over the DDC: null when it
/// does not answer. Takes some 50 ms.
pub fn feature(port: *const bcm2712.Port, code: u8, waiter: anytype) ?Feature {
    if (!bcm2712.on_bcm2712) return null;
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1;
    if (!send(port, 0, &askFor(code), waiter)) return null;
    waiter.wait(ddcci_answer_us);
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1 | 1;
    var answer: [11]u8 = undefined;
    if (!receive(port, readCondition(true, true), &answer, waiter)) return null;
    return answerOf(&answer, code);
}

/// The monitor's control `code` set to `value`, and the time it wants
/// before it is spoken to again waited out: false when it did not take
/// the message.
pub fn setFeature(port: *const bcm2712.Port, code: u8, value: u16, waiter: anytype) bool {
    if (!bcm2712.on_bcm2712) return false;
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1;
    const taken = send(port, 0, &setTo(code, value), waiter);
    waiter.wait(ddcci_set_us);
    return taken;
}

/// How many blocks of a monitor's EDID the port reads: the two halves of
/// its first segment.
pub const edid_blocks: u32 = 2;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the monitor's controls: DDC/CI's messages and answers" {
    // The brightness asked for, and set to 50: the checksum starts from
    // the monitor's address, 0x6E.
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x82, 0x01, 0x10, 0xAC }, &askFor(VCP_BRIGHTNESS));
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A }, &setTo(VCP_BRIGHTNESS, 50));
    // The answer: 50 of 100, its checksum from the host's 0x50.
    var answer = [11]u8{ 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
    const got = answerOf(&answer, VCP_BRIGHTNESS).?;
    try testing.expectEqual(@as(u16, 50), got.value);
    try testing.expectEqual(@as(u16, 100), got.most);
    // A checksum that does not add up, a control the monitor has not got.
    answer[10] ^= 1;
    try testing.expect(answerOf(&answer, VCP_BRIGHTNESS) == null);
    answer[10] ^= 1;
    answer[3] = 1;
    answer[10] ^= 1;
    try testing.expect(answerOf(&answer, VCP_BRIGHTNESS) == null);
    // Not ready: the null message.
    const nothing = [11]u8{ 0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expect(answerOf(&nothing, VCP_BRIGHTNESS) == null);
}

test "the BCM2712's DDC: how the pieces of a read end and start" {
    try testing.expectEqual(COND_NOSTOP, readCondition(true, false));
    try testing.expectEqual(COND_NOSTART | COND_NOSTOP, readCondition(false, false));
    try testing.expectEqual(COND_NOSTART, readCondition(false, true));
}
