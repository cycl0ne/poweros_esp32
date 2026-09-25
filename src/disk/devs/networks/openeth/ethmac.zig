// SPDX-License-Identifier: MIT
//! The OpenCores Ethernet MAC, for openeth.device: registers at the
//! part's address, and 128 buffer descriptors 0x400 past them.
//!
//! A descriptor is two words, its length and flags and the address of its
//! buffer, which the MAC reads and writes by itself. The first TX_BD_NUM
//! descriptors are for sending, the rest for receiving, and each ring
//! ends at the descriptor marked WRAP. A frame to send is handed over by
//! writing its descriptor with RD set; the MAC clears RD once the frame is
//! out. A receive descriptor is handed over with E set; the MAC fills its
//! buffer, writes the length, which counts the four checksum bytes at the
//! end, and clears E. Each of these raises its bit in INT_SOURCE if the
//! descriptor has IRQ set, and so does a frame that found no descriptor
//! free (BUSY); a bit stays until it is written back.
//!
//! Turning receiving or sending on starts that ring from its first
//! descriptor, so a ring is set up afresh every time the MAC is started.
//!
//! It keeps no state: every call is register writes at `base`, the
//! address the board's part gives.

const reg = @import("sdk").hardware.mmio.reg;

const moder = 0x00;
const int_source = 0x04;
const int_mask = 0x08;
const packetlen = 0x18;
const tx_bd_num = 0x20;
const mac_addr0 = 0x40;
const mac_addr1 = 0x44;
const hash0 = 0x48;
const hash1 = 0x4C;
const descriptors = 0x400;

/// MODER: pad short frames to the minimum, append the checksum, the rest
/// as asked.
const moder_rst: u32 = 0x800;
const moder_pad: u32 = 0x8000;
const moder_crcen: u32 = 0x2000;
const moder_pro: u32 = 0x20;
const moder_txen: u32 = 0x2;
const moder_rxen: u32 = 0x1;

/// INT_SOURCE and INT_MASK.
pub const int_busy: u32 = 0x10;
pub const int_rxb: u32 = 0x4;
pub const int_txb: u32 = 0x1;

/// A send descriptor's length and flags.
pub const txd_len_shift = 16;
pub const txd_rd: u32 = 0x8000;
pub const txd_irq: u32 = 0x4000;
pub const txd_wrap: u32 = 0x2000;
pub const txd_pad: u32 = 0x1000;
pub const txd_crc: u32 = 0x800;

/// A receive descriptor's length and flags.
pub const rxd_len_shift = 16;
pub const rxd_e: u32 = 0x8000;
pub const rxd_irq: u32 = 0x4000;
pub const rxd_wrap: u32 = 0x2000;
/// The frame was too long, or came with a bad checksum or a bad length.
pub const rxd_faults: u32 = 0x40 | 0x8 | 0x4 | 0x2 | 0x1;

/// The descriptors there are, for both rings together.
pub const descriptor_count = 128;
/// The checksum at the end of a received frame.
pub const checksum_bytes = 4;

/// The link's speed, as the MAC's PHY reports it.
pub const bps: u64 = 100_000_000;

/// PACKETLEN after a reset: the shortest and longest frame, 64 and 1536
/// bytes. Nothing here changes it, so reading it back finds the MAC.
const packetlen_reset: u32 = 0x0040_0600;

/// Whether a MAC answers at `base`.
pub fn present(base: usize) bool {
    return reg(base + packetlen).* == packetlen_reset;
}

/// Everything back to where the MAC starts: off, no interrupts, the
/// address it came with.
pub fn reset(base: usize) void {
    reg(base + moder).* = moder_rst;
    reg(base + moder).* = moder_pad | moder_crcen;
    reg(base + int_mask).* = 0;
    reg(base + int_source).* = 0xFFFF_FFFF;
}

/// The address the MAC came with.
pub fn stationAddress(base: usize) [6]u8 {
    const low = reg(base + mac_addr0).*;
    const high = reg(base + mac_addr1).*;
    return .{
        @truncate(high >> 8), @truncate(high),
        @truncate(low >> 24), @truncate(low >> 16),
        @truncate(low >> 8),  @truncate(low),
    };
}

/// The address the MAC takes frames for.
pub fn setStation(base: usize, address: *const [6]u8) void {
    reg(base + mac_addr1).* = @as(u32, address[0]) << 8 | address[1];
    reg(base + mac_addr0).* = @as(u32, address[2]) << 24 | @as(u32, address[3]) << 16 |
        @as(u32, address[4]) << 8 | address[5];
}

/// Which of the 64 hash bits a group address falls on: the top six bits
/// of its CRC-32, taken most significant bit first.
pub fn groupHash(address: *const [6]u8) u6 {
    var crc: u32 = 0xFFFF_FFFF;
    for (address) |octet| {
        var bits = octet;
        for (0..8) |_| {
            const carry: u32 = (crc >> 31) ^ (bits & 1);
            crc <<= 1;
            bits >>= 1;
            if (carry != 0) crc = (crc ^ 0x04C1_1DB6) | carry;
        }
    }
    return @truncate(crc >> 26);
}

/// The groups the MAC takes frames for, as the 64 bits of `groupHash`.
pub fn setGroups(base: usize, hash: u64) void {
    reg(base + hash0).* = @truncate(hash);
    reg(base + hash1).* = @truncate(hash >> 32);
}

/// How many descriptors are for sending; the rest are for receiving.
pub fn setSendCount(base: usize, count: u32) void {
    reg(base + tx_bd_num).* = count;
}

/// Receiving and sending on or off, and every frame taken or only the
/// ones for this station and its groups.
pub fn setMode(base: usize, running: bool, promiscuous: bool) void {
    var mode = moder_pad | moder_crcen;
    if (running) mode |= moder_rxen | moder_txen;
    if (promiscuous) mode |= moder_pro;
    reg(base + moder).* = mode;
}

pub fn setInterrupts(base: usize, mask: u32) void {
    reg(base + int_mask).* = mask;
}

/// What the MAC has raised, cleared.
pub fn takeInterrupts(base: usize) u32 {
    const raised = reg(base + int_source).*;
    reg(base + int_source).* = raised;
    return raised;
}

/// Descriptor `index` handed to the MAC: its buffer first, since writing
/// the flags of a send descriptor may start the frame at once.
pub fn setDescriptor(base: usize, index: u32, flags: u32, buffer: usize) void {
    const at = base + descriptors + index * 8;
    reg(at + 4).* = @intCast(buffer);
    reg(at).* = flags;
}

pub fn descriptorFlags(base: usize, index: u32) u32 {
    return reg(base + descriptors + index * 8).*;
}
