// SPDX-License-Identifier: MPL-2.0
//! The table of blocks the device's firmware leaves: where it is, and
//! each block's entry in it.
//!
//! The table lists every block of the chip with its version and the
//! addresses its registers are counted from. Those addresses are not
//! fixed for the part, so every driver of a block asks the table rather
//! than knowing them, and a chip that answers differently is one that
//! says so rather than one read at an address that belongs to something
//! else. The addresses count 32-bit registers.
//!
//! ## Where the table is
//!
//! Three places, and which one it was in is said out loud, because it is
//! the first thing to know about a part this has not been run on before.
//!
//! It is left below the top of the device's own memory - but the device's
//! memory is longer than the window onto it, so the top of the window is
//! not the top of the memory and reading there finds a picture, not a
//! table. What reads it is a pair of registers whose place is the same on
//! every part the vendor has made: an address is latched in the first and
//! the four bytes there come back from the second, with no window needed.
//! How far up to look is the device's own answer for how much memory it
//! has.
//!
//! A firmware that keeps that region in the machine's memory instead
//! leaves its address in three more registers of that fixed set, and then
//! the table is read where any other address in the machine is read.
//!
//! And on a part whose window shows all of its memory the table is in the
//! window after all, which is where this looks last.
//!
//! ## What an entry is
//!
//! The table's own list begins with the list of blocks, which is a list of
//! dies, each with its blocks one after another. A block's entry is its
//! kind, its instance, how many addresses it has and its version, then the
//! addresses - four bytes each, or eight from the fourth version of the
//! list where it says its addresses are 64-bit. The entries are walked in
//! order, since each is as long as its own number of addresses.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;

/// What the table's first word is, and what the list of blocks inside it
/// begins with.
const binary_mark: u32 = 0x2821_1407;
const list_mark: u32 = 0x5344_5049;

/// The table sits below the top of the device's memory, and is looked for
/// from there downwards on whole pages. The distance is fixed, but the
/// memory above the window's end is not always the device's to show, so
/// the look walks rather than trusting one place.
pub const table_below_top = 64 * 1024;
const look_page = 4096;
const look_bytes = 64 * 1024 * 1024;

/// How much of the table is read out of the device. It is the room the
/// firmware reserves for it; the list of blocks is far shorter, and the
/// rest is the other tables of the same binary.
pub const table_bytes = 10 * 1024;

/// The pair that reads the device's own memory with no window onto it,
/// and the registers that say how much memory there is and where the
/// firmware put the table when it is not in that memory. These few have
/// the same place on every part of this vendor, which is what makes them
/// readable before the table that says where everything else is.
/// Counted in 32-bit words, as every register here is.
const mm_index = 0x0;
const mm_data = 0x1;
const mm_index_high = 0x6;
pub const config_memsize = 0xde3;
const scratch_address = 0x94;
const scratch_address_high = 0x95;
const scratch_bytes = 0x96;

/// In the latched address, that it is an address in the device's memory
/// and not one of the device's registers. It takes the place of the
/// address's own bit 31, which is why the upper register is given the
/// address shifted by one less than the half it carries.
const index_is_memory: u32 = 0x8000_0000;
const index_high_shift = 31;

/// The furthest up the device's memory the table is looked for, so that a
/// device answering with something wild for how much memory it has is not
/// read at an address that means nothing.
const memory_most: u64 = 64 * 1024 * 1024 * 1024;

/// Where the list of blocks is in the table.
const binary_list_at = 12;
/// In the list of blocks: its own version and the version from which a
/// block's addresses may be 64-bit, where the count of dies is, where
/// their places are, and where the word that says how wide those
/// addresses are.
const list_version_at = 4;
const list_version_wide = 4;
const list_dies_at = 12;
const list_die_at = 14;
const list_dies_most = 16;
const list_wide_at = 78;
/// A die's own header, and a block's entry in it.
const die_count_at = 2;
const die_first_at = 4;
const block_instance_at = 2;
const block_addresses_at = 3;
const block_version_at = 4;
const block_header_bytes = 8;

/// One of the function's memory windows: where it is and how long.
pub const Window = struct { at: usize, bytes: usize };

/// The table, wherever it was found: where it can be read, the room a
/// copy of it is in - null where it is read where it lies - and where it
/// came from, for the line that says so.
pub const Table = struct { at: usize, room: ?*anyopaque = null, where: [*:0]const u8 };

/// The chip's table of blocks, looked for in each of the three places it
/// is. The device's own memory first, read through the latch, as far up
/// as the device says its memory goes; then the machine's memory, where a
/// firmware that keeps the region there leaves the address; then the
/// window, which is where it is on a part whose window shows all of its
/// memory. Each is taken only when what is there begins with the table's
/// mark, so a place that holds something else is passed over rather than
/// read as a table.
pub fn find(sys: *ExecBase, memory: Window, registers: Window) ?Table {
    // Every register read here is within the first kibibytes of the
    // window but for one, which is checked for rather than assumed.
    if (registers.bytes > (scratch_bytes + 1) * 4 and registers.bytes > (config_memsize + 1) * 4) {
        const memory_bytes = memoryBytes(registers);
        if (memory_bytes != 0 and memory_bytes <= memory_most and memory_bytes > table_below_top) {
            if (copyOut(sys, registers, memory_bytes - table_below_top)) |room| {
                return .{ .at = @intFromPtr(room), .room = room, .where = "the top of the device's own memory" };
            }
        }
        const left = @as(u64, readWord(registers, scratch_address_high)) << 32 |
            readWord(registers, scratch_address);
        const bytes = readWord(registers, scratch_bytes);
        if (bytes >= table_bytes and left != 0 and left % 4 == 0 and left <= std.math.maxInt(usize) - table_bytes) {
            const at: usize = @intCast(left);
            if (word32(at) == binary_mark) {
                return .{ .at = at, .where = "the machine's memory, where the firmware left it" };
            }
        }
    }
    if (tableAt(memory)) |at| return .{ .at = at, .where = "the device's memory window" };
    return null;
}

/// How much memory the device says it has, in bytes; 0 where it does not
/// say.
pub fn memoryBytes(registers: Window) u64 {
    if (registers.bytes <= (config_memsize + 1) * 4) return 0;
    return @as(u64, readWord(registers, config_memsize)) << 20;
}

/// The `instance`th block of kind `id` in the table at `table`, into
/// `block`; false where the table has none.
pub fn block(table: usize, id: u32, instance: u32, into: *amdgpu.GPUBlock) bool {
    var walk = Walk.begin(table) orelse return false;
    while (walk.next()) |entry| {
        if (entry.id == id and entry.instance == instance) {
            into.* = entry;
            return true;
        }
    }
    return false;
}

/// The table's blocks one after another, die by die.
pub const Walk = struct {
    table: usize,
    list: usize,
    dies: u32,
    wide: bool,
    die: u32 = 0,
    /// The die being walked: where its next entry is and how many are
    /// left in it.
    at: usize = 0,
    left: u32 = 0,

    /// A walk of the table at `table`; null where its list of blocks is
    /// not where the table says.
    pub fn begin(table: usize) ?Walk {
        // The first entry of the table's own list is the list of blocks,
        // as far into the table as that entry says.
        const list = table + word16(table + binary_list_at);
        if (word32(list) != list_mark) return null;
        return .{
            .table = table,
            .list = list,
            .dies = @min(word16(list + list_dies_at), list_dies_most),
            // The word after the dies says whether a block's addresses are
            // 64-bit, and only from the fourth version of the list: before
            // that it is padding, and every address is 32-bit.
            .wide = word16(list + list_version_at) >= list_version_wide and word8(list + list_wide_at) & 1 != 0,
        };
    }

    /// The next block, or null after the last.
    pub fn next(walk: *Walk) ?amdgpu.GPUBlock {
        while (walk.left == 0) {
            if (walk.die >= walk.dies) return null;
            const place = word16(walk.list + list_die_at + walk.die * 4 + 2);
            walk.die += 1;
            if (place == 0) continue;
            const die = walk.table + place;
            walk.left = word16(die + die_count_at);
            walk.at = die + die_first_at;
        }
        const at = walk.at;
        const addresses = word8(at + block_addresses_at);
        const first = at + block_header_bytes;
        const size: usize = if (walk.wide) 8 else 4;
        walk.at = first + addresses * size;
        walk.left -= 1;

        var entry: amdgpu.GPUBlock = .{
            .id = word16(at),
            .instance = word8(at + block_instance_at),
            .major = word8(at + block_version_at),
            .minor = word8(at + block_version_at + 1),
            .revision = word8(at + block_version_at + 2),
            .count = @intCast(@min(addresses, amdgpu.GPUBLOCK_ADDRESSES)),
        };
        // Even where the addresses are 64-bit, the lower half is what the
        // registers are counted from.
        var which: usize = 0;
        while (which < entry.count) : (which += 1) {
            entry.addresses[which] = word32(first + which * size);
        }
        return entry;
    }
};

/// The table copied out of the device's memory from `at`, in room of our
/// own, when what is there begins with the table's mark; null otherwise,
/// with the room given back. A word at a time, which is what the latch
/// gives: ten kibibytes is a few thousand reads of an uncached register
/// and happens once.
fn copyOut(sys: *ExecBase, registers: Window, at: u64) ?*anyopaque {
    const room = sys.AllocVec(table_bytes, exec.MEMF_ANY) orelse return null;
    const words: [*]u32 = @ptrCast(@alignCast(room));
    var which: usize = 0;
    while (which < table_bytes / 4) : (which += 1) {
        words[which] = readMemory(registers, at + which * 4);
    }
    if (words[0] != binary_mark) {
        sys.FreeVec(room);
        return null;
    }
    return room;
}

/// Four bytes of the device's own memory, through the latch.
fn readMemory(registers: Window, at: u64) u32 {
    writeWord(registers, mm_index, @as(u32, @truncate(at)) | index_is_memory);
    writeWord(registers, mm_index_high, @truncate(at >> index_high_shift));
    return readWord(registers, mm_data);
}

/// A register of the window, by its number in 32-bit words.
fn readWord(registers: Window, offset: u32) u32 {
    return reg(registers.at + offset * 4).*;
}

fn writeWord(registers: Window, offset: u32, value: u32) void {
    reg(registers.at + offset * 4).* = value;
}

/// Where the table is in the device's memory window: below the top, and
/// otherwise looked for on whole pages downwards from there. Null where
/// no page in the stretch begins with the table's mark.
fn tableAt(memory: Window) ?usize {
    if (memory.bytes <= table_below_top) return null;
    const top = memory.at + memory.bytes;
    const likely = top - table_below_top;
    if (word32(likely) == binary_mark) return likely;
    const end = if (memory.bytes > look_bytes) top - look_bytes else memory.at;
    var at = std.mem.alignBackward(usize, likely, look_page);
    while (at >= end) {
        if (word32(at) == binary_mark) return at;
        if (at < end + look_page) break;
        at -= look_page;
    }
    return null;
}

fn word8(at: usize) u8 {
    return sdk.hardware.mmio.reg8(at).*;
}

fn word16(at: usize) u32 {
    return sdk.hardware.mmio.reg16(at).*;
}

fn word32(at: usize) u32 {
    return reg(at).*;
}

// --- tests ------------------------------------------------------------------------

const testing = std.testing;

/// A table of two dies, laid out as the device's firmware lays one out,
/// with 32-bit addresses (`wide` false) or 64-bit ones; the resource's
/// own tests build theirs with it.
pub fn makeTable(room: []align(4) u8, wide: bool) void {
    @memset(room, 0);
    const put16 = struct {
        fn f(r: []u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, r[at..][0..2], v, .little);
        }
    }.f;
    const put32 = struct {
        fn f(r: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, r[at..][0..4], v, .little);
        }
    }.f;
    put32(room, 0, binary_mark);
    const list = 64;
    put16(room, binary_list_at, list);
    put32(room, list, list_mark);
    put16(room, list + list_version_at, if (wide) 4 else 3);
    put16(room, list + list_dies_at, 2);
    room[list + list_wide_at] = if (wide) 1 else 0;
    const dies = [_]usize{ 256, 512 };
    for (dies, 0..) |die, n| put16(room, list + list_die_at + n * 4 + 2, @intCast(die));
    const size: usize = if (wide) 8 else 4;
    // Die 0: the display engine with six addresses, then the video block.
    put16(room, dies[0] + die_count_at, 2);
    var at = dies[0] + die_first_at;
    put16(room, at, 271);
    room[at + block_addresses_at] = 6;
    room[at + block_version_at] = 3;
    room[at + block_version_at + 1] = 1;
    room[at + block_version_at + 2] = 4;
    for (0..6) |i| put32(room, at + block_header_bytes + i * size, @intCast(0x12 + i * 0x100));
    at += block_header_bytes + 6 * size;
    put16(room, at, 12);
    room[at + block_addresses_at] = 2;
    room[at + block_version_at] = 4;
    room[at + block_version_at + 2] = 2;
    put32(room, at + block_header_bytes, 0x7800);
    put32(room, at + block_header_bytes + size, 0x7E00);
    // Die 1: a second instance of the video block, and the security
    // processor with ten addresses, more than a block is answered with.
    put16(room, dies[1] + die_count_at, 2);
    at = dies[1] + die_first_at;
    put16(room, at, 12);
    room[at + block_instance_at] = 1;
    room[at + block_addresses_at] = 1;
    put32(room, at + block_header_bytes, 0x9000);
    at += block_header_bytes + size;
    put16(room, at, 255);
    room[at + block_addresses_at] = 10;
    room[at + block_version_at] = 13;
    room[at + block_version_at + 2] = 4;
    for (0..10) |i| put32(room, at + block_header_bytes + i * size, @intCast(0x16000 + i));
}

test "a block is found by its kind and instance, in either width" {
    for ([_]bool{ false, true }) |wide| {
        var room: [1024]u8 align(4) = undefined;
        makeTable(&room, wide);
        const table = @intFromPtr(&room);

        var found: amdgpu.GPUBlock = .{};
        try testing.expect(block(table, amdgpu.GPUBLOCK_DISPLAY, 0, &found));
        try testing.expectEqual(@as(u8, 3), found.major);
        try testing.expectEqual(@as(u8, 4), found.revision);
        try testing.expectEqual(@as(u8, 6), found.count);
        try testing.expectEqual(@as(u32, 0x212), found.addresses[2]);

        try testing.expect(block(table, amdgpu.GPUBLOCK_VIDEO, 0, &found));
        try testing.expectEqual(@as(u32, 0x7E00), found.addresses[1]);
        try testing.expect(block(table, amdgpu.GPUBLOCK_VIDEO, 1, &found));
        try testing.expectEqual(@as(u32, 0x9000), found.addresses[0]);
        try testing.expect(!block(table, amdgpu.GPUBLOCK_VIDEO, 2, &found));

        try testing.expect(block(table, amdgpu.GPUBLOCK_SECURITY, 0, &found));
        try testing.expectEqual(@as(u8, amdgpu.GPUBLOCK_ADDRESSES), found.count);
        try testing.expectEqual(@as(u32, 0x16007), found.addresses[7]);

        try testing.expect(!block(table, amdgpu.GPUBLOCK_POWER, 0, &found));
    }
}

test "a walk passes every block once, and a table without its list has none" {
    var room: [1024]u8 align(4) = undefined;
    makeTable(&room, false);
    var walk = Walk.begin(@intFromPtr(&room)).?;
    var count: u32 = 0;
    while (walk.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 4), count);

    std.mem.writeInt(u32, room[64..][0..4], 0, .little);
    try testing.expectEqual(@as(?Walk, null), Walk.begin(@intFromPtr(&room)));
    var found: amdgpu.GPUBlock = .{};
    try testing.expect(!block(@intFromPtr(&room), amdgpu.GPUBLOCK_DISPLAY, 0, &found));
}
