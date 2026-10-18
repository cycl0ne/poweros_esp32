// SPDX-License-Identifier: MPL-2.0
//! The kernel's memcpy, memmove and memset: what the compiler calls for
//! every `@memcpy`, `@memmove`, `@memset` and struct copy it does not do
//! inline. They are exec's loops (words.zig). compiler_rt's are weak, so
//! these take the names from them.
//!
//! A kernel root imports this file, and nothing else does: the host's
//! tests keep the host's own.

const words = @import("words.zig");

comptime {
    @export(&memcpy, .{ .name = "memcpy" });
    @export(&memmove, .{ .name = "memmove" });
    @export(&memset, .{ .name = "memset" });
}

fn memcpy(noalias dest: ?[*]u8, noalias source: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len != 0) words.forward(dest.?, source.?, len);
    return dest;
}

fn memmove(dest: ?[*]u8, source: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len != 0) words.move(dest.?, source.?, len);
    return dest;
}

fn memset(dest: ?[*]u8, value: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len != 0) words.fill(dest.?, @truncate(@as(c_uint, @bitCast(value))), len);
    return dest;
}
