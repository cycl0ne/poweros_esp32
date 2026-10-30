// SPDX-License-Identifier: MIT
//! The RP1's Ethernet MAC, for emac.device: Cadence's GEM (revision 7), a
//! 10/100/1000 MAC with a DMA engine of its own, its registers in one
//! block, and the management bus (MDC, MDIO) its PHY's registers are read
//! and written over.
//!
//! **The descriptors** are two rings in memory, one to receive into and
//! one to send from, each descriptor four words: its buffer's address, its
//! length and flags, the address's high half, and one unused. The last of
//! a ring says so (WRAP). A receive descriptor is the engine's while USED
//! is clear in its first word; the engine sets it once the frame is in. A
//! send descriptor is the engine's while USED is clear in its second word;
//! the engine sets it once the frame is out.
//!
//! **Four to a cache line.** The engine has no setting that spaces its
//! descriptors out, and the RP1 does not see the processors' caches, so a
//! line written back could undo what the engine wrote to a neighbour.
//! `_emac.zig` keeps the two apart: it hands receive descriptors back only
//! a whole line at a time, all of them filled, and fills send descriptors
//! only while the engine holds none. `next` is how a ring's last descriptor
//! is known here: it is followed by one no higher than itself.
//!
//! **Sending** stops at the first descriptor with USED set, and raises an
//! interrupt (`int_send` has it). TSTART goes on from there, but only if the
//! engine has stopped by then; one that was still on its way to that
//! descriptor, and read it before the frames were written out, stays
//! stopped, so the task gives TSTART again when it hears of it.
//!
//! **What the engine raises** is in ISR, a bit per cause, each kept until
//! it is written back: the RP1's GEM has no clear-on-read (DCFG1's IRQCOR
//! is 0). Received frames are held back a little (INTMOD), so a burst of
//! them is one interrupt. A frame with no free receive descriptor is
//! counted, not raised, and the next one finds what the task gave back in
//! between: no doorbell, so `pollReceive` has nothing to do.
//!
//! **The line.** The speed and duplex are set only with RE and TE off, as
//! the unit runs the engine only while there is a carrier. TE and RE going
//! off also send the engine's ring pointers back to the rings' starts,
//! where `setRunning` starts the rings afresh.
//!
//! **Checksums**: the MAC's checksum engine checks every received frame's
//! IP header and its TCP or UDP checksum, and says what it found in the
//! descriptor: a value of 2 or 3 is both right, for either IP (on a CM5,
//! TCP over IPv4 and over IPv6 both read 2). It is off while every frame is
//! passed: a frame with a wrong checksum is then for whoever asked to see
//! it, and those bits of the descriptor mean something else. What is sent
//! keeps the stack's checksums: the send side's engine (TXCOEN) is on for
//! every frame or for none, and on the JH7110 the same kind of engine
//! filled in some TCP segments wrongly.
//!
//! It keeps no state but where its registers are (`registers`) and whether
//! the checksum engine is on (`checking`). The values
//! follow Raspberry Pi's Linux (macb_main.c, raspberrypi_rp1_config) and
//! its device tree for the CM5.

const sdk = @import("sdk");
const net = sdk.devices.network;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;

/// Where the MAC's registers are; the device sets it from its port.
pub var registers: usize = 0;
/// Whether received frames' descriptors say what the checksum engine found.
var checking: bool = false;

fn at(offset: usize) *volatile u32 {
    return reg(registers + offset);
}

// The registers.
const ncr = 0x000;
const ncfgr = 0x004;
const nsr = 0x008;
const usrio = 0x00C;
const dmacfg = 0x010;
const tsr = 0x014;
const rbqp = 0x018;
const tbqp = 0x01C;
const rsr = 0x020;
const isr = 0x024;
const ier = 0x028;
const idr = 0x02C;
const man = 0x034;
const amp = 0x054;
const intmod = 0x05C;
const hrb = 0x080;
const hrt = 0x084;
const sa1b = 0x088;
const sa1t = 0x08C;
const sa2b = 0x090;
const sa4t = 0x0A4;
const mid = 0x0FC;
const rx_resource_errors = 0x1A0;
const rx_overruns = 0x1A4;
const dcfg1 = 0x280;
const tbqph = 0x4C8;
const rbqph = 0x4D4;

/// NCR: receiver and transmitter on, the management bus on, the counters
/// cleared, sending started, sending stopped after the current frame.
const ncr_re: u32 = 1 << 2;
const ncr_te: u32 = 1 << 3;
const ncr_mpe: u32 = 1 << 4;
const ncr_clear_stats: u32 = 1 << 5;
const ncr_tstart: u32 = 1 << 9;
const ncr_thalt: u32 = 1 << 10;

/// NCFGR: 100 Mbit/s, full duplex, every frame passed, multicast frames
/// by their hash, frames up to 1536 bytes, 1000 Mbit/s, pause frames
/// heeded, the checksum stripped from every received frame, the checksum
/// engine on for what comes in. MDC is the MAC's bus clock divided by 96:
/// the RP1's clk_sys of 200 MHz makes it 2.1 MHz.
const config_spd: u32 = 1 << 0;
const config_fd: u32 = 1 << 1;
const config_caf: u32 = 1 << 4;
const config_mti: u32 = 1 << 6;
const config_big: u32 = 1 << 8;
const config_gbe: u32 = 1 << 10;
const config_pae: u32 = 1 << 13;
const config_drfcs: u32 = 1 << 17;
const config_mdc_div96: u32 = 5 << 18;
const config_dbw_shift = 21;
const config_rx_checksum: u32 = 1 << 24;

/// DCFG1: the bus's width as 1, 2 or 4 words of 32 bits, which NCFGR's
/// DBW says as 0, 1 or 2.
const dcfg1_dbw_shift = 25;
const dcfg1_dbw_mask: u32 = 7;

/// USRIO: the line to the PHY is RGMII.
const usrio_rgmii: u32 = 1 << 0;

/// DMACFG: bursts of 16, the whole receive and send packet buffers, the
/// receive buffers' size in 64-byte units, descriptors of 64-bit addresses.
const dma_burst16: u32 = 16 << 0;
const dma_rx_buffer_all: u32 = 3 << 8;
const dma_tx_buffer_all: u32 = 1 << 10;
const dma_rx_size_shift = 16;
const dma_rx_size_unit = 64;
const dma_addr64: u32 = 1 << 30;

/// AMP: eight reads and eight writes outstanding on the bus, the writes
/// counted until their answers, as the device tree has it (the reset
/// value is one of each).
const amp_pipes: u32 = 8 << 0 | 8 << 8 | 1 << 16;

/// INTMOD: 50 us, in units of 800 ns, between interrupts, each way.
const moderation: u32 = 62;
const moderation_both: u32 = moderation | moderation << 16;

/// MAN: a clause 22 transfer, reading or writing, the PHY, the register,
/// the data.
const man_clause22: u32 = 1 << 30 | 2 << 16;
const man_read: u32 = 2 << 28;
const man_write: u32 = 1 << 28;
const man_phy_shift = 23;
const man_register_shift = 18;

/// NSR: the management bus is idle.
const nsr_idle: u32 = 1 << 2;
/// TSR: the engine is sending.
const tsr_go: u32 = 1 << 3;

/// MID: the module's number. Every GEM's is 2 or more; a MAC that reads
/// all ones or zeroes is not there.
const mid_shift = 16;
const mid_mask: u32 = 0xFFF;
const mid_gem: u32 = 2;

/// ISR, IER and IDR: a frame received, no receive descriptor, no send
/// descriptor, a frame sent; and what stops the engine: a send that ran
/// dry, too many retries, a frame cut off, a bus error.
pub const int_receive: u32 = 1 << 1;
pub const int_receive_unavailable: u32 = 1 << 2;
const int_tx_used: u32 = 1 << 3;
const int_tx_underrun: u32 = 1 << 4;
const int_tx_retries: u32 = 1 << 5;
const int_tx_corrupt: u32 = 1 << 6;
const int_tx_complete: u32 = 1 << 7;
const int_hresp: u32 = 1 << 11;
pub const int_send: u32 = int_tx_complete | int_tx_used;
pub const int_bus_error: u32 = int_hresp | int_tx_underrun | int_tx_retries | int_tx_corrupt;
const int_wanted: u32 = int_receive | int_send | int_bus_error;
const int_all: u32 = 0xFFFF_FFFF;

/// The MAC runs at 1000 Mbit/s.
pub const gigabit = true;

/// One descriptor. Four share a cache line: see the top.
pub const Descriptor = extern struct {
    address: u32 = 0,
    control: u32 = 0,
    address_high: u32 = 0,
    unused: u32 = 0,
};

/// A receive descriptor's first word: filled, the ring's last. Its second:
/// the frame's length, its first and last buffer, and with the checksum
/// engine on, in bits 22 and 23, what it found: 2 and 3 are TCP and UDP
/// packets whose checksums and IP header are right, so the higher bit says.
const receive_used: u32 = 1 << 0;
const receive_wrap: u32 = 1 << 1;
const receive_length_mask: u32 = 0xFFF;
const receive_sof: u32 = 1 << 14;
const receive_eof: u32 = 1 << 15;
const receive_checked: u32 = 1 << 23;
/// A send descriptor's second word: the frame's length, its last buffer,
/// what went wrong, the ring's last, sent.
const send_length_mask: u32 = 0x3FFF;
const send_last: u32 = 1 << 15;
const send_errors: u32 = 7 << 27;
const send_wrap: u32 = 1 << 30;
const send_used: u32 = 1 << 31;

/// How long a stopping send or an MDIO transfer may take, in microseconds.
const drain_us = 10_000;
const mdio_us = 10_000;

fn low(address: usize) u32 {
    return @truncate(address);
}

fn high(address: usize) u32 {
    return @truncate(@as(u64, address) >> 32);
}

/// Until `done` says so, or `us` have gone: false then.
fn waitFor(us: u64, done: *const fn () bool) bool {
    const until = systimer.uptimeUs() + us;
    while (!done()) {
        if (systimer.uptimeUs() > until) return false;
    }
    return true;
}

/// The MAC stopped, its causes off and cleared and its counters at zero.
/// It has no reset of its own. False if no GEM answers.
pub fn reset() bool {
    const module = (at(mid).* >> mid_shift) & mid_mask;
    if (module < mid_gem or module == mid_mask) return false;
    at(ncr).* = ncr_clear_stats;
    at(idr).* = int_all;
    at(isr).* = int_all;
    at(tsr).* = int_all;
    at(rsr).* = int_all;
    return true;
}

/// After `reset`: the line RGMII and the management bus on; the MAC
/// stripping checksums, neither receiving nor sending; the engine's bursts
/// and the receive buffers' size, `receive_bytes`. The checksum engine
/// checks what comes in.
pub fn setUp(receive_bytes: u32) void {
    const width = (at(dcfg1).* >> dcfg1_dbw_shift) & dcfg1_dbw_mask;
    const dbw: u32 = switch (width) {
        4 => 2,
        2 => 1,
        else => 0,
    };
    at(ncfgr).* = config_mdc_div96 | config_big | config_drfcs | config_rx_checksum | dbw << config_dbw_shift;
    checking = true;
    at(usrio).* = usrio_rgmii;
    at(amp).* = amp_pipes;
    at(intmod).* = moderation_both;
    at(dmacfg).* = dma_burst16 | dma_rx_buffer_all | dma_tx_buffer_all | dma_addr64 |
        (receive_bytes / dma_rx_size_unit) << dma_rx_size_shift;
    at(ncr).* = ncr_mpe;
}

/// The checksums the MAC's engine does, as Sana2DeviceQuery's `offload`
/// says them: those of what comes in checked, IPv4's and IPv6's. Never
/// those of what is sent (see the top).
pub fn offload() u32 {
    return net.S2OFFLOADF_RX_CHECKSUMS | net.S2OFFLOADF_RX_CHECKSUMS_IPV6;
}

/// The line's speed and duplex, as the PHY agreed them, with RE and TE off
/// (see the top). Pause frames are heeded on a full-duplex line.
pub fn setLine(mbits: u32, full_duplex: bool) void {
    var config = at(ncfgr).* & ~(config_spd | config_gbe | config_fd | config_pae);
    switch (mbits) {
        1000 => config |= config_gbe,
        100 => config |= config_spd,
        else => {},
    }
    if (full_duplex) config |= config_fd | config_pae;
    at(ncfgr).* = config;
}

/// The address the MAC takes frames for, and puts nowhere: the frames it
/// sends carry the source address they were built with. The other three
/// it could match are cleared, the top last, which switches each on.
pub fn setStation(address: *const [6]u8) void {
    var other: usize = sa2b;
    while (other <= sa4t) : (other += 4) at(other).* = 0;
    at(sa1b).* = @as(u32, address[3]) << 24 | @as(u32, address[2]) << 16 |
        @as(u32, address[1]) << 8 | address[0];
    at(sa1t).* = @as(u32, address[5]) << 8 | address[4];
}

/// Every frame passed, the checksum engine off so that a wrong one is too,
/// or every multicast frame as well as the station's and broadcasts - the
/// whole hash matches - or only those.
pub fn setFilter(promiscuous: bool, multicast: bool) void {
    var config = at(ncfgr).* & ~(config_caf | config_mti | config_rx_checksum);
    config |= if (promiscuous) config_caf else config_rx_checksum;
    checking = !promiscuous;
    if (multicast) config |= config_mti;
    const hash: u32 = if (multicast) 0xFFFF_FFFF else 0;
    at(hrb).* = hash;
    at(hrt).* = hash;
    at(ncfgr).* = config;
}

// --- the descriptors ------------------------------------------------------

/// A receive descriptor set up with its buffer and handed to the engine.
pub fn prepareReceive(descriptor: *Descriptor, buffer: []u8, next: *Descriptor, interrupt: bool) void {
    descriptor.address = if (@intFromPtr(next) <= @intFromPtr(descriptor)) receive_wrap else 0;
    giveBack(descriptor, buffer, interrupt);
}

/// A send descriptor set up empty, the driver's.
pub fn prepareSend(descriptor: *Descriptor, buffer: []u8, next: *Descriptor) void {
    _ = buffer;
    descriptor.* = .{ .control = send_used | if (@intFromPtr(next) <= @intFromPtr(descriptor)) send_wrap else 0 };
}

/// A filled receive descriptor handed back to the engine, its buffer given
/// it again. The engine raises its interrupt by its own timer, whatever
/// `interrupt` asks.
pub fn giveBack(descriptor: *Descriptor, buffer: []u8, interrupt: bool) void {
    _ = interrupt;
    const address = @intFromPtr(buffer.ptr);
    descriptor.address_high = high(address);
    descriptor.control = 0;
    descriptor.address = low(address) | (descriptor.address & receive_wrap);
}

/// What a receive descriptor holds once the engine has given it back.
pub const Frame = struct {
    /// The frame's length, without its checksum.
    length: u32,
    /// Whether it came in whole, in the one buffer.
    good: bool,
    /// Whether the checksum engine checked its TCP or UDP checksum and its
    /// IP header, and found them right.
    checked: bool,
};

/// The frame in a receive descriptor, or null while the engine has it.
pub fn received(descriptor: *const Descriptor, buffer_bytes: u32) ?Frame {
    if (descriptor.address & receive_used == 0) return null;
    const status = descriptor.control;
    const length = status & receive_length_mask;
    const whole = receive_sof | receive_eof;
    return .{
        .length = length,
        .good = status & whole == whole and length > 0 and length <= buffer_bytes,
        .checked = checking and status & receive_checked != 0,
    };
}

/// A send descriptor handed to the engine with the frame of `length` bytes
/// in `buffer`. The checksums are the stack's, so `fill` never asks.
pub fn queueSend(descriptor: *Descriptor, buffer: []u8, length: u32, fill: bool) void {
    _ = fill;
    const address = @intFromPtr(buffer.ptr);
    descriptor.address = low(address);
    descriptor.address_high = high(address);
    descriptor.control = (descriptor.control & send_wrap) | send_last | (length & send_length_mask);
}

/// Whether a send descriptor's frame went out, or null while the engine
/// still has it.
pub fn sendFinished(descriptor: *const Descriptor) ?bool {
    const status = descriptor.control;
    if (status & send_used == 0) return null;
    return status & send_errors == 0;
}

// --- running --------------------------------------------------------------

/// Receiving and sending started on the two rings, from their first
/// descriptors: every receive descriptor the engine's, no send descriptor
/// yet. The high halves first, then the pointers, its causes, then the
/// MAC.
pub fn start(receive_ring: []Descriptor, send_ring: []Descriptor) void {
    const rx = @intFromPtr(receive_ring.ptr);
    const tx = @intFromPtr(send_ring.ptr);
    at(rbqph).* = high(rx);
    at(rbqp).* = low(rx);
    at(tbqph).* = high(tx);
    at(tbqp).* = low(tx);
    at(isr).* = int_all;
    at(ier).* = int_wanted;
    fence();
    at(ncr).* |= ncr_re | ncr_te;
}

fn sendStopped() bool {
    return at(tsr).* & tsr_go == 0;
}

/// Receiving and sending stopped, and the engine's causes off: sending
/// once its frame is out, then the MAC.
pub fn stop() void {
    at(ncr).* |= ncr_thalt;
    _ = waitFor(drain_us, &sendStopped);
    at(ncr).* &= ~(ncr_re | ncr_te);
    at(idr).* = int_all;
    at(isr).* = int_all;
}

/// What the engine has raised, cleared.
pub fn takeInterrupts() u32 {
    const raised = at(isr).* & int_wanted;
    if (raised != 0) at(isr).* = raised;
    return raised;
}

/// The frames dropped since the last call: with no receive descriptor
/// free, and with the receive buffer full. Reading the counts clears them.
pub fn takeMissed() u32 {
    return at(rx_resource_errors).* + at(rx_overruns).*;
}

/// Nothing to say: the engine reads a descriptor again at each frame.
pub fn pollReceive(last: *const Descriptor) void {
    _ = last;
}

/// Sending started, or left to go on: `next` is where it stopped by itself.
pub fn pollSend(next: *const Descriptor) void {
    _ = next;
    fence();
    at(ncr).* |= ncr_tstart;
}

/// What was written for the engine reaches it before the register that
/// tells it to look.
fn fence() void {
    sdk.hardware.barrier.full();
}

// --- the management bus ---------------------------------------------------

/// PHY register `register` of the PHY at `phy`, or null if the bus did not
/// answer in time.
pub fn readPhy(phy: u32, register: u32) ?u16 {
    if (!mdioIdle()) return null;
    at(man).* = man_clause22 | man_read | phy << man_phy_shift | register << man_register_shift;
    if (!mdioIdle()) return null;
    return @truncate(at(man).*);
}

/// `value` into PHY register `register` of the PHY at `phy`; false if the
/// bus did not answer in time.
pub fn writePhy(phy: u32, register: u32, value: u16) bool {
    if (!mdioIdle()) return false;
    at(man).* = man_clause22 | man_write | phy << man_phy_shift | register << man_register_shift | value;
    return mdioIdle();
}

fn mdioDone() bool {
    return at(nsr).* & nsr_idle != 0;
}

fn mdioIdle() bool {
    return waitFor(mdio_us, &mdioDone);
}
