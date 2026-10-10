// SPDX-License-Identifier: MIT
//! The five UARTs: their registers - the same block at each UART's base
//! (`base`), so the registers are offsets into it - UART0 as the raw
//! console exec's RawPutChar drives (`consoleInit`, `consolePut`,
//! `consoleGet`), and the calls serial.device drives a port with (`Port`,
//! `setUp`, `setLine`, ...), the ESP32-S3's calls.
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
const hardware = @import("hardware.zig");
const intbits = @import("intbits.zig");
const system = @import("system.zig");
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

// SWFC_CONF0: software flow control - the xON character in bits 0-7,
// xOFF in 8-15.
pub const SWFC_XOFF_CHAR_SHIFT = 8;
pub const SWFC_SW_FLOW_CON_EN: u32 = 1 << 17;
pub const SWFC_XONOFF_DEL: u32 = 1 << 18;
// SWFC_CONF1: the FIFO levels xON (bits 0-7) and xOFF (8-15) are sent at.
pub const SWFC_XOFF_THRESHOLD_SHIFT = 8;

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

// CLKDIV: the integer part's width.
pub const CLKDIV_MAX: u32 = 0xFFF;

// CLK_CONF: the core's clocks and resets, each way.
pub const CLK_TX_SCLK_EN: u32 = 1 << 24;
pub const CLK_RX_SCLK_EN: u32 = 1 << 25;
pub const CLK_TX_RST_CORE: u32 = 1 << 26;
pub const CLK_RX_RST_CORE: u32 = 1 << 27;

/// What was written to the _SYNC registers of the UART at `uart` (its
/// base) carried over into its core: REG_UPDATE set, and cleared by the
/// UART once it is done - within a few of its clocks, so a UART that
/// never clears it (no clock, or none there, as in an emulator) is given
/// up on rather than waited for.
pub fn update(uart: usize) void {
    reg(uart + REG_UPDATE).* = 1;
    var spins: u32 = 0;
    while (reg(uart + REG_UPDATE).* & 1 != 0 and spins < 100_000) spins += 1;
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

// --- the driver -------------------------------------------------------------

/// The boot-up rate, exec's raw port's too.
pub const default_baud = 115_200;

/// The five UARTs, their registers and their interrupt sources
/// (ETS_UART0_INTR_SOURCE and the four after it).
pub const Port = enum(u3) {
    uart0,
    uart1,
    uart2,
    uart3,
    uart4,

    pub fn source(port: Port) u32 {
        return intbits.INTB_UART0 + @intFromEnum(port);
    }
};

comptime {
    if (intbits.INTB_UART4 != intbits.INTB_UART0 + 4) @compileError("UART sources aren't consecutive");
}

fn r(port: Port, offset: usize) *volatile u32 {
    return reg(baseOf(@intFromEnum(port)) + offset);
}

/// The receive side's interrupts.
const rx_ints = INT_RXFIFO_FULL | INT_PARITY_ERR | INT_FRM_ERR |
    INT_RXFIFO_OVF | INT_BRK_DET | INT_SW_XON | INT_SW_XOFF;

/// A UART's clocks and resets in HP_SYS_CLKRST.
fn peripheralOf(comptime port: Port) system.Peripheral {
    return switch (port) {
        .uart0 => .uart0,
        .uart1 => .uart1,
        .uart2 => .uart2,
        .uart3 => .uart3,
        .uart4 => .uart4,
    };
}

fn busClockIsOn(port: Port) bool {
    return switch (port) {
        inline else => |known| system.clockIsOn(comptime peripheralOf(known)),
    };
}

/// The UART's clocks on and through a reset, its function clock the
/// crystal undivided. HP_SYS_CLKRST's helpers take their peripheral at
/// compile time, so the port picks which one.
fn enableBus(port: Port) void {
    switch (port) {
        inline else => |known| {
            const peripheral = comptime peripheralOf(known);
            system.enable(peripheral);
            system.setFunctionClock(peripheral, .{});
        },
    }
}

/// The function clock's divider for the crystal, 1 to 256.
fn setSclkDivider(port: Port, divider: u32) void {
    switch (port) {
        inline else => |known| system.setFunctionClock(comptime peripheralOf(known), .{ .divider = divider }),
    }
}

/// Set the UART up: its clocks on, through a reset, the crystal as its
/// clock, the boot-up line (115200 8N1, no flow control). A UART whose
/// clocks are on already is left as it is: the ROM leaves UART0 running
/// that way for exec's raw port, and a reset would cut its output.
pub fn setUp(port: Port) void {
    if (busClockIsOn(port)) return;
    enableBus(port);
    r(port, CLK_CONF).* |= CLK_TX_SCLK_EN | CLK_RX_SCLK_EN;
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
    const raised = r(port, INT_ST).* & rx_ints;
    if (raised == 0) return null;
    r(port, INT_CLR).* = raised;
    return .{
        .parity_error = raised & INT_PARITY_ERR != 0,
        .frame_error = raised & INT_FRM_ERR != 0,
        .overflow = raised & INT_RXFIFO_OVF != 0,
        .brk = raised & INT_BRK_DET != 0,
        .xon = raised & INT_SW_XON != 0,
        .xoff = raised & INT_SW_XOFF != 0,
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
/// the crystal: the function clock's divider takes it down for slow
/// rates, CLKDIV (with 1/16 steps) does the rest. The _SYNC registers
/// written take effect together, at the update.
pub fn setLine(port: Port, line: Line) void {
    waitTxIdle(port);
    const baud: u64 = line.baud;
    const sclk_div: u64 = @max(1, (hardware.XTAL_HZ + CLKDIV_MAX * baud - 1) / (CLKDIV_MAX * baud));
    const div16 = (@as(u64, hardware.XTAL_HZ) << 4) / (baud * sclk_div);
    setSclkDivider(port, @intCast(@min(sclk_div, 256)));
    r(port, CLKDIV).* = @truncate((div16 & 0xF) << CLKDIV_FRAG_SHIFT | div16 >> 4);

    var conf0 = r(port, CONF0).* & ~(CONF0_PARITY | CONF0_PARITY_EN | 3 << CONF0_BIT_NUM_SHIFT | 3 << CONF0_STOP_BIT_NUM_SHIFT);
    conf0 |= @as(u32, line.bits - 5) << CONF0_BIT_NUM_SHIFT;
    conf0 |= @as(u32, if (line.stop_bits == 2) 3 else 1) << CONF0_STOP_BIT_NUM_SHIFT;
    switch (line.parity) {
        .none => {},
        .even => conf0 |= CONF0_PARITY_EN,
        .odd => conf0 |= CONF0_PARITY_EN | CONF0_PARITY,
    }
    r(port, CONF0).* = conf0;

    // xOFF when the 128-byte FIFO holds 100, xON again at 20.
    r(port, SWFC_CONF1).* = 20 | @as(u32, 100) << SWFC_XOFF_THRESHOLD_SHIFT;
    var swfc = r(port, SWFC_CONF0).* & ~(@as(u32, 0xFFFF) | SWFC_SW_FLOW_CON_EN | SWFC_XONOFF_DEL);
    swfc |= line.xon | @as(u32, line.xoff) << SWFC_XOFF_CHAR_SHIFT;
    if (line.xon_xoff) swfc |= SWFC_SW_FLOW_CON_EN | SWFC_XONOFF_DEL;
    r(port, SWFC_CONF0).* = swfc;
    update(baseOf(@intFromEnum(port)));
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
    update(baseOf(@intFromEnum(port)));
}

/// The UART's modem lines, as levels: low (false) is active.
pub const Lines = struct { dsr_n: bool, cts_n: bool, rts_n: bool, dtr_n: bool };

pub fn lines(port: Port) Lines {
    const status = r(port, STATUS).*;
    return .{
        .dsr_n = status & STATUS_DSRN != 0,
        .cts_n = status & STATUS_CTSN != 0,
        .rts_n = status & STATUS_RTSN != 0,
        .dtr_n = status & STATUS_DTRN != 0,
    };
}
