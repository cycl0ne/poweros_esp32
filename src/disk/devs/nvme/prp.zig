// SPDX-License-Identifier: MIT
//! A piece of a transfer as a command's PRP entries describe it: the
//! address of each memory page the data is in - the first may start
//! inside its page - in PRP1, PRP2, and where there are more than two, a
//! list of the rest that PRP2 points at.
//!
//! **The caller's buffer is used as it is** wherever the controller and
//! the caches can share it: a whole page of it, or all of it where it
//! starts on `line` (its length is whole blocks, so it ends on one too).
//! A controller that sees the caches shares any of it: `line` is four
//! bytes, which PRP1 must be on. One that does not cannot share a cache
//! line with something else - the memory before the buffer and after it
//! - which could be written back over what the controller wrote, or lose
//! what the processor wrote beside it: `line` is `cache_line`, and those
//! bytes go through two pages of the device's own instead: the head,
//! from the buffer's start to the end of its first page, and the tail,
//! from the start of its last page to its end. A transfer is copied
//! through them at most 8 KiB a piece.
//!
//! A buffer that is not even on four bytes goes through the head page
//! whole, a page at a time.

const std = @import("std");

/// The bytes the processor's caches keep together.
pub const cache_line: usize = 64;
/// What PRP1 must be on: what a controller that sees the caches needs.
pub const dword: usize = 4;

/// The device's own pages of a command: the head and the tail of a
/// transfer, and the list of its pages past the first.
pub const Pages = struct {
    head: usize,
    tail: usize,
    list: usize,
};

pub const Plan = struct {
    prp1: u64,
    prp2: u64 = 0,
    /// How many pages, the first included.
    entries: u32,
    /// The bytes at the transfer's start that are in the head page, at
    /// `head_offset` in it, and the bytes at its end that are at the start
    /// of the tail page.
    head: u32 = 0,
    head_offset: u32 = 0,
    tail: u32 = 0,
};

/// The most bytes one piece from `data` may have, of `remaining`, where a
/// command moves at most `most` bytes: a page where the buffer is not on
/// four bytes.
pub fn pieceOf(data: usize, remaining: u64, most: u32, page: u32) u32 {
    const limit: u64 = if (data % 4 != 0) page else most;
    return @intCast(@min(remaining, limit));
}

/// `bytes` from `data` described, the pages past the first written to
/// `list` (the list page, as the processor sees it) where there are more
/// than two. `bytes` is a piece from `pieceOf`; `page` the controller's
/// memory page; `line` what the buffer must start on to be used as it is
/// (`cache_line` or `dword`).
pub fn plan(data: usize, bytes: u32, page: u32, line: usize, pages: Pages, list: []u64) Plan {
    if (data % 4 != 0) return .{ .prp1 = pages.head, .entries = 1, .head = bytes };
    var result: Plan = undefined;
    // Where the caller's own pages start, and how much of them is used.
    var at: usize = data;
    var left: u32 = bytes;
    if (data % line == 0) {
        result = .{ .prp1 = data, .entries = 1 };
        const first = @min(bytes, page - @as(u32, @intCast(data % page)));
        at += first;
        left -= first;
    } else {
        const offset: u32 = @intCast(data % page);
        const head = @min(bytes, page - offset);
        result = .{ .prp1 = pages.head + offset, .entries = 1, .head = head, .head_offset = offset };
        at += head;
        left -= head;
    }
    // `at` is on a page now, or nothing is left.
    var count: usize = 0;
    while (left > 0) {
        if (left < page and data % line != 0) {
            result.tail = left;
            list[count] = pages.tail;
            count += 1;
            break;
        }
        const step = @min(left, page);
        list[count] = at;
        count += 1;
        at += step;
        left -= step;
    }
    result.entries += @intCast(count);
    if (count == 1) {
        result.prp2 = list[0];
    } else if (count > 1) {
        result.prp2 = pages.list;
    }
    return result;
}

const testing = std.testing;

const own = Pages{ .head = 0x9000_0000, .tail = 0x9000_1000, .list = 0x9000_2000 };

test "a buffer on a cache line: its own pages, the first where it starts, a list past two" {
    var list: [8]u64 = undefined;
    // Within one page.
    var p = plan(0x4000_0040, 512, 4096, cache_line, own, &list);
    try testing.expectEqual(@as(u64, 0x4000_0040), p.prp1);
    try testing.expectEqual(@as(u32, 1), p.entries);
    try testing.expectEqual(@as(u64, 0), p.prp2);
    try testing.expectEqual(@as(u32, 0), p.head + p.tail);
    // Across two pages: PRP2 is the second.
    p = plan(0x4000_0E00, 1024, 4096, cache_line, own, &list);
    try testing.expectEqual(@as(u32, 2), p.entries);
    try testing.expectEqual(@as(u64, 0x4000_1000), p.prp2);
    // Four pages from a page's start: the list.
    p = plan(0x4000_0000, 16384, 4096, cache_line, own, &list);
    try testing.expectEqual(@as(u64, 0x4000_0000), p.prp1);
    try testing.expectEqual(@as(u32, 4), p.entries);
    try testing.expectEqual(own.list, p.prp2);
    try testing.expectEqualSlices(u64, &.{ 0x4000_1000, 0x4000_2000, 0x4000_3000 }, list[0..3]);
}

test "a buffer off a cache line: its first and last bytes through the head and tail pages" {
    var list: [8]u64 = undefined;
    // 16 bytes into a page, 8 KiB: 4080 bytes to the head, a page of its
    // own, 16 bytes to the tail.
    const p = plan(0x4000_0010, 8192, 4096, cache_line, own, &list);
    try testing.expectEqual(own.head + 0x10, p.prp1);
    try testing.expectEqual(@as(u32, 4080), p.head);
    try testing.expectEqual(@as(u32, 0x10), p.head_offset);
    try testing.expectEqual(@as(u32, 16), p.tail);
    try testing.expectEqual(@as(u32, 3), p.entries);
    try testing.expectEqual(own.list, p.prp2);
    try testing.expectEqualSlices(u64, &.{ 0x4000_1000, own.tail }, list[0..2]);
    // Within its first page, all of it in the head.
    const small = plan(0x4000_0010, 512, 4096, cache_line, own, &list);
    try testing.expectEqual(@as(u32, 1), small.entries);
    try testing.expectEqual(@as(u32, 512), small.head);
    try testing.expectEqual(@as(u32, 0), small.tail);
    // Ending on a page: no tail.
    const even = plan(0x4000_0E10, 4096 - 0xE10 + 4096, 4096, cache_line, own, &list);
    try testing.expectEqual(@as(u32, 0), even.tail);
    try testing.expectEqual(@as(u64, 0x4000_1000), even.prp2);
}

test "a controller that sees the caches: a buffer on four bytes used as it is" {
    var list: [8]u64 = undefined;
    // 16 bytes into a page, 8 KiB: its own three pages, nothing copied.
    const p = plan(0x4000_0010, 8192, 4096, dword, own, &list);
    try testing.expectEqual(@as(u64, 0x4000_0010), p.prp1);
    try testing.expectEqual(@as(u32, 0), p.head + p.tail);
    try testing.expectEqual(@as(u32, 3), p.entries);
    try testing.expectEqual(own.list, p.prp2);
    try testing.expectEqualSlices(u64, &.{ 0x4000_1000, 0x4000_2000 }, list[0..2]);
    // Not on four bytes it still cannot be.
    const odd = plan(0x4000_0013, 4096, 4096, dword, own, &list);
    try testing.expectEqual(own.head, odd.prp1);
    try testing.expectEqual(@as(u32, 4096), odd.head);
}

test "a buffer not on four bytes: a page at a time, through the head page" {
    var list: [8]u64 = undefined;
    try testing.expectEqual(@as(u32, 4096), pieceOf(0x4000_0003, 65536, 131072, 4096));
    try testing.expectEqual(@as(u32, 65536), pieceOf(0x4000_0004, 65536, 131072, 4096));
    const p = plan(0x4000_0003, 4096, 4096, cache_line, own, &list);
    try testing.expectEqual(own.head, p.prp1);
    try testing.expectEqual(@as(u32, 4096), p.head);
    try testing.expectEqual(@as(u32, 0), p.head_offset);
    try testing.expectEqual(@as(u32, 1), p.entries);
}
