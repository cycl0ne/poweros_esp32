// SPDX-License-Identifier: MIT
//! A program's memcpy, memmove and memset - what the compiler calls for
//! its `@memcpy`, `@memmove`, `@memset` and the struct copies it does not
//! do inline - are exec's `CopyMem` and `SetMem`, through the jump table.
//! A program is built once for every board of a chip, the kernel for each
//! board: exec's loops are the ones for the board's CPU, and a word at a
//! time where compiler_rt's would go a byte at a time (a RISC-V core
//! without fast misaligned access). `sdk/program.zig` exports them,
//! unless the program has memory calls of its own (`own_memory_calls`).
//!
//! Less than two words is copied or filled here, a byte at a time as exec
//! would: the call would take longer than the bytes. A C call is handed
//! no base, so SysBase comes from `AbsExecBase`.

const exec = @import("exec.zig");

/// From this many bytes on, exec's loops.
const call_least = 2 * @sizeOf(usize);

fn sysBase() *exec.ExecBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    return cell.*;
}

pub fn memcpy(noalias dest: ?[*]u8, noalias source: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len >= call_least) {
        sysBase().CopyMem(source.?, dest.?, len);
    } else if (len != 0) {
        bytesUp(dest.?, source.?, len);
    }
    return dest;
}

pub fn memmove(dest: ?[*]u8, source: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len >= call_least) {
        sysBase().CopyMem(source.?, dest.?, len);
    } else if (len != 0) {
        // dest at or below source, or past its end: from the first byte up.
        if (@intFromPtr(dest) -% @intFromPtr(source) >= len)
            bytesUp(dest.?, source.?, len)
        else
            bytesDown(dest.?, source.?, len);
    }
    return dest;
}

pub fn memset(dest: ?[*]u8, value: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    if (len >= call_least) {
        sysBase().SetMem(dest.?, byte, len);
    } else {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            barrier();
            dest.?[i] = byte;
        }
    }
    return dest;
}

inline fn bytesUp(dest: [*]u8, source: [*]const u8, len: usize) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        barrier();
        dest[i] = source[i];
    }
}

inline fn bytesDown(dest: [*]u8, source: [*]const u8, len: usize) void {
    @setRuntimeSafety(false);
    var i = len;
    while (i != 0) {
        barrier();
        i -= 1;
        dest[i] = source[i];
    }
}

/// Keeps LLVM from taking the loop it is in for a copy or a fill, and
/// making it a call of the function the loop is in.
inline fn barrier() void {
    asm volatile ("" ::: .{ .memory = true });
}
