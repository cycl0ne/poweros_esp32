// SPDX-License-Identifier: MIT
//! The BCM2711's mini UART, the line cyw43455bt.device speaks to the
//! controller on, and the controller's power line.
//!
//! **The mini UART** is the first of the AUX block's three peripherals:
//! its registers 0x40 into the block, which also holds the interrupt the
//! three share (AUX_IRQ, bit 0 the mini UART's) and their enables
//! (AUX_ENABLES, bit 0 the mini UART's - with it clear the mini UART's
//! registers do not answer). It has 8-byte FIFOs each way, and its rate
//! is the chip's core clock - the VideoCore's, which its firmware is
//! asked for - divided by eight times BAUD + 1.
//!
//!   0x00  IO     a byte from the receive FIFO, to the transmit FIFO
//!   0x04  IER    bit 0 the receive interrupt, bit 1 the transmit one;
//!                bits 2 and 3 set for either to reach the line
//!   0x08  IIR    written: bits 1 and 2 clear the receive and transmit
//!                FIFOs
//!   0x0C  LCR    3: eight data bits
//!   0x10  MCR    bit 1: RTS driven low, asserted, while auto RTS is off
//!   0x14  LSR    bit 0 a byte to read, bit 5 room to send one, bit 6 the
//!                transmitter idle
//!   0x18  MSR    bit 4: CTS low, asserted
//!   0x20  CNTL   bit 0 receiver on, bit 1 transmitter on, bit 2 RTS by
//!                the receive FIFO's level, bit 3 the transmitter held
//!                while CTS is not asserted; bits 4 and 5 the level, 3
//!                for RTS let go with four places left; bits 6 and 7 RTS
//!                and CTS asserted low - clear, the mini UART asserts
//!                them high
//!   0x28  BAUD   the divisor, 16 bits
//!
//! The receive interrupt stands while the receive FIFO holds a byte, the
//! transmit one while the transmit FIFO is empty: each comes again until
//! its FIFO is served or the interrupt turned off.
//!
//! **Flow control is the hardware's**: RTS goes up when the receive FIFO
//! has four places left, and the controller stops sending, so that a late
//! interrupt costs time and no bytes; the transmitter sends only while
//! the controller's RTS, the mini UART's CTS, is down. Both ends' lines
//! are asserted low, which the mini UART is told: by itself it asserts
//! its own high and takes CTS high for asserted.
//!
//! **The pins** are the part's (GPIO 30 to 33 on the Raspberry Pi 4 Model
//! B), each in its ALT5 function - every pin the mini UART's lines come
//! out on has them there - the receiving ones, RXD and CTS, pulled up, so
//! that with the controller's power away they read idle and not asserted
//! rather than whatever a floating line picks up.
//!
//! **The controller's power**, BT_REG_ON, is a line of the firmware's GPIO
//! expander, which the VideoCore's mailbox switches (the part's
//! PART_PinPower). The controller is reset by taking it low and raising
//! it again, and is ready 100 to 120 ms after - with RTS held up
//! meanwhile: a controller that finds it down as it starts waits to learn
//! the line's rate from the first command.
//!
//! The pin controller and the AUX enables are shared with whatever else
//! uses them, so every change is a masked read-modify-write inside exec's
//! Disable.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const videocore = sdk.hardware.videocore;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

// The AUX block, before the mini UART's registers.
const AUX_IRQ: isize = -0x40;
const AUX_ENABLES: isize = -0x3C;
const AUX_MINI_UART: u32 = 1 << 0;

// The mini UART's registers.
const MU_IO: usize = 0x00;
const MU_IER: usize = 0x04;
const MU_IIR: usize = 0x08;
const MU_LCR: usize = 0x0C;
const MU_MCR: usize = 0x10;
const MU_LSR: usize = 0x14;
const MU_MSR: usize = 0x18;
const MU_CNTL: usize = 0x20;
const MU_BAUD: usize = 0x28;

const IER_RX: u32 = 1 << 0;
const IER_TX: u32 = 1 << 1;
/// Without them neither interrupt reaches the line.
const IER_LINE: u32 = 3 << 2;
const IIR_CLEAR_FIFOS: u32 = 0xC6;
const LCR_8BIT: u32 = 3;
const MCR_RTS: u32 = 1 << 1;
const LSR_DATA: u32 = 1 << 0;
const LSR_TX_ROOM: u32 = 1 << 5;
const LSR_TX_IDLE: u32 = 1 << 6;
const MSR_CTS: u32 = 1 << 4;
const CNTL_RX: u32 = 1 << 0;
const CNTL_TX: u32 = 1 << 1;
const CNTL_AUTO_RTS: u32 = 1 << 2;
const CNTL_AUTO_CTS: u32 = 1 << 3;
/// RTS let go with four places left in the receive FIFO.
const CNTL_RTS_FOUR: u32 = 3 << 4;
/// RTS and CTS asserted low.
const CNTL_RTS_LOW: u32 = 1 << 6;
const CNTL_CTS_LOW: u32 = 1 << 7;

/// The BCM2711's GPIO block: three bits a pin for its function, ten pins
/// a register; two bits a pin for its pull, sixteen pins a register (0
/// none, 1 up).
const gpio: usize = 0xFE20_0000;
const GPFSEL0: usize = 0x00;
const GPIO_PUP_PDN_CNTRL_REG0: usize = 0xE4;
const FSEL_ALT5: u32 = 2;
const PULL_NONE: u32 = 0;
const PULL_UP: u32 = 1;

/// The pins the mini UART's lines come out on, each in its ALT5
/// function.
const txd_pins = [_]u8{ 14, 32, 40 };
const rxd_pins = [_]u8{ 15, 33, 41 };
const cts_pins = [_]u8{ 16, 30, 43 };
const rts_pins = [_]u8{ 17, 31, 42 };

/// The firmware's expander: its lines numbered past the SoC's own when
/// the firmware is asked about them, how many it has, and the tag that
/// sets one - whose answer is 0 written over the line's number when it
/// was done, its own answered bit left clear.
const expander_base: u32 = 128;
const expander_lines = 8;
const TAG_SET_GPIO_STATE: u32 = 0x0003_8041;
/// A clock's rate, and the chip's core clock's number.
const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const CLOCK_CORE: u32 = 4;
/// A message's code once the firmware has answered it.
const code_answered: u32 = 0x8000_0000;

/// Everything the line is: the registers, the pins, the power line, and
/// the firmware's mailbox with the buffer its messages are written in.
pub const Line = extern struct {
    /// The mini UART's registers; the AUX block is 0x40 below.
    regs: usize = 0,
    mailbox: usize = 0,
    mail: usize = 0,
    txd: u8 = 0,
    rxd: u8 = 0,
    rts: u8 = 0,
    cts: u8 = 0,
    power: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The core clock, as the firmware said when the line was started.
    clock_hz: u32 = 0,
};

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

fn aux(line: *const Line, offset: isize) *volatile u32 {
    return reg(@intCast(@as(isize, @intCast(line.regs)) + offset));
}

fn mu(line: *const Line, offset: usize) *volatile u32 {
    return reg(line.regs + offset);
}

/// The pin the part's tag `tag` names, when it is a GPIO among `pins`.
fn pinOf(utility: *UtilityBase, tags: ?[*]const TagItem, tag: u32, pins: []const u8) ?u8 {
    const pin = boardpin.BoardPin.of(utility.GetTagData(tag, 0, tags));
    if (pin.kind != boardpin.BPIN_GPIO or pin.active_low != 0) return null;
    for (pins) |candidate| {
        if (candidate == pin.number) return candidate;
    }
    return null;
}

/// The line a part names, or null where its lines are not the mini
/// UART's or its power line is not one of the firmware's expander.
pub fn lineOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Line {
    const address = utility.GetTagData(st.PART_Address, 0, tags);
    if (address == 0) return null;
    const power_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinPower, 0, tags));
    if (power_pin.kind != boardpin.BPIN_EXPANDER or power_pin.number >= expander_lines or power_pin.active_low != 0) return null;
    return .{
        .regs = address,
        .txd = pinOf(utility, tags, st.PART_PinDataOut, &txd_pins) orelse return null,
        .rxd = pinOf(utility, tags, st.PART_PinDataIn, &rxd_pins) orelse return null,
        .rts = pinOf(utility, tags, st.PART_PinRts, &rts_pins) orelse return null,
        .cts = pinOf(utility, tags, st.PART_PinCts, &cts_pins) orelse return null,
        .power = power_pin.number,
    };
}

/// BAUD for `baud` bits a second from a clock of `clock_hz`: the
/// nearest, within what the register holds.
pub fn divisor(clock_hz: u32, baud: u32) u16 {
    const eight: u64 = 8 * @as(u64, baud);
    const nearest = (@as(u64, clock_hz) + eight / 2) / eight;
    return @intCast(@min(@max(nearest, 1), 0x1_0000) - 1);
}

/// The rate BAUD gives from a clock of `clock_hz`.
pub fn rateOf(clock_hz: u32, baud_register: u16) u32 {
    return @intCast(@as(u64, clock_hz) / (8 * (@as(u64, baud_register) + 1)));
}

/// The firmware asked tag `tag` with `value`, its answer read back into
/// it: false without a mailbox, or when it did not answer.
fn askFirmware(sys: *ExecBase, line: *const Line, tag: u32, value: []u32) bool {
    if (line.mailbox == 0 or line.mail == 0) return false;
    const buffer: *align(videocore.buffer_bytes) videocore.Buffer = @ptrFromInt(line.mail);
    return videocore.call(sys, line.mailbox, buffer, tag, value);
}

/// The chip's core clock, which the mini UART counts from: null where the
/// firmware does not say.
pub fn coreClock(sys: *ExecBase, line: *const Line) ?u32 {
    var value = [_]u32{ CLOCK_CORE, 0 };
    if (!askFirmware(sys, line, TAG_GET_CLOCK_RATE, &value) or value[1] == 0) return null;
    return value[1];
}

/// BT_REG_ON driven high or low: false where the firmware did not answer,
/// and the line is as it was. The firmware leaves the tag's answered bit
/// clear and writes its status over the line's number, so the message's
/// code is what says it was read.
pub fn power(sys: *ExecBase, line: *const Line, on: bool) bool {
    var value = [_]u32{ expander_base + line.power, @intFromBool(on) };
    if (askFirmware(sys, line, TAG_SET_GPIO_STATE, &value)) return value[0] == 0;
    if (line.mail == 0) return false;
    const buffer: *const videocore.Buffer = @ptrFromInt(line.mail);
    return buffer[1] == code_answered and buffer[5] == 0;
}

/// Pin `pin` given to the mini UART - its ALT5 function - with its pull.
fn setPin(sys: *ExecBase, pin: u8, pull: u32) void {
    sys.Disable();
    defer sys.Enable();
    const fsel = reg(gpio + GPFSEL0 + (@as(usize, pin) / 10) * 4);
    const fsel_shift: u5 = @intCast((pin % 10) * 3);
    fsel.* = (fsel.* & ~(@as(u32, 7) << fsel_shift)) | (FSEL_ALT5 << fsel_shift);
    const pulls = reg(gpio + GPIO_PUP_PDN_CNTRL_REG0 + (@as(usize, pin) / 16) * 4);
    const pull_shift: u5 = @intCast((pin % 16) * 2);
    pulls.* = (pulls.* & ~(@as(u32, 3) << pull_shift)) | (pull << pull_shift);
}

/// The line's four pins given to the mini UART.
pub fn pinsUp(sys: *ExecBase, line: *const Line) void {
    setPin(sys, line.txd, PULL_NONE);
    setPin(sys, line.rxd, PULL_UP);
    setPin(sys, line.rts, PULL_NONE);
    setPin(sys, line.cts, PULL_UP);
}

/// The mini UART switched on and started afresh at `baud` from the clock
/// the line has: eight data bits, both FIFOs empty, no interrupts, the
/// receiver and the transmitter on, and RTS held up by hand, so that the
/// controller sends nothing until `flowOn`.
pub fn start(sys: *ExecBase, line: *const Line, baud: u32) void {
    {
        sys.Disable();
        defer sys.Enable();
        aux(line, AUX_ENABLES).* |= AUX_MINI_UART;
    }
    mu(line, MU_CNTL).* = 0;
    mu(line, MU_IER).* = 0;
    mu(line, MU_LCR).* = LCR_8BIT;
    mu(line, MU_MCR).* = 0;
    mu(line, MU_IIR).* = IIR_CLEAR_FIFOS;
    mu(line, MU_BAUD).* = divisor(line.clock_hz, baud);
    mu(line, MU_CNTL).* = CNTL_RX | CNTL_TX;
}

/// RTS and CTS handed to the hardware, asserted low.
pub fn flowOn(line: *const Line) void {
    mu(line, MU_CNTL).* = CNTL_RX | CNTL_TX | CNTL_AUTO_RTS | CNTL_AUTO_CTS | CNTL_RTS_FOUR | CNTL_RTS_LOW | CNTL_CTS_LOW;
}

/// Whether the controller holds its RTS, the mini UART's CTS, down: it
/// takes bytes.
pub fn ctsAsserted(line: *const Line) bool {
    return mu(line, MU_MSR).* & MSR_CTS != 0;
}

/// Whether the transmitter has sent all it was given.
pub fn txIdle(line: *const Line) bool {
    return mu(line, MU_LSR).* & LSR_TX_IDLE != 0;
}

/// The line's rate changed to `baud` once the transmitter is idle: the
/// rate it runs at, which BAUD makes of the clock.
pub fn setRate(sys: *ExecBase, line: *const Line, baud: u32) u32 {
    const until = sys.UptimeUs() + 10_000;
    while (!txIdle(line) and sys.UptimeUs() < until) {}
    const register = divisor(line.clock_hz, baud);
    mu(line, MU_BAUD).* = register;
    return rateOf(line.clock_hz, register);
}

/// Both FIFOs emptied: what was in them is gone.
pub fn clearFifos(line: *const Line) void {
    mu(line, MU_IIR).* = IIR_CLEAR_FIFOS;
}

/// The interrupts the line raises: none, receiving, sending, both.
pub fn setInterrupts(line: *const Line, rx: bool, tx: bool) void {
    var ier: u32 = 0;
    if (rx) ier |= IER_RX;
    if (tx) ier |= IER_TX;
    if (ier != 0) ier |= IER_LINE;
    mu(line, MU_IER).* = ier;
}

/// Whether the AUX block's interrupt is the mini UART's.
pub fn interrupting(line: *const Line) bool {
    return aux(line, AUX_IRQ).* & AUX_MINI_UART != 0;
}

/// Whether the receive FIFO holds a byte, and the byte.
pub fn hasByte(line: *const Line) bool {
    return mu(line, MU_LSR).* & LSR_DATA != 0;
}

pub fn readByte(line: *const Line) u8 {
    return @truncate(mu(line, MU_IO).*);
}

/// Whether the transmit FIFO has room for a byte, and the byte sent.
pub fn hasRoom(line: *const Line) bool {
    return mu(line, MU_LSR).* & LSR_TX_ROOM != 0;
}

pub fn writeByte(line: *const Line, byte: u8) void {
    mu(line, MU_IO).* = byte;
}

/// The mini UART stopped: no interrupts, receiver and transmitter off, RTS
/// up.
pub fn stop(line: *const Line) void {
    mu(line, MU_IER).* = 0;
    mu(line, MU_CNTL).* = 0;
    mu(line, MU_MCR).* = 0;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the divisor: the nearest rate from the core clock" {
    // 500 MHz: 921600 bit/s is 919117 (-0.27 %), 115200 is 115101.
    try testing.expectEqual(@as(u16, 67), divisor(500_000_000, 921600));
    try testing.expectEqual(@as(u32, 919117), rateOf(500_000_000, 67));
    try testing.expectEqual(@as(u16, 542), divisor(500_000_000, 115200));
    try testing.expectEqual(@as(u32, 115101), rateOf(500_000_000, 542));
    // 250 MHz, the clock the firmware fixes for a mini UART console.
    try testing.expectEqual(@as(u16, 33), divisor(250_000_000, 921600));
    // Out of the register's reach either way.
    try testing.expectEqual(@as(u16, 0), divisor(500_000_000, 500_000_000));
    try testing.expectEqual(@as(u16, 0xFFFF), divisor(500_000_000, 1));
}
