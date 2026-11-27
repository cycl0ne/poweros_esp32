// SPDX-License-Identifier: MPL-2.0
//! C:test/Gpu's kernels for the graphics block's compute engine, built
//! for it by the build's own compiler (`poweros_sdk.addGPUCode`) and
//! embedded in the command as its code object.
//!
//! `fill` writes `value + i` into word `i` of `out` for each `i` below
//! `count`, a thread a word: it is dispatched in groups of 64 threads,
//! and each group writes the 64 words from its own number times 64 on.
//! Its arguments are the buffer's address, the value and the count - 16
//! bytes, handed to it by address in its first two scalar registers.
//!
//! `spill` takes the same arguments and writes into word `i` a sum over a
//! table of 128 words each thread fills and reads at places it works out
//! from them, so that the table cannot be kept in registers and is kept
//! in the thread's private memory, the queue's scratch: entry
//! `(k * 5 + value) & 127` is `i + k`, and the word the sum of entry
//! `(k * 3 + i) & 127` times `k + 1` for each `k` below 128.
//!
//! `spin` reads the word at `flag` until it is not 0, which nothing
//! writes while COMPUTE RESET waits for it: a kernel that does not end,
//! for the queue's reset to give up.

export fn fill(out: [*]addrspace(.global) u32, value: u32, count: u32) callconv(.kernel) void {
    const index = @workGroupId(0) *% 64 +% @workItemId(0);
    if (index < count) out[index] = value +% index;
}

export fn spill(out: [*]addrspace(.global) u32, value: u32, count: u32) callconv(.kernel) void {
    const index = @workGroupId(0) *% 64 +% @workItemId(0);
    if (index >= count) return;
    var table: [128]u32 = undefined;
    for (0..128) |at| {
        const step: u32 = @intCast(at);
        table[(step *% 5 +% value) & 127] = index +% step;
    }
    var sum: u32 = 0;
    for (0..128) |at| {
        const step: u32 = @intCast(at);
        sum +%= table[(step *% 3 +% index) & 127] *% (step + 1);
    }
    out[index] = sum;
}

export fn spin(flag: *addrspace(.global) volatile u32) callconv(.kernel) void {
    while (flag.* == 0) {}
}
