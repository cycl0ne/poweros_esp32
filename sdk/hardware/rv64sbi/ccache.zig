// SPDX-License-Identifier: MIT
//! SiFive's L2 cache controller, as the JH7110 has it: the machine's
//! devices reach RAM past the U74s' caches, so what a core has written
//! for a device is not seen by it until it is out of them. A line's
//! address written to the controller's Flush64 register writes the line
//! back if it is dirty and drops it, from the L2 and from the cores'
//! own caches above it. exec's cache calls (CacheClearE, CachePreDMA,
//! CachePostDMA) come here.

/// The Flush64 register, which the kernel sets from the board
/// (SYSTAG_CacheFlush); 0 on a machine whose devices see the caches, and
/// then nothing is done.
pub var flush64: usize = 0;

/// The line the controller works in.
pub const line_size = 64;

/// Every line of [addr, addr + size) written back and dropped.
pub fn flush(addr: usize, size: usize) void {
    const register = flush64;
    if (register == 0 or size == 0) return;
    const cell: *volatile u64 = @ptrFromInt(register);
    var line = addr & ~@as(usize, line_size - 1);
    // The stores before are done before the first line is flushed, and
    // each flush before the next: the controller takes one at a time.
    asm volatile ("fence rw, o" ::: .{ .memory = true });
    while (line < addr + size) : (line += line_size) {
        cell.* = line;
        asm volatile ("fence o, rw" ::: .{ .memory = true });
    }
}
