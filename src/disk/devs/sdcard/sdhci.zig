// SPDX-License-Identifier: MIT
//! An SD Host Controller (SDHCI, version 3.00), for sdcard.device: the
//! BCM2711's EMMC2, which the Compute Module 4's eMMC is on - or, on a
//! module without one, the IO board's card slot. It answers the calls
//! `sdmmc.zig` answers, so the device above it is the same on every
//! chip; the device picks one of the two when it is built
//! (`_sdcard.sdmmc`).
//!
//! **What is the same as the DesignWare host's.** A command is a word,
//! and the controller answers in a status register whose bits are
//! written back to clear them: a command done, a transfer over, or an
//! error (no answer, a bad CRC, a timeout). Blocks move by the
//! controller's own DMA - ADMA2 here, a table of descriptors in the
//! device's work block, each a stretch of the buffer, the last marked as
//! the end - so the CPU never touches the data port. One interrupt
//! carries all of it.
//!
//! **What is not.** The controller's registers are where the board's
//! part says (`place`), not where the chip fixes them. A long answer
//! comes without its checksum, eight bits lower than the card numbers
//! it, and is moved back up here (`response`) so that `card.zig` reads
//! it with the card's numbering as it does the DesignWare host's. There
//! is no interrupt for the CMD12 a run of blocks ends with: the
//! controller raises the end of the transfer after it. A card's clock is
//! changed with the card's clock stopped, and the controller's own clock
//! settles before the card's is let through.
//!
//! **32-bit accesses only.** The BCM2711's EMMC2 takes no narrower write
//! (Linux's sdhci-iproc says so for it): the eight- and sixteen-bit
//! registers are reached through the word they are in - the block size
//! with the block count, the transfer mode with the command (the
//! command's half starts it), the host control with the power, the clock
//! with the timeout and the resets.
//!
//! **The card's supplies are the firmware's.** The Compute Module 4's
//! eMMC is powered, and its lines held at 3.3 V, by regulators on the
//! firmware's GPIO expander, which the firmware leaves on - its
//! bootloader has just read the eMMC. This switches on the controller's
//! side of the bus, at 3.3 V, and nothing else.
//!
//! **Both edges of the clock.** An eMMC that offers it is run in its
//! dual data rate (`ddr`, `setDdr`): its data lines carry a bit on each
//! edge of the same 50 MHz clock, twice what they carry on one, and its
//! command line stays on the rising edge. The controller says it can in
//! its second capabilities word (DDR50), and is put there through Host
//! Control 2's UHS mode with the card's clock stopped, as Linux's sdhci
//! does; on the BCM2711 at 3.3 V (sdhci-iproc's MMC_CAP_3_3V_DDR, the
//! module's device tree's `mmc-ddr-3_3v`).
//!
//! **The card is always taken to be there.** The slot is either an eMMC
//! soldered on or one whose detect line the board does not wire
//! (`broken-cd`), so whether a card is in is found out by trying to
//! identify one, as on a DesignWare slot with no detect line.
//!
//! It keeps no state beyond where the controller is and what the last
//! command was: what is remembered about a card is the device's business.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const barrier = hardware.barrier;
const systimer = hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;
const card = @import("card.zig");

// --- the registers ----------------------------------------------------------

/// The block size (its low half) and the count of blocks (its high half).
const BLOCK = 0x04;
const ARGUMENT = 0x08;
/// The transfer mode (its low half) and the command (its high half),
/// written as one word: the command's half starts it.
const COMMAND = 0x0C;
/// The answer, four words: a short one in the first.
const RESPONSE = 0x10;
const PRESENT = 0x24;
/// The host control, the power, the block gap control and the wake-up
/// control, a byte each.
const CONTROL = 0x28;
/// The clock control (its low half), the data timeout and the resets.
const CLOCK = 0x2C;
/// The normal interrupts (low half) and the errors (high half): a set
/// bit is written back to clear it.
const INT_STATUS = 0x30;
/// Which of them are recorded in INT_STATUS at all, and which of those
/// raise the interrupt line.
const INT_ENABLE = 0x34;
const SIGNAL_ENABLE = 0x38;
const CAPABILITIES = 0x40;
/// The Auto CMD12 error status (its low half) and Host Control 2 (its
/// high half), whose UHS mode picks the data lines' timing.
const CONTROL2 = 0x3C;
/// The second capabilities word: which UHS modes the controller has.
const CAPABILITIES_1 = 0x44;
/// Where the ADMA2 table starts: the low word, and the high one, which
/// stays 0 - the table is in the first 4 GiB.
const ADMA_ADDRESS = 0x58;
const ADMA_ADDRESS_HIGH = 0x5C;
/// The slot interrupt status (low half) and the version (high half).
const VERSION = 0xFC;

const PRESENT_CMD_INHIBIT: u32 = 1 << 0;
const PRESENT_DAT_INHIBIT: u32 = 1 << 1;
const PRESENT_CARD_INSERTED: u32 = 1 << 16;
/// The level of DAT0, which the card holds low while it is busy.
const PRESENT_DAT0: u32 = 1 << 20;

const CONTROL_WIDTH_4: u32 = 1 << 1;
const CONTROL_HIGH_SPEED: u32 = 1 << 2;
/// The DMA the controller runs: ADMA2 with 32-bit addresses.
const CONTROL_DMA_MASK: u32 = 3 << 3;
const CONTROL_ADMA2_32: u32 = 2 << 3;
const CONTROL_WIDTH_8: u32 = 1 << 5;
/// The card's presence taken from the test level rather than the detect
/// line, and that level: there.
const CONTROL_CD_TEST_LEVEL: u32 = 1 << 6;
const CONTROL_CD_TEST: u32 = 1 << 7;
const CONTROL_POWER_ON: u32 = 1 << 8;
const CONTROL_POWER_330: u32 = 7 << 9;
const CONTROL_POWER_MASK: u32 = 0xFF << 8;

const CONTROL2_UHS_MASK: u32 = 7 << 16;
/// The UHS mode for data on both edges: SD's DDR50, an eMMC's DDR52.
const CONTROL2_UHS_DDR50: u32 = 4 << 16;
const CAPABILITIES_1_DDR50: u32 = 1 << 2;

const CLOCK_INTERNAL_ON: u32 = 1 << 0;
const CLOCK_INTERNAL_STABLE: u32 = 1 << 1;
const CLOCK_CARD_ON: u32 = 1 << 2;
/// The longest data timeout: the timeout clock times 2^27.
const CLOCK_TIMEOUT_MAX: u32 = 0xE << 16;
const RESET_ALL: u32 = 1 << 24;
const RESET_CMD: u32 = 1 << 25;
const RESET_DATA: u32 = 1 << 26;

const MODE_DMA: u32 = 1 << 0;
const MODE_BLOCK_COUNT: u32 = 1 << 1;
const MODE_AUTO_CMD12: u32 = 1 << 2;
const MODE_READ: u32 = 1 << 4;
const MODE_MULTI: u32 = 1 << 5;

/// The command's half: what answer it waits for (its length, and
/// whether the checksum and the index are checked), whether data
/// follows, and whether it is an abort.
const CMD_RESPONSE_LONG: u32 = 1;
const CMD_RESPONSE_SHORT: u32 = 2;
const CMD_RESPONSE_BUSY: u32 = 3;
const CMD_CHECK_CRC: u32 = 1 << 3;
const CMD_CHECK_INDEX: u32 = 1 << 4;
const CMD_DATA: u32 = 1 << 5;
const CMD_ABORT: u32 = 3 << 6;

const INT_COMMAND_DONE: u32 = 1 << 0;
const INT_TRANSFER_DONE: u32 = 1 << 1;
const ERR_COMMAND_TIMEOUT: u32 = 1 << 16;
const ERR_COMMAND_CRC: u32 = 1 << 17;
const ERR_COMMAND_END_BIT: u32 = 1 << 18;
const ERR_COMMAND_INDEX: u32 = 1 << 19;
const ERR_DATA_TIMEOUT: u32 = 1 << 20;
const ERR_DATA_CRC: u32 = 1 << 21;
const ERR_DATA_END_BIT: u32 = 1 << 22;
const ERR_CURRENT_LIMIT: u32 = 1 << 23;
const ERR_AUTO_CMD12: u32 = 1 << 24;
const ERR_ADMA: u32 = 1 << 25;
const ERR_ALL: u32 = 0x03FF_0000;

// --- what sdcard.device asks for ------------------------------------------

/// A command over, and the transfer that went with it.
pub const int_command_done: u32 = INT_COMMAND_DONE;
pub const int_data_over: u32 = INT_TRANSFER_DONE;
/// The CMD12 that ends a run of blocks has no bit of its own: the
/// transfer's end is raised after it.
pub const int_auto_command_done: u32 = 0;
/// What the controller records and raises: the two above and every
/// error.
pub const int_wanted: u32 = INT_COMMAND_DONE | INT_TRANSFER_DONE | ERR_ALL;
/// The DMA has no status of its own: an ADMA error is one of the errors.
pub const dma_int_wanted: u32 = 0;

/// The card's clock while it is identified, at the speed every card
/// starts at; after, at the default speed and at high speed.
pub const identify_hz: u32 = 400_000;
pub const fast_hz: u32 = 25_000_000;
pub const high_speed_hz: u32 = 50_000_000;

/// The most one descriptor carries. The length field is 16 bits; 32 KiB
/// stays clear of its top.
pub const dma_buffer_max: u32 = 32 * 1024;

/// One line of the ADMA2 table: its attributes, how many bytes, and
/// where. The table is read in order until a line marked the end, so
/// `next` is not needed; the addresses are 32 bits, so the table and
/// the buffer are in the first 4 GiB (MEMF_DMA).
pub const Descriptor = extern struct {
    attributes: u16 = 0,
    length: u16 = 0,
    address: u32 = 0,

    /// ADMA2 has no mark for the first line.
    pub const first: u32 = 0;
    /// The end of the table.
    pub const last: u32 = 1 << 1;
    const valid: u16 = 1 << 0;
    /// Act: move the bytes (as against a no-op or a link).
    const transfer: u16 = 2 << 4;

    /// A line for `bytes` at `buffer`; `flags` adds `last` where it
    /// belongs.
    pub fn set(self: *Descriptor, buffer: ?*const anyopaque, bytes: u32, flags: u32, next: ?*Descriptor) void {
        _ = next;
        self.address = @intCast(@intFromPtr(buffer));
        self.length = @intCast(bytes);
        self.attributes = valid | transfer | @as(u16, @intCast(flags & last));
    }
};

pub const Response = enum { none, short, short_unchecked, short_busy, long };
pub const Direction = enum { from_card, to_card };

/// The slot's lines, as the DesignWare host is given them. The SDHCI's
/// are its own, so none of them is used.
pub const Pins = struct {
    clock: u8,
    command: u8,
    data: [4]u8,
    detect: ?u8 = null,
    write_protect: ?u8 = null,
};

pub const Started = enum { ready, no_controller, pads_refused };

// --- where it is ------------------------------------------------------------

/// The controller's registers, as the board's card-slot part gives them.
var base: usize = 0;
/// The clock the card's is divided from: the capabilities' figure, which
/// the BCM2711's EMMC2 gives (100 MHz).
var base_hz: u32 = default_base_hz;
const default_base_hz: u32 = 100_000_000;
/// What the next command moves: how many blocks, 0 for none. Set by
/// `prepareData`, read by `sendCommand`.
var data_blocks: u32 = 0;
/// Whether the last command's answer was a long one, which `response`
/// moves back to the card's numbering.
var last_long = false;

/// How long the controller is given: a reset, its clock to settle, a
/// line to come free.
const reset_us: u64 = 100_000;
const clock_us: u64 = 20_000;
const line_us: u64 = 10_000;

/// The controller's registers at `address`: before anything else here.
pub fn place(address: usize) void {
    base = address;
}

fn at(offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// Until `done` says so or `us` microseconds have gone; whether it did.
fn spinUntil(us: u64, comptime done: fn () bool) bool {
    const until = systimer.uptimeUs() + us;
    while (!done()) {
        if (systimer.uptimeUs() > until) return false;
    }
    return true;
}

/// Whether the machine has the controller where it was placed: its
/// version register names one. A part with no address has none.
pub fn present(sys: *ExecBase) bool {
    _ = sys;
    if (base == 0) return false;
    const word = at(VERSION).*;
    return word != 0 and word != 0xFFFF_FFFF;
}

/// The controller reset, its card's bus powered and the card's clock at
/// `identify_hz`: `ready`; `no_controller` where there is none.
pub fn init(sys: *ExecBase, pins: Pins) Started {
    _ = pins;
    if (!present(sys)) return .no_controller;
    reset();
    _ = setClock(identify_hz);
    return .ready;
}

/// The controller back to where it starts, and set up again: ADMA2, the
/// bus powered at 3.3 V, one data line, the card's presence forced where
/// no detect line says it, the longest data timeout, nothing recorded or
/// raised. The card's clock is stopped; `setClock` starts it.
pub fn reset() void {
    _ = resetLines(RESET_ALL);
    const caps_mhz = (at(CAPABILITIES).* >> 8) & 0xFF;
    if (caps_mhz != 0) base_hz = caps_mhz * 1_000_000;
    var control: u32 = CONTROL_ADMA2_32;
    if (at(PRESENT).* & PRESENT_CARD_INSERTED == 0) control |= CONTROL_CD_TEST | CONTROL_CD_TEST_LEVEL;
    at(CONTROL).* = control;
    at(CONTROL).* = control | CONTROL_POWER_330;
    at(CONTROL).* = control | CONTROL_POWER_330 | CONTROL_POWER_ON;
    at(CLOCK).* = CLOCK_TIMEOUT_MAX;
    at(INT_ENABLE).* = 0;
    at(SIGNAL_ENABLE).* = 0;
    at(INT_STATUS).* = 0xFFFF_FFFF;
    data_blocks = 0;
}

/// The command and data lines reset after an error, without disturbing
/// the card's clock or its width.
pub fn resetTransfer() void {
    _ = resetLines(RESET_CMD | RESET_DATA);
    at(INT_STATUS).* = 0xFFFF_FFFF;
    data_blocks = 0;
}

/// The lines in `lines` reset - written with the clock's word, whose
/// other bits stay - and waited for. False if the reset never ends.
fn resetLines(lines: u32) bool {
    const word = at(CLOCK);
    word.* = (word.* & 0x00FF_FFFF) | lines;
    const until = systimer.uptimeUs() + reset_us;
    while (word.* & lines != 0) {
        if (systimer.uptimeUs() > until) return false;
    }
    return true;
}

/// The card's clock, as near `hz` as the divider reaches without going
/// over: the base clock over an even number, or the base clock itself.
/// Stopped first, the controller's high-speed timing set for a clock
/// above the default speed's, the controller's own clock let settle,
/// then the card's let through - and the card given its 74 clocks before
/// anything is sent. Answers what the card gets.
pub fn setClock(hz: u32) u32 {
    const wanted = @max(hz, 1);
    const divider: u32 = if (wanted >= base_hz)
        0
    else
        @min((base_hz + 2 * wanted - 1) / (2 * wanted), 1023);
    const actual = if (divider == 0) base_hz else base_hz / (2 * divider);

    const word = at(CLOCK);
    word.* = CLOCK_TIMEOUT_MAX;
    const control = at(CONTROL);
    if (actual > fast_hz) {
        control.* |= CONTROL_HIGH_SPEED;
    } else {
        control.* &= ~CONTROL_HIGH_SPEED;
    }
    const value = CLOCK_TIMEOUT_MAX | ((divider & 0xFF) << 8) | ((divider >> 8) << 6) | CLOCK_INTERNAL_ON;
    word.* = value;
    _ = spinUntil(clock_us, clockStable);
    word.* = value | CLOCK_CARD_ON;
    const settle_us: u64 = 74 * 1_000_000 / actual + 1;
    const until = systimer.uptimeUs() + settle_us;
    while (systimer.uptimeUs() <= until) {}
    return actual;
}

fn clockStable() bool {
    return at(CLOCK).* & CLOCK_INTERNAL_STABLE != 0;
}

/// Four data lines rather than one, which the card is told separately.
pub fn setWide(wide: bool) void {
    setBusWidth(if (wide) 4 else 1);
}

/// Whether the controller can move data on both edges of the clock:
/// version 3.00 or later, with DDR50 among its UHS modes.
pub fn ddr() bool {
    const spec = (at(VERSION).* >> 16) & 0xFF;
    return spec >= 2 and at(CAPABILITIES_1).* & CAPABILITIES_1_DDR50 != 0;
}

/// The data lines on both edges of the clock, or back on the rising one
/// alone: Host Control 2's UHS mode changed with the card's clock
/// stopped, then the clock let through again at the speed it had.
pub fn setDdr(on: bool) void {
    const clock = at(CLOCK);
    const running = clock.* & 0x0000_FFFF;
    clock.* = (clock.* & ~@as(u32, 0xFFFF)) | (running & ~CLOCK_CARD_ON);
    const control2 = at(CONTROL2);
    var value = control2.* & ~CONTROL2_UHS_MASK & 0xFFFF_0000;
    if (on) value |= CONTROL2_UHS_DDR50;
    control2.* = value;
    clock.* = (clock.* & ~@as(u32, 0xFFFF)) | running;
}

/// One, four or eight data lines.
pub fn setBusWidth(lines: u8) void {
    const control = at(CONTROL);
    var value = control.* & ~(CONTROL_WIDTH_4 | CONTROL_WIDTH_8);
    switch (lines) {
        8 => value |= CONTROL_WIDTH_8,
        4 => value |= CONTROL_WIDTH_4,
        else => {},
    }
    control.* = value;
}

/// Whether the controller can drive eight data lines.
pub fn eightBit() bool {
    return at(CAPABILITIES).* & (1 << 18) != 0;
}

/// A card is taken to be in: see the top of the file.
pub fn cardPresent() bool {
    return true;
}

/// No write-protect line is wired.
pub fn writeProtected() bool {
    return false;
}

/// Whether the card is still working on what it was last given: the
/// controller still holds the data lines, or the card holds DAT0 low.
pub fn busy() bool {
    const state = at(PRESENT).*;
    return state & PRESENT_DAT_INHIBIT != 0 or state & PRESENT_DAT0 == 0;
}

/// What the controller has said since this was last called, and cleared.
pub fn takeStatus() u32 {
    const said = at(INT_STATUS).*;
    at(INT_STATUS).* = said;
    barrier.fromDevice();
    return said;
}

/// The DMA says what it has to in the status above.
pub fn takeDmaStatus() u32 {
    return 0;
}

/// What the controller records, and raises to the CPU: the same.
pub fn interruptsOn(controller: u32, dma: u32) void {
    _ = dma;
    at(INT_ENABLE).* = controller;
    at(SIGNAL_ENABLE).* = controller;
}

/// The data the next command moves: `blocks` blocks of `block_size`
/// through the table at `chain`, or none when `chain` is null. The
/// table and the bytes were written out of the cache by the caller; the
/// barrier keeps them ahead of the register write that tells the
/// controller where to look.
pub fn prepareData(chain: ?*Descriptor, block_size: u32, blocks: u32) void {
    const table = chain orelse {
        data_blocks = 0;
        return;
    };
    barrier.toDevice();
    at(ADMA_ADDRESS).* = @intCast(@intFromPtr(table));
    at(ADMA_ADDRESS_HIGH).* = 0;
    at(BLOCK).* = (blocks << 16) | (block_size & 0xFFF);
    data_blocks = blocks;
}

/// Nothing to tell: the controller reads the table when the command
/// starts.
pub fn pollDma() void {}

/// A command started. `data` says whether blocks follow and which way,
/// `stop` whether the controller ends a run of them with CMD12 itself.
/// The lines it needs are waited for first: the command line, and the
/// data lines for a command that moves data or leaves the card busy.
pub fn sendCommand(index: u32, argument: u32, expect: Response, data: ?Direction, stop: bool) void {
    var inhibit = PRESENT_CMD_INHIBIT;
    if (data != null or expect == .short_busy) inhibit |= PRESENT_DAT_INHIBIT;
    waitLines(inhibit);

    var command = (index & 0x3F) << 8;
    switch (expect) {
        .none => {},
        .short => command |= CMD_RESPONSE_SHORT | CMD_CHECK_CRC | CMD_CHECK_INDEX,
        .short_unchecked => command |= CMD_RESPONSE_SHORT,
        .short_busy => command |= CMD_RESPONSE_BUSY | CMD_CHECK_CRC | CMD_CHECK_INDEX,
        .long => command |= CMD_RESPONSE_LONG | CMD_CHECK_CRC,
    }
    var mode: u32 = 0;
    if (data) |way| {
        command |= CMD_DATA;
        mode = MODE_DMA | MODE_BLOCK_COUNT;
        if (way == .from_card) mode |= MODE_READ;
        if (data_blocks > 1) mode |= MODE_MULTI;
        if (stop) mode |= MODE_AUTO_CMD12;
    }
    last_long = expect == .long;
    at(ARGUMENT).* = argument;
    at(COMMAND).* = (command << 16) | mode;
}

/// Until the lines in `inhibit` are free, for as long as a line may
/// take; a line still held after that is the next reset's to free.
fn waitLines(inhibit: u32) void {
    const until = systimer.uptimeUs() + line_us;
    while (at(PRESENT).* & inhibit != 0) {
        if (systimer.uptimeUs() > until) return;
    }
}

/// CMD12, to end a run of blocks the controller is in the middle of: an
/// abort, sent once the command line is free - reset first where a
/// failed command still holds it - and waited for.
pub fn sendStop() void {
    if (at(PRESENT).* & PRESENT_CMD_INHIBIT != 0) _ = resetLines(RESET_CMD);
    last_long = false;
    at(ARGUMENT).* = 0;
    at(COMMAND).* = (card.STOP_TRANSMISSION << 8 | CMD_ABORT | CMD_RESPONSE_BUSY | CMD_CHECK_CRC | CMD_CHECK_INDEX) << 16;
    waitLines(PRESENT_CMD_INHIBIT);
}

/// Whether the controller has taken the command: the command line is
/// free again.
pub fn commandTaken() bool {
    return at(PRESENT).* & PRESENT_CMD_INHIBIT == 0;
}

/// The card's answer to the last command: one word in `into[0]`, or four
/// for a long answer, moved up eight bits to where the card numbers them
/// - the controller leaves out the checksum at the bottom, which reads
/// as 0.
pub fn response(into: *[4]u32) void {
    var words: [4]u32 = undefined;
    for (0..4) |i| words[i] = at(RESPONSE + i * 4).*;
    if (!last_long) {
        into.* = words;
        return;
    }
    into[0] = words[0] << 8;
    for (1..4) |i| into[i] = (words[i] << 8) | (words[i - 1] >> 24);
}

/// The controller's complaints, in the card's terms.
pub fn faultOf(status: u32, dma_status: u32) card.Fault {
    _ = dma_status;
    return .{
        .no_answer = status & (ERR_COMMAND_TIMEOUT | ERR_DATA_TIMEOUT) != 0,
        .bad_checksum = status & (ERR_COMMAND_CRC | ERR_COMMAND_END_BIT | ERR_COMMAND_INDEX |
            ERR_DATA_CRC | ERR_DATA_END_BIT) != 0,
        .other = status & (ERR_CURRENT_LIMIT | ERR_AUTO_CMD12 | ERR_ADMA) != 0,
    };
}
