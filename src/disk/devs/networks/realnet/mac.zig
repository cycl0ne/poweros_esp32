// SPDX-License-Identifier: MIT
//! The controller's registers, for realnet.device: the whole of what
//! this device touches, at `at` - the address the function's base
//! address register was placed at. The controller keeps its state
//! itself, so nothing is held here.
//!
//! **Three register spaces behind one.** Only a small block is reached
//! by address; everything else this device touches is behind an indirect
//! register that takes an address and carries sixteen bits of data:
//!
//! - the MAC's own extended registers (`macOcpRead`, `macOcpWrite`),
//!   where the part's working settings are;
//! - the PHY's (`phyOcpRead`, `phyOcpWrite`), and the eight standard
//!   management registers of a PHY, which are a window into those
//!   (`phyRead`, `phyWrite`);
//! - the PCI Express part's own configuration space (`csiRead`,
//!   `csiWrite`), which is how the link's settings are reached without
//!   going out to the bridge.
//!
//! Each is an address written to a register, a busy bit to wait on, and
//! the data in the low half of the same register.
//!
//! **The receive filter** is two things. The station address registers
//! take frames addressed to the machine, and the two multicast registers
//! take a group by a hash of its address: six bits of the frame check
//! sequence over the six address bytes, one of 64 bits, so a group that
//! was never joined can get through and the unit above drops it. The
//! receive configuration register has the blunt instruments - every
//! multicast frame, and every frame at all.
//!
//! **Waits.** What the part asks for between two writes is counted in
//! reads of a register it answers at once: a read over the link takes
//! about a microsecond, which is the order of those waits. The waits in
//! milliseconds are the caller's, on the timer.

const hardware = @import("sdk").hardware;
const reg32 = hardware.mmio.reg;
const reg16 = hardware.mmio.reg16;
const reg8 = hardware.mmio.reg8;
const barrier = hardware.barrier;
const ethernet = @import("sdk").devices.network.ethernet;

// --- the registers ----------------------------------------------------------------

/// The station address the part answers to, and the multicast hash.
const mac0 = 0x0000;
const mac4 = 0x0004;
const mar0 = 0x0008;
const mar4 = 0x000c;

/// Where each ring starts. The part reads both as 64-bit addresses, low
/// half first.
const txdesc_lo = 0x0020;
const txdesc_hi = 0x0024;
const rxdesc_lo = 0x00e4;
const rxdesc_hi = 0x00e8;

/// How the part raises its interrupt, when it is told to raise it at all.
const int_cfg0 = 0x0034;
const int_cfg1 = 0x007a;

/// The command register: receiving, sending, the reset, and the request
/// to stop that empties both FIFOs first.
pub const cmd = 0x0037;
pub const cmd_txenb: u8 = 0x04;
pub const cmd_rxenb: u8 = 0x08;
const cmd_reset: u8 = 0x10;
const cmd_stopreq: u8 = 0x80;

/// What the part may raise, and what it has raised.
pub const imr = 0x0038;
pub const isr = 0x003c;

pub const cause_rx: u32 = 0x0000_0001;
pub const cause_rx_err: u32 = 0x0000_0002;
pub const cause_tx: u32 = 0x0000_0004;
pub const cause_tx_err: u32 = 0x0000_0008;
pub const cause_rx_empty: u32 = 0x0000_0010;
pub const cause_link: u32 = 0x0000_0020;
pub const cause_rx_overflow: u32 = 0x0000_0040;
pub const cause_tx_empty: u32 = 0x0000_0080;
pub const cause_pcs_timeout: u32 = 0x0000_4000;
pub const cause_system: u32 = 0x0000_8000;

/// What the device asks to hear about: frames in and out, the link, and
/// the two that say something went wrong.
pub const causes_wanted: u32 = cause_rx | cause_rx_err | cause_tx | cause_tx_err |
    cause_link | cause_tx_empty | cause_rx_overflow | cause_pcs_timeout | cause_system;

/// How sending and receiving are set up. The send configuration's top
/// bits are read-only and say which part this is.
pub const txcfg = 0x0040;
pub const rxcfg = 0x0044;
const txcfg_hwrev: u32 = 0x7cf0_0000;

/// What the part is told to send and receive like. Both are the figures
/// the part comes up wanting: the burst lengths and thresholds its
/// documents give, with the descriptor layout this driver writes.
pub const txcfg_config: u32 = 0x0300_0700;
pub const rxcfg_config: u32 = 0x41c0_0700;

const rxcfg_allphys: u32 = 0x0000_0001;
const rxcfg_indiv: u32 = 0x0000_0002;
const rxcfg_multi: u32 = 0x0000_0004;
const rxcfg_broad: u32 = 0x0000_0008;
const rxcfg_runt: u32 = 0x0000_0010;
const rxcfg_errpkt: u32 = 0x0000_0020;
const rxcfg_taking: u32 = rxcfg_allphys | rxcfg_indiv | rxcfg_multi |
    rxcfg_broad | rxcfg_runt | rxcfg_errpkt;

/// The timer whose count stands in for an interrupt the part would
/// otherwise raise at once; left at zero here, so every frame raises its
/// own.
pub const timercnt = 0x0048;
pub const timerint0 = 0x0058;
pub const timerint1 = 0x005c;
pub const timerint2 = 0x008c;
pub const timerint3 = 0x00f4;

/// The lock on the configuration registers: they take a write only while
/// it is open.
const eecmd = 0x0050;
const eecmd_writecfg: u8 = 0xc0;

pub const cfg1 = 0x0052;
pub const cfg2 = 0x0053;
pub const cfg3 = 0x0054;
pub const cfg5 = 0x0056;
pub const cfg1_speed_down: u8 = 0x10;
pub const cfg2_clkreq_en: u8 = 0x80;
pub const cfg3_rdy_to_l23: u8 = 0x02;
pub const cfg5_pme_sts: u8 = 0x01;

/// How many descriptors the part fetches at a time.
pub const tdfnr = 0x0057;

/// The PCI Express configuration space, reached from this side.
const csidr = 0x0064;
const csiar = 0x0068;
const csiar_byte_en: u32 = 0x0000_000f;
const csiar_byte_en_shift = 12;
const csiar_addr_mask: u32 = 0x0000_0fff;
const csiar_busy: u32 = 0x8000_0000;

/// What the link is doing, in one register.
pub const physt = 0x006c;
pub const phy_fdx: u16 = 0x0001;
pub const phy_link: u16 = 0x0002;
pub const phy_10: u16 = 0x0004;
pub const phy_100: u16 = 0x0008;
pub const phy_1000: u16 = 0x0010;
pub const phy_2500: u16 = 0x0400;
pub const phy_5000: u16 = 0x1000;

/// The PHY's power.
pub const pmch = 0x006f;

/// Written when a send descriptor has been filled: the part fetches it
/// rather than waiting for its own next look.
const txstart = 0x0090;
const txstart_start: u16 = 0x0001;

/// The two indirect registers, and what their halves mean.
const macocp = 0x00b0;
const phyocp = 0x00b8;
const ocp_data_mask: u32 = 0x0000_ffff;
const ocp_busy: u32 = 0x8000_0000;
const ocp_addr_shift = 16;

/// Power saving on the link, the two-wire bus to the board's management
/// part, and what that part is doing.
pub const dllpr = 0x00d0;
pub const dllpr_pfm_en: u8 = 0x40;
pub const dllpr_tx_10m_ps_en: u8 = 0x80;
const twicmd = 0x00d2;
pub const mcucmd = 0x00d3;
const mcucmd_rxfifo_empty: u8 = 0x10;
const mcucmd_txfifo_empty: u8 = 0x20;
const mcucmd_is_oob: u8 = 0x80;

/// The longest frame the part takes in.
const rxmaxsize = 0x00da;

/// What the part works out for itself on the way in, and the moderation
/// register beside it, whose two low bits say when both paths have come
/// to a stop.
pub const cpluscmd = 0x00e0;
const im = 0x00e2;
pub const cpluscmd_rxcsum: u16 = 0x0020;

/// The gate in front of the receive path, and the switch that keeps the
/// transmit path alive at ten megabits.
pub const ppsw = 0x00f2;
pub const ppsw_rxdv_gate: u8 = 0x08;

/// Where the PHY's standard registers are in the PHY's own space.
const phybase = 0x0a40;

/// The address the part came up with, which is the one in its own
/// storage.
const addr0 = 0x19e0;
const addr1 = 0x19e4;

/// Receiving spread over several rings, which this device does not do.
/// One moderation timer per cause, all of them left at zero: nothing
/// waits for a timer before its interrupt is raised.
pub const intmiti = 0x0a00;

pub const rss_ctrl = 0x4500;
pub const rxqueue_ctrl = 0x4800;

/// A whole frame check sequence over the six bytes of a group address,
/// most significant bit first.
const crc_poly: u32 = 0x04c1_1db7;

/// How many reads of a register one wait is: a read over the link is
/// about a microsecond.
const micro = 1;

// --- the parts --------------------------------------------------------------------

/// Which controller this is, from the revision in the send
/// configuration register - the one register that says. They differ in
/// two settings and in the speeds they reach, and in nothing else this
/// device touches.
pub const Part = struct {
    name: [*:0]const u8,
    /// The fastest it goes, for a unit with no carrier to report.
    bps: u64,
    /// Whether it is the first of these parts, which wants two settings
    /// the later ones do not.
    first: bool,
    /// How it is told to receive: the thresholds and the burst length
    /// its own documents give, with the descriptor layout this driver
    /// writes. The incoming tag of a frame that carries one is left on
    /// the frame rather than taken off into the descriptor.
    receiving: u32,
    /// What its extended register 0xe614 is set to, which is how much of
    /// the part's buffer the receive path may take.
    fifo: u16,
};

const rtl8125a: Part = .{
    .name = "RTL8125A",
    .bps = 2_500_000_000,
    .first = true,
    .receiving = 0x4100_0700,
    .fifo = 0x0300,
};
const rtl8125b: Part = .{
    .name = "RTL8125B",
    .bps = 2_500_000_000,
    .first = false,
    .receiving = 0x4100_0c00,
    .fifo = 0x0200,
};
const rtl8125d: Part = .{
    .name = "RTL8125D",
    .bps = 2_500_000_000,
    .first = false,
    .receiving = 0x4120_0c00,
    .fifo = 0x0300,
};
const rtl8126: Part = .{
    .name = "RTL8126",
    .bps = 5_000_000_000,
    .first = false,
    .receiving = 0x4120_0d00,
    .fifo = 0x0300,
};

/// The part at `at`, or null for a revision this device does not drive.
pub fn partOf(at: usize) ?*const Part {
    return switch (read32(at, txcfg) & txcfg_hwrev) {
        0x6080_0000, 0x6090_0000 => &rtl8125a,
        0x6400_0000, 0x6410_0000 => &rtl8125b,
        0x6880_0000, 0x6890_0000 => &rtl8125d,
        0x6490_0000, 0x64a0_0000 => &rtl8126,
        else => null,
    };
}

/// The revision as it reads, for a line about a part that is not driven.
pub fn revision(at: usize) u32 {
    return read32(at, txcfg) & txcfg_hwrev;
}

// --- the registers, read and written ----------------------------------------------

pub fn read32(at: usize, offset: usize) u32 {
    return reg32(at + offset).*;
}

pub fn write32(at: usize, offset: usize, value: u32) void {
    reg32(at + offset).* = value;
}

pub fn read16(at: usize, offset: usize) u16 {
    return reg16(at + offset).*;
}

pub fn write16(at: usize, offset: usize, value: u16) void {
    reg16(at + offset).* = value;
}

pub fn read8(at: usize, offset: usize) u8 {
    return reg8(at + offset).*;
}

pub fn write8(at: usize, offset: usize, value: u8) void {
    reg8(at + offset).* = value;
}

pub fn set8(at: usize, offset: usize, bits: u8) void {
    write8(at, offset, read8(at, offset) | bits);
}

pub fn clear8(at: usize, offset: usize, bits: u8) void {
    write8(at, offset, read8(at, offset) & ~bits);
}

pub fn set16(at: usize, offset: usize, bits: u16) void {
    write16(at, offset, read16(at, offset) | bits);
}

pub fn clear16(at: usize, offset: usize, bits: u16) void {
    write16(at, offset, read16(at, offset) & ~bits);
}

pub fn set32(at: usize, offset: usize, bits: u32) void {
    write32(at, offset, read32(at, offset) | bits);
}

pub fn clear32(at: usize, offset: usize, bits: u32) void {
    write32(at, offset, read32(at, offset) & ~bits);
}

/// About `us` microseconds waited out in reads of the command register,
/// which the part answers without a wait of its own.
pub fn wait(at: usize, us: u32) void {
    var left = us;
    while (left > 0) : (left -= 1) _ = read8(at, cmd);
}

/// Whether anything answers where the registers were placed: the part
/// that is gone or was never there reads as all ones.
pub fn present(at: usize) bool {
    return read32(at, txcfg) != 0xffff_ffff;
}

// --- the registers behind registers -----------------------------------------------

/// One of the MAC's extended registers. Their addresses are even and the
/// register takes them halved.
pub fn macOcpRead(at: usize, address: u16) u16 {
    write32(at, macocp, (@as(u32, address >> 1) << ocp_addr_shift));
    return @truncate(read32(at, macocp) & ocp_data_mask);
}

pub fn macOcpWrite(at: usize, address: u16, value: u16) void {
    write32(at, macocp, (@as(u32, address >> 1) << ocp_addr_shift) | @as(u32, value) | ocp_busy);
}

pub fn macOcpSet(at: usize, address: u16, bits: u16) void {
    macOcpWrite(at, address, macOcpRead(at, address) | bits);
}

pub fn macOcpClear(at: usize, address: u16, bits: u16) void {
    macOcpWrite(at, address, macOcpRead(at, address) & ~bits);
}

/// One of the MAC's extended registers with `mask`'s bits set to
/// `value`'s: the pattern most of the bring-up is written in.
pub fn macOcpModify(at: usize, address: u16, mask: u16, value: u16) void {
    macOcpWrite(at, address, (macOcpRead(at, address) & ~mask) | value);
}

/// One of the PHY's registers. The busy bit is the part's answer that
/// the transfer over the management bus is done.
pub fn phyOcpRead(at: usize, address: u16) u16 {
    var value: u32 = @as(u32, address >> 1) << ocp_addr_shift;
    write32(at, phyocp, value);
    var left: u32 = 100;
    while (left > 0) : (left -= 1) {
        wait(at, micro);
        value = read32(at, phyocp);
        if (value & ocp_busy != 0) break;
    }
    return @truncate(value & ocp_data_mask);
}

pub fn phyOcpWrite(at: usize, address: u16, value: u16) void {
    write32(at, phyocp, (@as(u32, address >> 1) << ocp_addr_shift) | ocp_busy | value);
    var left: u32 = 100;
    while (left > 0) : (left -= 1) {
        wait(at, micro);
        if (read32(at, phyocp) & ocp_busy == 0) break;
    }
}

pub fn phyOcpSet(at: usize, address: u16, bits: u16) void {
    phyOcpWrite(at, address, phyOcpRead(at, address) | bits);
}

pub fn phyOcpClear(at: usize, address: u16, bits: u16) void {
    phyOcpWrite(at, address, phyOcpRead(at, address) & ~bits);
}

/// Where one of the PHY's eight standard management registers lies in
/// the PHY's own space: they are a window of eight, and the window is
/// chosen by which of them is wanted.
fn phyPlace(number: u16) u16 {
    const page = phybase + (number / 8);
    const offset = 0x10 + (number % 8);
    return (page << 4) + ((offset - 16) << 1);
}

pub fn phyRead(at: usize, number: u16) u16 {
    return phyOcpRead(at, phyPlace(number));
}

pub fn phyWrite(at: usize, number: u16, value: u16) void {
    phyOcpWrite(at, phyPlace(number), value);
}

/// One register of the part's own PCI Express configuration space.
pub fn csiRead(at: usize, address: u32) u32 {
    write32(at, csiar, (address & csiar_addr_mask) | (csiar_byte_en << csiar_byte_en_shift));
    var left: u32 = 10;
    while (left > 0) : (left -= 1) {
        wait(at, 100);
        if (read32(at, csiar) & csiar_busy != 0) break;
    }
    wait(at, 20);
    return read32(at, csidr);
}

pub fn csiWrite(at: usize, address: u32, value: u32) void {
    write32(at, csidr, value);
    write32(at, csiar, (address & csiar_addr_mask) |
        (csiar_byte_en << csiar_byte_en_shift) | csiar_busy);
    var left: u32 = 10;
    while (left > 0) : (left -= 1) {
        wait(at, 100);
        if (read32(at, csiar) & csiar_busy == 0) break;
    }
    wait(at, 20);
}

// --- the configuration registers' lock --------------------------------------------

pub fn unlock(at: usize) void {
    set8(at, eecmd, eecmd_writecfg);
}

pub fn lock(at: usize) void {
    clear8(at, eecmd, eecmd_writecfg);
}

// --- the station address and the filter -------------------------------------------

/// The address the part came up with, from its own storage.
pub fn stationAddress(at: usize) ethernet.Address {
    var address: ethernet.Address = @splat(0);
    const low = read32(at, addr0);
    const high = read16(at, addr1);
    address[0] = @truncate(low);
    address[1] = @truncate(low >> 8);
    address[2] = @truncate(low >> 16);
    address[3] = @truncate(low >> 24);
    address[4] = @truncate(high);
    address[5] = @truncate(high >> 8);
    return address;
}

/// The address the part answers to.
pub fn setStation(at: usize, address: *const ethernet.Address) void {
    unlock(at);
    write32(at, mac0, @as(u32, address[0]) | @as(u32, address[1]) << 8 |
        @as(u32, address[2]) << 16 | @as(u32, address[3]) << 24);
    write32(at, mac4, @as(u32, address[4]) | @as(u32, address[5]) << 8);
    lock(at);
}

/// Which of the 64 hash bits a group address falls in: the top six bits
/// of the frame check sequence over it.
pub fn groupHash(address: *const ethernet.Address) u32 {
    var crc: u32 = 0xffff_ffff;
    for (address) |byte| {
        var bits = byte;
        var left: u32 = 8;
        while (left > 0) : (left -= 1) {
            const carry = (crc >> 31) ^ (bits & 1);
            crc <<= 1;
            bits >>= 1;
            if (carry != 0) crc ^= crc_poly;
        }
    }
    return crc >> 26;
}

/// The groups the part takes. The two registers are written the other
/// way round from the way the bits are counted, which is how the part
/// reads them.
pub fn setGroups(at: usize, hash: *const [2]u32) void {
    write32(at, mar0, @byteSwap(hash[1]));
    write32(at, mar4, @byteSwap(hash[0]));
}

/// Receiving set up: the machine's own frames and broadcasts always,
/// every multicast frame so that the hash decides, and every frame at
/// all where that was asked for.
pub fn startReceive(at: usize, promiscuous: bool) void {
    var filter = read32(at, rxcfg) & ~rxcfg_taking;
    filter |= rxcfg_indiv | rxcfg_broad | rxcfg_multi;
    if (promiscuous) filter |= rxcfg_allphys;
    write32(at, rxcfg, filter);
}

pub fn stopReceive(at: usize) void {
    clear32(at, rxcfg, rxcfg_taking);
}

// --- the part running -------------------------------------------------------------

/// Frames in and out.
pub fn start(at: usize) void {
    write8(at, cmd, cmd_txenb | cmd_rxenb);
}

/// What the part may raise, turned on. The causes are cleared first:
/// what it raised before the device was there is not news.
pub fn enableCauses(at: usize) void {
    write32(at, isr, read32(at, isr));
    write32(at, imr, causes_wanted);
}

pub fn disableCauses(at: usize) void {
    write32(at, imr, 0);
    write32(at, isr, read32(at, isr));
}

/// Every cause turned off, with what has been raised left standing.
/// The part is quiet from here until `enableCauses` - its causes are a
/// level, so one that is still true when they go back on raises its
/// interrupt again, and nothing is lost by turning them off for a
/// while. What is wanted from that while is one interrupt for a pass of
/// the rings however many frames the pass finds, rather than one
/// interrupt per frame.
pub fn maskCauses(at: usize) void {
    write32(at, imr, 0);
}

/// What the part has raised, taken and cleared. Null where it raised
/// nothing, which on a shared interrupt line is somebody else's turn.
pub fn takeCauses(at: usize) ?u32 {
    const raised = read32(at, isr);
    if (raised == 0 or raised == 0xffff_ffff) return null;
    write32(at, isr, raised);
    return raised;
}

/// A send descriptor has been filled: the part told to fetch it. What
/// was written into the ring has to have reached memory before the part
/// is sent after it.
pub fn pollSend(at: usize) void {
    barrier.toDevice();
    write16(at, txstart, txstart_start);
}

/// Where each ring starts, and how long a frame may be. The part reads
/// both rings as 64-bit addresses.
pub fn setRings(at: usize, receive: u64, send: u64, frame_bytes: u32) void {
    write32(at, rxdesc_lo, @truncate(receive));
    write32(at, rxdesc_hi, @truncate(receive >> 32));
    write32(at, txdesc_lo, @truncate(send));
    write32(at, txdesc_hi, @truncate(send >> 32));
    write16(at, rxmaxsize, @truncate(frame_bytes));
}

// --- the reset --------------------------------------------------------------------

/// The part brought to a stop and reset: receiving off, the gate in
/// front of the receive path closed, both FIFOs emptied, then the reset
/// bit, which the part clears when it is done. False where it never
/// does.
pub fn reset(at: usize) bool {
    clear32(at, rxcfg, rxcfg_taking);
    set8(at, ppsw, ppsw_rxdv_gate);
    set8(at, cmd, cmd_stopreq);
    wait(at, 200);

    var left: u32 = 3000;
    while (left > 0) : (left -= 1) {
        wait(at, 50);
        const emptied = mcucmd_rxfifo_empty | mcucmd_txfifo_empty;
        if (read8(at, mcucmd) & emptied == emptied) break;
    }
    left = 3000;
    while (left > 0) : (left -= 1) {
        wait(at, 50);
        if (read16(at, im) & 0x0103 == 0x0103) break;
    }

    write8(at, cmd, read8(at, cmd) & (cmd_txenb | cmd_rxenb));
    write8(at, cmd, cmd_reset);
    left = 100;
    while (left > 0) : (left -= 1) {
        wait(at, 100);
        if (read8(at, cmd) & cmd_reset == 0) return true;
    }
    return false;
}

/// The part taken away from the board's own management, which may have
/// been driving it before the machine started: its wake-on-network
/// paths off, the out-of-band path given up, and the PHY taken out of
/// whatever state it was left in.
pub fn exitOob(at: usize) bool {
    macOcpWrite(at, 0xc0bc, 0x00ff);
    if (!reset(at)) return false;
    clear8(at, mcucmd, mcucmd_is_oob);
    macOcpClear(at, 0xe8de, 0x4000);
    var left: u32 = 10;
    while (left > 0) : (left -= 1) {
        wait(at, 100);
        if (read16(at, twicmd) & 0x0200 != 0) break;
    }
    macOcpWrite(at, 0xc0aa, 0x07d0);
    macOcpWrite(at, 0xc0a6, 0x01b5);
    macOcpWrite(at, 0xc01e, 0x5555);
    left = 10;
    while (left > 0) : (left -= 1) {
        wait(at, 100);
        if (read16(at, twicmd) & 0x0200 != 0) break;
    }
    if (macOcpRead(at, 0xd42c) & 0x0100 != 0) {
        left = 100;
        while (left > 0) : (left -= 1) {
            if (phyOcpRead(at, 0xa420) & 0x0007 == 2) break;
            wait(at, 1000);
        }
        macOcpClear(at, 0xd42c, 0x0100);
        phyOcpClear(at, 0xa466, 0x0001);
        phyOcpClear(at, 0xa468, 0x000a);
    }
    return true;
}

/// The PHY given its power and told to negotiate, and waited for until
/// it says it is running.
pub fn phyPowerOn(at: usize) void {
    set8(at, pmch, 0xc0);
    phyWrite(at, 0, 0x1000);
    var left: u32 = 100;
    while (left > 0) : (left -= 1) {
        if (phyOcpRead(at, 0xa420) & 0x0007 == 3) break;
        wait(at, 1000);
    }
}

/// What the link is doing, as the one register says it.
pub fn linkStatus(at: usize) u16 {
    return read16(at, physt);
}
