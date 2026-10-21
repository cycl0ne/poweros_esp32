// SPDX-License-Identifier: MIT
//! Synopsys's DesignWare I2C controller - the JH7110's seven - as a bus
//! master that waits for every transfer itself: for code that runs
//! before there are tasks to wait in, or with interrupts off, such as the
//! board's power controller on I2C5 (an AXP15060 at 0x36), which holds
//! the CPU's supply and through which the firmware resets the board.
//!
//! A transfer is one command per byte into the controller's FIFO - a
//! byte to send, or a byte to read - the last with STOP; the controller
//! sends the START, the address and a repeated START where the direction
//! turns by itself. A slave that does not answer, or a lost arbitration,
//! aborts it (TX_ABRT), which the controller then holds until it is
//! cleared. Its FIFOs hold eight bytes each way here, so a transfer is
//! kept to that.
//!
//! The controller's clock and reset are the caller's (`system`), and its
//! pads too. Standard mode, 100 kHz, with the counts U-Boot sets on the
//! VisionFive 2 for its 49.152 MHz bus clock.
//!
//! The registers by the names of Synopsys's databook as Linux's driver
//! has them (i2c-designware-core.h).

const reg = @import("mmio.zig").reg;

const IC_CON = 0x00;
const IC_TAR = 0x04;
const IC_DATA_CMD = 0x10;
const IC_SS_SCL_HCNT = 0x14;
const IC_SS_SCL_LCNT = 0x18;
const IC_INTR_MASK = 0x30;
const IC_RAW_INTR_STAT = 0x34;
const IC_CLR_INTR = 0x40;
const IC_ENABLE = 0x6C;
const IC_STATUS = 0x70;
const IC_RXFLR = 0x78;
const IC_SDA_HOLD = 0x7C;
const IC_TX_ABRT_SOURCE = 0x80;
const IC_ENABLE_STATUS = 0x9C;

/// Master, standard mode, 7-bit addresses, repeated STARTs on, slave
/// off - U-Boot's setting, which OpenSBI's reset counts on too.
const CON_MASTER: u32 = 0x63;
const SCL_HCNT: u32 = 0x4A;
const SCL_LCNT: u32 = 0x16B;
const SDA_HOLD: u32 = 0x0F;

/// A command's bits above its byte: read rather than send, and STOP after
/// it.
const CMD_READ: u32 = 1 << 8;
const CMD_STOP: u32 = 1 << 9;

const INTR_TX_ABRT: u32 = 1 << 6;
const INTR_STOP_DET: u32 = 1 << 9;
const STATUS_TFNF: u32 = 1 << 1;

/// The bytes a transfer moves at the most, either way.
pub const max_bytes = 8;

/// How many times a wait reads its register before it gives up: at
/// 100 kHz a byte takes 90 microseconds, and this is far longer than a
/// transfer of `max_bytes`.
const patience: u32 = 2_000_000;

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// Whether the controller came to be off, or on.
fn enabled(base: usize, on: bool) bool {
    at(base, IC_ENABLE).* = @intFromBool(on);
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (at(base, IC_ENABLE_STATUS).* & 1 == @intFromBool(on)) return true;
    }
    return false;
}

/// The controller at `base` set up as a master, its interrupts masked:
/// it takes its settings only while it is off. False if it would not
/// turn off.
pub fn setUp(base: usize) bool {
    if (!enabled(base, false)) return false;
    at(base, IC_CON).* = CON_MASTER;
    at(base, IC_SS_SCL_HCNT).* = SCL_HCNT;
    at(base, IC_SS_SCL_LCNT).* = SCL_LCNT;
    at(base, IC_SDA_HOLD).* = SDA_HOLD;
    at(base, IC_INTR_MASK).* = 0;
    return true;
}

/// `out` sent to the slave at `address`, then `in` read from it, with a
/// repeated START between. False if the slave did not answer, the bus was
/// lost or the transfer did not finish; `in` then holds nothing.
pub fn transfer(base: usize, address: u7, out: []const u8, in: []u8) bool {
    const total = out.len + in.len;
    if (total == 0 or out.len > max_bytes or in.len > max_bytes) return false;
    if (!enabled(base, false)) return false;
    at(base, IC_TAR).* = address;
    _ = at(base, IC_CLR_INTR).*;
    if (!enabled(base, true)) return false;

    var sent: usize = 0;
    while (sent < total) : (sent += 1) {
        var command: u32 = if (sent < out.len) out[sent] else CMD_READ;
        if (sent == total - 1) command |= CMD_STOP;
        var tries: u32 = 0;
        while (at(base, IC_STATUS).* & STATUS_TFNF == 0) : (tries += 1) {
            if (tries == patience) return false;
        }
        at(base, IC_DATA_CMD).* = command;
    }

    // The STOP, or the abort, is what says it is over.
    var tries: u32 = 0;
    while (at(base, IC_RAW_INTR_STAT).* & (INTR_STOP_DET | INTR_TX_ABRT) == 0) : (tries += 1) {
        if (tries == patience) return false;
    }
    const aborted = at(base, IC_RAW_INTR_STAT).* & INTR_TX_ABRT != 0 or at(base, IC_TX_ABRT_SOURCE).* != 0;
    if (aborted or at(base, IC_RXFLR).* < in.len) {
        _ = at(base, IC_CLR_INTR).*;
        return false;
    }
    for (in) |*byte| byte.* = @truncate(at(base, IC_DATA_CMD).*);
    _ = at(base, IC_CLR_INTR).*;
    return true;
}

/// Register `index` of the slave at `address`, as most I2C chips have
/// them: the register's number sent, its value read. Null if the slave
/// did not answer.
pub fn readRegister(base: usize, address: u7, index: u8) ?u8 {
    var value: [1]u8 = undefined;
    if (!transfer(base, address, &.{index}, &value)) return null;
    return value[0];
}

/// Register `index` of the slave at `address` set to `value`: the
/// register's number sent, then the value. False if the slave did not
/// answer.
pub fn writeRegister(base: usize, address: u7, index: u8, value: u8) bool {
    var nothing: [0]u8 = .{};
    return transfer(base, address, &.{ index, value }, &nothing);
}
