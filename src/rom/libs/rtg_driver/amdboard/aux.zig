// SPDX-License-Identifier: MPL-2.0
//! A socket's AUX channel: driven by its own AUX engine's registers, or
//! made ready for the display controller to use.
//!
//! Each DDC line's two pins serve either I2C - an HDMI or DVI monitor's
//! EDID - or DisplayPort's AUX channel, by the pad's mode; and each line
//! has an AUX engine of its own, which drives the channel. The line's pad
//! is put into AUX mode - its mode bit set, its I2C mode cleared - and
//! driven by the engine (its GPIO masks cleared, which it gets back
//! after); the engine is switched on, reset on the way where it was off,
//! and asked for at its arbitration register. An engine the controller
//! holds for itself is left alone.
//!
//! **A transaction by the engine** (`transfer`): its done flag
//! acknowledged and waited for to clear, the header written into its
//! buffer - the command and the address's top four bits, the address's
//! other two bytes, the length less one where there is a length - then a
//! write's bytes, and the engine told how many bytes to send and to go.
//! It is waited for until it says it is done, 2.4 ms at the most; a
//! socket with nothing on it says so (`unplugged`), and a reply that
//! timed out or came broken is told apart from one that came. The reply's
//! first byte holds the sink's answer in its top four bits - an ACK, a
//! NACK or a DEFER, for the AUX channel and for the I2C bus behind it -
//! and the bytes read follow. The engine is given back after each.
//!
//! **The EDID over AUX** (`readEdid`) is I2C over AUX: each message
//! starts with a bare address packet that keeps the bus (middle of
//! transaction), its bytes go 16 at a time, and a bare packet without it
//! ends the whole; a DEFER is waited out and asked again, seven times at
//! the most. The blocks are those the I2C engine reads (`i2c.zig`).
//!
//! **For the controller** (`ready`): the pad and the engine made ready
//! as above, then the engine asked for and given back once, which settles
//! who may use its registers; the controller does the transaction itself.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const tags = sdk.rtg.tags;
const dcn = @import("dcn.zig");
const i2c = @import("i2c.zig");

/// How many lines there are with an AUX engine.
pub const lines = 5;

/// The first line's pad mask register and each next one's step; the
/// register holding every pad's I2C mode.
const pad_mask_at = 0x28d0;
const pad_mask_stride = 4;
const pad_control_5 = 0x291d;

/// The first engine's control and arbitration registers and each next
/// engine's step.
const aux_control_at = 0x1f50;
const aux_sw_control_at = 0x1f51;
const aux_arbitration_at = 0x1f52;
const aux_interrupt_at = 0x1f53;
const aux_status_at = 0x1f54;
const aux_data_at = 0x1f56;
const aux_receive_at = 0x1f5a;
const aux_stride = 0x1c;

/// Their bits.
const pad_aux_mode: u32 = 1 << 16;
const pad_i2c_mode_first: u32 = 1 << 12;
const aux_enable: u32 = 1 << 0;
const aux_reset: u32 = 1 << 4;
const aux_reset_done: u32 = 1 << 5;
const arbitration_owner_mask: u32 = 0x3 << 2;
const arbitration_controller_owns: u32 = 2 << 2;
const arbitration_software_owns: u32 = 1 << 2;
const arbitration_request: u32 = 1 << 16;
const arbitration_done: u32 = 1 << 17;
const pad_clock_mask: u32 = 1 << 0;
const pad_data_mask: u32 = 1 << 8;

/// AUX_SW_CONTROL's: go, how many bytes to send.
const sw_go: u32 = 1 << 0;
const sw_start_delay_mask: u32 = 0xf << 4;
const sw_bytes_shift = 16;
const sw_bytes_mask: u32 = 0x1f << sw_bytes_shift;
/// AUX_INTERRUPT_CONTROL's acknowledge of done.
const interrupt_done_ack: u32 = 1 << 1;
/// AUX_SW_STATUS's: done, the reply's time out, nothing on the socket,
/// a broken reply, how many bytes came.
const status_done: u32 = 1 << 0;
const status_timeout_state: u32 = 0x7 << 4;
const status_timeout: u32 = 1 << 7;
const status_unplugged: u32 = 1 << 9;
const status_invalid_stop: u32 = 1 << 14;
const status_no_detect: u32 = 1 << 20;
const status_invalid_high: u32 = 1 << 22;
const status_invalid_low: u32 = 1 << 23;
const status_count_shift = 24;
const status_count_mask: u32 = 0x1f;
/// AUX_SW_DATA's: reading, the byte, where in the buffer, that place not
/// moved on.
const data_read: u32 = 1 << 0;
const data_shift = 8;
const data_mask: u32 = 0xff << data_shift;
const data_index_mask: u32 = 0x1f << 16;
const data_hold_index: u32 = 1 << 31;

/// How long a transaction is waited for: six times the engine's own
/// 400 us, in steps of 10.
const polling_us = 6 * 400;
const polling_step_us = 10;

/// The commands, in the header's top four bits: I2C's write, read and
/// keep-the-bus, DPCD's write and read.
pub const i2c_write: u32 = 0x00;
pub const i2c_read: u32 = 0x10;
pub const i2c_more: u32 = 0x40;
pub const dpcd_write: u32 = 0x80;
pub const dpcd_read: u32 = 0x90;

/// A reply's answers: the channel's in its low two bits, the I2C bus's in
/// the next two.
const reply_native_mask: u32 = 0x3;
const reply_nack: u32 = 0x1;
const reply_defer: u32 = 0x2;
const reply_i2c_shift = 2;

/// The most a transaction carries, and the most tries of a DEFER.
pub const most_bytes = 16;
const defer_tries = 7;
const defer_wait_us = 500;

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

/// Where line `line`'s registers are.
pub fn padMask(line: u32) u32 {
    return pad_mask_at + line * pad_mask_stride;
}

pub fn auxControl(line: u32) u32 {
    return aux_control_at + line * aux_stride;
}

/// Line `line`'s engine's control, arbitration, status and receive
/// registers into `into`.
pub fn read(engine: dcn.Engine, line: u32, into: *[4]u32) void {
    if (line >= lines) return;
    const step = line * aux_stride;
    into.* = .{
        at(engine, aux_control_at + step).*,
        at(engine, aux_arbitration_at + step).*,
        at(engine, aux_status_at + step).*,
        at(engine, aux_receive_at + step).*,
    };
}

/// Line `line`'s pad in AUX mode and its engine on: false for a line
/// that has none, or whose engine the controller holds.
pub fn ready(engine: dcn.Engine, line: u32) bool {
    if (line >= lines) return false;
    padToAux(engine, line);
    if (!switchOn(engine, line)) return false;
    // Asked for and given back: whoever used its registers last is done.
    const arbitration = at(engine, aux_arbitration_at + line * aux_stride);
    arbitration.* |= arbitration_request;
    arbitration.* = arbitration.* & ~arbitration_request | arbitration_done;
    return true;
}

/// The pad in AUX mode, its I2C mode cleared.
fn padToAux(engine: dcn.Engine, line: u32) void {
    const mask = at(engine, padMask(line));
    if (mask.* & pad_aux_mode == 0) mask.* |= pad_aux_mode;
    const pads = at(engine, pad_control_5);
    pads.* &= ~(pad_i2c_mode_first << @intCast(line));
}

/// The engine on, reset on the way where it was off: false where the
/// controller holds it.
fn switchOn(engine: dcn.Engine, line: u32) bool {
    const arbitration = at(engine, aux_arbitration_at + line * aux_stride);
    if (arbitration.* & arbitration_owner_mask == arbitration_controller_owns) return false;
    const control = at(engine, auxControl(line));
    if (control.* & aux_enable == 0) {
        control.* |= aux_enable | aux_reset;
        waitFor(engine.sys, control, aux_reset_done, aux_reset_done);
        control.* &= ~aux_reset;
        waitFor(engine.sys, control, aux_reset_done, 0);
    }
    return true;
}

/// How a transaction went, the sink's answer and the bytes it sent.
pub const Reply = struct {
    result: u32 = tags.RTG_AMD_AUX_OK,
    answer: u32 = 0,
    bytes: u32 = 0,
};

/// One transaction on line `line` by its engine: `command` (one of the
/// commands above, I2C's with `i2c_more` where the bus is kept) at
/// `address`, `data` written or read into - 16 bytes at the most, none
/// for a bare address packet.
pub fn transfer(engine: dcn.Engine, line: u32, command: u32, address: u32, data: []u8) Reply {
    if (line >= lines or data.len > most_bytes) return .{ .result = tags.RTG_AMD_AUX_UNKNOWN };
    const pads = at(engine, padMask(line));
    const masks = pads.* & (pad_clock_mask | pad_data_mask);
    pads.* &= ~(pad_clock_mask | pad_data_mask);
    defer pads.* = pads.* & ~(pad_clock_mask | pad_data_mask) | masks;
    padToAux(engine, line);
    if (!switchOn(engine, line)) return .{ .result = tags.RTG_AMD_AUX_BUSY };
    const arbitration = at(engine, aux_arbitration_at + line * aux_stride);
    arbitration.* |= arbitration_request;
    defer arbitration.* = arbitration.* & ~arbitration_request | arbitration_done;
    if (arbitration.* & arbitration_owner_mask != arbitration_software_owns) return .{ .result = tags.RTG_AMD_AUX_BUSY };

    const step = line * aux_stride;
    const status = at(engine, aux_status_at + step);
    at(engine, aux_interrupt_at + step).* |= interrupt_done_ack;
    _ = until(engine.sys, status, status_done, 0);
    const writes = isWrite(command);
    const count: u32 = @intCast(data.len);
    const sent = headerBytes(count) + (if (writes) count else 0);
    const sw_control = at(engine, aux_sw_control_at + step);
    sw_control.* = sw_control.* & ~(sw_start_delay_mask | sw_bytes_mask) | sent << sw_bytes_shift;
    const data_register = at(engine, aux_data_at + step);
    // The first byte at the buffer's start, the place held to write it;
    // the rest after it.
    var value = data_register.* & ~(data_index_mask | data_read | data_mask) | data_hold_index |
        (command | (address >> 16 & 0xf)) << data_shift;
    data_register.* = value;
    value = value & ~(data_hold_index | data_mask) | (address >> 8 & 0xff) << data_shift;
    data_register.* = value;
    value = value & ~data_mask | (address & 0xff) << data_shift;
    data_register.* = value;
    if (count != 0) {
        value = value & ~data_mask | (count - 1) << data_shift;
        data_register.* = value;
    }
    if (writes) {
        for (data) |byte| {
            value = value & ~data_mask | @as(u32, byte) << data_shift;
            data_register.* = value;
        }
    }
    sw_control.* |= sw_go;

    // Nothing on the socket is said whether or not the engine got done.
    const done = until(engine.sys, status, status_done, status_done);
    const found = status.*;
    if (found & status_unplugged != 0) return .{ .result = tags.RTG_AMD_AUX_UNPLUGGED };
    if (!done) return .{ .result = tags.RTG_AMD_AUX_TIMEOUT };
    const result = resultOf(found);
    if (result != tags.RTG_AMD_AUX_OK) return .{ .result = result };
    // The reply: its first byte the answer, then what was read - the
    // buffer's start, its place held, read from there on.
    const replied = found >> status_count_shift & status_count_mask;
    value = data_register.* & ~data_index_mask;
    data_register.* = value;
    value |= data_hold_index;
    data_register.* = value;
    value |= data_read;
    data_register.* = value;
    const answer = (data_register.* >> data_shift & 0xff) >> 4;
    var reply: Reply = .{ .answer = answer };
    if (answer != 0) return reply;
    const bytes = replied - 1;
    if (bytes > data.len) return .{ .result = tags.RTG_AMD_AUX_BAD_REPLY, .answer = answer };
    if (!writes) {
        for (data[0..bytes]) |*byte| byte.* = @truncate(data_register.* >> data_shift);
    }
    reply.bytes = bytes;
    return reply;
}

/// The header's bytes: the command and the address, and the length where
/// there is one.
pub fn headerBytes(count: u32) u32 {
    return if (count != 0) 4 else 3;
}

fn isWrite(command: u32) bool {
    if (command & 0x80 != 0) return command == dpcd_write;
    return command & ~i2c_more == i2c_write;
}

/// What the status says of a transaction that is done.
pub fn resultOf(status: u32) u32 {
    if (status & status_unplugged != 0) return tags.RTG_AMD_AUX_UNPLUGGED;
    if (status & (status_timeout_state | status_timeout) != 0) return tags.RTG_AMD_AUX_TIMEOUT;
    if (status & (status_invalid_stop | status_no_detect | status_invalid_high | status_invalid_low) != 0) return tags.RTG_AMD_AUX_BAD_REPLY;
    if (status >> status_count_shift & status_count_mask == 0) return tags.RTG_AMD_AUX_BAD_REPLY;
    return tags.RTG_AMD_AUX_OK;
}

/// `register`'s `bits` waited for until they read `value`, 2.4 ms at the
/// most: whether they did.
fn until(sys: *ExecBase, register: *volatile u32, bits: u32, value: u32) bool {
    const end = sys.UptimeUs() + polling_us;
    while (register.* & bits != value) {
        if (sys.UptimeUs() > end) return false;
        dcn.pause(sys, polling_step_us);
    }
    return true;
}

/// How an EDID read over AUX went: the bytes read, whole blocks, and the
/// last transaction's result and answer.
pub const Edid = struct {
    bytes: u32 = 0,
    reply: Reply = .{},
};

/// The monitor's EDID on line `line`'s AUX channel into `into`, as many
/// blocks as it has and `into` holds.
pub fn readEdid(engine: dcn.Engine, line: u32, into: []u8) Edid {
    var read_so_far: Edid = .{};
    const room: u32 = @intCast(into.len / i2c.block_bytes);
    if (room == 0) return read_so_far;
    read_so_far.reply = readBlock(engine, line, 0, into[0..i2c.block_bytes]);
    if (read_so_far.reply.result != tags.RTG_AMD_AUX_OK or read_so_far.reply.answer != 0) return read_so_far;
    read_so_far.bytes = i2c.block_bytes;
    const blocks = @min(room, 1 + @as(u32, into[126]));
    var block: u32 = 1;
    while (block < blocks) : (block += 1) {
        const place = block * i2c.block_bytes;
        read_so_far.reply = readBlock(engine, line, block, into[place..][0..i2c.block_bytes]);
        if (read_so_far.reply.result != tags.RTG_AMD_AUX_OK or read_so_far.reply.answer != 0) break;
        read_so_far.bytes += i2c.block_bytes;
    }
    return read_so_far;
}

/// Block `block` into `into`: the segment where past the second, the
/// offset, then the block 16 bytes at a time, the bus kept throughout and
/// let go at the end; tried again where its bytes do not sum to 0.
fn readBlock(engine: dcn.Engine, line: u32, block: u32, into: *[i2c.block_bytes]u8) Reply {
    var reply: Reply = .{};
    var tried: u32 = 0;
    while (tried < 3) : (tried += 1) {
        reply = readBlockOnce(engine, line, block, into);
        if (reply.result != tags.RTG_AMD_AUX_OK or reply.answer != 0) return reply;
        if (i2c.sum(into) == 0) return reply;
        reply.result = tags.RTG_AMD_AUX_BAD_REPLY;
    }
    return reply;
}

fn readBlockOnce(engine: dcn.Engine, line: u32, block: u32, into: *[i2c.block_bytes]u8) Reply {
    var segment = [1]u8{@intCast(block / 2)};
    var offset = [1]u8{if (block % 2 == 0) 0 else i2c.block_bytes};
    // The bus let go at the end, by a bare packet of the last message's
    // kind without keeping it.
    var none: [0]u8 = .{};
    defer _ = transfer(engine, line, i2c_read, 0x50, &none);
    if (segment[0] != 0) {
        const reply = message(engine, line, 0x30, false, &segment);
        if (reply.result != tags.RTG_AMD_AUX_OK or reply.answer != 0) return reply;
    }
    const reply = message(engine, line, 0x50, false, &offset);
    if (reply.result != tags.RTG_AMD_AUX_OK or reply.answer != 0) return reply;
    return message(engine, line, 0x50, true, into);
}

/// One I2C message over AUX, the bus kept: a bare address packet, then
/// `bytes` 16 at a time - a short reply asked on from where it ended.
fn message(engine: dcn.Engine, line: u32, address: u32, reading: bool, bytes: []u8) Reply {
    const command = (if (reading) i2c_read else i2c_write) | i2c_more;
    var none: [0]u8 = .{};
    var reply = withDefers(engine, line, command, address, &none);
    if (reply.result != tags.RTG_AMD_AUX_OK or reply.answer != 0) return reply;
    var done: usize = 0;
    while (done < bytes.len) {
        const piece = bytes[done..][0..@min(most_bytes, bytes.len - done)];
        reply = withDefers(engine, line, command, address, piece);
        if (reply.result != tags.RTG_AMD_AUX_OK or reply.answer != 0) return reply;
        // A write is taken whole; a read is as long as the reply.
        const took: usize = if (reading) reply.bytes else piece.len;
        if (took == 0) return .{ .result = tags.RTG_AMD_AUX_BAD_REPLY };
        done += took;
    }
    return reply;
}

/// A transaction asked again while the channel or the bus DEFERs it,
/// seven times at the most, half a millisecond apart. A NACK is the
/// answer as it came.
fn withDefers(engine: dcn.Engine, line: u32, command: u32, address: u32, data: []u8) Reply {
    var reply: Reply = .{};
    var tried: u32 = 0;
    while (tried < defer_tries) : (tried += 1) {
        reply = transfer(engine, line, command, address, data);
        if (reply.result != tags.RTG_AMD_AUX_OK) return reply;
        if (!defers(reply.answer)) return reply;
        dcn.pause(engine.sys, defer_wait_us);
    }
    return reply;
}

/// Whether an answer is a DEFER, of the channel or of the bus.
pub fn defers(answer: u32) bool {
    return answer & reply_native_mask == reply_defer or (answer >> reply_i2c_shift) & reply_native_mask == reply_defer;
}

/// Whether an answer is a NACK, of the channel or of the bus.
pub fn nacks(answer: u32) bool {
    return answer & reply_native_mask == reply_nack or (answer >> reply_i2c_shift) & reply_native_mask == reply_nack;
}

/// `register` waited for until its `bits` read `value`, 11 times a
/// microsecond's wait at the most, as long as the engine's reset takes.
fn waitFor(sys: *ExecBase, register: *volatile u32, bits: u32, value: u32) void {
    var tries: u32 = 0;
    while (tries < 11 and register.* & bits != value) : (tries += 1) {
        var never: exec.Waitable = .{};
        const list = [_]*exec.Waitable{&never};
        _ = sys.WaitForAny(&list, 1, 1);
    }
}

test "a transaction's header and how its end reads" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 3), headerBytes(0));
    try testing.expectEqual(@as(u32, 4), headerBytes(16));
    try testing.expect(isWrite(dpcd_write));
    try testing.expect(!isWrite(dpcd_read));
    try testing.expect(isWrite(i2c_write | i2c_more));
    try testing.expect(!isWrite(i2c_read | i2c_more));
    // Nothing on the socket wins over every other bit.
    try testing.expectEqual(tags.RTG_AMD_AUX_UNPLUGGED, resultOf(status_done | status_unplugged | status_timeout));
    try testing.expectEqual(tags.RTG_AMD_AUX_TIMEOUT, resultOf(status_done | status_timeout));
    try testing.expectEqual(tags.RTG_AMD_AUX_BAD_REPLY, resultOf(status_done | status_no_detect | 1 << status_count_shift));
    try testing.expectEqual(tags.RTG_AMD_AUX_BAD_REPLY, resultOf(status_done));
    try testing.expectEqual(tags.RTG_AMD_AUX_OK, resultOf(status_done | 17 << status_count_shift));
}

test "an answer's DEFER and NACK, of the channel and of the bus" {
    const testing = @import("std").testing;
    try testing.expect(defers(0x2));
    try testing.expect(defers(0x8));
    try testing.expect(!defers(0x0));
    try testing.expect(nacks(0x1));
    try testing.expect(nacks(0x4));
    try testing.expect(!nacks(0x8));
}

test "each line's registers are a step on" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0x28d0), padMask(0));
    try testing.expectEqual(@as(u32, 0x28e0), padMask(4));
    try testing.expectEqual(@as(u32, 0x1f50), auxControl(0));
    try testing.expectEqual(@as(u32, 0x1f6c), auxControl(1));
}
