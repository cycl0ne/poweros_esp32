// SPDX-License-Identifier: MIT
//! Memory for the drawing: two functions the caller gives - vector.library
//! exec's AllocVec and FreeVec, a host test its allocator - and a list
//! that grows in them.

/// Where the drawing's memory comes from. Every block is aligned to 8
/// bytes, which every type here needs at most.
pub const Memory = struct {
    context: ?*anyopaque = null,
    allocFn: *const fn (context: ?*anyopaque, bytes: usize) ?[*]align(8) u8,
    freeFn: *const fn (context: ?*anyopaque, block: [*]align(8) u8, bytes: usize) void,

    /// Room for `n` of `T`, not cleared; null without it.
    pub fn alloc(memory: Memory, comptime T: type, n: usize) ?[]T {
        comptime if (@alignOf(T) > 8) @compileError("memory: a type aligned past 8 bytes");
        if (n == 0) return &.{};
        const bytes = @mulWithOverflow(n, @sizeOf(T));
        if (bytes[1] != 0) return null;
        const block = memory.allocFn(memory.context, bytes[0]) orelse return null;
        const items: [*]T = @ptrCast(block);
        return items[0..n];
    }

    pub fn free(memory: Memory, comptime T: type, items: []T) void {
        if (items.len == 0) return;
        memory.freeFn(memory.context, @ptrCast(@alignCast(items.ptr)), items.len * @sizeOf(T));
    }

    /// One `T`, not cleared.
    pub fn create(memory: Memory, comptime T: type) ?*T {
        const one = memory.alloc(T, 1) orelse return null;
        return &one[0];
    }

    pub fn destroy(memory: Memory, comptime T: type, item: *T) void {
        memory.free(T, @as([*]T, @ptrCast(item))[0..1]);
    }
};

/// Items kept in a row, the room doubled each time it runs out, and kept
/// when the list is emptied.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        room: []T = &.{},
        len: usize = 0,

        pub fn items(list: *const Self) []T {
            return list.room[0..list.len];
        }

        pub fn clear(list: *Self) void {
            list.len = 0;
        }

        /// Room for `more` past what is there; false without it, and the
        /// list as it was.
        pub fn reserve(list: *Self, memory: Memory, more: usize) bool {
            const wanted = list.len + more;
            if (wanted <= list.room.len) return true;
            var size: usize = @max(list.room.len * 2, 16);
            while (size < wanted) size *= 2;
            const bigger = memory.alloc(T, size) orelse return false;
            @memcpy(bigger[0..list.len], list.room[0..list.len]);
            memory.free(T, list.room);
            list.room = bigger;
            return true;
        }

        /// One more at the end; false without the room for it.
        pub fn append(list: *Self, memory: Memory, item: T) bool {
            if (!list.reserve(memory, 1)) return false;
            list.room[list.len] = item;
            list.len += 1;
            return true;
        }

        pub fn deinit(list: *Self, memory: Memory) void {
            memory.free(T, list.room);
            list.* = .{};
        }
    };
}

// --- tests ---------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// Memory from the test allocator, which finds what is not given back.
pub const test_memory = Memory{ .allocFn = testAlloc, .freeFn = testFree };

fn testAlloc(context: ?*anyopaque, bytes: usize) ?[*]align(8) u8 {
    _ = context;
    const block = testing.allocator.alignedAlloc(u8, .@"8", bytes) catch return null;
    return block.ptr;
}

fn testFree(context: ?*anyopaque, block: [*]align(8) u8, bytes: usize) void {
    _ = context;
    testing.allocator.free(block[0..bytes]);
}

test "a list grows, keeps its items, and keeps its room when emptied" {
    var list: List(u32) = .{};
    defer list.deinit(test_memory);
    for (0..100) |i| try testing.expect(list.append(test_memory, @intCast(i)));
    try testing.expectEqual(@as(usize, 100), list.len);
    try testing.expectEqual(@as(u32, 57), list.items()[57]);
    const room = list.room.len;
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.items().len);
    try testing.expectEqual(room, list.room.len);
}
