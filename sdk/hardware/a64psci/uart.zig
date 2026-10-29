// SPDX-License-Identifier: MIT
//! The console UART, an Arm PL011 (Arm DDI 0183): QEMU's virt's, the
//! BCM2712's debug UART, and the CM5's RP1's UART0. UART0 is exec's raw
//! console (`consoleInit`, `consolePut`, `consoleGet`), polled.
//!
//! Where the console is, its clock and its interrupt are `console`, which
//! the kernel sets from the board before exec's raw port starts.
//!
//! **The console needs little setting up.** The Pi's firmware leaves it
//! running at 115200 8N1; QEMU's runs whatever it is told. The raw port
//! switches it on with its FIFOs if it is off, and sets the rate only
//! when the board names the UART's clock and the UART had none set.
//!
//! serial.device drives the same UART as its one unit (`Port.uart0`), by
//! interrupt: the receive side's, and its timeout's, which says the FIFO
//! holds bytes below its trigger level that have waited. The PL011's
//! modem lines are its own: RTS and DTR in its control register, CTS and
//! DSR in its flags.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;

/// Where a PL011 is, and what the board says of it.
pub const Geometry = struct {
    base: usize = map.UART0,
    /// The clock its divisor divides, in Hz; 0 if the board does not say.
    clock_hz: u32 = 0,
    /// Its interrupt ID.
    irq: u32 = 0,
};

/// The console's, as the board says.
pub var console: Geometry = .{};

/// The registers, by their offsets.
pub const DR = 0x00; // data
pub const RSR = 0x04; // receive status (read), error clear (write)
pub const FR = 0x18; // flags
pub const IBRD = 0x24; // integer baud rate divisor
pub const FBRD = 0x28; // fractional baud rate divisor
pub const LCR_H = 0x2C; // line control
pub const CR = 0x30; // control
pub const IFLS = 0x34; // FIFO interrupt levels
pub const IMSC = 0x38; // interrupt mask (set: on)
pub const RIS = 0x3C; // raw interrupt status
pub const MIS = 0x40; // masked interrupt status
pub const ICR = 0x44; // interrupt clear

/// DR, as read: the byte and what came with it.
pub const DR_FE: u32 = 1 << 8;
pub const DR_PE: u32 = 1 << 9;
pub const DR_BE: u32 = 1 << 10;
pub const DR_OE: u32 = 1 << 11;

pub const FR_CTS: u32 = 1 << 0;
pub const FR_DSR: u32 = 1 << 1;
pub const FR_BUSY: u32 = 1 << 3;
pub const FR_RXFE: u32 = 1 << 4;
pub const FR_TXFF: u32 = 1 << 5;
pub const FR_TXFE: u32 = 1 << 7;

pub const LCR_H_BRK: u32 = 1 << 0;
pub const LCR_H_PEN: u32 = 1 << 1;
pub const LCR_H_EPS: u32 = 1 << 2;
pub const LCR_H_STP2: u32 = 1 << 3;
pub const LCR_H_FEN: u32 = 1 << 4;
/// Word length 5-8 bits is 0-3 here.
pub const LCR_H_WLEN_SHIFT: u5 = 5;
pub const LCR_H_WLEN_8: u32 = 3 << LCR_H_WLEN_SHIFT;

pub const CR_UARTEN: u32 = 1 << 0;
pub const CR_TXE: u32 = 1 << 8;
pub const CR_RXE: u32 = 1 << 9;
pub const CR_DTR: u32 = 1 << 10;
pub const CR_RTS: u32 = 1 << 11;

/// The interrupts, as IMSC, RIS, MIS and ICR have them.
pub const INT_RX: u32 = 1 << 4;
pub const INT_TX: u32 = 1 << 5;
pub const INT_RT: u32 = 1 << 6;
pub const INT_FE: u32 = 1 << 7;
pub const INT_PE: u32 = 1 << 8;
pub const INT_BE: u32 = 1 << 9;
pub const INT_OE: u32 = 1 << 10;
const INT_ERRORS = INT_FE | INT_PE | INT_BE | INT_OE;

/// The FIFOs' depth: 32 on the PL011 revisions both machines have.
pub const FIFO_LEN = 32;

fn at(geometry: Geometry, offset: usize) *volatile u32 {
    return reg(geometry.base + offset);
}

/// The divisor for `baud` from `clock_hz`, in sixty-fourths: IBRD above
/// six bits, FBRD in them.
fn divisor(clock_hz: u32, baud: u32) u32 {
    return @intCast((@as(u64, clock_hz) * 4 + baud / 2) / baud);
}

/// The UART stopped once its last character is out, its rate set when
/// the clock is known, the frame and FIFOs set, and on again with both
/// directions. The PL011 takes a new line only while it is off, and
/// latches the divisor on the write to LCR_H after it.
fn reprogram(geometry: Geometry, baud: u32, lcr: u32) void {
    while (at(geometry, FR).* & FR_BUSY != 0) {}
    const keep = at(geometry, CR).* & (CR_DTR | CR_RTS);
    at(geometry, CR).* = 0;
    if (geometry.clock_hz != 0 and baud != 0) {
        const div = divisor(geometry.clock_hz, baud);
        at(geometry, IBRD).* = @max(1, div >> 6);
        at(geometry, FBRD).* = div & 0x3F;
    }
    at(geometry, LCR_H).* = lcr;
    at(geometry, CR).* = keep | CR_UARTEN | CR_TXE | CR_RXE;
}

/// exec's raw port: the UART on with its FIFOs, as the firmware left it
/// where it left it running. It is polled, and leaves the UART's
/// interrupts as they are: they are serial.device's.
pub fn consoleInit() void {
    const cr = at(console, CR).*;
    const lcr = at(console, LCR_H).*;
    if (cr & (CR_UARTEN | CR_TXE | CR_RXE) == CR_UARTEN | CR_TXE | CR_RXE and lcr & LCR_H_FEN != 0) return;
    const frame = if (lcr & (3 << LCR_H_WLEN_SHIFT) == 0) LCR_H_WLEN_8 else lcr;
    const baud: u32 = if (at(console, IBRD).* == 0) default_baud else 0;
    reprogram(console, baud, frame | LCR_H_FEN);
}

pub fn consolePut(character: u8) void {
    while (at(console, FR).* & FR_TXFF != 0) {}
    at(console, DR).* = character;
}

pub fn consoleGet() ?u8 {
    if (at(console, FR).* & FR_RXFE != 0) return null;
    return @truncate(at(console, DR).*);
}

// --- the driver -------------------------------------------------------------

/// The boot-up rate, exec's raw port's too.
pub const default_baud = 115_200;

/// The UARTs serial.device has: the console.
pub const Port = enum(u3) {
    uart0,

    /// Its interrupt ID.
    pub fn source(port: Port) u32 {
        return geometryOf(port).irq;
    }
};

fn geometryOf(port: Port) Geometry {
    return switch (port) {
        .uart0 => console,
    };
}

fn get(port: Port, offset: usize) u32 {
    return at(geometryOf(port), offset).*;
}

fn set(port: Port, offset: usize, value: u32) void {
    at(geometryOf(port), offset).* = value;
}

/// The UART as serial.device takes it over: the firmware's line kept, the
/// FIFOs on with the receive side interrupting at an eighth full (and on
/// its timeout below that), DTR and RTS on.
pub fn setUp(port: Port) void {
    set(port, IFLS, 0);
    if (get(port, LCR_H) & LCR_H_FEN == 0) reprogram(geometryOf(port), 0, get(port, LCR_H) | LCR_H_FEN);
    set(port, CR, get(port, CR) | CR_DTR | CR_RTS);
}

/// One byte out. Waits while the transmit FIFO is full.
pub fn putTo(port: Port, c: u8) void {
    while (get(port, FR) & FR_TXFF != 0) {}
    set(port, DR, c);
}

/// The next byte the UART received, if any.
pub fn read(port: Port) ?u8 {
    if (get(port, FR) & FR_RXFE != 0) return null;
    return @truncate(get(port, DR));
}

/// The receive interrupts on: data, its timeout, and the line's errors
/// and breaks. Enable the source first; an interrupt raised before that
/// waits.
pub fn enableRx(port: Port) void {
    set(port, IMSC, get(port, IMSC) | INT_RX | INT_RT | INT_ERRORS);
}

pub fn disableRx(port: Port) void {
    set(port, IMSC, get(port, IMSC) & ~(INT_RX | INT_RT | INT_ERRORS));
}

/// What a receive interrupt found.
pub const RxEvents = struct {
    parity_error: bool = false,
    frame_error: bool = false,
    /// The hardware FIFO overflowed.
    overflow: bool = false,
    /// A break came in.
    brk: bool = false,
    /// The PL011 takes no xON or xOFF out of the input.
    xon: bool = false,
    xoff: bool = false,
};

/// What the UART's interrupt raised, null if it raised nothing: its
/// errors, cleared, and the data left for the server to read. The data
/// and timeout interrupts are cleared too: reading the FIFO empty ends
/// them, and one that comes in meanwhile raises them again.
pub fn takeRxInterrupt(port: Port) ?RxEvents {
    const status = get(port, MIS);
    if (status & (INT_RX | INT_RT | INT_ERRORS) == 0) return null;
    set(port, ICR, status & (INT_RX | INT_RT | INT_ERRORS));
    set(port, RSR, 0);
    return .{
        .parity_error = status & INT_PE != 0,
        .frame_error = status & INT_FE != 0,
        .overflow = status & INT_OE != 0,
        .brk = status & INT_BE != 0,
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
    /// Software flow control, which a PL011 does not do itself.
    xon_xoff: bool,
    xon: u8,
    xoff: u8,
};

/// Set the UART's line, once the last byte has left: the divisor from the
/// clock the board names (kept as the firmware set it when the board names
/// none), then the frame.
pub fn setLine(port: Port, line: Line) void {
    var lcr: u32 = LCR_H_FEN | @as(u32, line.bits - 5) << LCR_H_WLEN_SHIFT;
    if (line.stop_bits == 2) lcr |= LCR_H_STP2;
    switch (line.parity) {
        .none => {},
        .even => lcr |= LCR_H_PEN | LCR_H_EPS,
        .odd => lcr |= LCR_H_PEN,
    }
    lcr |= get(port, LCR_H) & LCR_H_BRK;
    reprogram(geometryOf(port), line.baud, lcr);
}

/// Hold the TX line low (a break), or let it go again; the break starts
/// once the last byte has left.
pub fn setBreak(port: Port, on: bool) void {
    if (on) {
        while (get(port, FR) & FR_BUSY != 0) {}
        set(port, LCR_H, get(port, LCR_H) | LCR_H_BRK);
    } else {
        set(port, LCR_H, get(port, LCR_H) & ~LCR_H_BRK);
    }
}

/// The UART's modem lines, as levels: low (false) is active.
pub const Lines = struct { dsr_n: bool, cts_n: bool, rts_n: bool, dtr_n: bool };

pub fn lines(port: Port) Lines {
    const flags = get(port, FR);
    const control = get(port, CR);
    return .{
        .dsr_n = flags & FR_DSR == 0,
        .cts_n = flags & FR_CTS == 0,
        .rts_n = control & CR_RTS == 0,
        .dtr_n = control & CR_DTR == 0,
    };
}
