// SPDX-License-Identifier: MIT
//! The interrupt controllers, by their registers: a local one per core,
//! and the machine's I/O one in front of it.
//!
//! **The local controller** is a core's own, mapped at one address every
//! core sees its own copy of. It has the core's id, the register that says
//! an interrupt has been served (EOI), the vector it sends when it has
//! nothing to send, a timer of its own, and the register one core writes
//! to raise an interrupt on another (ICR). It is driven here through its
//! memory-mapped registers (xAPIC), which every machine has; a core's
//! model registers would reach the same controller faster (x2APIC) and
//! would want a second way of writing every one of these.
//!
//! **The I/O controller** takes the machine's interrupt lines and says
//! which vector each is sent on and to which core. Its registers are
//! reached two at a time: an index is written to one address and the
//! register's value read or written at another. A machine may have more
//! than one, each with the line it starts at; where they are and what they
//! start at is in the firmware's tables, and the kernel sets it before
//! anything uses it.
//!
//! **The old interrupt controllers** of a PC - the pair of 8259s in the
//! I/O port space - are in front of nothing here: every line comes through
//! the I/O controller. They are moved off the vectors the architecture's
//! exceptions are on and then every line of them is masked, because a
//! controller left as the firmware had it can still send one.

const map = @import("map.zig");
const mmio = @import("mmio.zig");
const reg = mmio.reg;

/// Where this core's local controller is mapped. Every core reads its own
/// through the same address; the kernel sets it from the firmware's tables.
pub var lapic_base: usize = map.LAPIC;

// The local controller's registers, by their distance from its base.
pub const LAPIC_ID = 0x020;
pub const LAPIC_VERSION = 0x030;
/// The priority below which interrupts are held back: 0 lets all through.
pub const LAPIC_TPR = 0x080;
pub const LAPIC_EOI = 0x0B0;
/// Where interrupts are sent by default - flat, this core alone.
pub const LAPIC_DFR = 0x0E0;
/// The controller on, and the vector it sends when it has nothing.
pub const LAPIC_SVR = 0x0F0;
/// What one core raises on another: the vector and the mode low, the core
/// it is for high.
pub const LAPIC_ICR_LOW = 0x300;
pub const LAPIC_ICR_HIGH = 0x310;
/// The core's own timer: its vector and mode, what it counts from, what it
/// has left, and what divides its input.
pub const LAPIC_LVT_TIMER = 0x320;
pub const LAPIC_TIMER_INITIAL = 0x380;
pub const LAPIC_TIMER_CURRENT = 0x390;
pub const LAPIC_TIMER_DIVIDE = 0x3E0;

/// SVR: the controller on at all.
pub const SVR_ENABLE: u32 = 1 << 8;

/// The timer's modes: once, over and over, or until the core's counter
/// reaches a value written to a model register.
pub const TIMER_ONE_SHOT: u32 = 0b00 << 17;
pub const TIMER_PERIODIC: u32 = 0b01 << 17;
pub const TIMER_DEADLINE: u32 = 0b10 << 17;
/// Any entry of the local controller's vector table: held back.
pub const LVT_MASKED: u32 = 1 << 16;

/// The counter value the timer in deadline mode fires at.
pub const MSR_TSC_DEADLINE: u32 = 0x6E0;

/// ICR: what is being raised and where. A fixed interrupt carries a
/// vector; the core it is for is named in the high register, or by one of
/// the shorthands - this core, every core, every core but this one.
pub const ICR_FIXED: u32 = 0b000 << 8;
pub const ICR_INIT: u32 = 0b101 << 8;
pub const ICR_STARTUP: u32 = 0b110 << 8;
pub const ICR_ASSERT: u32 = 1 << 14;
pub const ICR_TO_NAMED: u32 = 0b00 << 18;
pub const ICR_TO_SELF: u32 = 0b01 << 18;
pub const ICR_TO_ALL: u32 = 0b10 << 18;
pub const ICR_TO_OTHERS: u32 = 0b11 << 18;
/// Set while the controller has not sent what it was last given.
pub const ICR_SENDING: u32 = 1 << 12;

fn local(offset: usize) *volatile u32 {
    return reg(lapic_base + offset);
}

pub fn read(offset: usize) u32 {
    return local(offset).*;
}

pub fn write(offset: usize, value: u32) void {
    local(offset).* = value;
}

/// This core's local controller id, as the machine numbers it.
pub fn ownId() u32 {
    return read(LAPIC_ID) >> 24;
}

/// The controller on, every priority let through, and `spurious` the
/// vector it sends when it has nothing to send. Called on each core.
pub fn localOn(spurious: u8) void {
    write(LAPIC_DFR, 0xFFFF_FFFF);
    write(LAPIC_TPR, 0);
    write(LAPIC_SVR, SVR_ENABLE | spurious);
}

/// The interrupt just served is done with. Every vector the controller
/// sent is ended this way; the spurious one is not, having never been in
/// service.
pub inline fn endOfInterrupt() void {
    write(LAPIC_EOI, 0);
}

/// `vector` raised on the core whose controller id is `id`.
pub fn raise(id: u32, vector: u8) void {
    waitSent();
    write(LAPIC_ICR_HIGH, id << 24);
    write(LAPIC_ICR_LOW, ICR_TO_NAMED | ICR_ASSERT | ICR_FIXED | vector);
}

/// `vector` raised on the core this runs on.
pub fn raiseSelf(vector: u8) void {
    waitSent();
    write(LAPIC_ICR_LOW, ICR_TO_SELF | ICR_ASSERT | ICR_FIXED | vector);
}

/// Until the controller has sent what it was last given.
pub fn waitSent() void {
    while (read(LAPIC_ICR_LOW) & ICR_SENDING != 0) {}
}

// --- the I/O controller ------------------------------------------------------------

/// One of the machine's I/O controllers: where it is, and the first of the
/// machine's interrupt lines it takes.
pub const IoController = struct {
    base: usize = 0,
    /// The line its first input is: a machine with one has 0 here.
    first_line: u32 = 0,
    /// How many inputs it has, read from the controller itself.
    lines: u32 = 0,
};

/// How many I/O controllers the kernel keeps room for.
pub const MAX_IO_CONTROLLERS = 4;

/// The machine's, which the kernel sets from the firmware's tables.
pub var io: [MAX_IO_CONTROLLERS]IoController = @splat(.{});
pub var io_count: u32 = 0;

/// Its registers are reached two at a time: the index written here, the
/// value read or written there.
const IOAPIC_INDEX = 0x00;
const IOAPIC_DATA = 0x10;

/// Its own registers, by index.
pub const IOAPIC_ID = 0x00;
pub const IOAPIC_VERSION = 0x01;
/// The first of the pairs that say where an input goes; input n is at
/// IOAPIC_REDIRECT + 2n.
pub const IOAPIC_REDIRECT = 0x10;

/// A redirection entry's low word: the vector, how it is delivered, and
/// how it is taken.
pub const REDIRECT_LEVEL: u32 = 1 << 15;
pub const REDIRECT_LOW_ACTIVE: u32 = 1 << 13;
pub const REDIRECT_MASKED: u32 = 1 << 16;

fn ioRead(controller: IoController, index: u32) u32 {
    reg(controller.base + IOAPIC_INDEX).* = index;
    return reg(controller.base + IOAPIC_DATA).*;
}

fn ioWrite(controller: IoController, index: u32, value: u32) void {
    reg(controller.base + IOAPIC_INDEX).* = index;
    reg(controller.base + IOAPIC_DATA).* = value;
}

/// How many inputs a controller has: its version register's highest entry,
/// plus one.
pub fn ioLines(controller: IoController) u32 {
    return ((ioRead(controller, IOAPIC_VERSION) >> 16) & 0xFF) + 1;
}

/// The controllers' input counts read, which is the one thing about them
/// the firmware's tables do not say.
pub fn countIoLines() void {
    for (io[0..io_count]) |*controller| controller.lines = ioLines(controller.*);
}

/// Which controller takes line `line`, and which of its inputs that is.
pub fn inputOf(line: u32) ?struct { controller: IoController, input: u32 } {
    for (io[0..io_count]) |controller| {
        if (line >= controller.first_line and line - controller.first_line < controller.lines) {
            return .{ .controller = controller, .input = line - controller.first_line };
        }
    }
    return null;
}

/// Line `line` sent on `vector` to the core whose controller id is `id`,
/// taken on its level or its edge and active low or high as the firmware's
/// tables said, and let through or held back.
pub fn route(line: u32, vector: u8, id: u32, level: bool, low_active: bool, on: bool) void {
    const found = inputOf(line) orelse return;
    const index = IOAPIC_REDIRECT + 2 * found.input;
    var low: u32 = vector;
    if (level) low |= REDIRECT_LEVEL;
    if (low_active) low |= REDIRECT_LOW_ACTIVE;
    if (!on) low |= REDIRECT_MASKED;
    // The high half first: the entry is held back until the low half is
    // written, so where it goes is settled before it may go anywhere.
    ioWrite(found.controller, index + 1, id << 24);
    ioWrite(found.controller, index, low);
}

/// Line `line` let through or held back, leaving the rest of its entry as
/// it was.
pub fn setLineEnabled(line: u32, on: bool) void {
    const found = inputOf(line) orelse return;
    const index = IOAPIC_REDIRECT + 2 * found.input;
    const low = ioRead(found.controller, index);
    ioWrite(found.controller, index, if (on) low & ~REDIRECT_MASKED else low | REDIRECT_MASKED);
}

pub fn isLineEnabled(line: u32) bool {
    const found = inputOf(line) orelse return false;
    return ioRead(found.controller, IOAPIC_REDIRECT + 2 * found.input) & REDIRECT_MASKED == 0;
}

/// Every input of every controller held back and pointed nowhere: what the
/// kernel starts from, so that a line the firmware had routed cannot
/// arrive before anything asked for it.
pub fn maskAllLines(spurious: u8) void {
    for (io[0..io_count]) |controller| {
        var input: u32 = 0;
        while (input < controller.lines) : (input += 1) {
            const index = IOAPIC_REDIRECT + 2 * input;
            ioWrite(controller, index + 1, 0);
            ioWrite(controller, index, REDIRECT_MASKED | spurious);
        }
    }
}

// --- the old controllers -----------------------------------------------------------

/// The pair of 8259s in the I/O port space: their command and data ports.
const PIC1_COMMAND: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_COMMAND: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

/// Moved off the vectors the architecture's exceptions are on - to `base`
/// and `base` + 8 - and then every line of both masked. A controller left
/// where the firmware had it can still send a line, and where it had it is
/// on top of the exceptions.
pub fn oldControllersOff(base: u8) void {
    // Both told four initialisation words are coming: the vector they
    // start at, how they are wired to each other, and that they are to be
    // ended by hand.
    mmio.out8(PIC1_COMMAND, 0x11);
    mmio.out8(PIC2_COMMAND, 0x11);
    mmio.out8(PIC1_DATA, base);
    mmio.out8(PIC2_DATA, base + 8);
    mmio.out8(PIC1_DATA, 0x04); // the second is on the first's line 2
    mmio.out8(PIC2_DATA, 0x02); // and is that line
    mmio.out8(PIC1_DATA, 0x01);
    mmio.out8(PIC2_DATA, 0x01);
    mmio.out8(PIC1_DATA, 0xFF);
    mmio.out8(PIC2_DATA, 0xFF);
}
