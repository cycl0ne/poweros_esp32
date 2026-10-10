// SPDX-License-Identifier: MIT
//! The ESP32-P4's Ethernet MAC, for emac.device: a 10/100 MAC with a DMA
//! engine of its own, its registers in two blocks - the MAC's at
//! `map.EMAC`, the DMA's 0x1000 past them - and the management bus (MDC,
//! MDIO) a PHY's registers are read and written over.
//!
//! **The descriptors.** The DMA engine walks two chains of descriptors
//! in memory, one to receive into and one to send from, each descriptor
//! pointing at its buffer and at the next. A descriptor is the engine's
//! while its OWN bit is set: the driver sets it to hand a buffer over,
//! the engine clears it once the frame is in or out, with the frame's
//! length and status beside it. A chain the engine found nothing in is
//! suspended until it is told to look again (`pollReceive`,
//! `pollSend`). The descriptors are the long form, eight words, each
//! alone in a 64-byte cache line (`Descriptor`): the L1 data cache is in
//! front of internal memory too, so each one is written back after the
//! driver changes it and invalidated before the driver reads it, and a
//! line never holds anything else to lose.
//!
//! **What the engine raises** is in DMA_STATUS, a bit per cause and two
//! summaries; each stays until it is written back. The MAC's own causes
//! (power management, time stamps) are masked.
//!
//! It keeps no state: every call is register writes and reads. The
//! values follow ESP-IDF v6.1's emac_hal_init_mac_default and
//! emac_hal_init_dma_default.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

const mac = sdk.hardware.map.EMAC;
const dma = mac + 0x1000;

// The MAC's registers.
const mac_config = mac + 0x00;
const mac_frame_filter = mac + 0x04;
const mac_mii_address = mac + 0x10;
const mac_mii_data = mac + 0x14;
const mac_interrupt_mask = mac + 0x3C;
const mac_address0_high = mac + 0x40;
const mac_address0_low = mac + 0x44;

/// MAC_CONFIG: receiver and transmitter on, the line's speed and duplex,
/// and the MII port select, which a 10/100 MAC keeps set.
const config_re: u32 = 1 << 2;
const config_te: u32 = 1 << 3;
const config_dm: u32 = 1 << 11;
const config_fes: u32 = 1 << 14;
const config_ps: u32 = 1 << 15;

/// MAC_FRAME_FILTER: every frame, or every multicast frame, passed.
const filter_pr: u32 = 1 << 0;
const filter_pm: u32 = 1 << 4;

/// MAC_MII_ADDRESS: busy, write, the clock range, the register, the PHY.
const mii_busy: u32 = 1 << 0;
const mii_write: u32 = 1 << 1;
const mii_cr_shift = 2;
const mii_reg_shift = 6;
const mii_phy_shift = 11;
/// MDC as the system clock divided by 102: 1.8 MHz at the 180 MHz the
/// system clock runs at, within the bus's 2.5 MHz for anything up to
/// 250 MHz.
const mii_cr_div102: u32 = 4;

// The DMA engine's registers.
const dma_bus_mode = dma + 0x00;
const dma_send_poll = dma + 0x04;
const dma_receive_poll = dma + 0x08;
const dma_receive_list = dma + 0x0C;
const dma_send_list = dma + 0x10;
const dma_status = dma + 0x14;
const dma_operation = dma + 0x18;
const dma_interrupt_enable = dma + 0x1C;
const dma_missed = dma + 0x20;

/// DMA_BUS_MODE: the software reset; then mixed and address-aligned
/// bursts of up to 32 beats, and the long descriptors.
const bus_swr: u32 = 1 << 0;
const bus_atds: u32 = 1 << 7;
const bus_pbl_shift = 8;
const bus_aal: u32 = 1 << 25;
const bus_mb: u32 = 1 << 26;
const bus_mode: u32 = bus_mb | bus_aal | 32 << bus_pbl_shift | bus_atds;

/// DMA_OPERATION: receiving and sending started, the next frame sent
/// while the last one's status is still being written back, the send
/// FIFO flushed. The rest stays 0: the FIFOs pass a frame on after 64
/// bytes, and a frame with an error is dropped.
const op_sr: u32 = 1 << 1;
const op_osf: u32 = 1 << 2;
const op_st: u32 = 1 << 13;
const op_ftf: u32 = 1 << 20;

/// DMA_STATUS and DMA_INTERRUPT_ENABLE: a frame sent, a frame received,
/// no free receive descriptor, a bus error, and the two summaries.
pub const int_send: u32 = 1 << 0;
pub const int_receive: u32 = 1 << 6;
pub const int_receive_unavailable: u32 = 1 << 7;
pub const int_bus_error: u32 = 1 << 13;
const int_abnormal: u32 = 1 << 15;
const int_normal: u32 = 1 << 16;
/// Every cause DMA_STATUS keeps until it is written back.
const int_all: u32 = 0x1_FFFF;
const int_wanted: u32 = int_send | int_receive | int_receive_unavailable |
    int_bus_error | int_abnormal | int_normal;

/// One descriptor, alone in its cache line.
pub const Descriptor = extern struct {
    /// The engine's word: OWN, the frame's status and length.
    status: u32 = 0,
    /// The driver's: the buffer's size, chaining.
    control: u32 = 0,
    buffer: u32 = 0,
    next: u32 = 0,
    /// The long form's extended status and time stamp.
    extended: [4]u32 = @splat(0),
    pad: [8]u32 = @splat(0),
};

/// Both kinds: the engine has it.
pub const own: u32 = 1 << 31;

/// A send descriptor's status: interrupt when sent, the frame's last
/// and first buffer, `next` is the next descriptor; and its error
/// summary.
pub const send_ic: u32 = 1 << 30;
pub const send_ls: u32 = 1 << 29;
pub const send_fs: u32 = 1 << 28;
pub const send_tch: u32 = 1 << 20;
pub const send_es: u32 = 1 << 15;
/// A send descriptor's control: the bytes in the buffer.
pub const send_length_mask: u32 = 0x1FFF;

/// A receive descriptor's status: the frame's length (its checksum
/// counted), its error summary, its first and last buffer.
pub const receive_length_shift = 16;
pub const receive_length_mask: u32 = 0x3FFF;
pub const receive_es: u32 = 1 << 15;
pub const receive_fs: u32 = 1 << 9;
pub const receive_ls: u32 = 1 << 8;
/// A receive descriptor's control: `next` is the next descriptor, and
/// the buffer's size.
pub const receive_rch: u32 = 1 << 14;
pub const receive_size_mask: u32 = 0x1FFF;

/// The checksum at the end of a received frame.
pub const checksum_bytes = 4;

/// How long the software reset may take, and an MDIO transfer, in reads
/// of the register that says it is over: a few milliseconds at 360 MHz.
const reset_spins = 1_000_000;
const mii_spins = 100_000;

/// The MAC and its DMA engine back to where they start. The reset only
/// ends when the receive and send clocks run, which on RMII come from
/// the reference clock: false if it did not end.
pub fn reset() bool {
    reg(dma_bus_mode).* = bus_swr;
    var spins: u32 = 0;
    while (reg(dma_bus_mode).* & bus_swr != 0) : (spins += 1) {
        if (spins == reset_spins) return false;
    }
    return true;
}

/// After `reset`: the MAC at 100 Mbit/s full duplex, neither receiving
/// nor sending, its own causes masked; the engine's bursts, its FIFOs'
/// modes, the send FIFO flushed. Received frames are not checked for IP
/// checksums: the network stack checks them itself.
pub fn setUp() void {
    reg(mac_interrupt_mask).* = 0xFFFF_FFFF;
    reg(mac_config).* = config_ps | config_fes | config_dm;
    reg(mac_frame_filter).* = 0;
    reg(dma_bus_mode).* = bus_mode;
    reg(dma_operation).* = op_osf | op_ftf;
    var spins: u32 = 0;
    while (reg(dma_operation).* & op_ftf != 0 and spins < reset_spins) spins += 1;
    reg(dma_interrupt_enable).* = 0;
    reg(dma_status).* = int_all;
}

/// The line's speed and duplex, as the PHY agreed them.
pub fn setLine(fast: bool, full_duplex: bool) void {
    var config = reg(mac_config).* & ~(config_fes | config_dm);
    if (fast) config |= config_fes;
    if (full_duplex) config |= config_dm;
    reg(mac_config).* = config;
}

/// The address the MAC takes frames for, and puts nowhere: the frames it
/// sends carry the source address they were built with.
pub fn setStation(address: *const [6]u8) void {
    reg(mac_address0_high).* = @as(u32, address[5]) << 8 | address[4];
    reg(mac_address0_low).* = @as(u32, address[3]) << 24 | @as(u32, address[2]) << 16 |
        @as(u32, address[1]) << 8 | address[0];
}

/// Every frame passed, or every multicast frame as well as the station's
/// and broadcasts, or only those.
pub fn setFilter(promiscuous: bool, multicast: bool) void {
    var filter: u32 = 0;
    if (promiscuous) filter |= filter_pr;
    if (multicast) filter |= filter_pm;
    reg(mac_frame_filter).* = filter;
}

/// Receiving and sending started on the two chains, from their first
/// descriptors, in the order the engine wants: its causes on, the
/// transmitter, the engine's two sides, the receiver.
pub fn start(receive_list: usize, send_list: usize) void {
    reg(dma_receive_list).* = @intCast(receive_list);
    reg(dma_send_list).* = @intCast(send_list);
    reg(dma_status).* = int_all;
    reg(dma_interrupt_enable).* = int_wanted;
    reg(mac_config).* |= config_te;
    reg(dma_operation).* |= op_st | op_sr;
    reg(mac_config).* |= config_re;
}

/// Receiving and sending stopped, and the engine's causes off. A frame
/// half out is cut short.
pub fn stop() void {
    reg(dma_operation).* &= ~op_st;
    reg(mac_config).* &= ~config_re;
    reg(dma_operation).* &= ~op_sr;
    reg(mac_config).* &= ~config_te;
    reg(dma_interrupt_enable).* = 0;
    reg(dma_status).* = int_all;
}

/// What the engine has raised, cleared.
pub fn takeInterrupts() u32 {
    const raised = reg(dma_status).* & int_all;
    reg(dma_status).* = raised;
    return raised;
}

/// The frames dropped since the last call: with no receive descriptor
/// free, and with the receive FIFO full. Reading the counts clears them.
pub fn takeMissed() u32 {
    const counts = reg(dma_missed).*;
    return (counts & 0xFFFF) + ((counts >> 17) & 0x7FF);
}

/// The receive chain looked at again: a descriptor was handed back.
pub fn pollReceive() void {
    reg(dma_receive_poll).* = 1;
}

/// The send chain looked at again: a frame was handed over.
pub fn pollSend() void {
    reg(dma_send_poll).* = 1;
}

/// PHY register `register` of the PHY at `phy`, or null if the bus did
/// not answer in time.
pub fn readPhy(phy: u32, register: u32) ?u16 {
    if (!miiIdle()) return null;
    reg(mac_mii_address).* = phy << mii_phy_shift | register << mii_reg_shift |
        mii_cr_div102 << mii_cr_shift | mii_busy;
    if (!miiIdle()) return null;
    return @truncate(reg(mac_mii_data).*);
}

/// `value` into PHY register `register` of the PHY at `phy`; false if the
/// bus did not answer in time.
pub fn writePhy(phy: u32, register: u32, value: u16) bool {
    if (!miiIdle()) return false;
    reg(mac_mii_data).* = value;
    reg(mac_mii_address).* = phy << mii_phy_shift | register << mii_reg_shift |
        mii_cr_div102 << mii_cr_shift | mii_write | mii_busy;
    return miiIdle();
}

fn miiIdle() bool {
    var spins: u32 = 0;
    while (reg(mac_mii_address).* & mii_busy != 0) : (spins += 1) {
        if (spins == mii_spins) return false;
    }
    return true;
}
