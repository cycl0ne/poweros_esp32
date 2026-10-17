// SPDX-License-Identifier: MIT
//! The console UART, a 16550: QEMU's, or the JH7110's DesignWare APB UART
//! in its 16550-compatible register set. UART0 is exec's raw console
//! (`consoleInit`, `consolePut`, `consoleGet`), polled.
//!
//! The two place the same registers differently: QEMU's are bytes, one
//! after the other; the JH7110's are 32-bit words, four bytes apart, and
//! want 32-bit accesses. Where the console is and how its registers are
//! read is `console`, which the kernel sets from the board before exec's
//! raw port starts.
//!
//! **The console needs no setting up.** The firmware below the kernel
//! (OpenSBI, and U-Boot on the board) leaves it running at 115200 8N1 -
//! its own banner comes out of it - so the raw port only lets its last
//! bytes out, keeps the line as it found it, and switches the FIFOs on.
//!
//! serial.device drives the same UART as its one unit (`Port.uart0`),
//! by interrupt: the receive side's, from the PLIC source the board
//! names. A 16550 has no flow control of its own and no modem lines
//! QEMU or the board wire up; xON/xOFF is the device's to do, and the
//! lines read as the registers have them.

const map = @import("map.zig");
const mmio = @import("mmio.zig");

/// Where a 16550's registers are and how they are read.
pub const Geometry = struct {
    base: usize = map.UART0,
    /// Register n is at base + (n << shift).
    shift: u3 = 0,
    /// 32-bit accesses (the DesignWare APB UART's) rather than bytes.
    wide: bool = false,
    /// The clock its divisor divides, in Hz.
    clock_hz: u32 = 0,
    /// Its PLIC source.
    irq: u32 = 0,
};

/// The console's, as the board says.
pub var console: Geometry = .{};

/// The registers, by number (the byte offset on a 16550 whose registers
/// are bytes).
pub const RBR = 0; // receive buffer (read)
pub const THR = 0; // transmit holding (write)
pub const DLL = 0; // divisor latch, low byte (LCR_DLAB set)
pub const IER = 1; // interrupt enable
pub const DLM = 1; // divisor latch, high byte (LCR_DLAB set)
pub const IIR = 2; // interrupt identification (read)
pub const FCR = 2; // FIFO control (write)
pub const LCR = 3; // line control
pub const MCR = 4; // modem control
pub const LSR = 5; // line status
pub const MSR = 6; // modem status
pub const SCR = 7; // scratch

pub const IER_RX_DATA: u8 = 1 << 0;
pub const IER_TX_EMPTY: u8 = 1 << 1;
pub const IER_LINE_STATUS: u8 = 1 << 2;
pub const IER_MODEM_STATUS: u8 = 1 << 3;

/// IIR's low four bits: none pending, or what is.
pub const IIR_NONE: u8 = 0x1;
pub const IIR_ID: u8 = 0xF;

pub const FCR_FIFO_ENABLE: u8 = 1 << 0;
pub const FCR_RX_RESET: u8 = 1 << 1;
pub const FCR_TX_RESET: u8 = 1 << 2;
/// The receive FIFO interrupts at 1, 4, 8 or 14 characters.
pub const FCR_RX_TRIGGER_1: u8 = 0 << 6;
pub const FCR_RX_TRIGGER_4: u8 = 1 << 6;
pub const FCR_RX_TRIGGER_8: u8 = 2 << 6;
pub const FCR_RX_TRIGGER_14: u8 = 3 << 6;

/// Word length 5-8 bits is 0-3.
pub const LCR_WORD_LENGTH: u8 = 0x3;
pub const LCR_STOP_2: u8 = 1 << 2;
pub const LCR_PARITY_ENABLE: u8 = 1 << 3;
pub const LCR_PARITY_EVEN: u8 = 1 << 4;
pub const LCR_BREAK: u8 = 1 << 6;
pub const LCR_DLAB: u8 = 1 << 7;

pub const MCR_DTR: u8 = 1 << 0;
pub const MCR_RTS: u8 = 1 << 1;
/// On a PC's 16550 the interrupt line's gate; kept on.
pub const MCR_OUT2: u8 = 1 << 3;

pub const LSR_DATA_READY: u8 = 1 << 0;
pub const LSR_OVERRUN: u8 = 1 << 1;
pub const LSR_PARITY_ERROR: u8 = 1 << 2;
pub const LSR_FRAMING_ERROR: u8 = 1 << 3;
pub const LSR_BREAK: u8 = 1 << 4;
pub const LSR_THR_EMPTY: u8 = 1 << 5;
pub const LSR_TX_EMPTY: u8 = 1 << 6;

pub const MSR_CTS: u8 = 1 << 4;
pub const MSR_DSR: u8 = 1 << 5;

/// The transmit FIFO's depth: 16 on both.
pub const FIFO_LEN = 16;

/// The DesignWare UART's own: IIR's "busy" - LCR written while a
/// character was going out, which the UART ignored - and the status
/// register whose read clears it.
pub const IIR_BUSY: u8 = 0x7;
pub const USR = 31;
/// USR: a character is coming in or going out, and LCR does not take a
/// write.
pub const USR_BUSY: u8 = 1 << 0;

/// Register `n` of the UART `geometry` describes.
pub inline fn readReg(geometry: Geometry, n: u8) u8 {
    const address = geometry.base + (@as(usize, n) << geometry.shift);
    return if (geometry.wide) @truncate(mmio.reg(address).*) else mmio.reg8(address).*;
}

pub inline fn writeReg(geometry: Geometry, n: u8, value: u8) void {
    const address = geometry.base + (@as(usize, n) << geometry.shift);
    if (geometry.wide) mmio.reg(address).* = value else mmio.reg8(address).* = value;
}

/// exec's raw port: what the firmware sent let out, and the FIFOs on. It
/// is polled, and leaves the UART's interrupts as they are: they are
/// serial.device's.
pub fn consoleInit() void {
    while (readReg(console, LSR) & LSR_TX_EMPTY == 0) {}
    writeReg(console, FCR, FCR_FIFO_ENABLE | FCR_RX_TRIGGER_1);
}

pub fn consolePut(character: u8) void {
    while (readReg(console, LSR) & LSR_THR_EMPTY == 0) {}
    writeReg(console, THR, character);
}

pub fn consoleGet() ?u8 {
    if (readReg(console, LSR) & LSR_DATA_READY == 0) return null;
    return readReg(console, RBR);
}

// --- the driver -------------------------------------------------------------

/// The boot-up rate, exec's raw port's too.
pub const default_baud = 115_200;

/// The UARTs serial.device has: the console.
pub const Port = enum(u3) {
    uart0,

    /// Its PLIC source.
    pub fn source(port: Port) u32 {
        return geometryOf(port).irq;
    }
};

fn geometryOf(port: Port) Geometry {
    return switch (port) {
        .uart0 => console,
    };
}

fn get(port: Port, n: u8) u8 {
    return readReg(geometryOf(port), n);
}

fn set(port: Port, n: u8, value: u8) void {
    writeReg(geometryOf(port), n, value);
}

/// The UART as serial.device takes it over: the firmware's line kept,
/// the FIFOs on with the receive side interrupting at every byte, DTR,
/// RTS and the interrupt gate (OUT2) on.
pub fn setUp(port: Port) void {
    set(port, FCR, FCR_FIFO_ENABLE | FCR_RX_TRIGGER_1);
    set(port, MCR, MCR_DTR | MCR_RTS | MCR_OUT2);
}

/// One byte out. Waits while the transmit holding register is full.
pub fn putTo(port: Port, c: u8) void {
    while (get(port, LSR) & LSR_THR_EMPTY == 0) {}
    set(port, THR, c);
}

/// The next byte the UART received, if any.
pub fn read(port: Port) ?u8 {
    if (get(port, LSR) & LSR_DATA_READY == 0) return null;
    return get(port, RBR);
}

/// The receive interrupts on: data, and the line's errors and breaks.
/// Enable the source first; an interrupt raised before that waits.
pub fn enableRx(port: Port) void {
    set(port, IER, get(port, IER) | IER_RX_DATA | IER_LINE_STATUS);
}

pub fn disableRx(port: Port) void {
    set(port, IER, get(port, IER) & ~(IER_RX_DATA | IER_LINE_STATUS));
}

/// What a receive interrupt found.
pub const RxEvents = struct {
    parity_error: bool = false,
    frame_error: bool = false,
    /// The hardware FIFO overflowed.
    overflow: bool = false,
    /// A break came in.
    brk: bool = false,
    /// The 16550 takes no xON or xOFF out of the input.
    xon: bool = false,
    xoff: bool = false,
};

/// What the UART's interrupt raised, null if it raised nothing: the line
/// status read (which clears its errors), and the data left for the
/// server to read - reading the UART empty lowers the data interrupt. A
/// DesignWare UART's busy interrupt is cleared and reported as nothing.
pub fn takeRxInterrupt(port: Port) ?RxEvents {
    const id = get(port, IIR) & IIR_ID;
    if (id == IIR_NONE) return null;
    if (id == IIR_BUSY) {
        _ = get(port, USR);
        return null;
    }
    const status = get(port, LSR);
    return .{
        .parity_error = status & LSR_PARITY_ERROR != 0,
        .frame_error = status & LSR_FRAMING_ERROR != 0,
        .overflow = status & LSR_OVERRUN != 0,
        .brk = status & LSR_BREAK != 0,
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
    /// Software flow control, which a 16550 does not do itself.
    xon_xoff: bool,
    xon: u8,
    xoff: u8,
};

/// Wait until the UART has sent everything, the last bit included.
fn waitTxIdle(port: Port) void {
    while (get(port, LSR) & LSR_TX_EMPTY == 0) {}
}

/// Set the UART's line, once the last byte has left: the divisor from
/// the clock the board names (kept as the firmware set it when the board
/// names none), then the frame.
pub fn setLine(port: Port, line: Line) void {
    waitTxIdle(port);
    var lcr: u8 = line.bits - 5;
    if (line.stop_bits == 2) lcr |= LCR_STOP_2;
    switch (line.parity) {
        .none => {},
        .even => lcr |= LCR_PARITY_ENABLE | LCR_PARITY_EVEN,
        .odd => lcr |= LCR_PARITY_ENABLE,
    }
    const clock_hz = geometryOf(port).clock_hz;
    if (clock_hz != 0 and line.baud != 0) {
        const divisor: u32 = @max(1, (clock_hz + 8 * line.baud) / (16 * line.baud));
        setLcr(port, LCR_DLAB);
        set(port, DLL, @truncate(divisor));
        set(port, DLM, @truncate(divisor >> 8));
    }
    setLcr(port, lcr);
}

/// LCR written so that it takes. A DesignWare UART that is busy - a
/// character coming in, as well as one going out - ignores the write,
/// and then a divisor written next would go to THR and IER instead. So
/// it is read back, and until it holds what was written the FIFOs are
/// cleared and the UART let finish (USR, which only a DesignWare UART
/// has, and only it gets this far), as Linux's dw8250 does. What was
/// coming in meanwhile is lost: the line is changing anyway.
fn setLcr(port: Port, value: u8) void {
    var tries: u32 = 0;
    while (tries < 16) : (tries += 1) {
        set(port, LCR, value);
        if (get(port, LCR) == value) return;
        set(port, FCR, FCR_FIFO_ENABLE | FCR_RX_RESET | FCR_TX_RESET);
        _ = get(port, RBR);
        var spins: u32 = 0;
        while (get(port, USR) & USR_BUSY != 0 and spins < 100_000) : (spins += 1) {}
        set(port, FCR, FCR_FIFO_ENABLE | FCR_RX_TRIGGER_1);
    }
}

/// Hold the TX line low (a break), or let it go again; the break starts
/// once the last byte has left.
pub fn setBreak(port: Port, on: bool) void {
    if (on) {
        waitTxIdle(port);
        setLcr(port, get(port, LCR) | LCR_BREAK);
    } else {
        setLcr(port, get(port, LCR) & ~LCR_BREAK);
    }
}

/// The UART's modem lines, as levels: low (false) is active.
pub const Lines = struct { dsr_n: bool, cts_n: bool, rts_n: bool, dtr_n: bool };

pub fn lines(port: Port) Lines {
    const msr = get(port, MSR);
    const mcr = get(port, MCR);
    return .{
        .dsr_n = msr & MSR_DSR == 0,
        .cts_n = msr & MSR_CTS == 0,
        .rts_n = mcr & MCR_RTS == 0,
        .dtr_n = mcr & MCR_DTR == 0,
    };
}
