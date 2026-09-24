// SPDX-License-Identifier: MIT
//! The three UARTs' registers: the same block at each UART's base
//! (`base`), so the registers are offsets into it. serial.device's units
//! and exec's raw port (kprintf) both drive UART0 through these.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

/// A UART's registers, by its number (0-2).
pub inline fn base(comptime n: u2) usize {
    return switch (n) {
        0 => map.UART0,
        1 => map.UART1,
        2 => map.UART2,
        3 => @compileError("the chip has three UARTs"),
    };
}

/// The same, for a number known only at run time.
pub fn baseOf(n: u2) usize {
    return switch (n) {
        0 => map.UART0,
        1 => map.UART1,
        else => map.UART2,
    };
}

// The registers, as offsets from a UART's base.
pub const FIFO = 0x00;
pub const INT_RAW = 0x04;
pub const INT_ST = 0x08;
pub const INT_ENA = 0x0C;
pub const INT_CLR = 0x10;
pub const CLKDIV = 0x14;
pub const STATUS = 0x1C;
pub const CONF0 = 0x20;
pub const CONF1 = 0x24;
pub const FLOW_CONF = 0x34;
pub const SWFC_CONF0 = 0x3C;
pub const SWFC_CONF1 = 0x40;
pub const FSM_STATUS = 0x6C;
pub const CLK_CONF = 0x78;

/// The FIFOs' depth, in bytes, each way.
pub const FIFO_LEN = 128;

// INT_*: the interrupt bits, in INT_RAW, INT_ST, INT_ENA and INT_CLR.
pub const INT_RXFIFO_FULL: u32 = 1 << 0;
pub const INT_PARITY_ERR: u32 = 1 << 2;
pub const INT_FRM_ERR: u32 = 1 << 3;
pub const INT_RXFIFO_OVF: u32 = 1 << 4;
pub const INT_BRK_DET: u32 = 1 << 7;
pub const INT_SW_XON: u32 = 1 << 9;
pub const INT_SW_XOFF: u32 = 1 << 10;

// CLKDIV: the divider's integer part (bits 0-11) and its sixteenths
// (bits 20-23).
pub const CLKDIV_FRAG_SHIFT = 20;

// STATUS: how full each FIFO is, and the modem lines' levels (active low).
pub const STATUS_RXFIFO_CNT: u32 = 0x3FF;
pub const STATUS_TXFIFO_CNT_SHIFT = 16;
pub const STATUS_TXFIFO_CNT: u32 = 0x3FF << STATUS_TXFIFO_CNT_SHIFT;
pub const STATUS_DSRN: u32 = 1 << 13;
pub const STATUS_CTSN: u32 = 1 << 14;
pub const STATUS_DTRN: u32 = 1 << 29;
pub const STATUS_RTSN: u32 = 1 << 30;

// CONF0: parity (bits 0-1), data bits (2-3: 5 to 8), stop bits (4-5: 1
// is one, 3 is two), the TX line inverted.
pub const CONF0_PARITY: u32 = 1 << 0;
pub const CONF0_PARITY_EN: u32 = 1 << 1;
pub const CONF0_BIT_NUM_SHIFT = 2;
pub const CONF0_STOP_BIT_NUM_SHIFT = 4;
/// Everything that says what a character is.
pub const CONF0_FRAME: u32 = 0x3F;
/// Eight data bits, no parity, one stop bit.
pub const CONF0_8N1: u32 = 3 << CONF0_BIT_NUM_SHIFT | 1 << CONF0_STOP_BIT_NUM_SHIFT;
pub const CONF0_TXD_INV: u32 = 1 << 22;

// CONF1: how many bytes in the RX FIFO raise RXFIFO_FULL (bits 0-9).
pub const CONF1_RXFIFO_FULL_THRHD: u32 = 0x3FF;

// FLOW_CONF: XON/XOFF done by the UART itself.
pub const FLOW_SW_FLOW_CON_EN: u32 = 1 << 0;
pub const FLOW_XONOFF_DEL: u32 = 1 << 1;

// FSM_STATUS: the transmitter's state machine (bits 4-7), 0 when idle.
pub const FSM_ST_UTX_OUT_SHIFT = 4;
pub const FSM_ST_UTX_OUT: u32 = 0xF << FSM_ST_UTX_OUT_SHIFT;

// CLK_CONF: the clock the UART counts from, divided.
pub const CLK_SCLK_DIV_NUM_SHIFT = 12;
pub const CLK_SCLK_DIV_NUM: u32 = 0xFF << CLK_SCLK_DIV_NUM_SHIFT;
pub const CLK_SCLK_SEL_SHIFT = 20;
pub const CLK_SCLK_SEL: u32 = 3 << CLK_SCLK_SEL_SHIFT;
/// The 40 MHz crystal as the UART's clock.
pub const CLK_SCLK_SEL_XTAL: u32 = 3 << CLK_SCLK_SEL_SHIFT;
pub const CLK_SCLK_EN: u32 = 1 << 22;
pub const CLK_RST_CORE: u32 = 1 << 23;
pub const CLK_TX_SCLK_EN: u32 = 1 << 24;
pub const CLK_RX_SCLK_EN: u32 = 1 << 25;
