// SPDX-License-Identifier: MPL-2.0
//! The display engine's I2C engine, and a monitor's EDID read through it.
//!
//! One engine serves the five DDC lines in turn: it is pointed at a line
//! (`DDC_SELECT`), handed up to four transactions - each a start, the
//! address byte and the bytes to write or room for those to read, the
//! last one ending with a stop - in a buffer of its own, and sent them
//! with one go. Writes the caller marks as followed by more (`more`, an
//! offset before a read) are held until a read or the last write, then
//! all go together, a repeated start between them.
//!
//! **Taking it.** The engine is the hardware's own to use too (it reads a
//! monitor's EDID by itself where it is told to) and the display
//! controller's; who has it is settled at its arbitration register: it
//! is asked for, and refused where the hardware holds the line or the
//! controller holds the engine. The line's pads are put into I2C mode
//! first and driven by the engine (their GPIO masks cleared, which they
//! get back after), its memory let out of light sleep, its clock set to
//! 100 kHz from the engine's reference, and the line's time limit and
//! reset length set. Given back, the engine is reset where software held
//! it, told it is done with, and its memory let sleep again.
//!
//! **Waiting.** A transaction's longest time is 32 of the bus's clocks
//! per bit it may take, stretched; the engine's status is read until it
//! is no longer busy, or that time is up.
//!
//! **The EDID** is read in blocks of 128 bytes from the monitor's address
//! 0x50: its offset written, then the block read, a repeated start
//! between. Blocks past the second are in segments of two, the segment
//! written to 0x30 first. The first block says how many follow. A block
//! whose bytes do not sum to 0 is read again, three tries in all.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");

/// How many DDC lines have the engine.
pub const lines = 5;

/// The engine's registers, in 32-bit words from the engine's third
/// address; a line's own are a step on per line.
const control_at = 0x1e98;
const arbitration_at = 0x1e99;
const sw_status_at = 0x1e9b;
const hw_status_first = 0x1e9c;
const speed_first = 0x1ea2;
const setup_first = 0x1ea3;
const line_stride = 2;
const transaction_first = 0x1eae;
const data_at = 0x1eb2;
const memory_status_at = 0x1edd;
const memory_control_at = 0x1ede;
/// From the engine's second address: the reference's divider.
const time_base_at = 0x7b;

/// The lines' pads: a mask register per line, the register of every
/// pad's I2C mode and the one of every pad's receiver.
const pad_mask_first = 0x28d0;
const pad_stride = 4;
const pad_control_5 = 0x291d;
const pad_receivers = 0x28ff;
/// The first line's GPIO register as the BIOS's table of pins names it.
const pad_pins_first = 0x28d1;

/// CONTROL's bits.
const control_go: u32 = 1 << 0;
const control_soft_reset: u32 = 1 << 1;
const control_send_reset: u32 = 1 << 2;
const control_status_reset: u32 = 1 << 3;
const control_select_shift = 8;
const control_select_mask: u32 = 0x7 << control_select_shift;
const control_count_shift = 20;
const control_count_mask: u32 = 0x3 << control_count_shift;

/// ARBITRATION's: who has the engine (idle, software, the hardware; the
/// controller alone), the queue, software's request and release.
const arbitration_status_shift = 2;
const arbitration_status_mask: u32 = 0x3 << arbitration_status_shift;
const arbitration_no_queued_go: u32 = 1 << 4;
const arbitration_request: u32 = 1 << 20;
const arbitration_done: u32 = 1 << 21;

/// The engine's status as SW_STATUS and a line's HW_STATUS say it.
const status_idle = 0;
const status_software = 1;
const status_hardware = 2;
const status_controller_only = 2;
const status_mask: u32 = 0x3;
const sw_done: u32 = 1 << 2;
const sw_aborted: u32 = 1 << 4;
const sw_timeout: u32 = 1 << 5;
const sw_nack: u32 = 1 << 8;

/// A line's SETUP: its drive and delays, the reset length, the engine on
/// for it, its time limit.
const setup_data_drive_en: u32 = 1 << 0;
const setup_data_drive_sel: u32 = 1 << 1;
const setup_reset_length: u32 = 1 << 2;
const setup_enable: u32 = 1 << 6;
const setup_clock_drive_en: u32 = 1 << 7;
const setup_byte_delay_mask: u32 = 0xff << 8;
const setup_transaction_delay_mask: u32 = 0xff << 16;
const setup_limit_shift = 24;
const setup_limit_mask: u32 = 0xff << setup_limit_shift;
const time_limit = 3;

/// A line's SPEED: the threshold, the start and stop timing, the
/// prescaler.
const speed_threshold_mask: u32 = 0x3;
const speed_timing_shift = 8;
const speed_timing_mask: u32 = 0x3 << speed_timing_shift;
const speed_prescale_shift = 16;
const speed_prescale_mask: u32 = 0xffff << speed_prescale_shift;
const speed_khz = 100;

/// A TRANSACTION register's: read, stop on a NACK, start, stop, count.
const transaction_read: u32 = 1 << 0;
const transaction_stop_on_nack: u32 = 1 << 8;
const transaction_start: u32 = 1 << 12;
const transaction_stop: u32 = 1 << 13;
const transaction_count_shift = 16;

/// DATA's: reading, the byte, where in the buffer, that place written.
const data_read: u32 = 1 << 0;
const data_shift = 8;
const data_index_shift = 16;
const data_index_write: u32 = 1 << 31;

/// The pads' bits: the clock's and data's GPIO masks and pull-downs, AUX
/// mode; each pad's I2C mode in CONTROL_5, its receiver's selection.
const pad_clock_mask: u32 = 1 << 0;
const pad_clock_pull_down: u32 = 1 << 4;
const pad_data_mask: u32 = 1 << 8;
const pad_data_pull_down: u32 = 1 << 12;
const pad_aux_mode: u32 = 1 << 16;
const pad_i2c_mode_first: u32 = 1 << 12;
const receiver_shift_first = 10;
const receiver_i2c: u32 = 1;

/// The light sleep of the engine's memory, and its state.
const memory_sleep_force: u32 = 1 << 0;
const memory_asleep: u32 = 1 << 0;

/// The reference's divider's fields; the engine's reference where it
/// holds none.
const time_base_mask: u32 = 0x7f;
const time_base_xtal_shift = 8;
const time_base_xtal_mask: u32 = 0x7f;
const reference_khz = 48_000;

/// The engine's buffer, in bytes.
const buffer_bytes = 538;
/// A transaction's clocks waited for per bit, stretched.
const clocks_per_bit = 32;

/// The EDID's places on the bus, and a block.
const edid_address = 0x50;
const segment_address = 0x30;
pub const block_bytes = 128;
const tries = 3;

/// How a transfer went.
pub const Result = enum(u32) { ok, busy, nack, timeout, failed, too_long };

/// One transaction: to the 7-bit `address`, `bytes` written or read into.
/// A write that is not the last is held for what follows.
pub const Message = struct {
    address: u8,
    read: bool,
    bytes: []u8,
};

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

fn clocksAt(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.clocks) + offset) * 4);
}

/// The DDC line a connector's pins are on (0 for DDC1), from the register
/// the BIOS's table of pins names: null for none, or one of a line
/// without the engine.
pub fn lineOf(engine: dcn.Engine, connector: amdgpu.GPUConnector) ?u32 {
    if (connector.ddc_pin < engine.block) return null;
    return lineOfRegister(connector.ddc_pin - engine.block);
}

pub fn lineOfRegister(register: u32) ?u32 {
    if (register < pad_pins_first) return null;
    const step = register - pad_pins_first;
    if (step % pad_stride != 0 or step / pad_stride >= lines) return null;
    return step / pad_stride;
}

/// What a transfer had to put back when it was done.
const Held = struct {
    line: u32,
    masks: u32,
};

/// `messages` on line `line`, in order: a write with more after it is
/// held for the next; a read, or a write that ends, sends them all.
pub fn transfer(engine: dcn.Engine, line: u32, messages: []const Message) Result {
    if (line >= lines) return .failed;
    if (!available(engine, line)) return .busy;
    const held = open(engine, line);
    defer close(engine, held);
    if (!setUp(engine, line)) {
        release(engine, line);
        return .busy;
    }
    defer release(engine, line);

    var pending: u32 = 0;
    var used: u32 = 0;
    var write_place: u32 = 0;
    var result: Result = .ok;
    for (messages, 0..) |message, index| {
        const last_message = index + 1 == messages.len;
        if (message.bytes.len + 1 > buffer_bytes - used) return .too_long;
        const ends = pending == 3 or message.read or last_message;
        const count: u32 = @intCast(message.bytes.len);
        at(engine, transaction_first + pending).* = transaction_stop_on_nack | transaction_start |
            (if (message.read) transaction_read else 0) |
            count << transaction_count_shift |
            (if (ends) transaction_stop else 0);
        // The address byte, with the direction in its lowest bit; the
        // first of a go put at the buffer's start.
        const address: u32 = @as(u32, message.address) << 1 | @intFromBool(message.read);
        if (pending == 0) {
            at(engine, data_at).* = address << data_shift | data_index_write;
            write_place = 0;
        } else {
            at(engine, data_at).* = address << data_shift;
        }
        write_place += 1;
        if (!message.read) {
            for (message.bytes) |byte| {
                at(engine, data_at).* = @as(u32, byte) << data_shift;
                write_place += 1;
            }
        }
        pending += 1;
        used += count + 1;
        if (!ends) continue;

        const wait_us = waitFor(used, pending, count + 1);
        if (busy(engine, line)) return .busy;
        go(engine, pending);
        pending = 0;
        used = 0;
        result = finish(engine, wait_us);
        if (result != .ok) return result;
        if (message.read) {
            at(engine, data_at).* = write_place << data_index_shift | data_read | data_index_write;
            for (message.bytes) |*byte| byte.* = @truncate(at(engine, data_at).* >> data_shift);
        }
    }
    return result;
}

/// The longest a go may take, in microseconds: a period of 32 of the
/// bus's clocks for each bit of the transaction and those before it in
/// the buffer, a start and a stop, and two per transaction.
fn waitFor(used: u32, transactions: u32, bytes: u32) u64 {
    const period_us: u64 = 1000 * clocks_per_bit / speed_khz;
    const stretches: u64 = 1 + @as(u64, bytes) * 8 + 1 + @as(u64, used - bytes) * 8 + @as(u64, transactions - 1) * 2;
    return period_us * stretches;
}

/// Whether the engine can be had for line `line`: the hardware is not
/// using the line, nor the controller the engine.
fn available(engine: dcn.Engine, line: u32) bool {
    if (at(engine, hw_status_first + line).* & status_mask == status_hardware) return false;
    const arbitration = at(engine, arbitration_at).*;
    return (arbitration & arbitration_status_mask) >> arbitration_status_shift != status_controller_only;
}

/// Whether the engine is busy for software: it is in use, and not to be
/// had.
fn busy(engine: dcn.Engine, line: u32) bool {
    if (at(engine, sw_status_at).* & status_mask == status_idle) return false;
    return !available(engine, line);
}

/// Line `line`'s pads put into I2C mode and driven by the engine: what
/// their masks were, to be put back.
fn open(engine: dcn.Engine, line: u32) Held {
    const pads = at(engine, pad_mask_first + line * pad_stride);
    const found = pads.*;
    var value = found & ~(pad_clock_mask | pad_data_mask);
    // A transient on the pad is let out through its pull-downs.
    if (value & pad_data_pull_down == 0 or value & pad_clock_pull_down == 0) {
        value |= pad_data_pull_down | pad_clock_pull_down;
    }
    pads.* = value;
    if (value & pad_aux_mode != 0) {
        // Its pins let go before it changes mode.
        dcn.pause(engine.sys, 2000);
        pads.* = pads.* & ~pad_aux_mode;
    }
    at(engine, pad_control_5).* |= pad_i2c_mode_first << @intCast(line);
    const receivers = at(engine, pad_receivers);
    const shift: u5 = @intCast(receiver_shift_first + 2 * line);
    receivers.* = receivers.* & ~(@as(u32, 0x3) << shift) | receiver_i2c << shift;
    return .{ .line = line, .masks = found & (pad_clock_mask | pad_data_mask) };
}

/// The pads' masks back as they were.
fn close(engine: dcn.Engine, held: Held) void {
    const pads = at(engine, pad_mask_first + held.line * pad_stride);
    pads.* = pads.* & ~(pad_clock_mask | pad_data_mask) | held.masks;
}

/// The engine taken for line `line` and set up: false where it could not
/// be had.
fn setUp(engine: dcn.Engine, line: u32) bool {
    at(engine, control_at).* &= ~control_soft_reset;
    // Its memory out of light sleep.
    at(engine, memory_control_at).* &= ~memory_sleep_force;
    var tries_left: u32 = 5;
    while (tries_left > 0 and at(engine, memory_status_at).* & memory_asleep != 0) : (tries_left -= 1) {}

    const arbitration = at(engine, arbitration_at);
    switch ((arbitration.* & arbitration_status_mask) >> arbitration_status_shift) {
        status_software => {},
        status_hardware => return false,
        else => {
            arbitration.* |= arbitration_request;
            if ((arbitration.* & arbitration_status_mask) >> arbitration_status_shift != status_software) return false;
        },
    }
    setSpeed(engine, line);
    const control = at(engine, control_at);
    control.* = control.* & ~(control_go | control_send_reset | control_count_mask | control_select_mask) |
        control_status_reset | line << control_select_shift;
    const setup = at(engine, setup_first + line * line_stride);
    setup.* = setup.* & ~setup_limit_mask | time_limit << setup_limit_shift | setup_reset_length | setup_enable;
    arbitration.* &= ~arbitration_no_queued_go;
    return true;
}

/// Line `line`'s clock at 100 kHz, from the engine's reference and its
/// divider.
fn setSpeed(engine: dcn.Engine, line: u32) void {
    const time_base = clocksAt(engine, time_base_at).*;
    var xtal_divider = time_base >> time_base_xtal_shift & time_base_xtal_mask;
    if (xtal_divider == 0) xtal_divider = 2;
    const base_divider = time_base & time_base_mask;
    const reference: u32 = if (base_divider == 0) reference_khz else base_divider * 1000;
    const prescale = reference / xtal_divider / speed_khz;
    const speed = at(engine, speed_first + line * line_stride);
    speed.* = speed.* & ~(speed_prescale_mask | speed_threshold_mask | speed_timing_mask) |
        (prescale << speed_prescale_shift & speed_prescale_mask) | 2 | @as(u32, 2) << speed_timing_shift;
}

/// The held transactions sent: `pending` of them.
fn go(engine: dcn.Engine, pending: u32) void {
    const control = at(engine, control_at);
    control.* |= control_status_reset;
    const line = (control.* & control_select_mask) >> control_select_shift;
    const setup = at(engine, setup_first + line * line_stride);
    setup.* &= ~(setup_data_drive_en | setup_clock_drive_en | setup_data_drive_sel | setup_byte_delay_mask | setup_transaction_delay_mask);
    control.* = control.* & ~(control_soft_reset | control_status_reset | control_send_reset | control_go | control_count_mask) |
        (pending - 1) << control_count_shift;
    control.* |= control_go;
}

/// The go waited for until the engine is not busy, `wait_us` at the most:
/// how it ended.
fn finish(engine: dcn.Engine, wait_us: u64) Result {
    const until = engine.sys.UptimeUs() + wait_us;
    while (true) {
        const status = at(engine, sw_status_at).*;
        if (status & status_mask != status_software) return resultOf(status);
        if (engine.sys.UptimeUs() > until) return .timeout;
        dcn.pause(engine.sys, 100);
    }
}

pub fn resultOf(status: u32) Result {
    if (status & status_mask == status_software) return .busy;
    if (status & sw_nack != 0) return .nack;
    if (status & sw_timeout != 0) return .timeout;
    if (status & sw_aborted != 0) return .failed;
    return .ok;
}

/// The engine given back: reset where software held it, told it is done
/// with - twice where it stays taken, as a line booted without a monitor
/// leaves it - and its memory let sleep.
fn release(engine: dcn.Engine, line: u32) void {
    const control = at(engine, control_at);
    if (at(engine, sw_status_at).* & status_mask == status_software) {
        control.* |= control_soft_reset | control_status_reset;
    } else {
        control.* |= control_status_reset;
    }
    setSpeed(engine, line);
    const arbitration = at(engine, arbitration_at);
    arbitration.* |= arbitration_done;
    if ((arbitration.* & arbitration_status_mask) >> arbitration_status_shift == status_software) {
        arbitration.* |= arbitration_done;
    }
    at(engine, memory_control_at).* |= memory_sleep_force;
}

/// The registers a read of line `line` is judged by: the engine's control,
/// arbitration and status, the line's status, speed and setup, the
/// reference's divider and the line's pads.
pub fn read(engine: dcn.Engine, line: u32, into: *[8]u32) void {
    if (line >= lines) return;
    into.* = .{
        at(engine, control_at).*,
        at(engine, arbitration_at).*,
        at(engine, sw_status_at).*,
        at(engine, hw_status_first + line).*,
        at(engine, speed_first + line * line_stride).*,
        at(engine, setup_first + line * line_stride).*,
        clocksAt(engine, time_base_at).*,
        at(engine, pad_mask_first + line * pad_stride).*,
    };
}

/// How an EDID read went: the bytes read, whole blocks, and how the last
/// transfer ended.
pub const Edid = struct {
    bytes: u32 = 0,
    result: Result = .ok,
};

/// The monitor's EDID on line `line` into `into`, as many blocks as it
/// has and `into` holds.
pub fn readEdid(engine: dcn.Engine, line: u32, into: []u8) Edid {
    var read_so_far: Edid = .{};
    const room: u32 = @intCast(into.len / block_bytes);
    if (room == 0) return read_so_far;
    read_so_far.result = readBlock(engine, line, 0, into[0..block_bytes]);
    if (read_so_far.result != .ok) return read_so_far;
    read_so_far.bytes = block_bytes;
    const blocks = @min(room, 1 + @as(u32, into[126]));
    var block: u32 = 1;
    while (block < blocks) : (block += 1) {
        const place = block * block_bytes;
        read_so_far.result = readBlock(engine, line, block, into[place..][0..block_bytes]);
        if (read_so_far.result != .ok) break;
        read_so_far.bytes += block_bytes;
    }
    return read_so_far;
}

/// Block `block` of the EDID into `into`, tried again where it does not
/// read or its bytes do not sum to 0.
fn readBlock(engine: dcn.Engine, line: u32, block: u32, into: *[block_bytes]u8) Result {
    var result: Result = .failed;
    var tried: u32 = 0;
    while (tried < tries) : (tried += 1) {
        var segment = [1]u8{@intCast(block / 2)};
        var offset = [1]u8{if (block % 2 == 0) 0 else block_bytes};
        const with_segment = [_]Message{
            .{ .address = segment_address, .read = false, .bytes = &segment },
            .{ .address = edid_address, .read = false, .bytes = &offset },
            .{ .address = edid_address, .read = true, .bytes = into },
        };
        const messages: []const Message = if (segment[0] == 0) with_segment[1..] else &with_segment;
        result = transfer(engine, line, messages);
        if (result == .ok and sum(into) == 0) return .ok;
        if (result == .ok) result = .failed;
        // Nothing answers at the address: no monitor to try again.
        if (result == .nack) return result;
    }
    return result;
}

pub fn sum(block: *const [block_bytes]u8) u8 {
    var total: u8 = 0;
    for (block) |byte| total +%= byte;
    return total;
}

test "a pin's register names its DDC line" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(?u32, 0), lineOfRegister(0x28d1));
    try testing.expectEqual(@as(?u32, 1), lineOfRegister(0x28d5));
    try testing.expectEqual(@as(?u32, 4), lineOfRegister(0x28e1));
    // The VGA line has no engine, and nothing between lines is one.
    try testing.expectEqual(@as(?u32, null), lineOfRegister(0x28e9));
    try testing.expectEqual(@as(?u32, null), lineOfRegister(0x28d2));
    try testing.expectEqual(@as(?u32, null), lineOfRegister(0x28d0));
}

test "a go's longest wait counts every bit before it" {
    const testing = @import("std").testing;
    // An offset written, then 128 bytes read: 320 us per stretch.
    try testing.expectEqual(@as(u64, 320 * (1 + 129 * 8 + 1 + 2 * 8 + 2)), waitFor(2 + 129, 2, 129));
}

test "a status says how a go ended" {
    const testing = @import("std").testing;
    try testing.expectEqual(Result.busy, resultOf(status_software));
    try testing.expectEqual(Result.nack, resultOf(sw_done | sw_nack));
    try testing.expectEqual(Result.timeout, resultOf(sw_done | sw_timeout));
    try testing.expectEqual(Result.ok, resultOf(sw_done));
}
