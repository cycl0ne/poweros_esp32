// SPDX-License-Identifier: MIT
//! The BCM2711's Ethernet MAC, for emac.device: Broadcom's GENET, version
//! 5 - a 10/100/1000 MAC (UniMAC) with a DMA engine of its own, its
//! registers in one block, and the management bus (MDC, MDIO) its PHY's
//! registers are read and written over.
//!
//! **The descriptors are the engine's own**: 256 to receive into at
//! +0x2000 and 256 to send from at +0x4000, three words each - length and
//! flags, the buffer's address, the address's high half - in the GENET's
//! registers, not in memory. Of its seventeen rings only the default one,
//! 16, is used, over the first descriptors of each side; the engine goes
//! through a ring's descriptors in order from where its pointer is.
//!
//! **Who has a descriptor** is not in the descriptor but in two counts
//! each ring keeps, 16 bits wide, counting on past the ring's end. On the
//! receive side the engine counts the frames it put in (the producer
//! index) and the driver those it took (the consumer index); on the send
//! side the driver counts the frames it gave and the engine those it sent.
//! The receive producer index's top half counts the frames dropped for
//! want of a descriptor.
//!
//! **emac.device's descriptors** (`Descriptor`) are therefore shadows in
//! memory, a cache line each so that emac.device gives each back alone:
//! the buffer's address, and for a send the count it went out at. `start`
//! writes the engine's descriptors from them; `received` and
//! `sendFinished` read the counts. The counts cannot always be set to 0
//! (U-Boot found so), so `start` takes them, and where the engine's
//! pointers are, as it finds them.
//!
//! **What the engine raises** is in the GENET's first interrupt
//! controller (INTRL2_0), a bit per cause, each kept until cleared: the
//! default ring's frames received and sent, every one of them, and the
//! receive buffer running over.
//!
//! **The line**: RGMII to an external PHY. The GENET delays the clock of
//! what it sends (its "ID mode", ID_MODE_DIS clear), as the Compute Module
//! 4's wiring - the device tree's rgmii-rxid - wants: the PHY delays what
//! it receives. With the CRC not forwarded the MAC takes it off every
//! frame received; it adds it, and pads short frames, to every frame sent.
//!
//! **Filtering**: the MAC passes the frames for the addresses in its
//! destination filter (MDF), seventeen of them: broadcast, the station,
//! and up to fifteen multicast groups (`setGroups`); with more, or
//! promiscuous, every frame.
//!
//! No checksums are done here. The values follow Linux's bcmgenet driver
//! and U-Boot's.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;
const ethernet = sdk.devices.network.ethernet;
const Group = sdk.devices.network.unit.Group;

/// Where the GENET's registers are; the device sets it from its port.
pub var registers: usize = 0;

fn at(offset: usize) *volatile u32 {
    return reg(registers + offset);
}

// --- the registers --------------------------------------------------------

/// The system block: the version, the port's mode, the receive buffer's
/// flush control - whose bit 1 resets UniMAC.
const sys_rev_ctrl = 0x000;
const sys_port_ctrl = 0x004;
const sys_rbuf_flush_ctrl = 0x008;
const port_mode_ext_gphy: u32 = 3;
const flush_umac_reset: u32 = 1 << 1;
const version_shift = 24;
const version_mask: u32 = 0xF;

/// The two interrupt controllers: what is raised, cleared by writing it,
/// what is masked, and masking and unmasking.
const intrl2_0 = 0x200;
const intrl2_1 = 0x240;
const cpu_stat = 0x00;
const cpu_clear = 0x08;
const cpu_mask_status = 0x0C;
const cpu_mask_set = 0x10;
const cpu_mask_clear = 0x14;

/// The RGMII block: the link up, the out-of-band signals off, RGMII on,
/// the send clock's delay off.
const ext_rgmii_oob_ctrl = 0x08C;
const rgmii_link: u32 = 1 << 4;
const oob_disable: u32 = 1 << 5;
const rgmii_mode_en: u32 = 1 << 6;
const id_mode_dis: u32 = 1 << 16;

/// The receive and send buffers: a 64-byte status block before each frame,
/// two bytes before a received one, the checksum engine, the buffers'
/// size, the frames lost to a full receive buffer.
const rbuf_ctrl = 0x300;
const rbuf_64b: u32 = 1 << 0;
const rbuf_align_2b: u32 = 1 << 1;
const rbuf_chk_ctrl = 0x314;
const rbuf_rxchk_en: u32 = 1 << 0;
const rbuf_overflows = 0x394;
const rbuf_tbuf_size_ctrl = 0x3B4;
const tbuf_ctrl = 0x600;
const tbuf_64b: u32 = 1 << 0;

/// UniMAC: its command, the station address, the longest frame, the send
/// FIFO's flush, the counters' reset, the management bus, the destination
/// filter.
const umac_cmd = 0x808;
const umac_mac0 = 0x80C;
const umac_mac1 = 0x810;
const umac_max_frame_len = 0x814;
const umac_tx_flush = 0xB34;
const umac_mib_ctrl = 0xD80;
const mdio_cmd = 0xE14;
const umac_mdf_ctrl = 0xE50;
const umac_mdf_addr = 0xE54;

/// UMAC_CMD: sending and receiving on, the speed, every frame passed, the
/// CRC passed on, received pause frames ignored, half duplex, the reset,
/// looped back, pause frames never sent.
const cmd_tx_en: u32 = 1 << 0;
const cmd_rx_en: u32 = 1 << 1;
const cmd_speed_shift = 2;
const cmd_speed_mask: u32 = 3 << cmd_speed_shift;
const cmd_speed_100: u32 = 1;
const cmd_speed_1000: u32 = 2;
const cmd_promisc: u32 = 1 << 4;
const cmd_crc_fwd: u32 = 1 << 6;
const cmd_rx_pause_ignore: u32 = 1 << 8;
const cmd_hd_en: u32 = 1 << 10;
const cmd_sw_reset: u32 = 1 << 13;
const cmd_lcl_loop_en: u32 = 1 << 15;
const cmd_tx_pause_ignore: u32 = 1 << 28;

/// UMAC_MIB_CTRL: the receive, runt and send counters reset.
const mib_reset_all: u32 = 7;

/// The longest frame: 1500 bytes, the header, a VLAN tag, the CRC and
/// room, as Linux has it - an emac.device buffer.
const max_frame: u32 = 1536;

/// MDIO_CMD: start (and busy until done), the read failed, read, write,
/// the PHY, the register, the data.
const mdio_start_busy: u32 = 1 << 29;
const mdio_read_fail: u32 = 1 << 28;
const mdio_read: u32 = 2 << 26;
const mdio_write: u32 = 1 << 26;
const mdio_phy_shift = 21;
const mdio_register_shift = 16;

/// The destination filter's entries, two words each; entry `i` is on with
/// bit 16 - i of UMAC_MDF_CTRL.
const mdf_entries = 17;

// --- the DMA engine -------------------------------------------------------

/// The descriptors: where each side's are, how many, how big, and their
/// words.
const rx_descriptors = 0x2000;
const tx_descriptors = 0x4000;
const descriptors = 256;
const descriptor_bytes = 12;
const descriptor_words = descriptor_bytes / 4;
const length_status = 0x0;
const address_low = 0x4;
const address_high = 0x8;

/// The default ring, whose registers are past the descriptors and the
/// other sixteen rings', 0x40 each; the engine's own past them.
const ring = 16;
const ring_bytes = 0x40;
const rx_ring = rx_descriptors + descriptors * descriptor_bytes + ring * ring_bytes;
const tx_ring = tx_descriptors + descriptors * descriptor_bytes + ring * ring_bytes;
const rx_dma = rx_ring + ring_bytes;
const tx_dma = tx_ring + ring_bytes;

/// A ring's registers, in 32-bit words of the descriptors where they are
/// places: the engine's pointer (receive: where it writes; send: where it
/// reads), the engine's count, the driver's count, the ring's size and
/// its buffers', its start and end, how many frames make an interrupt,
/// flow control, the driver's pointer.
const ring_engine_ptr = 0x00;
const ring_engine_ptr_hi = 0x04;
const ring_engine_index = 0x08;
const ring_driver_index = 0x0C;
const ring_buf_size = 0x10;
const ring_start = 0x14;
const ring_start_hi = 0x18;
const ring_end = 0x1C;
const ring_end_hi = 0x20;
const ring_done_thresh = 0x24;
const ring_flow = 0x28;
const ring_driver_ptr = 0x2C;
const ring_driver_ptr_hi = 0x30;
const ring_size_shift = 16;

/// The receive ring's pause frames: asked for with 16 descriptors left,
/// stopped with 5, as Linux has it.
const xon_xoff: u32 = 5 << 16 | descriptors >> 4;

/// The engine's registers: which rings are rings, the engine and its
/// rings on, its state, its bursts on the bus.
const dma_ring_cfg = 0x00;
const dma_ctrl = 0x04;
const dma_status = 0x08;
const dma_scb_burst = 0x0C;
const dma_en: u32 = 1 << 0;
const dma_ring_en: u32 = 1 << (1 + ring);
const dma_disabled: u32 = 1 << 0;
const dma_burst: u32 = 8;

/// A descriptor's first word: the length in the top half; owned (as the
/// engine sets it), the frame's last and first buffer; to send, the CRC
/// added and every queue tag; received, what went wrong - overrun, CRC,
/// a receive error, no buffer, too long.
const length_shift = 16;
const length_mask: u32 = 0xFFF;
const own: u32 = 0x8000;
const eop: u32 = 0x4000;
const sop: u32 = 0x2000;
const tx_append_crc: u32 = 0x0040;
const tx_qtag: u32 = 0x3F << 7;
const rx_errors: u32 = 0x1F;

/// INTRL2_0: the receive buffer ran over, the default ring's frames
/// received and sent.
const irq_rbuf_overflow: u32 = 1 << 9;
const irq_rxdma_done: u32 = 1 << 13;
const irq_txdma_done: u32 = 1 << 16;
pub const int_receive: u32 = irq_rxdma_done;
pub const int_receive_unavailable: u32 = irq_rbuf_overflow;
pub const int_send: u32 = irq_txdma_done;
/// The GENET raises nothing for a bus error.
pub const int_bus_error: u32 = 0;
const int_wanted: u32 = int_receive | int_receive_unavailable | int_send;
const int_all: u32 = 0xFFFF_FFFF;

/// How long the engine may take to stop, and an MDIO transfer, in
/// microseconds.
const dma_stop_us = 5_000;
const mdio_us = 10_000;

/// The MAC runs at 1000 Mbit/s.
pub const gigabit = true;

/// One descriptor's shadow, a cache line: see the top.
pub const Descriptor = extern struct {
    /// Its buffer's address.
    buffer: u64 = 0,
    /// A send's: the count it was given at.
    count: u32 = 0,
    unused: [52]u8 = @splat(0),
};

// --- the state ------------------------------------------------------------

/// The size of a receive buffer.
var buffer_bytes: u32 = max_frame;
/// The shadow rings and their lengths, as `start` was given them.
var receive_ring: usize = 0;
var receive_count: u32 = 1;
var send_ring: usize = 0;
var send_count: u32 = 1;
/// The engine's descriptor for each ring's first shadow.
var receive_first: u32 = 0;
var send_first: u32 = 0;
/// The receive count up to which frames were taken, and the shadow the
/// next frame is in.
var taken: u16 = 0;
var next_slot: u32 = 0;
/// The send count up to which frames were given.
var given: u16 = 0;
/// The frames dropped as last counted: for want of a descriptor, and
/// for a full receive buffer.
var discards: u16 = 0;
var overflows: u32 = 0;
/// The station, the groups the filter passes, and whether it passes
/// every frame.
var station: ethernet.Address = @splat(0);
var groups: [mdf_entries - 2]ethernet.Address = undefined;
var group_count: u32 = 0;
var every_frame: bool = false;

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

fn spin(us: u64) void {
    const until = systimer.uptimeUs() + us;
    while (systimer.uptimeUs() <= until) {}
}

/// What was written for the engine reaches it before the register that
/// tells it to look.
fn fence() void {
    sdk.hardware.barrier.full();
}

// --- setting up -----------------------------------------------------------

/// UniMAC reset and stopped, the engine stopped, the causes off and
/// cleared, the counters at zero. False if no GENET of version 4 or 5
/// answers.
pub fn reset() bool {
    const version = (at(sys_rev_ctrl).* >> version_shift) & version_mask;
    if (version < 5 or version > 7) return false;
    const flush = at(sys_rbuf_flush_ctrl);
    flush.* |= flush_umac_reset;
    spin(10);
    flush.* &= ~flush_umac_reset;
    spin(10);
    flush.* = 0;
    spin(10);
    at(umac_cmd).* = 0;
    at(umac_cmd).* = cmd_sw_reset | cmd_lcl_loop_en;
    spin(2);
    at(umac_cmd).* = 0;
    at(umac_mib_ctrl).* = mib_reset_all;
    at(umac_mib_ctrl).* = 0;
    stopEngine(tx_dma);
    stopEngine(rx_dma);
    for ([_]usize{ intrl2_0, intrl2_1 }) |controller| {
        at(controller + cpu_mask_set).* = int_all;
        at(controller + cpu_clear).* = int_all;
    }
    return true;
}

/// After `reset`: the port an external gigabit PHY's on RGMII, the GENET
/// delaying the send clock (see the top); frames with no status block
/// before them, sent or received, and no checksums; the receive buffers'
/// size, `receive_bytes`.
pub fn setUp(receive_bytes: u32) void {
    buffer_bytes = receive_bytes;
    at(sys_port_ctrl).* = port_mode_ext_gphy;
    const oob = at(ext_rgmii_oob_ctrl);
    oob.* = (oob.* & ~(oob_disable | id_mode_dis)) | rgmii_mode_en;
    at(umac_max_frame_len).* = max_frame;
    at(rbuf_ctrl).* &= ~(rbuf_64b | rbuf_align_2b);
    at(tbuf_ctrl).* &= ~tbuf_64b;
    at(rbuf_chk_ctrl).* &= ~rbuf_rxchk_en;
    at(rbuf_tbuf_size_ctrl).* = 1;
    at(umac_mdf_ctrl).* = 0;
}

/// The line's speed and duplex, as the PHY agreed them, and the RGMII
/// block told the link is up. Received pause frames are heeded on a
/// full-duplex line; none are sent.
pub fn setLine(mbits: u32, full_duplex: bool) void {
    var cmd = at(umac_cmd).* & ~(cmd_speed_mask | cmd_hd_en | cmd_rx_pause_ignore | cmd_crc_fwd);
    const speed: u32 = switch (mbits) {
        1000 => cmd_speed_1000,
        100 => cmd_speed_100,
        else => 0,
    };
    cmd |= speed << cmd_speed_shift | cmd_tx_pause_ignore;
    if (!full_duplex) cmd |= cmd_hd_en | cmd_rx_pause_ignore;
    at(umac_cmd).* = cmd;
    at(ext_rgmii_oob_ctrl).* |= rgmii_link;
}

/// The station: what UniMAC puts in pause frames, and the filter's second
/// entry.
pub fn setStation(address: *const [6]u8) void {
    station = address.*;
    at(umac_mac0).* = @as(u32, address[0]) << 24 | @as(u32, address[1]) << 16 |
        @as(u32, address[2]) << 8 | address[3];
    at(umac_mac1).* = @as(u32, address[4]) << 8 | address[5];
    writeFilter();
}

/// Every frame passed, or those for broadcast, the station and the groups
/// someone here joined - every frame too when there are more of those
/// than the filter has entries.
pub fn setGroups(joined: []const Group, promiscuous: bool) void {
    group_count = 0;
    every_frame = promiscuous;
    for (joined) |group| {
        if (group.users == 0) continue;
        if (group_count == groups.len) {
            every_frame = true;
            break;
        }
        groups[group_count] = group.address;
        group_count += 1;
    }
    writeFilter();
}

fn writeFilter() void {
    if (every_frame) {
        at(umac_cmd).* |= cmd_promisc;
        at(umac_mdf_ctrl).* = 0;
        return;
    }
    var entry: u32 = 0;
    filterEntry(&entry, &ethernet.broadcast);
    filterEntry(&entry, &station);
    for (groups[0..group_count]) |*address| filterEntry(&entry, address);
    at(umac_mdf_ctrl).* = ((@as(u32, 1) << @intCast(entry)) - 1) << @intCast(mdf_entries - entry);
    at(umac_cmd).* &= ~cmd_promisc;
}

fn filterEntry(entry: *u32, address: *const ethernet.Address) void {
    const words = umac_mdf_addr + entry.* * 8;
    at(words).* = @as(u32, address[0]) << 8 | address[1];
    at(words + 4).* = @as(u32, address[2]) << 24 | @as(u32, address[3]) << 16 |
        @as(u32, address[4]) << 8 | address[5];
    entry.* += 1;
}

// --- the descriptors ------------------------------------------------------

/// A receive descriptor's shadow set up with its buffer.
pub fn prepareReceive(descriptor: *Descriptor, buffer: []u8, next: *Descriptor, interrupt: bool) void {
    _ = next;
    _ = interrupt;
    descriptor.* = .{ .buffer = @intFromPtr(buffer.ptr) };
}

/// A send descriptor's shadow set up with its buffer.
pub fn prepareSend(descriptor: *Descriptor, buffer: []u8, next: *Descriptor) void {
    _ = next;
    descriptor.* = .{ .buffer = @intFromPtr(buffer.ptr) };
}

/// Which shadow `descriptor` is in its ring.
fn slotOf(ring_address: usize, descriptor: *const Descriptor) u32 {
    return @intCast((@intFromPtr(descriptor) - ring_address) / @sizeOf(Descriptor));
}

/// The engine's descriptor for shadow `slot`.
fn engineDescriptor(side: usize, slot: u32, first: u32, count: u32) usize {
    return side + ((slot + first) % count) * descriptor_bytes;
}

/// A taken receive descriptor handed back to the engine, its buffer given
/// it again; the count goes to the engine at `pollReceive`. Each frame
/// makes its interrupt, whatever `interrupt` asks.
pub fn giveBack(descriptor: *Descriptor, buffer: []u8, interrupt: bool) void {
    _ = interrupt;
    const slot = slotOf(receive_ring, descriptor);
    const engine = engineDescriptor(rx_descriptors, slot, receive_first, receive_count);
    const address = @intFromPtr(buffer.ptr);
    at(engine + address_low).* = low(address);
    at(engine + address_high).* = high(address);
    taken +%= 1;
    next_slot = (next_slot + 1) % receive_count;
}

/// What a receive descriptor holds once the engine has filled it.
pub const Frame = struct {
    /// The frame's length, without its CRC.
    length: u32,
    /// Whether it came in whole, in the one buffer, with nothing wrong.
    good: bool,
    /// Never: the checksums are not checked here.
    checked: bool = false,
};

/// The frame in a receive descriptor, or null while the engine has not
/// filled it.
pub fn received(descriptor: *const Descriptor, bytes: u32) ?Frame {
    const slot = slotOf(receive_ring, descriptor);
    const filled: u16 = @as(u16, @truncate(at(rx_ring + ring_engine_index).*)) -% taken;
    const ahead = (slot + receive_count - next_slot) % receive_count;
    if (ahead >= filled) return null;
    const engine = engineDescriptor(rx_descriptors, slot, receive_first, receive_count);
    const status = at(engine + length_status).*;
    const length = (status >> length_shift) & length_mask;
    const whole = sop | eop;
    return .{
        .length = length,
        .good = status & whole == whole and status & rx_errors == 0 and length > 0 and length <= bytes,
    };
}

/// A send descriptor handed to the engine with the frame of `length` bytes
/// in `buffer`; the engine hears of it at `pollSend`. The checksums are
/// the stack's, so `fill` never asks.
pub fn queueSend(descriptor: *Descriptor, buffer: []u8, length: u32, fill: bool) void {
    _ = fill;
    const slot = slotOf(send_ring, descriptor);
    const engine = engineDescriptor(tx_descriptors, slot, send_first, send_count);
    const address = @intFromPtr(buffer.ptr);
    at(engine + address_low).* = low(address);
    at(engine + address_high).* = high(address);
    at(engine + length_status).* = (length & length_mask) << length_shift | tx_qtag | tx_append_crc | sop | eop;
    descriptor.count = given;
    given +%= 1;
}

/// Whether a send descriptor's frame went out, or null while the engine
/// has not sent it: the engine's count is past the one it was given at.
pub fn sendFinished(descriptor: *const Descriptor) ?bool {
    const sent: u16 = @truncate(at(tx_ring + ring_engine_index).*);
    const past = sent -% @as(u16, @truncate(descriptor.count));
    if (past == 0 or past > 0x8000) return null;
    return true;
}

// --- running --------------------------------------------------------------

/// A ring of `count` descriptors from the first, its buffers
/// `buffer_bytes` each, its counts and pointers at the start - as far as
/// the engine takes them.
fn setUpRing(ring_registers: usize, count: u32) void {
    at(ring_registers + ring_engine_index).* = 0;
    at(ring_registers + ring_driver_index).* = 0;
    at(ring_registers + ring_buf_size).* = count << ring_size_shift | buffer_bytes;
    at(ring_registers + ring_start).* = 0;
    at(ring_registers + ring_start_hi).* = 0;
    at(ring_registers + ring_engine_ptr).* = 0;
    at(ring_registers + ring_engine_ptr_hi).* = 0;
    at(ring_registers + ring_driver_ptr).* = 0;
    at(ring_registers + ring_driver_ptr_hi).* = 0;
    at(ring_registers + ring_end).* = count * descriptor_words - 1;
    at(ring_registers + ring_end_hi).* = 0;
    at(ring_registers + ring_done_thresh).* = 1;
}

/// Where the engine's pointer is in a ring of `count`, in descriptors.
fn enginePlace(ring_registers: usize, count: u32) u32 {
    return (at(ring_registers + ring_engine_ptr).* / descriptor_words) % count;
}

/// Receiving and sending started on the two rings: every receive
/// descriptor the engine's, with its buffer, no send descriptor yet. The
/// rings, the counts as the engine has them, the causes, the engine, then
/// UniMAC.
pub fn start(receive: []Descriptor, send: []Descriptor) void {
    receive_ring = @intFromPtr(receive.ptr);
    receive_count = @intCast(@min(receive.len, descriptors));
    send_ring = @intFromPtr(send.ptr);
    send_count = @intCast(@min(send.len, descriptors));

    at(rx_dma + dma_scb_burst).* = dma_burst;
    setUpRing(rx_ring, receive_count);
    at(rx_ring + ring_flow).* = xon_xoff;
    const produced = at(rx_ring + ring_engine_index).*;
    taken = @truncate(produced);
    discards = @truncate(produced >> 16);
    overflows = at(rbuf_overflows).*;
    at(rx_ring + ring_driver_index).* = taken;
    receive_first = enginePlace(rx_ring, receive_count);
    next_slot = 0;
    for (receive[0..receive_count], 0..) |*shadow, slot| {
        const engine = engineDescriptor(rx_descriptors, @intCast(slot), receive_first, receive_count);
        at(engine + address_low).* = low(shadow.buffer);
        at(engine + address_high).* = high(shadow.buffer);
        at(engine + length_status).* = buffer_bytes << length_shift | own;
    }
    at(rx_dma + dma_ring_cfg).* = 1 << ring;

    at(tx_dma + dma_scb_burst).* = dma_burst;
    setUpRing(tx_ring, send_count);
    at(tx_ring + ring_flow).* = 0;
    given = @truncate(at(tx_ring + ring_engine_index).*);
    at(tx_ring + ring_driver_index).* = given;
    send_first = enginePlace(tx_ring, send_count);
    at(tx_dma + dma_ring_cfg).* = 1 << ring;

    at(intrl2_0 + cpu_clear).* = int_all;
    at(intrl2_0 + cpu_mask_clear).* = int_wanted;
    fence();
    at(tx_dma + dma_ctrl).* = dma_ring_en | dma_en;
    at(rx_dma + dma_ctrl).* = dma_ring_en | dma_en;
    at(umac_cmd).* |= cmd_tx_en | cmd_rx_en;
}

var stopping: usize = 0;

fn engineStopped() bool {
    return at(stopping + dma_status).* & dma_disabled != 0;
}

/// One side of the engine stopped, once its frame is done.
fn stopEngine(engine: usize) void {
    at(engine + dma_ctrl).* &= ~(dma_ring_en | dma_en);
    stopping = engine;
    _ = waitFor(dma_stop_us, &engineStopped);
}

/// Receiving and sending stopped and the engine's causes off: UniMAC's
/// receiver, the engine's sending and its receiving, UniMAC's sender, and
/// what was left in the send FIFO thrown away.
pub fn stop() void {
    at(umac_cmd).* &= ~cmd_rx_en;
    stopEngine(tx_dma);
    stopEngine(rx_dma);
    at(umac_cmd).* &= ~cmd_tx_en;
    at(umac_tx_flush).* = 1;
    spin(10);
    at(umac_tx_flush).* = 0;
    at(intrl2_0 + cpu_mask_set).* = int_all;
    at(intrl2_0 + cpu_clear).* = int_all;
}

/// What the engine has raised, cleared.
pub fn takeInterrupts() u32 {
    const raised = at(intrl2_0 + cpu_stat).* & ~at(intrl2_0 + cpu_mask_status).* & int_wanted;
    if (raised != 0) at(intrl2_0 + cpu_clear).* = raised;
    return raised;
}

/// The frames dropped since the last call: with no receive descriptor
/// free, and with the receive buffer full. Both counts run on; the
/// difference is taken.
pub fn takeMissed() u32 {
    const now_discards: u16 = @truncate(at(rx_ring + ring_engine_index).* >> 16);
    const now_overflows = at(rbuf_overflows).*;
    const missed = @as(u32, now_discards -% discards) + (now_overflows -% overflows);
    discards = now_discards;
    overflows = now_overflows;
    return missed;
}

/// The descriptors taken given back to the engine: the receive count.
pub fn pollReceive(last: *const Descriptor) void {
    _ = last;
    fence();
    at(rx_ring + ring_driver_index).* = taken;
}

/// The frames queued given to the engine: the send count.
pub fn pollSend(next: *const Descriptor) void {
    _ = next;
    fence();
    at(tx_ring + ring_driver_index).* = given;
}

// --- the management bus ---------------------------------------------------

/// PHY register `register` of the PHY at `phy`, or null if the bus did not
/// answer in time or the PHY not at all.
pub fn readPhy(phy: u32, register: u32) ?u16 {
    if (!mdioIdle()) return null;
    at(mdio_cmd).* = mdio_read | (phy & 0x1F) << mdio_phy_shift | (register & 0x1F) << mdio_register_shift;
    at(mdio_cmd).* |= mdio_start_busy;
    if (!mdioIdle()) return null;
    const value = at(mdio_cmd).*;
    if (value & mdio_read_fail != 0) return null;
    return @truncate(value);
}

/// `value` into PHY register `register` of the PHY at `phy`; false if the
/// bus did not answer in time.
pub fn writePhy(phy: u32, register: u32, value: u16) bool {
    if (!mdioIdle()) return false;
    at(mdio_cmd).* = mdio_write | (phy & 0x1F) << mdio_phy_shift | (register & 0x1F) << mdio_register_shift | value;
    at(mdio_cmd).* |= mdio_start_busy;
    return mdioIdle();
}

fn mdioDone() bool {
    return at(mdio_cmd).* & mdio_start_busy == 0;
}

fn mdioIdle() bool {
    return waitFor(mdio_us, &mdioDone);
}
