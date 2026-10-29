// SPDX-License-Identifier: MIT
//! The SDIO card the radio is, for cyw43455.device: found on the bus and
//! given an address, and spoken to as the SDIO specification says - one
//! register at a time (CMD52) or a run of bytes or blocks (CMD53), in one
//! of its functions.
//!
//! **The functions.** Function 0 is the card's own: its common registers
//! (the CCCR), where its functions are enabled, its bus made four lines
//! wide and its speed raised, and each function's block size set. The
//! chip has two more: function 1 is the way into its backplane
//! (backplane.zig), function 2 the frames to and from its firmware, which
//! is enabled only once the firmware runs.
//!
//! **Finding it.** The card is told to go idle (CMD0), asked which
//! voltages it takes (CMD5), told to start at the CM5's 3.3 V and asked
//! again until it is ready, then gives itself an address (CMD3) and is
//! selected by it (CMD7). It is spoken to at 400 kHz until then.

const host_file = @import("host.zig");
const Host = host_file.Host;
const Error = host_file.Error;
const Response = host_file.Response;

const CMD_GO_IDLE = 0;
const CMD_SEND_RELATIVE_ADDR = 3;
const CMD_IO_SEND_OP_COND = 5;
const CMD_SELECT_CARD = 7;
const CMD_IO_RW_DIRECT = 52;
const CMD_IO_RW_EXTENDED = 53;

/// CMD5's answer: the card ready, its functions, the voltages it takes.
const OCR_READY: u32 = 1 << 31;
const OCR_FUNCTIONS_SHIFT = 28;
const OCR_VOLTAGES: u32 = 0x00FF_FFFF;
/// 3.2 to 3.4 V, the CM5's.
const host_voltages: u32 = 0x0030_0000;

/// The common registers: which functions are enabled and ready, the
/// interrupts, the bus's width, its speed, and the block size's place in
/// a function's registers.
pub const CCCR_IO_ENABLE = 0x02;
pub const CCCR_IO_READY = 0x03;
pub const CCCR_INT_ENABLE = 0x04;
const CCCR_ABORT = 0x06;
pub const CCCR_BUS_INTERFACE = 0x07;
pub const CCCR_SPEED = 0x13;
const FBR_BLOCK_SIZE = 0x10;
const BUS_WIDTH_MASK: u8 = 3;
const BUS_WIDTH_4: u8 = 2;
const SPEED_SUPPORTS_HIGH: u8 = 1 << 0;
const SPEED_HIGH: u8 = 1 << 1;

/// R5's flags, the response's second byte: a general error, a function
/// that is not there, an address out of range - the ones Linux takes as
/// the command's failing. (Its CRC and illegal-command flags are the
/// previous command's.)
const R5_ERRORS: u32 = 0x0B00;

/// How often the card is asked whether it is ready, and how long apart;
/// how long a function may take to come up: function 2, three seconds
/// while the firmware starts.
const ready_tries = 100;
const ready_wait_us = 10_000;
const function_tries = 300;
const function_wait_us = 10_000;

/// The card on the bus, as found.
pub const Card = extern struct {
    host: *const Host,
    /// The address it gave itself.
    rca: u32 = 0,
    /// How many functions it has past function 0.
    functions: u32 = 0,
};

/// What waits between tries: the device's timer.
pub const Wait = *const fn (context: *anyopaque, us: u64) void;

/// The card found on the bus and selected. The host's clock is the slow
/// one.
pub fn identify(host: *const Host, wait: Wait, context: *anyopaque) Error!Card {
    _ = try host_file.command(host, CMD_GO_IDLE, 0, .none);
    const ocr = try host_file.command(host, CMD_IO_SEND_OP_COND, 0, .r4);
    if (ocr & OCR_VOLTAGES & host_voltages == 0) return error.Failed;
    var answer: u32 = 0;
    for (0..ready_tries) |_| {
        answer = try host_file.command(host, CMD_IO_SEND_OP_COND, host_voltages, .r4);
        if (answer & OCR_READY != 0) break;
        wait(context, ready_wait_us);
    } else return error.Timeout;
    const rca = (try host_file.command(host, CMD_SEND_RELATIVE_ADDR, 0, .r1)) >> 16;
    _ = try host_file.command(host, CMD_SELECT_CARD, rca << 16, .r1b);
    return .{ .host = host, .rca = rca, .functions = (answer >> OCR_FUNCTIONS_SHIFT) & 7 };
}

/// A register of function `function` read.
pub fn read8(card: *const Card, function: u32, address: u32) Error!u8 {
    return direct(card, false, function, address, 0);
}

/// A register of function `function` written.
pub fn write8(card: *const Card, function: u32, address: u32, value: u8) Error!void {
    _ = try direct(card, true, function, address, value);
}

fn direct(card: *const Card, write: bool, function: u32, address: u32, value: u8) Error!u8 {
    var argument: u32 = (function & 7) << 28 | (address & 0x1FFFF) << 9 | value;
    if (write) argument |= 1 << 31;
    const response = try host_file.command(card.host, CMD_IO_RW_DIRECT, argument, .r1);
    if (response & R5_ERRORS != 0) return error.Failed;
    return @truncate(response);
}

/// A run of bytes of function `function` read or written: up to 512 in
/// one command, from `address` on, or all at `address` - a FIFO's.
pub fn bytes(card: *const Card, write: bool, function: u32, address: u32, buffer: []u8, incrementing: bool) Error!void {
    var argument: u32 = (function & 7) << 28 | (address & 0x1FFFF) << 9 | @as(u32, @intCast(buffer.len & 0x1FF));
    if (write) argument |= 1 << 31;
    if (incrementing) argument |= 1 << 26;
    const response = try host_file.transfer(card.host, CMD_IO_RW_EXTENDED, argument, .{
        .buffer = buffer,
        .block_bytes = @intCast(buffer.len),
        .blocks = 1,
        .write = write,
    });
    if (response & R5_ERRORS != 0) return error.Failed;
}

/// Whole blocks of function `function` read or written, of the block
/// size it was given.
pub fn blocks(card: *const Card, write: bool, function: u32, address: u32, buffer: []u8, block_bytes: u32, incrementing: bool) Error!void {
    const count: u32 = @intCast(buffer.len / block_bytes);
    var argument: u32 = (function & 7) << 28 | 1 << 27 | (address & 0x1FFFF) << 9 | (count & 0x1FF);
    if (write) argument |= 1 << 31;
    if (incrementing) argument |= 1 << 26;
    const response = try host_file.transfer(card.host, CMD_IO_RW_EXTENDED, argument, .{
        .buffer = buffer,
        .block_bytes = block_bytes,
        .blocks = count,
        .write = write,
    });
    if (response & R5_ERRORS != 0) return error.Failed;
}

/// The card's bus made four lines wide, on its side.
pub fn setWide(card: *const Card) Error!void {
    const value = try read8(card, 0, CCCR_BUS_INTERFACE);
    try write8(card, 0, CCCR_BUS_INTERFACE, (value & ~BUS_WIDTH_MASK) | BUS_WIDTH_4);
}

/// The card's high speed - 50 MHz - turned on, if it has it: whether it
/// does.
pub fn setHighSpeed(card: *const Card) Error!bool {
    const value = try read8(card, 0, CCCR_SPEED);
    if (value & SPEED_SUPPORTS_HIGH == 0) return false;
    try write8(card, 0, CCCR_SPEED, value | SPEED_HIGH);
    return true;
}

/// Function `function`'s block size.
pub fn setBlockSize(card: *const Card, function: u32, size: u16) Error!void {
    const at = function * 0x100 + FBR_BLOCK_SIZE;
    try write8(card, 0, at, @truncate(size));
    try write8(card, 0, at + 1, @truncate(size >> 8));
}

/// The transfer function `function` was in the middle of abandoned, on
/// the card's side.
pub fn abort(card: *const Card, function: u32) Error!void {
    try write8(card, 0, CCCR_ABORT, @intCast(function & 7));
}

/// Function `function` enabled, and waited for until it says it is
/// ready.
pub fn enable(card: *const Card, function: u32, wait: Wait, context: *anyopaque) Error!void {
    const bit = @as(u8, 1) << @intCast(function);
    const enabled = try read8(card, 0, CCCR_IO_ENABLE);
    try write8(card, 0, CCCR_IO_ENABLE, enabled | bit);
    for (0..function_tries) |_| {
        if (try read8(card, 0, CCCR_IO_READY) & bit != 0) return;
        wait(context, function_wait_us);
    }
    return error.Timeout;
}
