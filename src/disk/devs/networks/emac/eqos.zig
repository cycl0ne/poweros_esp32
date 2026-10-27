// SPDX-License-Identifier: MIT
//! The JH7110's Ethernet MACs, for emac.device: Synopsys's Ethernet QoS
//! 5.20, a 10/100/1000 MAC with a DMA engine of its own and a queue each
//! way between them (the MTL), its registers in one block - the MAC's at
//! 0, the queues' at 0xC00, the DMA's at 0x1000 - and the management bus
//! (MDC, MDIO) its PHY's registers are read and written over.
//!
//! **The descriptors** are two rings in memory, one to receive into and
//! one to send from, each descriptor four words: its buffer's address,
//! and its length and flags. A descriptor is the engine's while its OWN
//! bit is set; the engine clears it once the frame is in or out, writing
//! the frame's length and status over the descriptor, so a receive
//! descriptor is given its buffer again each time it is handed back. The
//! engine goes round a ring up to its tail pointer, which the driver
//! moves on as it hands descriptors over (`pollReceive`, `pollSend`):
//! the send ring's is past the last frame given it, the receive ring's at
//! the descriptor handed back last. Each descriptor is alone in a 64-byte
//! cache line (`Descriptor`) - the engine skips the six eight-byte bus
//! words after each - so each one is written back and invalidated whole
//! and a line never holds anything else to lose.
//!
//! **What the engine raises** is in DMA_CH0_Status, a bit per cause and
//! two summaries; each stays until it is written back. The MAC's own
//! causes and its counters' are masked. A received frame raises one only
//! if its descriptor asks (`giveBack`'s `interrupt`); for the others the
//! engine's watchdog raises it a little after they came (`rx_watchdog`),
//! so a burst of frames is one interrupt, and a frame alone waits only
//! that little.
//!
//! **Checksums**: the MAC's checksum engine checks every received IPv4
//! packet's header checksum and its TCP or UDP checksum, and an IPv6
//! packet's TCP or UDP checksum, and says what it found in the
//! descriptor. It could fill both in for a frame sent with
//! `fill`, but `offload` does not offer that: on the JH7110 some TCP
//! segments it filled in went out with a checksum the peer refused, the
//! same segment every time it was sent again, so a long write over IPv4
//! stalled for good. The stack fills them in itself.
//!
//! It keeps no state but where its registers are (`registers`). The
//! values follow U-Boot's dwc_eth_qos.c (eqos_start), which runs this
//! MAC on the VisionFive 2, but for the engine's bus and the receive
//! queue's mode, which follow Linux's device tree for the JH7110.

const sdk = @import("sdk");
const net = sdk.devices.network;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;

/// Where the MAC's registers are; the device sets it from its port.
pub var registers: usize = 0;

fn at(offset: usize) *volatile u32 {
    return reg(registers + offset);
}

// The MAC's registers.
const mac_configuration = 0x000;
const mac_packet_filter = 0x008;
const mac_q0_tx_flow = 0x070;
const mac_rx_flow = 0x090;
const mac_rxq_ctrl0 = 0x0A0;
const mac_interrupt_enable = 0x0B4;
const mac_hw_feature0 = 0x11C;
const mac_hw_feature1 = 0x120;
const mac_mdio_address = 0x200;
const mac_mdio_data = 0x204;
const mac_address0_high = 0x300;
const mac_address0_low = 0x304;
// The counters' interrupt masks.
const mmc_rx_interrupt_mask = 0x70C;
const mmc_tx_interrupt_mask = 0x710;
const mmc_ipc_rx_interrupt_mask = 0x800;
// The queues'.
const mtl_txq0_operation = 0xD00;
const mtl_txq0_debug = 0xD08;
const mtl_rxq0_operation = 0xD30;
const mtl_rxq0_missed = 0xD34;
const mtl_rxq0_debug = 0xD38;
// The DMA engine's, its channel 0's.
const dma_mode = 0x1000;
const dma_sysbus_mode = 0x1004;
const dma_control = 0x1100;
const dma_tx_control = 0x1104;
const dma_rx_control = 0x1108;
const dma_tx_list_high = 0x1110;
const dma_tx_list = 0x1114;
const dma_rx_list_high = 0x1118;
const dma_rx_list = 0x111C;
const dma_tx_tail = 0x1120;
const dma_rx_tail = 0x1128;
const dma_tx_ring_length = 0x112C;
const dma_rx_ring_length = 0x1130;
const dma_interrupt_enable = 0x1134;
const dma_rx_watchdog = 0x1138;
const dma_status = 0x1160;

/// MAC_Configuration: receiver and transmitter on, full duplex, the
/// speed (PS and FES: 1000 neither, 100 both, 10 PS alone), the
/// checksum stripped from every received frame, and the checksum engine
/// checking what comes in.
const config_re: u32 = 1 << 0;
const config_te: u32 = 1 << 1;
const config_dm: u32 = 1 << 13;
const config_fes: u32 = 1 << 14;
const config_ps: u32 = 1 << 15;
const config_acs: u32 = 1 << 20;
const config_cst: u32 = 1 << 21;
const config_ipc: u32 = 1 << 27;

/// MAC_HW_Feature0: the checksum engine for what comes in.
const feature_rx_coe: u32 = 1 << 16;

/// MAC_Packet_Filter: every frame, or every multicast frame, passed.
const filter_pr: u32 = 1 << 0;
const filter_pm: u32 = 1 << 4;

/// Flow control: pause frames sent, with the longest pause, and heeded.
const tx_flow_tfe: u32 = 1 << 1;
const tx_flow_pt_shift = 16;
const rx_flow_rfe: u32 = 1 << 0;

/// MAC_RxQ_Ctrl0: the receive queue on, for every frame. Off, as it
/// starts, the MAC takes nothing in.
const rxq0_enabled: u32 = 2;

/// MAC_MDIO_Address: busy, the operation (write 1, read 3), the clock
/// range, the register, the PHY. MDC is the MAC's bus clock divided by
/// 124 (range 5), as U-Boot sets it.
const mdio_gb: u32 = 1 << 0;
const mdio_goc_shift = 2;
const mdio_write: u32 = 1;
const mdio_read: u32 = 3;
const mdio_cr: u32 = 5 << 8;
const mdio_rda_shift = 16;
const mdio_pa_shift = 21;

/// MAC_Address0_High: the address on.
const address_ae: u32 = 1 << 31;

/// MTL_TxQ0_Operation_Mode: whole frames passed on, the queue on, its
/// size in 256-byte blocks less one. MTL_RxQ0_Operation_Mode: a frame
/// passed on to the engine as soon as its first 64 bytes are in (RSF
/// off, RTC 0), those with a wrong checksum kept rather than dropped, its
/// size. The JH7110's receive queue holds 2 KiB, not two whole frames:
/// with each frame held whole until the engine took it, the queue ran
/// over whenever the engine was a little late - about 40 frames in a
/// 200 MB read - though descriptors were free.
const txq_tsf: u32 = 1 << 1;
const txq_enabled: u32 = 2 << 2;
const txq_tqs_shift = 16;
const rxq_rtc_64: u32 = 0;
const rxq_dis_tcp_ef: u32 = 1 << 6;
const rxq_rqs_shift = 20;

/// DMA_Mode: the software reset.
const mode_swr: u32 = 1 << 0;

/// DMA_SysBus_Mode: bursts of 4 to 256 beats, addresses past 32 bits,
/// 16 reads and 16 writes outstanding - as Linux's device tree for the
/// JH7110 has them. With U-Boot's one write outstanding and bursts of 16
/// beats at most, the engine wrote a frame out slower than the next came
/// in while the memory was busy, and the 2 KiB receive queue ran over.
const sysbus_mode: u32 = 0x7F << 1 | 1 << 11 | 15 << 16 | 15 << 24;

/// DMA_CH0_Control: burst lengths in eights, and the bus words skipped
/// after each descriptor - 64-bit words, so a descriptor's 16 bytes and
/// six of them fill a cache line.
const control_pblx8: u32 = 1 << 16;
const control_dsl: u32 = 6 << 18;

/// DMA_CH0_Tx_Control and Rx_Control: started, the next frame fetched
/// while the last one's status is written back, bursts of 8 times 8, the
/// receive buffers' size.
const tx_st: u32 = 1 << 0;
const tx_osf: u32 = 1 << 4;
const rx_sr: u32 = 1 << 0;
const rx_rbsz_shift = 1;
const pbl: u32 = 8 << 16;

/// DMA_CH0_Status and DMA_CH0_Interrupt_Enable: a frame sent, a frame
/// received, no free receive descriptor, a bus error, and the two
/// summaries.
pub const int_send: u32 = 1 << 0;
pub const int_receive: u32 = 1 << 6;
pub const int_receive_unavailable: u32 = 1 << 7;
pub const int_bus_error: u32 = 1 << 12;
const int_abnormal: u32 = 1 << 14;
const int_normal: u32 = 1 << 15;
const int_wanted: u32 = int_send | int_receive | int_receive_unavailable |
    int_bus_error | int_abnormal | int_normal;
/// Every cause DMA_CH0_Status keeps until it is written back.
const int_all: u32 = 0x3F_FFFF;

/// DMA_CH0_Rx_Interrupt_Watchdog_Timer: how long after a frame whose
/// descriptor asked for no interrupt the engine raises one all the same,
/// in 256 cycles of its clock: about 17 us on the VisionFive 2, by what
/// it adds to ping's round trip.
const rx_watchdog: u32 = 0x10;

/// The MAC runs at 1000 Mbit/s.
pub const gigabit = true;

/// One descriptor, alone in its cache line.
pub const Descriptor = extern struct {
    words: [4]u32 = @splat(0),
    pad: [12]u32 = @splat(0),
};

/// The descriptors' last word: the engine has it, the first and last
/// buffer of a frame, an error. A send descriptor's third word asks for
/// an interrupt when it is sent; a receive descriptor's last asks for one
/// when it is filled, and says its buffer is valid.
const own: u32 = 1 << 31;
const send_fd: u32 = 1 << 29;
const send_ld: u32 = 1 << 28;
const send_ioc: u32 = 1 << 31;
const send_es: u32 = 1 << 15;
const length_mask: u32 = 0x7FFF;
const receive_ioc: u32 = 1 << 30;
const receive_buf1v: u32 = 1 << 24;
const receive_ctxt: u32 = 1 << 30;
const receive_fd: u32 = 1 << 29;
const receive_ld: u32 = 1 << 28;
const receive_es: u32 = 1 << 15;
/// A send descriptor's checksums filled in by the engine, the pseudo
/// header's sum too. A received one's last word: its second holds what
/// the checksum engine found - the payload's type (UDP, TCP), a wrong
/// IPv4 header checksum or a wrong IPv6 length, an IPv4 header, an IPv6
/// one, the engine passed by, a wrong TCP or UDP checksum.
const send_cic_full: u32 = 3 << 16;
const receive_rs1v: u32 = 1 << 26;
const checks_type_mask: u32 = 0x7;
const checks_udp: u32 = 1;
const checks_tcp: u32 = 2;
const checks_header_error: u32 = 1 << 3;
const checks_ipv4: u32 = 1 << 4;
const checks_ipv6: u32 = 1 << 5;
const checks_bypassed: u32 = 1 << 6;
const checks_payload_error: u32 = 1 << 7;

/// How long the software reset may take, and a stopping queue or an
/// MDIO transfer, in microseconds.
const reset_us = 50_000;
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

fn resetDone() bool {
    return at(dma_mode).* & mode_swr == 0;
}

/// The MAC, its queues and its DMA engine back to where they start. The
/// reset ends only once the clocks the PHY sends in run: false if it did
/// not end.
pub fn reset() bool {
    at(dma_mode).* = mode_swr;
    return waitFor(reset_us, &resetDone);
}

/// After `reset`: the queues on, as big as the MAC has them; the MAC
/// stripping checksums, heeding and sending pause frames, its own causes
/// and its counters' masked, neither receiving nor sending; the engine's
/// bursts, its descriptors' spacing and the receive buffers' size,
/// `receive_bytes`. Where the MAC has the checksum engine, it checks
/// what comes in, and a packet whose checksum is wrong is passed on all
/// the same, for the network stack to count.
pub fn setUp(receive_bytes: u32) void {
    const features = at(mac_hw_feature1).*;
    const rx_fifo = @as(u32, 128) << @intCast(features & 0x1F);
    const tx_fifo = @as(u32, 128) << @intCast((features >> 6) & 0x1F);
    const checking = offload() & net.S2OFFLOADF_RX_CHECKSUMS != 0;
    at(mtl_txq0_operation).* = txq_tsf | txq_enabled | (tx_fifo / 256 - 1) << txq_tqs_shift;
    at(mtl_rxq0_operation).* = rxq_rtc_64 | rxq_dis_tcp_ef | (rx_fifo / 256 - 1) << rxq_rqs_shift;
    at(mac_rxq_ctrl0).* = rxq0_enabled;
    at(mac_q0_tx_flow).* = 0xFFFF << tx_flow_pt_shift | tx_flow_tfe;
    at(mac_rx_flow).* = rx_flow_rfe;
    at(mac_interrupt_enable).* = 0;
    at(mmc_rx_interrupt_mask).* = 0xFFFF_FFFF;
    at(mmc_tx_interrupt_mask).* = 0xFFFF_FFFF;
    at(mmc_ipc_rx_interrupt_mask).* = 0xFFFF_FFFF;
    at(mac_configuration).* = config_cst | config_acs | config_dm | (if (checking) config_ipc else 0);
    at(mac_packet_filter).* = 0;
    at(dma_sysbus_mode).* = sysbus_mode;
    at(dma_control).* = control_pblx8 | control_dsl;
    at(dma_tx_control).* = pbl | tx_osf;
    at(dma_rx_control).* = pbl | receive_bytes << rx_rbsz_shift;
    at(dma_interrupt_enable).* = 0;
    at(dma_rx_watchdog).* = rx_watchdog;
    at(dma_status).* = int_all;
}

/// The checksums the MAC's engine does, as Sana2DeviceQuery's `offload`
/// says them: those of what comes in checked, IPv4's and IPv6's, where
/// the MAC has the engine for it. Never those of what is sent (see the top): of a 1 MiB
/// SMB WRITE over IPv4, about one full segment in four was refused by
/// the server, each again when sent again, and the same data with the
/// stack's checksums went through.
pub fn offload() u32 {
    const features = at(mac_hw_feature0).*;
    return if (features & feature_rx_coe != 0) net.S2OFFLOADF_RX_CHECKSUMS | net.S2OFFLOADF_RX_CHECKSUMS_IPV6 else 0;
}

/// The line's speed and duplex, as the PHY agreed them.
pub fn setLine(mbits: u32, full_duplex: bool) void {
    var config = at(mac_configuration).* & ~(config_ps | config_fes | config_dm);
    switch (mbits) {
        1000 => {},
        100 => config |= config_ps | config_fes,
        else => config |= config_ps,
    }
    if (full_duplex) config |= config_dm;
    at(mac_configuration).* = config;
}

/// The address the MAC takes frames for, and puts nowhere: the frames it
/// sends carry the source address they were built with.
pub fn setStation(address: *const [6]u8) void {
    at(mac_address0_high).* = address_ae | @as(u32, address[5]) << 8 | address[4];
    at(mac_address0_low).* = @as(u32, address[3]) << 24 | @as(u32, address[2]) << 16 |
        @as(u32, address[1]) << 8 | address[0];
}

/// Every frame passed, or every multicast frame as well as the station's
/// and broadcasts, or only those.
pub fn setFilter(promiscuous: bool, multicast: bool) void {
    var filter: u32 = 0;
    if (promiscuous) filter |= filter_pr;
    if (multicast) filter |= filter_pm;
    at(mac_packet_filter).* = filter;
}

// --- the descriptors ------------------------------------------------------

/// A receive descriptor set up with its buffer and handed to the engine.
/// The ring needs no `next`: the engine goes on to the descriptor after.
pub fn prepareReceive(descriptor: *Descriptor, buffer: []u8, next: *Descriptor, interrupt: bool) void {
    _ = next;
    giveBack(descriptor, buffer, interrupt);
}

/// A send descriptor set up empty, the driver's.
pub fn prepareSend(descriptor: *Descriptor, buffer: []u8, next: *Descriptor) void {
    _ = buffer;
    _ = next;
    descriptor.* = .{};
}

/// A filled receive descriptor handed back to the engine, its buffer
/// given it again, asking for an interrupt when it is filled if
/// `interrupt`; else the watchdog raises one.
pub fn giveBack(descriptor: *Descriptor, buffer: []u8, interrupt: bool) void {
    const address = @intFromPtr(buffer.ptr);
    descriptor.words = .{ low(address), high(address), 0, own | (if (interrupt) receive_ioc else 0) | receive_buf1v };
}

/// What a receive descriptor holds once the engine has given it back.
pub const Frame = struct {
    /// The frame's length, without its checksum.
    length: u32,
    /// Whether it came in whole and without an error.
    good: bool,
    /// Whether the checksum engine checked its TCP or UDP checksum, and an
    /// IPv4 packet's header checksum, and found them right.
    checked: bool,
};

/// The frame in a receive descriptor, or null while the engine has it.
pub fn received(descriptor: *const Descriptor, buffer_bytes: u32) ?Frame {
    const status = descriptor.words[3];
    if (status & own != 0) return null;
    const length = status & length_mask;
    const whole = receive_fd | receive_ld;
    const good = status & (receive_es | receive_ctxt) == 0 and status & whole == whole and
        length > 0 and length <= buffer_bytes;
    const checks = descriptor.words[1];
    const payload = checks & checks_type_mask;
    const checked = status & receive_rs1v != 0 and checks & (checks_ipv4 | checks_ipv6) != 0 and
        (payload == checks_udp or payload == checks_tcp) and
        checks & (checks_header_error | checks_bypassed | checks_payload_error) == 0;
    return .{ .length = length, .good = good, .checked = checked };
}

/// A send descriptor handed to the engine with the frame of `length`
/// bytes in `buffer`, its checksums filled in by the engine if `fill`:
/// its address and length first, OWN last.
pub fn queueSend(descriptor: *Descriptor, buffer: []u8, length: u32, fill: bool) void {
    const address = @intFromPtr(buffer.ptr);
    descriptor.words[0] = low(address);
    descriptor.words[1] = high(address);
    descriptor.words[2] = send_ioc | length;
    descriptor.words[3] = own | send_fd | send_ld | (if (fill) send_cic_full else 0) | length;
}

/// Whether a send descriptor's frame went out, or null while the engine
/// still has it.
pub fn sendFinished(descriptor: *const Descriptor) ?bool {
    const status = descriptor.words[3];
    if (status & own != 0) return null;
    return status & send_es == 0;
}

// --- running --------------------------------------------------------------

/// Receiving and sending started on the two rings, from their first
/// descriptors: every receive descriptor the engine's, no send
/// descriptor yet. Its causes on, the engine's two sides, then the MAC.
pub fn start(receive_ring: []Descriptor, send_ring: []Descriptor) void {
    const rx = @intFromPtr(receive_ring.ptr);
    const tx = @intFromPtr(send_ring.ptr);
    at(dma_tx_list_high).* = high(tx);
    at(dma_tx_list).* = low(tx);
    at(dma_rx_list_high).* = high(rx);
    at(dma_rx_list).* = low(rx);
    at(dma_tx_ring_length).* = @intCast(send_ring.len - 1);
    at(dma_rx_ring_length).* = @intCast(receive_ring.len - 1);
    at(dma_status).* = int_all;
    at(dma_interrupt_enable).* = int_wanted;
    at(dma_tx_control).* |= tx_st;
    at(dma_rx_control).* |= rx_sr;
    fence();
    at(dma_tx_tail).* = low(tx);
    at(dma_rx_tail).* = low(@intFromPtr(&receive_ring[receive_ring.len - 1]));
    at(mac_configuration).* |= config_te | config_re;
}

fn sendDrained() bool {
    const debug = at(mtl_txq0_debug).*;
    return (debug >> 1) & 0x3 != 1 and debug & (1 << 4) == 0;
}

fn receiveDrained() bool {
    const debug = at(mtl_rxq0_debug).*;
    return (debug >> 16) & 0x3FFF == 0 and (debug >> 4) & 0x3 == 0;
}

/// Receiving and sending stopped, and the engine's causes off: the
/// engine's send side, once the queue has let its frame go; the MAC; the
/// engine's receive side, once the queue has handed on what it held.
pub fn stop() void {
    at(dma_tx_control).* &= ~tx_st;
    _ = waitFor(drain_us, &sendDrained);
    at(mac_configuration).* &= ~(config_te | config_re);
    _ = waitFor(drain_us, &receiveDrained);
    at(dma_rx_control).* &= ~rx_sr;
    at(dma_interrupt_enable).* = 0;
    at(dma_status).* = int_all;
}

/// What the engine has raised, cleared.
pub fn takeInterrupts() u32 {
    const raised = at(dma_status).* & int_wanted;
    at(dma_status).* = raised;
    return raised;
}

/// The frames dropped since the last call: with no receive descriptor
/// free, and with the receive queue full. Reading the counts clears them.
pub fn takeMissed() u32 {
    const counts = at(mtl_rxq0_missed).*;
    return (counts & 0x7FF) + ((counts >> 16) & 0x7FF);
}

/// The receive ring looked at again, up to `last`, the descriptor handed
/// back last.
pub fn pollReceive(last: *const Descriptor) void {
    fence();
    at(dma_rx_tail).* = low(@intFromPtr(last));
}

/// The send ring looked at again, up to `next`, the descriptor after the
/// last frame handed over.
pub fn pollSend(next: *const Descriptor) void {
    fence();
    at(dma_tx_tail).* = low(@intFromPtr(next));
}

/// What was written for the engine reaches it before the register that
/// tells it to look.
fn fence() void {
    sdk.hardware.barrier.full();
}

// --- the management bus ---------------------------------------------------

/// PHY register `register` of the PHY at `phy`, or null if the bus did
/// not answer in time.
pub fn readPhy(phy: u32, register: u32) ?u16 {
    if (!mdioIdle()) return null;
    at(mac_mdio_address).* = phy << mdio_pa_shift | register << mdio_rda_shift |
        mdio_cr | mdio_read << mdio_goc_shift | mdio_gb;
    if (!mdioIdle()) return null;
    return @truncate(at(mac_mdio_data).*);
}

/// `value` into PHY register `register` of the PHY at `phy`; false if the
/// bus did not answer in time.
pub fn writePhy(phy: u32, register: u32, value: u16) bool {
    if (!mdioIdle()) return false;
    at(mac_mdio_data).* = value;
    at(mac_mdio_address).* = phy << mdio_pa_shift | register << mdio_rda_shift |
        mdio_cr | mdio_write << mdio_goc_shift | mdio_gb;
    return mdioIdle();
}

fn mdioDone() bool {
    return at(mac_mdio_address).* & mdio_gb == 0;
}

fn mdioIdle() bool {
    return waitFor(mdio_us, &mdioDone);
}
