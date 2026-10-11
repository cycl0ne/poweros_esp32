// SPDX-License-Identifier: MIT
//! A growing array whose memory comes from exec.
//!
//! `Array(T)` holds its items in one block from `AllocVec`, made twice as
//! large whenever it is full, so adding an item costs a copy only now and
//! then. Every call that may grow it is handed the ExecBase to allocate
//! with and answers false when there was no memory, the array as it was.
//! An empty array holds no memory; `deinit` gives back what it holds.
//!
//! It is compiled into whoever uses it, a generic and not a library call:
//! the item type is the user's, and there is nothing to share at run time.
//!
//!   var keys: exec.Array(u32) = .{};
//!   defer keys.deinit(sys);
//!   if (!keys.append(sys, 42)) return error.OutOfMemory;
//!   for (keys.slice()) |key| use(key);

const ExecBase = @import("../../interface/exec.zig").ExecBase;
const memory = @import("memory.zig");

pub fn Array(comptime T: type) type {
    return struct {
        /// The items; only the first `len` are in use.
        items: [*]T = undefined,
        len: u32 = 0,
        /// How many fit before it has to grow; 0 while it holds no memory.
        capacity: u32 = 0,

        const Self = @This();

        /// Room for at least `wanted` items. False with no memory.
        pub fn ensure(array: *Self, sys: *ExecBase, wanted: u32) bool {
            if (wanted <= array.capacity) return true;
            // Small to begin with: most arrays stay short.
            var bigger: u32 = if (array.capacity == 0) 4 else array.capacity;
            while (bigger < wanted) bigger *= 2;
            const block: [*]T = @ptrCast(@alignCast(sys.AllocVec(bigger * @sizeOf(T), memory.MEMF_ANY) orelse return false));
            if (array.capacity != 0) {
                @memcpy(block[0..array.len], array.items[0..array.len]);
                sys.FreeVec(array.items);
            }
            array.items = block;
            array.capacity = bigger;
            return true;
        }

        /// `item` added at the end. False with no memory.
        pub fn append(array: *Self, sys: *ExecBase, item: T) bool {
            if (array.len == array.capacity and !array.ensure(sys, array.len + 1)) return false;
            array.items[array.len] = item;
            array.len += 1;
            return true;
        }

        /// Every one of `more` added at the end, or none of them. False with
        /// no memory.
        pub fn appendSlice(array: *Self, sys: *ExecBase, more: []const T) bool {
            if (!array.ensure(sys, array.len + @as(u32, @intCast(more.len)))) return false;
            @memcpy(array.items[array.len..][0..more.len], more);
            array.len += @intCast(more.len);
            return true;
        }

        /// The items in use, to read and change; good until the array grows.
        pub fn slice(array: *const Self) []T {
            return array.items[0..array.len];
        }

        /// Every item taken off; the memory kept for the next.
        pub fn clear(array: *Self) void {
            array.len = 0;
        }

        /// The memory given back; the array is empty again.
        pub fn deinit(array: *Self, sys: *ExecBase) void {
            if (array.capacity != 0) sys.FreeVec(array.items);
            array.* = .{};
        }
    };
}
