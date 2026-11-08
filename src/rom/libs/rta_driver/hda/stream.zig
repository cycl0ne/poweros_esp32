// SPDX-License-Identifier: MPL-2.0
//! An output stream of the controller: the ring of buffers it reads, the
//! descriptor that reads them, and the shape of the samples in them.
//!
//! **A stream is a descriptor and a list.** The descriptor is a block of
//! the controller's registers; the list is memory the controller reads,
//! an entry per buffer saying where that buffer is and how long it is.
//! The descriptor is told where the list is, how long the whole ring is
//! and which entry is the last, and from then on it walks the entries
//! round for ever: at the end of the last it starts again at the first.
//! So a ring of buffers needs nothing done to it to go round, and what a
//! driver has to do is fill each buffer before the controller comes back
//! to it.
//!
//! **Each entry ends its own transfer**, which is what the interrupt is
//! for: the controller raises it at the end of every buffer, so the task
//! playing through the sink is woken once a buffer and fills the one just
//! played. Nothing counts positions and nothing reads the controller's
//! position registers - the interrupts are the count.
//!
//! **A stream has two numbers.** Which descriptor of the controller it
//! is, which is also its bit in the interrupt registers, and the tag it
//! carries on the link, which is what a codec's converter is told to
//! listen for. They are not the same number and neither follows from the
//! other: the descriptors of the inputs come before those of the outputs,
//! while the tags are the driver's to hand out.

const regs = @import("regs.zig");
const controller = @import("controller.zig");
const Controller = controller.Controller;

/// One entry of a buffer descriptor list: where a buffer is, how long it
/// is, and whether the controller raises its interrupt at the end of it.
pub const Entry = extern struct {
    address: u64 align(4) = 0,
    length: u32 = 0,
    flags: u32 = 0,
};

/// Entry.flags: the interrupt at the end of this buffer.
pub const entry_interrupt: u32 = 1 << 0;

/// What the buffer descriptor list and each buffer in it start on. The
/// specification asks for 128 bytes, which is also a cache line of every
/// machine this runs on, so a buffer's write-back never reaches another.
pub const alignment: usize = 128;

/// How long a register of the descriptor is waited on, in microseconds.
/// A reset is the specification's few hundred nanoseconds; this is far
/// past it.
const wait_limit: u32 = 10_000;

/// An output stream being played.
pub const Stream = struct {
    hw: *Controller,
    /// Which stream descriptor it is, counted over all of them - the
    /// inputs come first - which is also its bit in the controller's
    /// interrupt registers.
    descriptor: u32 = 0,
    /// The number the stream carries on the link, 1 to 15: what a
    /// converter is told to take its samples from.
    tag: u4 = 0,
    /// The ring: where the first buffer is, how many there are and how
    /// long each one is.
    buffers: usize = 0,
    count: u32 = 0,
    bytes: u32 = 0,
    /// The buffer descriptor list, one entry a buffer.
    list: [*]Entry = undefined,

    /// The descriptor's own registers.
    pub fn at(s: *const Stream) usize {
        return regs.streamAt(s.hw.at, s.descriptor);
    }

    /// Which bit of the controller's interrupt registers is this
    /// stream's.
    fn gate(s: *const Stream) u32 {
        return @as(u32, 1) << @intCast(s.descriptor);
    }
};

/// The shape of a frame of `channels` samples of `bits` at `rate` frames
/// a second, as the descriptor and the converter both take it. Null for
/// a shape the register cannot say.
///
/// Every rate the register can say is one of two bases - 48000 and 44100
/// - multiplied by up to four and divided by up to eight, so the rate is
/// a table rather than a calculation.
pub fn format(rate: u32, bits: u32, channels: u32) ?u16 {
    if (channels == 0 or channels > 16) return null;
    const size: u16 = switch (bits) {
        8 => 0,
        16 => 1,
        20 => 2,
        24 => 3,
        32 => 4,
        else => return null,
    };
    const timing: u16 = switch (rate) {
        8_000 => div_6,
        11_025 => base_44 | div_4,
        16_000 => div_3,
        22_050 => base_44 | div_2,
        24_000 => div_2,
        32_000 => mult_2 | div_3,
        44_100 => base_44,
        48_000 => 0,
        88_200 => base_44 | mult_2,
        96_000 => mult_2,
        176_400 => base_44 | mult_4,
        192_000 => mult_4,
        else => return null,
    };
    return timing | (size << 4) | @as(u16, @intCast(channels - 1));
}

/// The format register's own fields: which base the rate is counted
/// from, what it is multiplied by, and what it is divided by.
const base_44: u16 = 1 << 14;
const mult_2: u16 = 1 << 11;
const mult_4: u16 = 3 << 11;
const div_2: u16 = 1 << 8;
const div_3: u16 = 2 << 8;
const div_4: u16 = 3 << 8;
const div_6: u16 = 4 << 8;

/// The ring written into the list the controller reads: an entry per
/// buffer, each the end of its own transfer so that the interrupt comes
/// as each one is played.
pub fn describe(s: *Stream) void {
    var which: u32 = 0;
    while (which < s.count) : (which += 1) {
        s.list[which] = .{
            .address = s.buffers + s.bytes * which,
            .length = s.bytes,
            .flags = entry_interrupt,
        };
    }
    s.hw.toDevice(@intFromPtr(s.list), @sizeOf(Entry) * s.count);
}

/// The descriptor taken through its own reset, which is what clears the
/// shape and the list a previous stream left in it. False where it does
/// not come out of reset.
pub fn reset(s: *Stream) bool {
    const at = s.at();
    // The low byte of the three-byte control register holds the reset and
    // the run bit, so it is reached a byte at a time: a wider write would
    // reach the status byte above it, whose bits are cleared by writing
    // them back.
    regs.write8(at, regs.sdctl, 0);
    if (!settles(s, regs.sdctl_run, false)) return false;
    regs.write8(at, regs.sdctl, regs.sdctl_srst);
    if (!settles(s, regs.sdctl_srst, true)) return false;
    regs.write8(at, regs.sdctl, 0);
    return settles(s, regs.sdctl_srst, false);
}

/// A bit of the control register waited on until it reads back as
/// wanted. False where it never does.
fn settles(s: *Stream, bit: u8, set: bool) bool {
    const at = s.at();
    var waited: u32 = 0;
    while ((regs.read8(at, regs.sdctl) & bit != 0) != set) {
        if (waited >= wait_limit) return false;
        waited += controller.pause(s.hw, 10);
    }
    return true;
}

/// The stream started on the ring: the descriptor reset, pointed at the
/// list, told how long the whole ring is and what shape its samples are,
/// and set going with an interrupt at the end of each buffer. False
/// where the descriptor does not reset, or where the ring is somewhere
/// the controller cannot reach.
pub fn up(s: *Stream, shape: u16) bool {
    const at = s.at();
    const list = @intFromPtr(s.list);
    if (!s.hw.wide and (@as(u64, s.buffers) >> 32 != 0 or @as(u64, list) >> 32 != 0)) return false;
    if (!reset(s)) return false;
    // The tag sits in the high nibble of the control register's third
    // byte, which is why it is written on its own.
    regs.write8(at, regs.sdctl + 2, @as(u8, s.tag) << 4);
    regs.write32(at, regs.sdcbl, s.bytes * s.count);
    regs.write16(at, regs.sdlvi, @intCast(s.count - 1));
    regs.write16(at, regs.sdfmt, shape);
    regs.write32(at, regs.sdbdplbase, @truncate(list));
    regs.write32(at, regs.sdbdpubase, @truncate(@as(u64, list) >> 32));
    // Anything left standing cleared, so that the first interrupt is this
    // stream's first buffer and not what was there before it.
    regs.write8(at, regs.sdsts, regs.sdsts_bcis | regs.sdsts_fifoe | regs.sdsts_dese);
    const gate = regs.read32(s.hw.at, regs.intctl);
    regs.write32(s.hw.at, regs.intctl, gate | regs.intctl_gie | s.gate());
    regs.write8(at, regs.sdctl, regs.sdctl_run | regs.sdctl_ioce);
    return true;
}

/// The stream stopped: the run bit off, its interrupt out of the
/// controller's gate, what it raised cleared, and the list let go of so
/// that the controller reads nothing of memory that is about to be
/// freed.
pub fn down(s: *Stream) void {
    const at = s.at();
    regs.write8(at, regs.sdctl, 0);
    _ = settles(s, regs.sdctl_run, false);
    const gate = regs.read32(s.hw.at, regs.intctl);
    regs.write32(s.hw.at, regs.intctl, gate & ~s.gate());
    regs.write8(at, regs.sdsts, regs.sdsts_bcis | regs.sdsts_fifoe | regs.sdsts_dese);
    regs.write32(at, regs.sdbdplbase, 0);
    regs.write32(at, regs.sdbdpubase, 0);
}

/// What a stream raised, as an interrupt sees it.
pub const Raised = struct {
    /// A buffer was played to its end.
    played: bool = false,
    /// The controller could not keep the stream fed, or could not read
    /// its list.
    trouble: bool = false,

    /// Whether this stream raised the interrupt at all, which is what a
    /// server on a shared line answers with.
    pub fn any(r: Raised) bool {
        return r.played or r.trouble;
    }
};

/// What the stream raised, answered by clearing it. Called from an
/// interrupt: nothing here waits and nothing allocates.
pub fn served(s: *Stream) Raised {
    const at = s.at();
    const status = regs.read8(at, regs.sdsts);
    const raised = status & (regs.sdsts_bcis | regs.sdsts_fifoe | regs.sdsts_dese);
    if (raised == 0) return .{};
    regs.write8(at, regs.sdsts, raised);
    return .{
        .played = raised & regs.sdsts_bcis != 0,
        .trouble = raised & (regs.sdsts_fifoe | regs.sdsts_dese) != 0,
    };
}

comptime {
    if (@sizeOf(Entry) != 16) @compileError("a buffer descriptor list's entry is sixteen bytes");
}

const std = @import("std");

test "the shape of a frame" {
    // 48000 Hz is the base rate itself: no multiple, no divisor.
    try std.testing.expectEqual(@as(?u16, 0x0011), format(48_000, 16, 2));
    try std.testing.expectEqual(@as(?u16, 0x4011), format(44_100, 16, 2));
    try std.testing.expectEqual(@as(?u16, 0x0010), format(48_000, 16, 1));
    // Twice the base, twenty-four bits: the multiple and the size.
    try std.testing.expectEqual(@as(?u16, 0x0831), format(96_000, 24, 2));
    // A sixth of it.
    try std.testing.expectEqual(@as(?u16, 0x0411), format(8_000, 16, 2));
}

test "a shape the register cannot say" {
    try std.testing.expectEqual(@as(?u16, null), format(37_000, 16, 2));
    try std.testing.expectEqual(@as(?u16, null), format(48_000, 12, 2));
    try std.testing.expectEqual(@as(?u16, null), format(48_000, 16, 0));
    try std.testing.expectEqual(@as(?u16, null), format(48_000, 16, 17));
}
