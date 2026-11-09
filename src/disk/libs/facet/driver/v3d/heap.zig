// SPDX-License-Identifier: MIT
//! A `std.mem.Allocator` over exec's AllocVec and FreeVec, for what of
//! the driver is written against one: the compiler ported from Mesa
//! (compiler/), whose lists, sets and graphs grow as a program is
//! compiled, where Mesa's grow with ralloc.
//!
//! The blocks are the calling task's, as facet's objects are
//! (`_objects.zig`), and aligned to exec's chunks. An alignment past that
//! is refused rather than padded for: nothing the compiler keeps asks
//! for one. A block is never grown where it lies - AllocVec cannot - so
//! a list that grows is moved, which an arena over this
//! (`std.heap.ArenaAllocator`) mostly spares.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const Alignment = std.mem.Alignment;

/// The allocator for `sys`'s calling task.
pub fn of(sys: *ExecBase) std.mem.Allocator {
    return .{ .ptr = sys, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    if (alignment.toByteUnits() > exec.MEM_BLOCKSIZE) return null;
    const sys: *ExecBase = @ptrCast(@alignCast(context));
    const memory = sys.AllocVec(@max(len, 1), 0) orelse return null;
    return @ptrCast(memory);
}

/// A block can shrink in place, as far as its user knows; never grow.
fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = context;
    _ = alignment;
    _ = ret_addr;
    return new_len <= memory.len;
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = context;
    _ = alignment;
    _ = ret_addr;
    return if (new_len <= memory.len) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const sys: *ExecBase = @ptrCast(@alignCast(context));
    sys.FreeVec(memory.ptr);
}

test {
    // There is no exec on the host: what can be checked here is that it
    // is an allocator, which analysing it does.
    std.testing.refAllDecls(@This());
}
