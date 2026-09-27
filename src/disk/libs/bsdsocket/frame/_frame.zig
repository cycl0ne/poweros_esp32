// SPDX-License-Identifier: MIT
//! Frames: a packet in one contiguous buffer, from the link's header to
//! the end of its data, with room in front for every header a packet
//! going out still has to be given. A frame moves through the layers by
//! pointer: going in, each layer takes its header off the front
//! (`pull`); going out, each puts its own on (`push`). What is valid is
//! `buffer[start .. start + length]`, so every header a layer reads is a
//! slice of that and a length that points past the packet is caught
//! where it is read.
//!
//! **The pool.** Frames come from a free list and go back to it. The list
//! grows a frame at a time, from memory of any kind - the external memory
//! first, where there is plenty - up to `frames_max`, and gives nothing
//! back until the library goes, so a busy moment costs no allocation the
//! next time. Every frame is taken and given back under the stack's lock.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const Address = @import("../ip6/address.zig").Address;
const Interface = @import("../netif/_netif.zig").Interface;

/// Room in front for the headers of a packet going out: the link's (14 on
/// Ethernet), IPv6's (40; IPv4's is 20) and the transport's (8 for UDP,
/// 20 for TCP, 24 with the MSS option), rounded up.
pub const headroom = 96;
/// A frame's buffer: the headroom and the largest packet a link takes,
/// 1500 bytes of IP and a 14-byte header, with its checksum.
pub const buffer_bytes = headroom + 1536;
/// The most frames there are at once: about 400 KiB, made only as a
/// busy moment needs them.
pub const frames_max = 256;

pub const Frame = extern struct {
    /// On the free list, a socket's receive queue, or an interface's
    /// queue: one at a time.
    node: exec.Node = .{},
    /// Where the valid bytes start in `buffer`, and how many there are.
    start: u32 = headroom,
    length: u32 = 0,
    /// Who sent the datagram, once the transport has taken its header off:
    /// IPv6's sixteen bytes, an IPv4 sender mapped.
    from_address: Address = .{},
    from_port: u16 = 0,
    pad0: u16 = 0,
    /// The interface it came in on, which a link-local sender's address
    /// needs.
    from_interface: ?*Interface = null,
    /// Held out of order by a connection: where its data starts in the
    /// sequence space (`tcp/reorder.zig`).
    sequence: u32 = 0,
    /// Going out on a network device: the type of what it carries, and
    /// the station it goes to, kept while it waits for the device.
    link_type: u16 = 0,
    link_address: [6]u8 = @splat(0),
    /// A large frame, allocated to its size for one datagram and freed
    /// when it is given back, rather than kept in the pool.
    large: u8 = 0,
    pad: u8 = 0,
    /// The bytes `buffer` holds: `buffer_bytes`, more for a large frame.
    capacity: u32 = buffer_bytes,
    buffer: [buffer_bytes]u8 = undefined,

    /// The memory the frame holds while it waits in a queue: its buffer
    /// and its record. A socket's receive limit is counted in this, so a
    /// queue of small datagrams is charged for the frames they fill.
    pub fn cost(frame: *const Frame) u32 {
        return @intCast(@offsetOf(Frame, "buffer") + @as(usize, frame.capacity));
    }

    /// The whole buffer, as far as it goes.
    pub fn room(frame: *Frame) []u8 {
        const whole: [*]u8 = @ptrCast(&frame.buffer);
        return whole[0..frame.capacity];
    }

    /// The valid bytes.
    pub fn bytes(frame: *Frame) []u8 {
        return frame.room()[frame.start..][0..frame.length];
    }

    /// Room for `count` more bytes in front, which are now part of the
    /// frame: where a header going out is written.
    pub fn push(frame: *Frame, count: u32) []u8 {
        frame.start -= count;
        frame.length += count;
        return frame.room()[frame.start..][0..count];
    }

    /// The first `count` valid bytes taken off: a header read going in.
    pub fn pull(frame: *Frame, count: u32) void {
        frame.start += count;
        frame.length -= count;
    }

    /// Only the first `count` valid bytes kept: padding a link added
    /// behind a packet shorter than its minimum.
    pub fn trim(frame: *Frame, count: u32) void {
        if (count < frame.length) frame.length = count;
    }

    fn fromNode(node: *exec.Node) *Frame {
        return @fieldParentPtr("node", node);
    }
};

/// The free frames, and how many there are in all.
pub const Pool = extern struct {
    free: exec.List = .{},
    made: u32 = 0,
    /// Large frames given out and not back yet.
    large_out: u32 = 0,

    pub fn init(pool: *Pool) void {
        pool.* = .{};
        pool.free.init(.unknown);
    }

    /// An empty frame with the full headroom in front, or null when there
    /// are `frames_max` already and none is free, or no memory for one.
    pub fn take(pool: *Pool, sys: *ExecBase) ?*Frame {
        const frame = if (sys.RemHead(&pool.free)) |node| Frame.fromNode(node) else blk: {
            if (pool.made >= frames_max) return null;
            const memory = sys.AllocMem(@sizeOf(Frame), exec.MEMF_ANY) orelse return null;
            pool.made += 1;
            break :blk @as(*Frame, @ptrCast(@alignCast(memory)));
        };
        frame.node = .{};
        frame.start = headroom;
        frame.length = 0;
        frame.from_address = .{};
        frame.from_port = 0;
        frame.from_interface = null;
        frame.sequence = 0;
        frame.link_type = 0;
        frame.large = 0;
        frame.capacity = buffer_bytes;
        return frame;
    }

    /// An empty large frame that holds `capacity` bytes, the headroom
    /// included; null when there is no memory for it.
    pub fn takeLarge(pool: *Pool, sys: *ExecBase, capacity: u32) ?*Frame {
        const memory = sys.AllocMem(largeBytes(capacity), exec.MEMF_ANY) orelse return null;
        const frame: *Frame = @ptrCast(@alignCast(memory));
        frame.node = .{};
        frame.start = headroom;
        frame.length = 0;
        frame.from_address = .{};
        frame.from_port = 0;
        frame.from_interface = null;
        frame.sequence = 0;
        frame.link_type = 0;
        frame.large = 1;
        frame.capacity = @max(capacity, buffer_bytes);
        pool.large_out += 1;
        return frame;
    }

    fn largeBytes(capacity: u32) usize {
        return @offsetOf(Frame, "buffer") + @as(usize, @max(capacity, buffer_bytes));
    }

    pub fn give(pool: *Pool, sys: *ExecBase, frame: *Frame) void {
        if (frame.large != 0) {
            pool.large_out -= 1;
            sys.FreeMem(frame, largeBytes(frame.capacity));
            return;
        }
        sys.AddHead(&pool.free, &frame.node);
    }

    /// How many frames are out of the pool now.
    pub fn used(pool: *Pool) u32 {
        var free: u32 = 0;
        var it = pool.free.iterator();
        while (it.next()) |_| free += 1;
        return pool.made - free + pool.large_out;
    }

    /// Every frame freed, when the library goes; all of them are back.
    pub fn deinit(pool: *Pool, sys: *ExecBase) void {
        while (sys.RemHead(&pool.free)) |node| {
            sys.FreeMem(Frame.fromNode(node), @sizeOf(Frame));
            pool.made -= 1;
        }
    }
};
