// SPDX-License-Identifier: MPL-2.0
//! The queue's memory as the firmware reads it: the kernel's block of
//! 2 MiB (PART_SharedMemory), mapped without caches, of which the queue
//! takes the first 284 KiB.
//!
//!   0x00000  slot 0: the slot zero - the layout, and the two sides'
//!            shared states (the firmware's, "master", the ARM's,
//!            "slave")
//!   0x01000  slot 1: the firmware's sync slot, 2-32 its slots
//!   0x21000  slot 33: the ARM's sync slot, 34-64 its slots
//!   0x41000  64 fragments of 128 bytes: the ends of a bulk the firmware
//!            writes that are not whole cache lines
//!   0x43000  64 pagelists of 256 bytes: the memory of a bulk, described
//!
//! A message is a header - its id (type, the sender's port, the
//! receiver's) and its size - and its bytes, 8-byte aligned in its slot;
//! a message does not cross into the next slot, the rest of one is a
//! padding message. Each side writes its own slots, in the order its
//! shared state's `slot_queue` names them, and says how far it got in
//! `tx_pos`, counted in bytes from the start; the other reads up to it
//! and gives a slot back when it has read it to its end, by naming it in
//! the writer's `slot_queue` at `slot_queue_recycle`.
//!
//! Either side tells the other with an event in the other's shared
//! state: it sets `fired`, and rings the other's doorbell when `armed` -
//! the ARM's four stay armed, so every one rings.
//!
//! The layout and the numbers are the Raspberry Pi's VCHIQ, version 8,
//! as Linux's driver lays it out (drivers/staging/vc04_services; its
//! numbers, the code here is written fresh).

const std = @import("std");

pub const slot_size: u32 = 4096;
pub const slot_mask: u32 = slot_size - 1;

/// Slot zero, then 32 slots a side: each side's sync slot first.
pub const slot_count: u32 = 65;
pub const master_sync: u32 = 1;
pub const master_first: u32 = 2;
pub const master_last: u32 = 32;
pub const slave_sync: u32 = 33;
pub const slave_first: u32 = 34;
pub const slave_last: u32 = 64;
pub const slave_slots: u32 = slave_last - slave_first + 1;

pub const fragments_at: usize = slot_count * slot_size;
pub const fragment_bytes: usize = 128;
pub const fragment_count: u32 = 64;
/// A fragment's two halves: the bytes before the first whole cache line,
/// and those after the last.
pub const fragment_tail: usize = 64;
pub const line: usize = 64;

pub const pagelists_at: usize = fragments_at + fragment_bytes * fragment_count;
pub const pagelist_bytes: usize = 256;
pub const pagelist_count: u32 = 64;
/// How many runs of pages one pagelist holds, at most 256 pages a run.
pub const pagelist_runs: usize = (pagelist_bytes - 8) / 4;
/// The most one bulk moves: its runs, less a page for the start not on a
/// page.
pub const max_bulk: u32 = @intCast(pagelist_runs * 256 * 4096 - 4096);

/// What the queue takes of the kept memory.
pub const bytes_needed: usize = pagelists_at + pagelist_bytes * pagelist_count;

pub const magic: u32 = 0x5643_4849; // 'VCHI'
pub const version: u16 = 8;
pub const version_min: u16 = 3;
pub const max_slots: u32 = 128;
pub const max_slots_per_side: u32 = 64;
pub const debug_entries: u32 = 11;

/// The types of message.
pub const MSG_PADDING: u32 = 0;
pub const MSG_CONNECT: u32 = 1;
pub const MSG_OPEN: u32 = 2;
pub const MSG_OPENACK: u32 = 3;
pub const MSG_CLOSE: u32 = 4;
pub const MSG_DATA: u32 = 5;
pub const MSG_BULK_RX: u32 = 6;
pub const MSG_BULK_TX: u32 = 7;
pub const MSG_BULK_RX_DONE: u32 = 8;
pub const MSG_BULK_TX_DONE: u32 = 9;
pub const MSG_PAUSE: u32 = 10;
pub const MSG_RESUME: u32 = 11;
pub const MSG_REMOTE_USE: u32 = 12;
pub const MSG_REMOTE_RELEASE: u32 = 13;
pub const MSG_REMOTE_USE_ACTIVE: u32 = 14;

/// A message's id: its type, the sender's port and the receiver's.
pub fn msgid(kind: u32, src: u32, dst: u32) u32 {
    return kind << 24 | (src & 0xFFF) << 12 | (dst & 0xFFF);
}
pub fn kindOf(id: u32) u32 {
    return id >> 24;
}
pub fn srcOf(id: u32) u32 {
    return (id >> 12) & 0xFFF;
}
pub fn dstOf(id: u32) u32 {
    return id & 0xFFF;
}

/// The bytes a message of `size` takes in its slot: its header and
/// bytes, to 8.
pub fn stride(size: u32) u32 {
    return (size + 8 + 7) & ~@as(u32, 7);
}

/// The most bytes one message holds: a slot less its header.
pub const max_message: u32 = slot_size - 8;

pub const Header = extern struct {
    msgid: u32,
    size: u32,
};

/// An event: `armed` by the side that waits for it, `fired` by the side
/// that tells it.
pub const RemoteEvent = extern struct {
    armed: u32,
    fired: u32,
    unused: u32,
};

/// One side's shared state.
pub const SharedState = extern struct {
    initialised: u32,
    slot_first: u32,
    slot_last: u32,
    slot_sync: u32,
    /// "Messages for you", told by the other side.
    trigger: RemoteEvent,
    tx_pos: u32,
    /// "Slots back for you."
    recycle: RemoteEvent,
    slot_queue_recycle: u32,
    sync_trigger: RemoteEvent,
    sync_release: RemoteEvent,
    slot_queue: [64]u32,
    debug: [11]u32,
};

pub const SlotZero = extern struct {
    magic: u32,
    version: u16,
    version_min: u16,
    slot_zero_size: u32,
    slot_size: u32,
    max_slots: u32,
    max_slots_per_side: u32,
    /// The fragments' address as the VideoCore names it, and their count.
    platform_data: [2]u32,
    master: SharedState,
    slave: SharedState,
    slots: [128]u32,
};

comptime {
    std.debug.assert(@sizeOf(SharedState) == 372);
    std.debug.assert(@sizeOf(SlotZero) == 1288);
    std.debug.assert(@offsetOf(SlotZero, "master") == 32);
    std.debug.assert(@offsetOf(SlotZero, "slave") == 404);
    std.debug.assert(bytes_needed <= 2 * 1024 * 1024);
}

/// The two words in front of a pagelist's runs: the bulk's length, then
/// its kind (0 the firmware reads, 1 it writes, 2 + n it writes using
/// fragment n) and where in its first page it starts.
pub const PAGELIST_WRITE: u32 = 0;
pub const PAGELIST_READ: u32 = 1;
pub const PAGELIST_READ_WITH_FRAGMENTS: u32 = 2;

/// The pagelist of `size` bytes at `address` (one piece of memory, as the
/// ARM's map is one to one) into `words`, its kind `kind`: how many words
/// it took. The BCM2711's form: each run is its first page's number above
/// 8 bits, and its pages less one below them - pages up to 36 bits, 256
/// to a run.
pub fn describe(words: []u32, address: usize, size: u32, kind: u32) usize {
    const offset: u32 = @intCast(address & slot_mask);
    words[0] = size;
    words[1] = kind | offset << 16;
    var page: u64 = address >> 12;
    var pages: u64 = (@as(u64, offset) + size + 4095) / 4096;
    var n: usize = 2;
    while (pages > 0) : (n += 1) {
        const run = @min(pages, 256);
        words[n] = @intCast(page << 8 | (run - 1));
        page += run;
        pages -= run;
    }
    return n;
}

/// Whether a bulk the firmware writes at `address` needs a fragment:
/// its start or its end is not on a cache line.
pub fn needsFragment(address: usize, size: u32) bool {
    return address & (line - 1) != 0 or (address + size) & (line - 1) != 0;
}

/// Where a fragment's bytes go once its bulk is done: the head - from
/// the start to the first whole line - and the tail, after the last.
pub const Ends = struct { head: usize, tail_at: usize, tail: usize };

pub fn ends(address: usize, actual: u32) Ends {
    const head = (line - (address & (line - 1))) & (line - 1);
    const tail = (address + actual) & (line - 1);
    return .{
        .head = @min(head, actual),
        .tail_at = (address + actual) & ~(line - 1),
        .tail = if (head < actual) tail else 0,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "message ids: type, then the ports" {
    try testing.expectEqual(@as(u32, 0x0100_0000), msgid(MSG_CONNECT, 0, 0));
    try testing.expectEqual(@as(u32, 0x0200_1000), msgid(MSG_OPEN, 1, 0));
    const id = msgid(MSG_DATA, 3, 0x7A5);
    try testing.expectEqual(MSG_DATA, kindOf(id));
    try testing.expectEqual(@as(u32, 3), srcOf(id));
    try testing.expectEqual(@as(u32, 0x7A5), dstOf(id));
}

test "a message's room: header and bytes to 8" {
    try testing.expectEqual(@as(u32, 8), stride(0));
    try testing.expectEqual(@as(u32, 24), stride(12));
    try testing.expectEqual(@as(u32, 304), stride(296));
    try testing.expectEqual(slot_size, stride(max_message));
}

test "the block's layout" {
    try testing.expectEqual(@as(usize, 0x41000), fragments_at);
    try testing.expectEqual(@as(usize, 0x43000), pagelists_at);
    try testing.expectEqual(@as(usize, 0x47000), bytes_needed);
    try testing.expectEqual(@as(u32, 31), slave_slots);
}

test "a pagelist: runs of up to 256 pages from the first page's number" {
    var words: [64]u32 = undefined;
    // 3 MiB + 100 bytes from 0x1_2345_6040: 769 pages from 0x123456.
    const n = describe(&words, 0x1_2345_6040, 3 * 1024 * 1024 + 100, PAGELIST_READ_WITH_FRAGMENTS + 5);
    try testing.expectEqual(@as(usize, 2 + 4), n);
    try testing.expectEqual(@as(u32, 3 * 1024 * 1024 + 100), words[0]);
    try testing.expectEqual(@as(u32, 7 | 0x040 << 16), words[1]);
    try testing.expectEqual(@as(u32, 0x123456 << 8 | 255), words[2]);
    try testing.expectEqual(@as(u32, (0x123456 + 256) << 8 | 255), words[3]);
    try testing.expectEqual(@as(u32, (0x123456 + 512) << 8 | 255), words[4]);
    try testing.expectEqual(@as(u32, (0x123456 + 768) << 8 | 0), words[5]);
    // One page, on a page.
    try testing.expectEqual(@as(usize, 3), describe(&words, 0x8000, 4096, PAGELIST_WRITE));
    try testing.expectEqual(@as(u32, 8 << 8), words[2]);
}

test "the biggest bulk fits a pagelist" {
    var words: [pagelist_bytes / 4]u32 = undefined;
    try testing.expectEqual(words.len, describe(&words, 0x1FFF, max_bulk, PAGELIST_READ));
}

test "a fragment's ends" {
    try testing.expect(!needsFragment(0x1000, 4096));
    try testing.expect(needsFragment(0x1000, 4097));
    try testing.expect(needsFragment(0x1010, 64));
    // From 16 bytes into a line, 200 bytes: 48 at the head, 24 at the
    // tail, which starts at 0x10C0.
    const e = ends(0x1010, 200);
    try testing.expectEqual(@as(usize, 48), e.head);
    try testing.expectEqual(@as(usize, 0x10C0), e.tail_at);
    try testing.expectEqual(@as(usize, 24), e.tail);
    // All inside one line: the head alone.
    const small = ends(0x1010, 20);
    try testing.expectEqual(@as(usize, 20), small.head);
    try testing.expectEqual(@as(usize, 0), small.tail);
    // On a line at the start: the tail alone.
    const tail_only = ends(0x1000, 100);
    try testing.expectEqual(@as(usize, 0), tail_only.head);
    try testing.expectEqual(@as(usize, 36), tail_only.tail);
}
