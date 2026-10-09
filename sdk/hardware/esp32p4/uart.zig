// SPDX-License-Identifier: MIT
//! The five UARTs: their registers - the same block at each UART's base
//! (`base`), so the registers are offsets into it - and UART0 as the raw
//! console exec's RawPutChar drives (`consoleInit`, `consolePut`,
//! `consoleGet`).
//!
//! The block is the ESP32-S3's UART grown: the FIFO counts and thresholds
//! are 8 bits, software flow control and the receive timeout have
//! registers of their own (SWFC_CONF0, TOUT_CONF), and its clock source
//! and divider are in HP_SYS_CLKRST (`system`) rather than in the UART. A
//! register named `_SYNC` by the manual is the UART core's own copy:
//! written, it takes effect once REG_UPDATE has carried it over
//! (`update`). Where the layout is the S3's, so are the names.
//!
//! **The console needs no setting up.** The ROM leaves UART0 running from
//! the crystal at 115200 8N1 - its own banner comes out of it - so exec's
//! raw port only lets the ROM's last bytes out before it starts.
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/uart_reg.h.

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

/// The same, for a number known only at run time.
pub fn baseOf(n: u3) usize {
    return switch (n) {
        0 => map.UART0,
        1 => map.UART1,
        2 => map.UART2,
        3 => map.UART3,
        else => map.UART4,
    };
}

// The registers, as offsets from a UART's base.
pub const FIFO = 0x00;
pub const INT_RAW = 0x04;
pub const INT_ST = 0x08;
pub const INT_ENA = 0x0C;
pub const INT_CLR = 0x10;
/// CLKDIV_SYNC.
pub const CLKDIV = 0x14;
pub const STATUS = 0x1C;
/// CONF0_SYNC.
pub const CONF0 = 0x20;
pub const CONF1 = 0x24;
/// HWFC_CONF_SYNC: hardware flow control.
pub const HWFC_CONF = 0x2C;
/// SWFC_CONF0_SYNC: software flow control.
pub const SWFC_CONF0 = 0x3C;
pub const SWFC_CONF1 = 0x40;
/// RS485_CONF_SYNC.
pub const RS485_CONF = 0x4C;
pub const MEM_CONF = 0x60;
/// TOUT_CONF_SYNC: the receive timeout.
pub const TOUT_CONF = 0x64;
pub const FSM_STATUS = 0x70;
pub const CLK_CONF = 0x88;
/// The block's version, and what it reads after reset.
pub const DATE = 0x8C;
pub const DATE_RESET: u32 = 0x0230_5050;
/// The _SYNC registers carried over into the UART core's clock domain.
pub const REG_UPDATE = 0x98;

/// The FIFOs' depth, in bytes, each way.
pub const FIFO_LEN = 128;

// INT_*: the interrupt bits, in INT_RAW, INT_ST, INT_ENA and INT_CLR.
pub const INT_RXFIFO_FULL: u32 = 1 << 0;
pub const INT_TXFIFO_EMPTY: u32 = 1 << 1;
pub const INT_PARITY_ERR: u32 = 1 << 2;
pub const INT_FRM_ERR: u32 = 1 << 3;
pub const INT_RXFIFO_OVF: u32 = 1 << 4;
pub const INT_BRK_DET: u32 = 1 << 7;
pub const INT_RXFIFO_TOUT: u32 = 1 << 8;
pub const INT_SW_XON: u32 = 1 << 9;
pub const INT_SW_XOFF: u32 = 1 << 10;
pub const INT_TX_DONE: u32 = 1 << 14;

// CLKDIV: the integer part (12 bits) and the sixteenths above it.
pub const CLKDIV_FRAG_SHIFT = 20;

// STATUS: how full the FIFOs are, and the modem lines.
pub const STATUS_RXFIFO_CNT: u32 = 0xFF;
pub const STATUS_TXFIFO_CNT_SHIFT = 16;
pub const STATUS_TXFIFO_CNT: u32 = 0xFF << STATUS_TXFIFO_CNT_SHIFT;
pub const STATUS_DSRN: u32 = 1 << 13;
pub const STATUS_CTSN: u32 = 1 << 14;
pub const STATUS_DTRN: u32 = 1 << 29;
pub const STATUS_RTSN: u32 = 1 << 30;

// CONF0: the frame.
pub const CONF0_PARITY: u32 = 1 << 0;
pub const CONF0_PARITY_EN: u32 = 1 << 1;
pub const CONF0_BIT_NUM_SHIFT = 2;
pub const CONF0_STOP_BIT_NUM_SHIFT = 4;
/// Parity, data bits and stop bits together.
pub const CONF0_FRAME: u32 = 0x3F;
/// 8 data bits, no parity, 1 stop bit.
pub const CONF0_8N1: u32 = 3 << CONF0_BIT_NUM_SHIFT | 1 << CONF0_STOP_BIT_NUM_SHIFT;
pub const CONF0_TXD_INV: u32 = 1 << 16;

// CONF1: the FIFO thresholds.
pub const CONF1_RXFIFO_FULL_THRHD: u32 = 0xFF;
pub const CONF1_TXFIFO_EMPTY_THRHD_SHIFT = 8;
pub const CONF1_TXFIFO_EMPTY_THRHD: u32 = 0xFF << CONF1_TXFIFO_EMPTY_THRHD_SHIFT;

// SWFC_CONF0: software flow control.
pub const SWFC_SW_FLOW_CON_EN: u32 = 1 << 17;
pub const SWFC_XONOFF_DEL: u32 = 1 << 18;

// RS485_CONF.
pub const RS485_EN: u32 = 1 << 0;
pub const RS485TX_RX_EN: u32 = 1 << 3;
pub const RS485RXBY_TX_EN: u32 = 1 << 4;

// TOUT_CONF: the receive timeout, in bit times.
pub const TOUT_RX_TOUT_EN: u32 = 1 << 0;
pub const TOUT_RX_TOUT_THRHD_SHIFT = 2;
pub const TOUT_RX_TOUT_THRHD: u32 = 0x3FF << TOUT_RX_TOUT_THRHD_SHIFT;

// FSM_STATUS: the transmitter's state; 0 is idle.
pub const FSM_ST_UTX_OUT_SHIFT = 4;
pub const FSM_ST_UTX_OUT: u32 = 0xF << FSM_ST_UTX_OUT_SHIFT;

// CLK_CONF: the core's clocks and resets, each way.
pub const CLK_TX_SCLK_EN: u32 = 1 << 24;
pub const CLK_RX_SCLK_EN: u32 = 1 << 25;
pub const CLK_TX_RST_CORE: u32 = 1 << 26;
pub const CLK_RX_RST_CORE: u32 = 1 << 27;

/// What was written to the _SYNC registers of the UART at `uart` (its
/// base) carried over into its core: REG_UPDATE set, and cleared by the
/// UART once it is done.
pub fn update(uart: usize) void {
    reg(uart + REG_UPDATE).* = 1;
    while (reg(uart + REG_UPDATE).* & 1 != 0) {}
}

// --- UART0 as the raw console -----------------------------------------------

const console = base(0);

/// The ROM's last bytes out, so its output and the kernel's do not run
/// together. The port itself stays as the ROM set it.
pub fn consoleInit() void {
    while (reg(console + STATUS).* & STATUS_TXFIFO_CNT != 0) {}
    while (reg(console + FSM_STATUS).* & FSM_ST_UTX_OUT != 0) {}
}

/// A byte out, waiting while the TX FIFO is full.
pub fn consolePut(character: u8) void {
    while ((reg(console + STATUS).* & STATUS_TXFIFO_CNT) >> STATUS_TXFIFO_CNT_SHIFT >= FIFO_LEN - 2) {}
    reg(console + FIFO).* = character;
}

/// A byte in, if one is waiting.
pub fn consoleGet() ?u8 {
    if (reg(console + STATUS).* & STATUS_RXFIFO_CNT == 0) return null;
    return @truncate(reg(console + FIFO).*);
}
