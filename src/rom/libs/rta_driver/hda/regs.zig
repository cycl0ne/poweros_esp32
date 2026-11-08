// SPDX-License-Identifier: MPL-2.0
//! The high definition audio controller's register block, by the names
//! the specification gives them, and the reads and writes that reach it.
//!
//! **One block, three parts.** The first 0x80 bytes are the controller
//! itself: what it can do, its reset, its interrupts, and the two rings
//! by which verbs are sent to a codec and answers come back. From 0x80
//! on there is a descriptor per stream, 0x20 bytes each, the inputs
//! first and the outputs after them, and how many of each there are is
//! read from `gcap`. Past those sit the vendor's own registers, which
//! nothing here touches.
//!
//! **The width of an access is part of the register.** A controller
//! answers a 32-bit read of a 16-bit register with whatever it likes, so
//! each register here is reached at the width the specification gives it
//! and the functions are named for that width.

/// What the controller can do: how many streams of each kind it has, and
/// whether it does 64-bit addresses. 16 bits.
pub const gcap: usize = 0x00;
/// Output streams, input streams, bidirectional streams, serial data
/// out lines, and the 64-bit bit.
pub const gcap_oss: u16 = 0xf000;
pub const gcap_iss: u16 = 0x0f00;
pub const gcap_bss: u16 = 0x00f8;
pub const gcap_64ok: u16 = 0x0001;

/// The specification it answers to. 8 bits each.
pub const vmin: usize = 0x02;
pub const vmaj: usize = 0x03;

/// Global control. 32 bits.
pub const gctl: usize = 0x08;
/// Out of reset while this is set; the controller is reset by clearing
/// it and waiting for it to read back clear.
pub const gctl_crst: u32 = 1 << 0;
/// Accept a codec's unsolicited answers.
pub const gctl_unsol: u32 = 1 << 8;

/// Which codecs may wake the machine. 16 bits.
pub const wakeen: usize = 0x0c;
/// Which codecs answered after a reset: a bit per serial data in line.
/// Write the bits back to clear them. 16 bits.
pub const statests: usize = 0x0e;

/// Interrupt control: the global gate, the controller's own causes, and
/// a bit per stream. 32 bits.
pub const intctl: usize = 0x20;
pub const intctl_gie: u32 = 1 << 31;
pub const intctl_cie: u32 = 1 << 30;
/// What is raised, in the same order. 32 bits.
pub const intsts: usize = 0x24;
pub const intsts_gis: u32 = 1 << 31;
pub const intsts_cis: u32 = 1 << 30;

/// The wall clock, which counts at the link's rate. 32 bits.
pub const walclk: usize = 0x30;

/// The ring verbs are written into: where it is, how far the driver has
/// written and how far the controller has read, its running bit and how
/// large it is.
pub const corblbase: usize = 0x40;
pub const corbubase: usize = 0x44;
pub const corbwp: usize = 0x48;
pub const corbrp: usize = 0x4a;
pub const corbctl: usize = 0x4c;
pub const corbsts: usize = 0x4d;
pub const corbsize: usize = 0x4e;
/// The read pointer is reset by setting this and waiting for it to read
/// back set, then clearing it and waiting for that.
pub const corbrp_rst: u16 = 1 << 15;
/// The controller fetches from the ring while this is set.
pub const corbctl_run: u8 = 1 << 1;
/// It reports a memory error through the other.
pub const corbctl_meie: u8 = 1 << 0;

/// The ring answers come back in, the same way round.
pub const rirblbase: usize = 0x50;
pub const rirbubase: usize = 0x54;
pub const rirbwp: usize = 0x58;
pub const rintcnt: usize = 0x5a;
pub const rirbctl: usize = 0x5c;
pub const rirbsts: usize = 0x5d;
pub const rirbsize: usize = 0x5e;
/// The write pointer is reset by writing this; it is write-only.
pub const rirbwp_rst: u16 = 1 << 15;
/// The controller writes answers into the ring while this is set, and
/// raises its interrupt every `rintcnt` answers with the other.
pub const rirbctl_dmaen: u8 = 1 << 1;
pub const rirbctl_rintctl: u8 = 1 << 0;
/// An answer arrived; an answer overran the ring. Written back to clear.
pub const rirbsts_rintfl: u8 = 1 << 0;
pub const rirbsts_oirs: u8 = 1 << 2;

/// How large a ring is: the low two bits say which of the three sizes it
/// is set to, and the high four say which of them the controller has.
pub const size_mask: u8 = 0x03;
pub const size_2: u8 = 0;
pub const size_16: u8 = 1;
pub const size_256: u8 = 2;
pub const size_cap_2: u8 = 1 << 4;
pub const size_cap_16: u8 = 1 << 5;
pub const size_cap_256: u8 = 1 << 6;

/// The immediate command interface: a verb written here, its answer
/// read from the next, and the third saying whether one is in flight and
/// whether an answer has arrived. One verb at a time, answered before
/// the write returns - which is what setting a codec up wants.
pub const ic: usize = 0x60;
pub const ir: usize = 0x64;
pub const irs: usize = 0x68;
/// A command is in flight: set by the driver to send one, cleared by the
/// controller when it has gone out.
pub const irs_busy: u16 = 1 << 0;
/// An answer is in `ir`. Written back to clear.
pub const irs_valid: u16 = 1 << 1;

/// Where the controller writes each stream's position. 32 bits each.
pub const dplbase: usize = 0x70;
pub const dpubase: usize = 0x74;
/// The lowest bits of the low half are not an address: the buffer is
/// 128-byte aligned and this bit turns the writing on.
pub const dplbase_enable: u32 = 1 << 0;

/// The first stream descriptor, and the distance between two.
pub const stream_base: usize = 0x80;
pub const stream_stride: usize = 0x20;

/// Within a stream descriptor.
pub const sdctl: usize = 0x00;
pub const sdsts: usize = 0x03;
pub const sdlpib: usize = 0x04;
pub const sdcbl: usize = 0x08;
pub const sdlvi: usize = 0x0c;
pub const sdfifod: usize = 0x10;
pub const sdfmt: usize = 0x12;
pub const sdbdplbase: usize = 0x18;
pub const sdbdpubase: usize = 0x1c;
/// The stream's reset, its run bit, and the three interrupts it may
/// raise. The first three bytes of `sdctl` are one 24-bit register, so
/// the low byte holds these.
pub const sdctl_srst: u8 = 1 << 0;
pub const sdctl_run: u8 = 1 << 1;
pub const sdctl_ioce: u8 = 1 << 2;
pub const sdctl_feie: u8 = 1 << 3;
pub const sdctl_deie: u8 = 1 << 4;
/// Which stream number the descriptor carries, in the high byte of the
/// 24-bit register: the tag a codec's converter is told to listen for.
pub const sdctl_stream_shift: u5 = 20;
/// A buffer finished, and the two kinds of trouble. Written back to
/// clear.
pub const sdsts_bcis: u8 = 1 << 2;
pub const sdsts_fifoe: u8 = 1 << 3;
pub const sdsts_dese: u8 = 1 << 4;
pub const sdsts_fifordy: u8 = 1 << 5;

pub fn read8(at: usize, offset: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(at + offset)).*;
}

pub fn write8(at: usize, offset: usize, value: u8) void {
    @as(*volatile u8, @ptrFromInt(at + offset)).* = value;
}

pub fn read16(at: usize, offset: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(at + offset)).*;
}

pub fn write16(at: usize, offset: usize, value: u16) void {
    @as(*volatile u16, @ptrFromInt(at + offset)).* = value;
}

pub fn read32(at: usize, offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(at + offset)).*;
}

pub fn write32(at: usize, offset: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(at + offset)).* = value;
}

/// A stream descriptor's own address, which the registers above are
/// reached from.
pub fn streamAt(at: usize, which: u32) usize {
    return at + stream_base + stream_stride * which;
}
