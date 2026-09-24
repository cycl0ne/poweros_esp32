// SPDX-License-Identifier: MPL-2.0
//! Libraries: making, adding, opening, closing, expunging and patching
//! them. The Library header and the jump table's layout (the diagram is
//! there) are the SDK's (sdk/libs/exec/libraries.zig); the four standard
//! vectors - Open, Close, Expunge, ExtFunc - are exec's own
//! (exec_base.zig), and its Expunge frees the library.
//!
//! A library is one block: the jump table below the base, the module's own
//! data above it. exec allocates it rather than letting the module find
//! its own memory, which is what lets a module live in a read-only ROM
//! image and what lets one Expunge free the whole of it.
//!
//! Every function in a jump table gets the library's base as its first
//! argument.
//!
//! Resources: named system objects on SysBase's resource list, **without
//! an open count**. OpenResource finds one by name and there is no closing
//! it, which is the right shape for something there is exactly one of and
//! that nobody may take away - a chip's DMA channels, a board's IO
//! expander, the watchdog.
//!
//! A resource starts with a Node, and in practice is a Library: its jump
//! table in front of it, so callers reach it the ordinary way.
//!
//! The library and resource calls are a file each in this folder; this
//! file is everything else: the low-memory handler that expunges what
//! nobody has open; working out a library's size, laying it out and
//! freeing it again; and the jump-table checksum. Every library brings its
//! own jump table; the standard vectors are in exec_base.zig.
//!
//! `librarySizes` and `buildLibrary` take no ExecBase: the bootstrap builds
//! exec.library with them, before there is one.

const sdk = @import("sdk");
const exec = @import("../exec.zig");

const ExecBase = exec.ExecBase;
const Library = sdk.exec.Library;

/// Low-memory handler: expunges libraries and devices nobody has open.
///
/// One per call - `MEM_TRY_AGAIN` after each one that went, so `AllocMem`
/// retries and only as many go as the allocation needed. A module that
/// refuses to go (exec.library) is left where it is, which is read from it
/// still being on the list rather than from what its vector answered.
///
/// INPUTS:
/// - `data` - what the allocation wanted; not looked at, since what is
///   wanted is freed by whoever will free it.
/// - `is_data` - the handler's own data: exec's base, which the handler's
///   `data` field is set to when it is added.
pub fn flushLibraries(data: *const sdk.exec.MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32 {
    _ = data;
    const base: *ExecBase = @ptrCast(@alignCast(is_data.?));
    for ([_]*sdk.exec.List{ &base.lib_list, &base.device_list }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const lib: *Library = @fieldParentPtr("node", node);
            if (lib.open_cnt != 0) continue;
            const address = @intFromPtr(lib);
            _ = base.iface().RemLibrary(lib); // the Expunge vector, as RemDevice
            if (!onList(list, address)) return sdk.exec.MEM_TRY_AGAIN;
        }
    }
    return sdk.exec.MEM_DID_NOTHING;
}

/// Whether a node of that address is still on the list. Addresses only:
/// the library may already be freed, so the node must not be read.
///
/// INPUTS:
/// - `list` - the list to walk.
/// - `address` - where the library was.
fn onList(list: *sdk.exec.List, address: usize) bool {
    var it = list.iterator();
    while (it.next()) |node| {
        if (@intFromPtr(node) == address) return true;
    }
    return false;
}

/// Frees a library's memory, jump table included - the block `MakeLibrary`
/// took, found again from the base and the header's two sizes.
///
/// INPUTS:
/// - `base` - exec: the jump table `FreeMem` goes through.
/// - `lib` - the library, off every list.
pub fn freeLibraryMemory(base: *ExecBase, lib: *Library) void {
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    base.iface().FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
}

/// Bytes of jump table (neg) and base (pos) of a library.
pub const LibrarySizes = struct {
    neg: usize,
    pos: usize,
};

/// What a library's base is aligned to, given an 8-aligned block.
pub const base_align = 8;

/// How big a library's two halves are.
///
/// INPUTS:
/// - `vector_count` - how many jump-table entries there are.
/// - `data_size` - the bytes of base asked for.
///
/// RESULT:
/// The sizes, or null if the description cannot be built: no vectors, a
/// base smaller than the header, or either half past what a `u16` holds.
pub fn librarySizes(vector_count: usize, data_size: usize) ?LibrarySizes {
    // At least one vector, and not necessarily the four standard ones: a
    // resource has none of them.
    if (vector_count == 0 or data_size < @sizeOf(Library)) return null;
    // The base is where a module's own data starts, and that data may hold
    // 64-bit fields (an IOStdReq's io_Length), so the base is 8-aligned
    // whatever the vector count: the table is rounded up, and the spare
    // word sits at its far end, below the last vector.
    const neg = alignUp(vector_count * sdk.exec.slot_size, base_align);
    const pos = alignUp(data_size, base_align);
    if (neg > 0xFFFF or pos > 0xFFFF) return null;
    return .{ .neg = neg, .pos = pos };
}

/// Lays a library out in memory already allocated: clears it, fills the
/// jump table, sets up the Library header.
///
/// INPUTS:
/// - `block` - `sizes.neg + sizes.pos` bytes, 8-aligned.
/// - `vectors` - the jump table, in slot order.
/// - `sizes` - what `librarySizes` worked out.
///
/// RESULT:
/// The base, `sizes.neg` into the block.
pub fn buildLibrary(block: [*]u8, vectors: []const *const anyopaque, sizes: LibrarySizes) *Library {
    @memset(block[0 .. sizes.neg + sizes.pos], 0);
    // Vector i sits at base - (i + 1) * slot_size; any padding is below.
    const table: [*]*const anyopaque = @ptrCast(@alignCast(block + sizes.neg - vectors.len * sdk.exec.slot_size));
    for (vectors, 0..) |vector, index| table[vectors.len - 1 - index] = vector;
    const lib: *Library = @ptrCast(@alignCast(block + sizes.neg));
    lib.* = .{ .neg_size = @intCast(sizes.neg), .pos_size = @intCast(sizes.pos) };
    return lib;
}

/// Keeps a library's jump-table checksum, for libraries that asked for one
/// with `LIBF_SUMUSED`.
///
/// After a legitimate change (`LIBF_CHANGED`, which `AddLibrary` and
/// `SetFunction` set) it stores the sum; otherwise it verifies it. A
/// mismatch means something wrote over a jump table, so there is nothing
/// left to trust and it panics rather than returning into the table.
///
/// INPUTS:
/// - `lib` - the library whose table is summed. One without
///   `LIBF_SUMUSED` is left alone, which is every library in this tree.
pub fn SumLibrary(lib: *Library) void {
    if (lib.flags & sdk.exec.LIBF_SUMUSED == 0) return;
    const table: [*]const usize = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    var sum: u32 = 0;
    for (table[0 .. lib.neg_size / sdk.exec.slot_size]) |entry| sum +%= @truncate(entry);
    if (lib.flags & sdk.exec.LIBF_CHANGED != 0) {
        lib.sum = sum;
        lib.flags &= ~sdk.exec.LIBF_CHANGED;
    } else if (sum != lib.sum) {
        @panic("library jump table checksum mismatch");
    }
}

/// `value` rounded up to a multiple of `alignment`, a power of two.
///
/// INPUTS:
/// - `value` - the size to round.
/// - `alignment` - a power of two.
pub fn alignUp(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(alignment - 1);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "librarySizes: 8-aligned halves, and what cannot be built is null" {
    const sizes = librarySizes(5, @sizeOf(Library) + 1).?;
    try testing.expectEqual(@as(usize, 0), sizes.neg % base_align);
    try testing.expectEqual(@as(usize, 0), sizes.pos % base_align);
    try testing.expect(sizes.neg >= 5 * sdk.exec.slot_size);
    try testing.expect(librarySizes(0, @sizeOf(Library)) == null);
    try testing.expect(librarySizes(4, @sizeOf(Library) - 1) == null);
    try testing.expect(librarySizes(4, 0x10000) == null);
}

test "buildLibrary puts the vectors below the base in slot order" {
    const vectors = [_]*const anyopaque{ @ptrFromInt(0x1000), @ptrFromInt(0x2000), @ptrFromInt(0x3000) };
    const sizes = librarySizes(vectors.len, @sizeOf(Library)).?;
    var block: [256]u8 align(8) = undefined;
    const lib = buildLibrary(&block, &vectors, sizes);
    try testing.expectEqual(@intFromPtr(&block) + sizes.neg, @intFromPtr(lib));
    const slots: [*]const usize = @ptrFromInt(@intFromPtr(lib) - vectors.len * sdk.exec.slot_size);
    try testing.expectEqual(@as(usize, 0x3000), slots[0]);
    try testing.expectEqual(@as(usize, 0x1000), slots[vectors.len - 1]);
    try testing.expectEqual(@as(u16, @intCast(sizes.neg)), lib.neg_size);
}
