// SPDX-License-Identifier: MPL-2.0
//! The part of the device's own memory the resource hands out, and what
//! of it is handed out: a list of pieces in the order of their places,
//! each found first fit.
//!
//! **Which part.** The device's memory is a part of the machine's that
//! its firmware set aside, and the firmware keeps two pieces of it: the
//! screen it lit, at the bottom - 14 MiB on a 2560 x 1440 screen, 32 MiB
//! on one of 3840 x 2160 - and a region of its own at the top, whose size
//! is in the video firmware's tables and whose last 64 KiB hold the table
//! of blocks. Those tables are not read, so the bottom and the top 64 MiB
//! are both left alone and what is handed out is between them; a device
//! with too little memory for that has nothing handed out.
//!
//! **The list** holds at most `max_pieces`, so a driver keeps few and
//! large: a ring, the buffers of the work under way.

/// The bottom and the top of the device's memory that are left alone.
pub const kept_bottom: u64 = 64 * 1024 * 1024;
pub const kept_top: u64 = 64 * 1024 * 1024;

/// The most pieces handed out at a time.
pub const max_pieces = 64;

/// The smallest step a piece starts on: a page, which no block asks less
/// than.
pub const least_alignment: u32 = 4096;

/// A piece handed out: where it starts in the device's memory, and how
/// long it is.
pub const Piece = extern struct {
    offset: u64 align(4) = 0,
    bytes: u64 align(4) = 0,
};

/// What is handed out of `start` .. `end`, offsets into the device's
/// memory; `end` 0 where there is nothing to hand out.
pub const Arena = extern struct {
    start: u64 align(4) = 0,
    end: u64 align(4) = 0,
    count: u32 = 0,
    pieces: [max_pieces]Piece = @splat(.{}),
};

/// The arena for a device with `memory_bytes` of memory: what lies
/// between the kept bottom and top, or nothing.
pub fn of(memory_bytes: u64) Arena {
    if (memory_bytes <= kept_bottom + kept_top) return .{};
    return .{ .start = kept_bottom, .end = memory_bytes - kept_top };
}

fn alignUp(at: u64, alignment: u64) u64 {
    return (at + alignment - 1) & ~(alignment - 1);
}

/// `bytes` placed on a multiple of `alignment` (a power of two, raised to
/// a page) in the first gap that holds them: its offset, or null where
/// none does, the list is full, or the alignment is no power of two.
pub fn place(arena: *Arena, bytes: u64, alignment: u32) ?u64 {
    if (bytes == 0 or arena.end == 0 or arena.count >= max_pieces) return null;
    if (alignment == 0 or alignment & (alignment - 1) != 0) return null;
    const step: u64 = @max(alignment, least_alignment);
    const length = alignUp(bytes, least_alignment);

    var index: u32 = 0;
    var from = arena.start;
    while (true) : (index += 1) {
        const until = if (index < arena.count) arena.pieces[index].offset else arena.end;
        const at = alignUp(from, step);
        if (at + length <= until) {
            // Into the list at `index`, the later ones moved up one.
            var later = arena.count;
            while (later > index) : (later -= 1) arena.pieces[later] = arena.pieces[later - 1];
            arena.pieces[index] = .{ .offset = at, .bytes = length };
            arena.count += 1;
            return at;
        }
        if (index >= arena.count) return null;
        from = arena.pieces[index].offset + arena.pieces[index].bytes;
    }
}

/// The piece at `offset` taken off the list: false where none starts
/// there.
pub fn remove(arena: *Arena, offset: u64) bool {
    var index: u32 = 0;
    while (index < arena.count) : (index += 1) {
        if (arena.pieces[index].offset != offset) continue;
        var later = index;
        while (later + 1 < arena.count) : (later += 1) arena.pieces[later] = arena.pieces[later + 1];
        arena.count -= 1;
        arena.pieces[arena.count] = .{};
        return true;
    }
    return false;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "pieces go first fit between the kept bottom and top, on their alignment" {
    const mib = 1024 * 1024;
    var arena = of(512 * mib);
    try testing.expectEqual(@as(u64, 64 * mib), arena.start);
    try testing.expectEqual(@as(u64, 448 * mib), arena.end);

    const ring = place(&arena, 16 * 1024, 4096).?;
    try testing.expectEqual(@as(u64, 64 * mib), ring);
    // A small piece is a page, and the next starts past it on its own
    // alignment.
    const small = place(&arena, 100, 256).?;
    try testing.expectEqual(@as(u64, 64 * mib + 16 * 1024), small);
    const big = place(&arena, 3 * mib, 2 * mib).?;
    try testing.expectEqual(@as(u64, 66 * mib), big);

    // A gap given back is found again by a piece that fits it.
    try testing.expect(remove(&arena, ring));
    try testing.expect(!remove(&arena, ring));
    try testing.expectEqual(ring, place(&arena, 8 * 1024, 4096).?);
    try testing.expectEqual(@as(u32, 3), arena.count);

    // What does not fit is refused, and so is an alignment that is no
    // power of two.
    try testing.expect(place(&arena, 400 * mib, 4096) == null);
    try testing.expect(place(&arena, 4096, 3000) == null);
    try testing.expect(place(&arena, 0, 4096) == null);
}

test "a device with too little memory has nothing handed out" {
    var arena = of(128 * 1024 * 1024);
    try testing.expectEqual(@as(u64, 0), arena.end);
    try testing.expect(place(&arena, 4096, 4096) == null);
}

test "the list holds so many pieces and no more" {
    var arena = of(512 * 1024 * 1024);
    var made: u32 = 0;
    while (place(&arena, 4096, 4096) != null) made += 1;
    try testing.expectEqual(@as(u32, max_pieces), made);
}
