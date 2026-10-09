// SPDX-License-Identifier: MIT
//! The five UARTs: their registers - the same block at each UART's base
//! (`base`), so the registers are offsets into it - and the raw console
//! on UART0 that exec's RawPutChar drives (`console`).
//!
//! **The console needs no setting up.** The ROM leaves UART0 running from
//! the crystal at 115200 8N1 - its own banner comes out of it - so exec's
//! raw port only lets the ROM's last bytes out before it starts. Its clock
//! and reset are in the HP_SYS_CLKRST block, not in the UART: the rate and
//! frame are set from there when serial.device drives the port.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;

/// A UART's registers, by its number (0-4).
pub inline fn base(comptime n: u3) usize {
    return switch (n) {
        0 => map.UART0,
        1 => map.UART1,
        2 => map.UART2,
        3 => map.UART3,
        4 => map.UART4,
        else => @compileError("the chip has five UARTs"),
    };
}

// The registers, as offsets from a UART's base.
pub const FIFO = 0x00;
pub const STATUS = 0x1C;
pub const FSM_STATUS = 0x70;

/// The FIFOs' depth, in bytes, each way.
pub const FIFO_LEN = 128;

// STATUS: how full the FIFOs are.
pub const STATUS_RXFIFO_CNT: u32 = 0xFF;
pub const STATUS_TXFIFO_CNT_SHIFT = 16;
pub const STATUS_TXFIFO_CNT: u32 = 0xFF << STATUS_TXFIFO_CNT_SHIFT;

// FSM_STATUS: the transmitter's state; 0 is idle.
pub const FSM_ST_UTX_OUT: u32 = 0xF << 4;

/// UART0 as the raw console: what exec's raw port is given in place of
/// a driver of its own (`consoleInit`, `consolePut`, `consoleGet`).
const uart0 = base(0);

/// The ROM's last bytes out, so its output and the kernel's do not run
/// together. The port itself stays as the ROM set it.
pub fn consoleInit() void {
    while (reg(uart0 + STATUS).* & STATUS_TXFIFO_CNT != 0) {}
    while (reg(uart0 + FSM_STATUS).* & FSM_ST_UTX_OUT != 0) {}
}

/// A byte out, waiting while the TX FIFO is full.
pub fn consolePut(character: u8) void {
    while ((reg(uart0 + STATUS).* & STATUS_TXFIFO_CNT) >> STATUS_TXFIFO_CNT_SHIFT >= FIFO_LEN - 2) {}
    reg(uart0 + FIFO).* = character;
}

/// A byte in, if one is waiting.
pub fn consoleGet() ?u8 {
    if (reg(uart0 + STATUS).* & STATUS_RXFIFO_CNT == 0) return null;
    return @truncate(reg(uart0 + FIFO).*);
}
