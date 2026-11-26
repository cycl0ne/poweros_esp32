// SPDX-License-Identifier: MPL-2.0
//! The DDC of the BCM2712's first HDMI port: the I2C master the monitor
//! is asked over - its EDID, and any transfer rtg.library's DDC/CI calls
//! hand the driver (`transfer`) - and told over, where it takes HDMI
//! 2.0's scrambling.
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

/// `bytes` written to the 7-bit `address` in one transaction - a start,
/// the address, the bytes, a stop - or read from it into `bytes`, in
/// pieces of 32 bytes the last of which ends with the stop. False when
/// the target did not answer, and for a write of more than 32 bytes,
/// which is not sent.
pub fn transfer(port: *const bcm2712.Port, address: u8, read: bool, bytes: []u8, waiter: anytype) bool {
    if (!bcm2712.on_bcm2712 or bytes.len == 0) return false;
    if (!read) {
        if (bytes.len > bsc_chunk) return false;
        bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = @as(u32, address) << 1;
        return send(port, 0, bytes, waiter);
    }
    bcm2712.at(port.blocks.ddc, BSC_CHIP_ADDRESS).* = @as(u32, address) << 1 | 1;
    var done: usize = 0;
    while (done < bytes.len) : (done += bsc_chunk) {
        const piece = @min(bsc_chunk, bytes.len - done);
        const condition = readCondition(done == 0, done + piece >= bytes.len);
        if (!receive(port, condition, bytes[done .. done + piece], waiter)) return false;
    }
    return true;
}

/// How many blocks of a monitor's EDID the port reads: the two halves of
/// its first segment.
pub const edid_blocks: u32 = 2;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the BCM2712's DDC: how the pieces of a read end and start" {
    try testing.expectEqual(COND_NOSTOP, readCondition(true, false));
    try testing.expectEqual(COND_NOSTART | COND_NOSTOP, readCondition(false, false));
    try testing.expectEqual(COND_NOSTART, readCondition(false, true));
}
