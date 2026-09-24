// SPDX-License-Identifier: MPL-2.0
//! The chip's UARTs 0-2, as serial.device's units 0-2 (unit.zig). setUp brings a UART
//! up: bus clock, reset, the 40 MHz crystal as its clock, and the boot-up
//! line, 115200 8N1. UART0 is exec's raw port (kprintf) too, but exec
//! drives it with its own driver (src/rom/libs/exec/rawio/_rawio.zig) and sets it
//! up first; setUp then leaves it running. Pins aren't routed here: UART0
//! keeps the ROM's (GPIO43 TX, GPIO44 RX); UART1 and UART2 have none yet.

const hardware = @import("sdk").hardware;
const intbits = hardware.intbits;
const reg = hardware.mmio.reg;
const system = hardware.system;
const regs = hardware.uart;

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
    return reg(regs.baseOf(@intFromEnum(port)) + offset);
}

/// The receive side's interrupts.
const rx_ints = regs.INT_RXFIFO_FULL | regs.INT_PARITY_ERR | regs.INT_FRM_ERR |
    regs.INT_RXFIFO_OVF | regs.INT_BRK_DET | regs.INT_SW_XON | regs.INT_SW_XOFF;

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

var set_up = [_]bool{ false, false, false };

/// Set the UART up, once: its bus clock on, reset, the crystal as its
/// clock, the boot-up line (115200 8N1, no flow control). The core is held
/// in reset across the bus reset, as ESP-IDF's uart_ll_reset_register does
/// on the S3, or the UART sends garbage. A UART that runs from the crystal
/// already is left as it is: exec's RawIOInit sets UART0 up that way (its
/// own driver, rawio/_rawio.zig), and a reset would cut its output.
pub fn setUp(port: Port) void {
    if (set_up[@intFromEnum(port)]) return;
    set_up[@intFromEnum(port)] = true;
    const running = regs.CLK_SCLK_EN | regs.CLK_SCLK_SEL_XTAL;
    if (busClockIsOn(port) and r(port, regs.CLK_CONF).* & running == running) return;
    system.clockOn(.uart_mem);
    busStep(port, .clock_on);
    busStep(port, .release_reset);
    r(port, regs.CLK_CONF).* |= regs.CLK_RST_CORE;
    busStep(port, .hold_in_reset);
    busStep(port, .release_reset);
    r(port, regs.CLK_CONF).* &= ~regs.CLK_RST_CORE;
    const sel = r(port, regs.CLK_CONF).* & ~regs.CLK_SCLK_SEL;
    r(port, regs.CLK_CONF).* = sel | regs.CLK_SCLK_SEL_XTAL | regs.CLK_SCLK_EN | regs.CLK_TX_SCLK_EN | regs.CLK_RX_SCLK_EN;
    setLine(port, .{ .baud = default_baud, .bits = 8, .parity = .none, .stop_bits = 1, .xon_xoff = false, .xon = 0x11, .xoff = 0x13 });
}

/// One byte out. Waits while the TX FIFO is full.
pub fn putTo(port: Port, c: u8) void {
    while ((r(port, regs.STATUS).* & regs.STATUS_TXFIFO_CNT) >> regs.STATUS_TXFIFO_CNT_SHIFT >= regs.FIFO_LEN - 2) {}
    r(port, regs.FIFO).* = c;
}

/// The next byte the UART received, if any.
pub fn read(port: Port) ?u8 {
    if (r(port, regs.STATUS).* & regs.STATUS_RXFIFO_CNT == 0) return null;
    return @truncate(r(port, regs.FIFO).*);
}

/// The receive interrupts on: for every byte (FIFO threshold 1), receive
/// errors, breaks and xON/xOFF. Route the source first; an interrupt
/// raised before that is lost.
pub fn enableRx(port: Port) void {
    r(port, regs.CONF1).* = (r(port, regs.CONF1).* & ~regs.CONF1_RXFIFO_FULL_THRHD) | 1;
    r(port, regs.INT_CLR).* = rx_ints;
    r(port, regs.INT_ENA).* |= rx_ints;
}

pub fn disableRx(port: Port) void {
    r(port, regs.INT_ENA).* &= ~rx_ints;
    r(port, regs.INT_CLR).* = rx_ints;
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
    const st = r(port, regs.INT_ST).* & rx_ints;
    if (st == 0) return null;
    r(port, regs.INT_CLR).* = st;
    return .{
        .parity_error = st & regs.INT_PARITY_ERR != 0,
        .frame_error = st & regs.INT_FRM_ERR != 0,
        .overflow = st & regs.INT_RXFIFO_OVF != 0,
        .brk = st & regs.INT_BRK_DET != 0,
        .xon = st & regs.INT_SW_XON != 0,
        .xoff = st & regs.INT_SW_XOFF != 0,
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
    while (r(port, regs.STATUS).* & regs.STATUS_TXFIFO_CNT != 0) {}
    while (r(port, regs.FSM_STATUS).* & regs.FSM_ST_UTX_OUT != 0) {}
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
    r(port, regs.CLKDIV).* = @truncate((div16 & 0xF) << regs.CLKDIV_FRAG_SHIFT | div16 >> 4);
    const clk = r(port, regs.CLK_CONF).* & ~regs.CLK_SCLK_DIV_NUM;
    r(port, regs.CLK_CONF).* = clk | @as(u32, @intCast(sclk_div - 1)) << regs.CLK_SCLK_DIV_NUM_SHIFT;

    var c0 = r(port, regs.CONF0).* & ~(regs.CONF0_PARITY | regs.CONF0_PARITY_EN | 3 << regs.CONF0_BIT_NUM_SHIFT | 3 << regs.CONF0_STOP_BIT_NUM_SHIFT);
    c0 |= @as(u32, line.bits - 5) << regs.CONF0_BIT_NUM_SHIFT;
    c0 |= @as(u32, if (line.stop_bits == 2) 3 else 1) << regs.CONF0_STOP_BIT_NUM_SHIFT;
    switch (line.parity) {
        .none => {},
        .even => c0 |= regs.CONF0_PARITY_EN,
        .odd => c0 |= regs.CONF0_PARITY_EN | regs.CONF0_PARITY,
    }
    r(port, regs.CONF0).* = c0;

    // xOFF when the 128-byte FIFO holds 100, xON again at 20.
    r(port, regs.SWFC_CONF0).* = 100 | @as(u32, line.xoff) << 10;
    r(port, regs.SWFC_CONF1).* = 20 | @as(u32, line.xon) << 10;
    const flow = r(port, regs.FLOW_CONF).* & ~(regs.FLOW_SW_FLOW_CON_EN | regs.FLOW_XONOFF_DEL);
    r(port, regs.FLOW_CONF).* = flow | if (line.xon_xoff) regs.FLOW_SW_FLOW_CON_EN | regs.FLOW_XONOFF_DEL else 0;
}

/// Hold the TX line low (a break), or let it go again. Inverting TXD makes
/// the idle line low; the break starts once the last byte has left.
pub fn setBreak(port: Port, on: bool) void {
    if (on) {
        waitTxIdle(port);
        r(port, regs.CONF0).* |= regs.CONF0_TXD_INV;
    } else {
        r(port, regs.CONF0).* &= ~regs.CONF0_TXD_INV;
    }
}

/// The UART's modem lines, as levels: low (false) is active.
pub const Lines = struct { dsr_n: bool, cts_n: bool, rts_n: bool, dtr_n: bool };

pub fn lines(port: Port) Lines {
    const s = r(port, regs.STATUS).*;
    return .{
        .dsr_n = s & regs.STATUS_DSRN != 0,
        .cts_n = s & regs.STATUS_CTSN != 0,
        .rts_n = s & regs.STATUS_RTSN != 0,
        .dtr_n = s & regs.STATUS_DTRN != 0,
    };
}
