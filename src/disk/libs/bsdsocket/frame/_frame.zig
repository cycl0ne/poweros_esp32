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

/// Room in front for the headers of a packet going out: the link's (14 on
/// Ethernet), IPv4's (20) and the transport's (8 for UDP, 20 for TCP),
/// rounded up.
pub const headroom = 64;
/// A frame's buffer: the headroom and the largest packet a link takes,
/// 1500 bytes of IP and a 14-byte header, with its checksum.
pub const buffer_bytes = headroom + 1536;
/// The most frames there are at once: about 200 KiB.
pub const frames_max = 128;

pub const Frame = extern struct {
    /// On the free list, a socket's receive queue, or an interface's
    /// queue: one at a time.
    node: exec.Node = .{},
    /// Where the valid bytes start in `buffer`, and how many there are.
    start: u32 = headroom,
    length: u32 = 0,
    /// Who sent the datagram, in the chip's order, once the transport has
    /// taken its header off.
    from_address: u32 = 0,
    from_port: u16 = 0,
    /// Going out on a network device: the type of what it carries, and
    /// the station it goes to, kept while it waits for the device.
    link_type: u16 = 0,
    link_address: [6]u8 = @splat(0),
    pad: [2]u8 = .{ 0, 0 },
    buffer: [buffer_bytes]u8 = undefined,

    /// The valid bytes.
    pub fn bytes(frame: *Frame) []u8 {
        return frame.buffer[frame.start..][0..frame.length];
    }

    /// Room for `count` more bytes in front, which are now part of the
    /// frame: where a header going out is written.
    pub fn push(frame: *Frame, count: u32) []u8 {
        frame.start -= count;
        frame.length += count;
        return frame.buffer[frame.start..][0..count];
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
        frame.from_address = 0;
        frame.from_port = 0;
        frame.link_type = 0;
        return frame;
    }

    pub fn give(pool: *Pool, sys: *ExecBase, frame: *Frame) void {
        sys.AddHead(&pool.free, &frame.node);
    }

    /// How many frames are out of the pool now.
    pub fn used(pool: *Pool) u32 {
        var free: u32 = 0;
        var it = pool.free.iterator();
        while (it.next()) |_| free += 1;
        return pool.made - free;
    }

    /// Every frame freed, when the library goes; all of them are back.
    pub fn deinit(pool: *Pool, sys: *ExecBase) void {
        while (sys.RemHead(&pool.free)) |node| {
            sys.FreeMem(Frame.fromNode(node), @sizeOf(Frame));
            pool.made -= 1;
        }
    }
};
