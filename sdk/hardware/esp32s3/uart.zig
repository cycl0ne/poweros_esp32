// SPDX-License-Identifier: MIT
//! The three UARTs: their registers - the same block at each UART's base
//! (`base`), so the registers are offsets into it - and the driver every
//! module that runs a UART shares: setting one up (`setUp`), its line
//! (`setLine`), bytes in and out, the receive interrupts. serial.device's
//! units and rs485.device run on it; exec's raw port (kprintf) drives
//! UART0 as the console (`consoleInit`, `consolePut`, `consoleGet`).
//!
//! The driver keeps no state: whether a UART is up is its bus clock and
//! its clock source, read back.

const map = @import("map.zig");
const hardware = @import("hardware.zig");
const intbits = @import("intbits.zig");
const system = @import("system.zig");
const reg = @import("mmio.zig").reg;

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

// --- UART0 as the raw console -----------------------------------------------

/// UART0 as exec's raw console (`consoleInit`, `consolePut`, `consoleGet`),
/// set up the same way `setUp` would: bus clock, reset with the core held,
/// the crystal as its clock, 115200 8N1. serial.device then finds UART0
/// already running from the crystal and leaves it alone. The helpers mask
/// interrupts at the CPU, not through exec: this runs before exec is up,
/// and after it has stopped.
const console = base(0);

/// UART0 set up. Whatever the boot ROM was still sending is let out
/// first, so its output and the kernel's do not run together.
pub fn consoleInit() void {
    while (reg(console + STATUS).* & STATUS_TXFIFO_CNT != 0) {}
    while (reg(console + FSM_STATUS).* & FSM_ST_UTX_OUT != 0) {}
    system.clockOn(.uart_mem);
    system.clockOn(.uart0);
    system.releaseReset(.uart0);
    reg(console + CLK_CONF).* |= CLK_RST_CORE;
    system.holdInReset(.uart0);
    system.releaseReset(.uart0);
    reg(console + CLK_CONF).* &= ~CLK_RST_CORE;
    const clk = reg(console + CLK_CONF).* & ~(CLK_SCLK_SEL | CLK_SCLK_DIV_NUM);
    reg(console + CLK_CONF).* = clk | CLK_SCLK_SEL_XTAL | CLK_SCLK_EN | CLK_TX_SCLK_EN | CLK_RX_SCLK_EN;
    const div16: u32 = (hardware.XTAL_HZ << 4) / default_baud; // in 1/16 steps
    reg(console + CLKDIV).* = (div16 & 0xF) << CLKDIV_FRAG_SHIFT | div16 >> 4;
    reg(console + CONF0).* = (reg(console + CONF0).* & ~CONF0_FRAME) | CONF0_8N1;
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
pub const RS485_CONF = 0x4C;
pub const MEM_CONF = 0x60;
pub const CLK_CONF = 0x78;

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
pub const CONF1_TXFIFO_EMPTY_THRHD_SHIFT = 10;
pub const CONF1_TXFIFO_EMPTY_THRHD: u32 = 0x3FF << CONF1_TXFIFO_EMPTY_THRHD_SHIFT;
/// The receive time-out on: RXFIFO_TOUT once the line has been quiet for
/// MEM_CONF's threshold with bytes in the FIFO.
pub const CONF1_RX_TOUT_EN: u32 = 1 << 23;

// RS485_CONF: the RS-485 mode. With RS485TX_RX_EN clear the receiver
// takes nothing in while the transmitter sends, so a transceiver that
// hears its own driver gives no echo.
pub const RS485_EN: u32 = 1 << 0;
pub const RS485TX_RX_EN: u32 = 1 << 3;
pub const RS485RXBY_TX_EN: u32 = 1 << 4;

// MEM_CONF: the receive time-out's threshold, in bit times (10 bits).
pub const MEM_CONF_RX_TOUT_THRHD_SHIFT = 17;
pub const MEM_CONF_RX_TOUT_THRHD: u32 = 0x3FF << MEM_CONF_RX_TOUT_THRHD_SHIFT;

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

// --- the driver -------------------------------------------------------------

/// The boot-up rate, exec's raw port's too.
pub const default_baud = 115_200;

/// The three UARTs, their registers and their interrupt sources
/// (ETS_UART0_INTR_SOURCE and the two after it).
pub const Port = enum(u2) {
    uart0,
    uart1,
    uart2,

    pub fn source(port: Port) u32 {
        return intbits.INTB_UART0 + @intFromEnum(port);
    }
};

comptime {
    if (intbits.INTB_UART2 != intbits.INTB_UART0 + 2) @compileError("UART sources aren't consecutive");
}

fn r(port: Port, offset: usize) *volatile u32 {
    return reg(baseOf(@intFromEnum(port)) + offset);
}

/// The receive side's interrupts.
const rx_ints = INT_RXFIFO_FULL | INT_PARITY_ERR | INT_FRM_ERR |
    INT_RXFIFO_OVF | INT_BRK_DET | INT_SW_XON | INT_SW_XOFF;

/// A UART's bus clock and reset, in SYSTEM.
fn peripheralOf(comptime port: Port) system.Peripheral {
    return switch (port) {
        .uart0 => .uart0,
        .uart1 => .uart1,
        .uart2 => .uart2,
    };
}

/// One step of a UART's bus set-up. SYSTEM's helpers take their
/// peripheral at compile time, so the port picks which one.
const BusStep = enum { clock_on, hold_in_reset, release_reset };

fn busStep(port: Port, step: BusStep) void {
    switch (port) {
        inline else => |known| {
            const peripheral = comptime peripheralOf(known);
            switch (step) {
                .clock_on => system.clockOn(peripheral),
                .hold_in_reset => system.holdInReset(peripheral),
                .release_reset => system.releaseReset(peripheral),
            }
        },
    }
}

fn busClockIsOn(port: Port) bool {
    return switch (port) {
        inline else => |known| system.clockIsOn(comptime peripheralOf(known)),
    };
}

/// Set the UART up: its bus clock on, reset, the crystal as its clock,
/// the boot-up line (115200 8N1, no flow control). The core is held
/// in reset across the bus reset, as ESP-IDF's uart_ll_reset_register does
/// on the S3, or the UART sends garbage. A UART that runs from the crystal
/// already is left as it is: exec's RawIOInit sets UART0 up that way (its
/// own driver, rawio/_rawio.zig), and a reset would cut its output.
pub fn setUp(port: Port) void {
    const running = CLK_SCLK_EN | CLK_SCLK_SEL_XTAL;
    if (busClockIsOn(port) and r(port, CLK_CONF).* & running == running) return;
    system.clockOn(.uart_mem);
    busStep(port, .clock_on);
    busStep(port, .release_reset);
    r(port, CLK_CONF).* |= CLK_RST_CORE;
    busStep(port, .hold_in_reset);
    busStep(port, .release_reset);
    r(port, CLK_CONF).* &= ~CLK_RST_CORE;
    const sel = r(port, CLK_CONF).* & ~CLK_SCLK_SEL;
    r(port, CLK_CONF).* = sel | CLK_SCLK_SEL_XTAL | CLK_SCLK_EN | CLK_TX_SCLK_EN | CLK_RX_SCLK_EN;
    setLine(port, .{ .baud = default_baud, .bits = 8, .parity = .none, .stop_bits = 1, .xon_xoff = false, .xon = 0x11, .xoff = 0x13 });
}

/// One byte out. Waits while the TX FIFO is full.
pub fn putTo(port: Port, c: u8) void {
    while ((r(port, STATUS).* & STATUS_TXFIFO_CNT) >> STATUS_TXFIFO_CNT_SHIFT >= FIFO_LEN - 2) {}
    r(port, FIFO).* = c;
}

/// The next byte the UART received, if any.
pub fn read(port: Port) ?u8 {
    if (r(port, STATUS).* & STATUS_RXFIFO_CNT == 0) return null;
    return @truncate(r(port, FIFO).*);
}

/// The receive interrupts on: for every byte (FIFO threshold 1), receive
/// errors, breaks and xON/xOFF. Route the source first; an interrupt
/// raised before that is lost.
pub fn enableRx(port: Port) void {
    r(port, CONF1).* = (r(port, CONF1).* & ~CONF1_RXFIFO_FULL_THRHD) | 1;
    r(port, INT_CLR).* = rx_ints;
    r(port, INT_ENA).* |= rx_ints;
}

pub fn disableRx(port: Port) void {
    r(port, INT_ENA).* &= ~rx_ints;
    r(port, INT_CLR).* = rx_ints;
}

/// What a receive interrupt found.
pub const RxEvents = struct {
    parity_error: bool = false,
    frame_error: bool = false,
    /// The hardware FIFO overflowed.
    overflow: bool = false,
    /// A break came in.
    brk: bool = false,
    /// The other side sent xON or xOFF (with software flow control on).
    xon: bool = false,
    xoff: bool = false,
};

/// What the UART's receive interrupt raised, cleared; null if it raised
/// nothing. Clear first, then read the UART empty: a byte that comes in
/// between raises it again.
pub fn takeRxInterrupt(port: Port) ?RxEvents {
    const st = r(port, INT_ST).* & rx_ints;
    if (st == 0) return null;
    r(port, INT_CLR).* = st;
    return .{
        .parity_error = st & INT_PARITY_ERR != 0,
        .frame_error = st & INT_FRM_ERR != 0,
        .overflow = st & INT_RXFIFO_OVF != 0,
        .brk = st & INT_BRK_DET != 0,
        .xon = st & INT_SW_XON != 0,
        .xoff = st & INT_SW_XOFF != 0,
    };
}

pub const Parity = enum { none, even, odd };

/// A UART's line.
pub const Line = struct {
    baud: u32,
    /// 5 to 8.
    bits: u8,
    parity: Parity,
    /// 1 or 2.
    stop_bits: u8,
    /// Software flow control: stop sending on xOFF, go on at xON (both
    /// taken out of the input), and send xOFF when the FIFO fills.
    xon_xoff: bool,
    xon: u8,
    xoff: u8,
};

/// Wait until the UART has sent everything, the last bit included.
fn waitTxIdle(port: Port) void {
    while (r(port, STATUS).* & STATUS_TXFIFO_CNT != 0) {}
    while (r(port, FSM_STATUS).* & FSM_ST_UTX_OUT != 0) {}
}

/// Set the UART's line, once the last byte has left. The rate comes from
/// the crystal: SCLK_DIV_NUM divides it down for slow rates, CLKDIV (with
/// 1/16 steps) does the rest.
pub fn setLine(port: Port, line: Line) void {
    waitTxIdle(port);
    const max_div: u64 = 0xFFF;
    const baud: u64 = line.baud;
    const sclk_div = @max(1, (hardware.XTAL_HZ + max_div * baud - 1) / (max_div * baud));
    const div16 = (@as(u64, hardware.XTAL_HZ) << 4) / (baud * sclk_div);
    r(port, CLKDIV).* = @truncate((div16 & 0xF) << CLKDIV_FRAG_SHIFT | div16 >> 4);
    const clk = r(port, CLK_CONF).* & ~CLK_SCLK_DIV_NUM;
    r(port, CLK_CONF).* = clk | @as(u32, @intCast(sclk_div - 1)) << CLK_SCLK_DIV_NUM_SHIFT;

    var c0 = r(port, CONF0).* & ~(CONF0_PARITY | CONF0_PARITY_EN | 3 << CONF0_BIT_NUM_SHIFT | 3 << CONF0_STOP_BIT_NUM_SHIFT);
    c0 |= @as(u32, line.bits - 5) << CONF0_BIT_NUM_SHIFT;
    c0 |= @as(u32, if (line.stop_bits == 2) 3 else 1) << CONF0_STOP_BIT_NUM_SHIFT;
    switch (line.parity) {
        .none => {},
        .even => c0 |= CONF0_PARITY_EN,
        .odd => c0 |= CONF0_PARITY_EN | CONF0_PARITY,
    }
    r(port, CONF0).* = c0;

    // xOFF when the 128-byte FIFO holds 100, xON again at 20.
    r(port, SWFC_CONF0).* = 100 | @as(u32, line.xoff) << 10;
    r(port, SWFC_CONF1).* = 20 | @as(u32, line.xon) << 10;
    const flow = r(port, FLOW_CONF).* & ~(FLOW_SW_FLOW_CON_EN | FLOW_XONOFF_DEL);
    r(port, FLOW_CONF).* = flow | if (line.xon_xoff) FLOW_SW_FLOW_CON_EN | FLOW_XONOFF_DEL else 0;
}

/// Hold the TX line low (a break), or let it go again. Inverting TXD makes
/// the idle line low; the break starts once the last byte has left.
pub fn setBreak(port: Port, on: bool) void {
    if (on) {
        waitTxIdle(port);
        r(port, CONF0).* |= CONF0_TXD_INV;
    } else {
        r(port, CONF0).* &= ~CONF0_TXD_INV;
    }
}

/// The UART's modem lines, as levels: low (false) is active.
pub const Lines = struct { dsr_n: bool, cts_n: bool, rts_n: bool, dtr_n: bool };

pub fn lines(port: Port) Lines {
    const s = r(port, STATUS).*;
    return .{
        .dsr_n = s & STATUS_DSRN != 0,
        .cts_n = s & STATUS_CTSN != 0,
        .rts_n = s & STATUS_RTSN != 0,
        .dtr_n = s & STATUS_DTRN != 0,
    };
}
