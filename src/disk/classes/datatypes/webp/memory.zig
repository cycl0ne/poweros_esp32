// SPDX-License-Identifier: MIT
//! The decoder's memory (`decode.Env`) from AllocVec, on the 16 bytes it
//! asks for: AllocVec's blocks are on 16 on the 64-bit machines; on the
//! others one is asked for 16 bytes larger, and the block's own start
//! kept in front of what is handed out.

const sdk = @import("sdk");
const exec = sdk.exec;
const decode = @import("decode.zig");
const ExecBase = sdk.interface.exec.ExecBase;

const direct = exec.MEM_BLOCKSIZE >= 16;

/// Memory for the decoder from `sys`.
pub fn envOf(sys: *ExecBase) decode.Env {
    return .{ .ctx = @ptrCast(sys), .alloc = alloc, .free = free };
}

fn alloc(ctx: *anyopaque, len: usize, clear: bool) ?[*]u8 {
    const sys: *ExecBase = @ptrCast(@alignCast(ctx));
    const flags = exec.MEMF_ANY | (if (clear) exec.MEMF_CLEAR else 0);
    if (direct) return @ptrCast(sys.AllocVec(len, flags) orelse return null);
    const block = sys.AllocVec(len + 16, flags) orelse return null;
    const at = (@intFromPtr(block) + 16) & ~@as(usize, 15);
    @as(*usize, @ptrFromInt(at - @sizeOf(usize))).* = @intFromPtr(block);
    return @ptrFromInt(at);
}

fn free(ctx: *anyopaque, memory: [*]u8, _: usize) void {
    const sys: *ExecBase = @ptrCast(@alignCast(ctx));
    if (direct) return sys.FreeVec(memory);
    const block = @as(*const usize, @ptrFromInt(@intFromPtr(memory) - @sizeOf(usize))).*;
    sys.FreeVec(@ptrFromInt(block));
}
