// SPDX-License-Identifier: MIT
//! The SD/MMC host controller, for sd.device: commands to a card on a
//! four-bit bus, and blocks moved by the controller's own DMA.
//!
//! A command is one word - the command's number and what to expect back -
//! written to a register, and the controller answers in a status register
//! it holds until the bits are written back: a command done, a response,
//! a transfer over, or one of the errors (no response, a bad CRC, a
//! timeout). Data does not pass through the CPU: the controller has a DMA
//! of its own, with descriptors in internal memory, which is why none of
//! dma.resource's channels are taken here and the five of them stay free
//! for the panel, the sound and the flash.
//!
//! Two clocks matter. The controller's own is the 160 MHz clock divided
//! by `clock_div`; the card's is that divided again by `CLKDIV`, and a
//! card is spoken to slowly until it has been identified and quickly
//! after. A divider is never changed while the card's clock is running:
//! the card's side of the controller takes a new divider only when it is
//! handed one by a command that carries nothing else (`applyClock`), and
//! skipping that is the one mistake here that fails silently.
//!
//! It keeps no state: every call is register writes, and what is
//! remembered about a card is the device's business.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const gpio = hardware.gpio;
const system = hardware.system;
const signals = hardware.signals;

const base = hardware.map.SDMMC;

const ctrl = base + 0x00;
const pwren = base + 0x04;
const clkdiv = base + 0x08;
const clksrc = base + 0x0C;
const clkena = base + 0x10;
const tmout = base + 0x14;
const ctype = base + 0x18;
const blksiz = base + 0x1C;
const bytcnt = base + 0x20;
const intmask = base + 0x24;
const cmdarg = base + 0x28;
const cmd_reg = base + 0x2C;
const resp0 = base + 0x30;
const rintsts = base + 0x44;
const status = base + 0x48;
const cdetect = base + 0x50;
const wrtprt = base + 0x54;
/// The controller names its own version here; a machine that has no
/// controller reads nothing back.
const verid = base + 0x6C;
const bmod = base + 0x80;
const poll_demand = base + 0x84;
const dbaddr = base + 0x88;
const idsts = base + 0x8C;
const idinten = base + 0x90;
/// Outside the controller proper: the clock this chip feeds it, and the
/// phases of the clock it sends out and the one it samples on.
const clock = base + 0x800;

// CTRL
const ctrl_controller_reset: u32 = 1 << 0;
const ctrl_fifo_reset: u32 = 1 << 1;
const ctrl_dma_reset: u32 = 1 << 2;
const ctrl_int_enable: u32 = 1 << 4;
const ctrl_dma_enable: u32 = 1 << 5;
const ctrl_use_internal_dma: u32 = 1 << 25;
const ctrl_resets: u32 = ctrl_controller_reset | ctrl_fifo_reset | ctrl_dma_reset;

// CMD: the command word, as the controller reads it.
const cmd_response_expect: u32 = 1 << 6;
const cmd_response_long: u32 = 1 << 7;
const cmd_check_response_crc: u32 = 1 << 8;
const cmd_data_expected: u32 = 1 << 9;
const cmd_write: u32 = 1 << 10;
const cmd_send_auto_stop: u32 = 1 << 12;
const cmd_wait_complete: u32 = 1 << 13;
const cmd_stop_abort: u32 = 1 << 14;
const cmd_send_init: u32 = 1 << 15;
const cmd_update_clock: u32 = 1 << 21;
/// The delayed clock of `phase_dout` is the one sent to the card.
const cmd_use_hold_reg: u32 = 1 << 29;
const cmd_start: u32 = 1 << 31;

// RINTSTS: what the controller has to say. A bit stays until it is
// written back.
pub const int_card_detect: u32 = 1 << 0;
pub const int_response_error: u32 = 1 << 1;
pub const int_command_done: u32 = 1 << 2;
pub const int_data_over: u32 = 1 << 3;
pub const int_response_crc: u32 = 1 << 6;
pub const int_data_crc: u32 = 1 << 7;
pub const int_response_timeout: u32 = 1 << 8;
pub const int_data_read_timeout: u32 = 1 << 9;
pub const int_host_timeout: u32 = 1 << 10;
pub const int_fifo_run: u32 = 1 << 11;
pub const int_hardware_locked: u32 = 1 << 12;
pub const int_start_bit: u32 = 1 << 13;
pub const int_auto_command_done: u32 = 1 << 14;
pub const int_end_bit: u32 = 1 << 15;
/// Everything that means the command or the data did not arrive.
pub const int_errors: u32 = int_response_error | int_response_crc | int_data_crc |
    int_response_timeout | int_data_read_timeout | int_host_timeout |
    int_fifo_run | int_hardware_locked | int_start_bit | int_end_bit;
/// The ones worth raising to the CPU: an end, either way, and every
/// error. The FIFO's own requests are not among them - the DMA empties
/// it, not the processor.
pub const int_wanted: u32 = int_command_done | int_data_over |
    int_auto_command_done | int_errors;

// STATUS
const status_data_busy: u32 = 1 << 9;

// BMOD: the DMA's own control.
const bmod_sw_reset: u32 = 1 << 0;
const bmod_fixed_burst: u32 = 1 << 1;
const bmod_enable: u32 = 1 << 7;

// IDSTS / IDINTEN: the DMA's own interrupts, beside the controller's.
pub const dma_int_transmit: u32 = 1 << 0;
pub const dma_int_receive: u32 = 1 << 1;
pub const dma_int_bus_error: u32 = 1 << 2;
pub const dma_int_no_descriptor: u32 = 1 << 4;
pub const dma_int_card_error: u32 = 1 << 5;
pub const dma_int_normal: u32 = 1 << 8;
pub const dma_int_abnormal: u32 = 1 << 9;
pub const dma_int_wanted: u32 = dma_int_transmit | dma_int_receive |
    dma_int_bus_error | dma_int_no_descriptor | dma_int_normal | dma_int_abnormal;

/// The clock the controller's divider is fed from.
const source_hz: u32 = 160_000_000;
/// What the controller itself runs at: the source halved. The card's
/// clock is divided out of this again.
const clock_div: u32 = 2;
const controller_hz: u32 = source_hz / clock_div;

/// The card's clock while it is being identified. A card that has not yet
/// been told its bus width must be spoken to at 400 kHz or less.
pub const identify_hz: u32 = 400_000;
/// The card's clock once it is identified. 25 MHz is as fast as a card
/// goes before it is switched into high speed, and 20 is what the divider
/// reaches from this controller's clock; the switch (CMD6) and the 40 MHz
/// above it are a later change, measured rather than assumed.
pub const fast_hz: u32 = 20_000_000;

/// A block, which is what a card of this age reads and writes.
pub const block_bytes: u32 = 512;

/// The most one descriptor carries.
pub const dma_buffer_max: u32 = 4096;

/// One link of the controller's DMA chain: four bytes aligned, in
/// internal memory, and owned by the controller until it hands it back.
/// A descriptor may name two buffers; this driver uses the first and
/// chains through the second.
pub const Descriptor = extern struct {
    flags: u32 = 0,
    sizes: u32 = 0,
    buffer: ?*const anyopaque = null,
    next: ?*Descriptor = null,

    pub const no_interrupt: u32 = 1 << 1;
    pub const last: u32 = 1 << 2;
    pub const first: u32 = 1 << 3;
    pub const chained: u32 = 1 << 4;
    pub const end_of_ring: u32 = 1 << 5;
    pub const card_error: u32 = 1 << 30;
    pub const owned: u32 = 1 << 31;

    /// A descriptor for `bytes` at `buffer`, chained to `next`, handed to
    /// the controller. `flags` adds `first` and `last` where they belong.
    pub fn set(self: *Descriptor, buffer: ?*const anyopaque, bytes: u32, flags: u32, next: ?*Descriptor) void {
        self.sizes = bytes & 0x1FFF;
        self.buffer = buffer;
        self.next = next;
        // Owned last: the controller may be looking, and a descriptor is
        // only its to read once everything else in it is written.
        self.flags = flags | chained | owned;
    }

    /// Whether the controller has finished with it.
    pub fn done(self: *const Descriptor) bool {
        return self.flags & owned == 0;
    }
};

/// What a command asks of the controller. `short_unchecked` is an answer
/// whose check bits are all ones by design - the card's operating
/// conditions (R3) - which a controller checking them would call damaged.
pub const Response = enum { none, short, short_unchecked, short_busy, long };

/// Which way the blocks of a command travel.
pub const Direction = enum { from_card, to_card };

/// The pads of a slot, as the board wired them. A board that has a card
/// detect or a write protect line names it; without one the controller is
/// told the card is in and not protected, and the truth is found out by
/// talking to it.
pub const Pins = struct {
    clock: u8,
    command: u8,
    data: [4]u8,
    detect: ?u8 = null,
    write_protect: ?u8 = null,
};

// The GPIO matrix's signals of slot 0. This chip has no fixed pin
// function for the controller, so every line goes through the matrix.
const signal_clock_out: u32 = signals.SDHOST_CCLK_1;
const signal_command: u32 = signals.SDHOST_CCMD_1;
const signal_data = [4]u32{ signals.SDHOST_CDATA_10, signals.SDHOST_CDATA_11, signals.SDHOST_CDATA_12, signals.SDHOST_CDATA_13 };
const signal_detect: u32 = signals.SDHOST_CARD_DETECT_N_1;
const signal_write_protect: u32 = signals.SDHOST_CARD_WRITE_PRT_1;

/// The controller clocked, out of reset and ready for a command, with the
/// card's clock at `identify_hz` and its pads connected. False if there is
/// no controller at this address, which is what the emulator looks like.
///
/// The command and the data lines are the card's to drive as well as
/// ours, so each goes both ways through the matrix and keeps a pull-up,
/// which is what an SD bus idles at. The clock is ours alone.
pub fn init(pins: Pins) bool {
    if (!present()) return false;

    // The controller's own clock and the phases it works to: the core
    // clock in step with the source, and the clock sent to the card a
    // quarter period late, so a card that is slow to let go of a line
    // still meets the hold time. `cmd_use_hold_reg` on a command is what
    // puts that delayed clock on the wire.
    const high = clock_div / 2 - 1;
    const low = clock_div - 1;
    const phase_dout: u32 = 1;
    reg(clock).* = phase_dout | (high << 9) | (low << 13) | (low << 17) | (1 << 23);

    reset();

    gpio.toMatrix(pins.clock);
    gpio.outputEnable(pins.clock, true);
    gpio.connectOut(pins.clock, signal_clock_out, false);
    connectBoth(pins.command, signal_command);
    for (pins.data, 0..) |pin, i| connectBoth(pin, signal_data[i]);

    // A slot without the line tells the controller what it would have
    // said: a card is in, and it is not write protected. Whether a card
    // is really there is then found out by trying to identify one.
    if (pins.detect) |pin| {
        gpio.toMatrix(pin);
        gpio.inputEnable(pin, true);
        gpio.pullUp(pin, true);
        gpio.connectIn(signal_detect, pin);
    } else gpio.connectIn(signal_detect, gpio.in_low);
    if (pins.write_protect) |pin| {
        gpio.toMatrix(pin);
        gpio.inputEnable(pin, true);
        gpio.pullUp(pin, true);
        gpio.connectIn(signal_write_protect, pin);
    } else gpio.connectIn(signal_write_protect, gpio.in_low);

    // Power on, one card, nothing in eight-bit mode, and the longest
    // timeouts there are: a card may take a while over a write, and a
    // wait the controller cuts short reads as a fault. The FIFO's
    // watermarks are left where they reset - the DMA empties it, and the
    // reset values are the ones it wants.
    reg(pwren).* = 1;
    reg(ctype).* = 0;
    reg(tmout).* = 0xFFFF_FFFF;
    reg(intmask).* = 0;
    reg(rintsts).* = 0xFFFF_FFFF;
    reg(clksrc).* = 0;
    setClock(identify_hz);
    return true;
}

/// Whether the machine has the controller: its clock on, out of reset,
/// and asked for its version, which a machine without one - the emulator
/// - answers with nothing.
pub fn present() bool {
    system.enable(.sdio_host);
    const id = reg(verid).*;
    return id != 0 and id != 0xFFFF_FFFF;
}

fn connectBoth(pin: u8, signal: u32) void {
    gpio.toMatrix(pin);
    gpio.inputEnable(pin, true);
    gpio.pullUp(pin, true);
    gpio.outputEnable(pin, true);
    gpio.connectOut(pin, signal, false);
    gpio.connectIn(signal, pin);
}

/// The controller, its FIFO and its DMA back to where they start, with
/// interrupts on at the controller's own gate.
pub fn reset() void {
    reg(ctrl).* = ctrl_resets;
    var spins: u32 = 0;
    while (reg(ctrl).* & ctrl_resets != 0 and spins < 100_000) spins += 1;
    reg(ctrl).* = ctrl_int_enable;
    reg(bmod).* = bmod_sw_reset;
    reg(idsts).* = 0xFFFF_FFFF;
    reg(idinten).* = 0;
}

/// The FIFO and the DMA emptied after an error, without disturbing the
/// card's clock or what the controller has been told about it. The DMA is
/// let go of before it is reset: resetting it while it still holds the
/// bus is what the controller asks not to be done.
pub fn resetTransfer() void {
    reg(ctrl).* &= ~ctrl_use_internal_dma;
    reg(bmod).* = 0;
    reg(ctrl).* |= ctrl_fifo_reset | ctrl_dma_reset;
    var spins: u32 = 0;
    while (reg(ctrl).* & (ctrl_fifo_reset | ctrl_dma_reset) != 0 and spins < 100_000) spins += 1;
    reg(bmod).* = bmod_sw_reset;
    reg(idsts).* = 0xFFFF_FFFF;
    reg(rintsts).* = 0xFFFF_FFFF;
}

/// The card's clock, as near `hz` as the divider reaches without going
/// over. The divider counts whole periods of half the controller's clock,
/// so the card gets `controller_hz / (2 * divider)`; a divider of 0 hands
/// the controller's clock straight through.
pub fn setClock(hz: u32) void {
    const wanted = @max(hz, 1);
    const divider: u32 = if (wanted >= controller_hz)
        0
    else
        @min((controller_hz + 2 * wanted - 1) / (2 * wanted), 0xFF);

    // Off, changed, on - and each step handed over on its own, because
    // the card's side of the controller reads these registers only when
    // it is told to.
    reg(clkena).* = 0;
    applyClock();
    reg(clkdiv).* = divider;
    applyClock();
    reg(clkena).* = 1;
    applyClock();
}

/// The clock registers handed to the card's side of the controller: a
/// command with nothing in it but that instruction.
fn applyClock() void {
    reg(cmdarg).* = 0;
    reg(cmd_reg).* = cmd_start | cmd_update_clock | cmd_wait_complete;
    var spins: u32 = 0;
    while (reg(cmd_reg).* & cmd_start != 0 and spins < 1_000_000) spins += 1;
    // The controller raises this one at an update it could not take; it
    // means nothing here and would otherwise be read as an error later.
    reg(rintsts).* = int_hardware_locked;
}

/// Four bits wide rather than one, which the card is told separately and
/// the controller has to be told too.
pub fn setWide(wide: bool) void {
    reg(ctype).* = if (wide) 1 else 0;
}

/// Whether a card is in the slot. A slot with no detect line always says
/// yes; see `init`.
pub fn cardPresent() bool {
    return reg(cdetect).* & 1 == 0;
}

/// Whether the slot's switch says the card may not be written. A slot
/// with no line always says it may.
pub fn writeProtected() bool {
    return reg(wrtprt).* & 1 != 0;
}

/// Whether the card is still working on what it was last given.
pub fn busy() bool {
    return reg(status).* & status_data_busy != 0;
}

/// What the controller has said, left where it is.
pub fn statusNow() u32 {
    return reg(rintsts).*;
}

/// What the controller has said since this was last called, and cleared.
pub fn takeStatus() u32 {
    const said = reg(rintsts).*;
    reg(rintsts).* = said;
    return said;
}

pub fn clearStatus(mask: u32) void {
    reg(rintsts).* = mask;
}

/// What the DMA has said since this was last called, and cleared.
pub fn takeDmaStatus() u32 {
    const said = reg(idsts).*;
    reg(idsts).* = said;
    return said;
}

/// The interrupts the controller raises to the CPU. Everything else still
/// appears in the status registers and is read from there.
pub fn interruptsOn(controller: u32, dma: u32) void {
    reg(intmask).* = controller;
    reg(idinten).* = dma;
}

/// The data the next command moves: `blocks` blocks of `block_size` from
/// the chain at `chain`, or none when `chain` is null.
///
/// The block is a parameter because not everything a card sends is one of
/// its own blocks: its configuration register comes over the data lines
/// as eight bytes, and the controller has to be told that is a whole
/// block or it waits for 504 more.
///
/// **The order is the whole of it.** Where the data goes, how much of it
/// there is, and which descriptor to start from are written before the
/// DMA is switched on, because it reads them as it starts: switched on
/// first, it would set off on whatever the last transfer left behind.
/// Then it is told to look, and until it is told it does nothing.
pub fn prepareData(chain: ?*Descriptor, block_size: u32, blocks: u32) void {
    if (chain) |first| {
        reg(idsts).* = 0xFFFF_FFFF;
        reg(bytcnt).* = blocks * block_size;
        reg(blksiz).* = block_size;
        reg(dbaddr).* = @intFromPtr(first);
        reg(ctrl).* |= ctrl_dma_enable | ctrl_use_internal_dma;
        reg(bmod).* = bmod_enable | bmod_fixed_burst;
        pollDma();
    } else {
        reg(ctrl).* &= ~ctrl_use_internal_dma;
        reg(bmod).* = 0;
        reg(blksiz).* = 0;
        reg(bytcnt).* = 0;
    }
}

/// The DMA told to look at its descriptors: it does nothing until it is,
/// and it stops again whenever it runs out of ones it owns.
pub fn pollDma() void {
    reg(poll_demand).* = 1;
}

/// A command started. `index` is the command's number and `argument` what
/// it carries; `data` says whether blocks follow and which way, and
/// `stop` whether the controller ends a run of them itself with CMD12.
///
/// The command is queued behind whatever the controller is still doing,
/// so a caller that has just handed over data need not wait first.
pub fn sendCommand(index: u32, argument: u32, expect: Response, data: ?Direction, stop: bool) void {
    var word: u32 = cmd_start | cmd_use_hold_reg | cmd_wait_complete | (index & 0x3F);
    switch (expect) {
        .none => {},
        .short, .short_busy => word |= cmd_response_expect | cmd_check_response_crc,
        .short_unchecked => word |= cmd_response_expect,
        .long => word |= cmd_response_expect | cmd_response_long | cmd_check_response_crc,
    }
    if (data) |way| {
        word |= cmd_data_expected;
        if (way == .to_card) word |= cmd_write;
        if (stop) word |= cmd_send_auto_stop;
    }
    // The first command a card hears carries the eighty clocks of ones it
    // needs before it listens at all.
    if (index == 0) word |= cmd_send_init;
    reg(cmdarg).* = argument;
    reg(cmd_reg).* = word;
}

/// CMD12, to end a transfer the controller is in the middle of. It goes
/// out ahead of the queue, which is the point of it.
pub fn sendStop() void {
    reg(cmdarg).* = 0;
    reg(cmd_reg).* = cmd_start | cmd_use_hold_reg | cmd_stop_abort |
        cmd_response_expect | cmd_check_response_crc | 12;
}

/// Whether the controller has taken the command word. It clears the start
/// bit once the command is on its way.
pub fn commandTaken() bool {
    return reg(cmd_reg).* & cmd_start == 0;
}

/// The card's answer to the last command: one word in `into[0]`, or four
/// for the long answers - the card's identification and its description.
pub fn response(into: *[4]u32) void {
    for (0..4) |i| into[i] = reg(resp0 + i * 4).*;
}
