// SPDX-License-Identifier: MPL-2.0
//! C:test/Gpu's kernel for the graphics block's compute engine, built for
//! it by the build's own compiler (`poweros_sdk.addGPUCode`) and embedded
//! in the command as its code object.
//!
//! `fill` writes `value + i` into word `i` of `out` for each `i` below
//! `count`, a thread a word: it is dispatched in groups of 64 threads,
//! and each group writes the 64 words from its own number times 64 on.
//! Its arguments are the buffer's address, the value and the count - 16
//! bytes, handed to it by address in its first two scalar registers.

export fn fill(out: [*]addrspace(.global) u32, value: u32, count: u32) callconv(.kernel) void {
    const index = @workGroupId(0) *% 64 +% @workItemId(0);
    if (index < count) out[index] = value +% index;
}
