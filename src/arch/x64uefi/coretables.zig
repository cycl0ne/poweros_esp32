// SPDX-License-Identifier: MPL-2.0
//! The cores' own tables: one block of RAM for all of them, taken before
//! exec is built.
//!
//! **How many cores there are is the machine's to say.** The firmware's
//! tables name them (`sdk/hardware/acpi.zig`), and that is any number at
//! all, so nothing here is an array of a fixed size: each piece of a
//! core's state - the word its dispatcher leaves behind, its trap state,
//! its timer, its task segment, its stack for a fault, its block - is laid
//! out here, one after another, for as many cores as were found.
//!
//! **Why it is taken rather than allocated.** Most of it is read before
//! exec exists: GS points at a core's block from the kernel's first
//! instruction, and an exception taken on the way to exec's init wants the
//! fault stack. So the block comes out of the memory map, which the kernel
//! has already read from the stub, and what is left of RAM goes to exec.
//! Nothing frees it: the machine's cores last as long as the machine.
//!
//! **Until it is taken** every module here keeps one core's worth of its
//! own, in .bss, and points at that. A machine whose RAM has no room for
//! the tables goes on running on that one core, which is what the boot's
//! line then says.

const ram = @import("ram.zig");
const cpu = @import("cpu.zig");
const cpu1 = @import("cpu1.zig");
const context = @import("context.zig");
const desc = @import("desc.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
const apic = @import("apic.zig");
const rendezvous = @import("rendezvous.zig");

/// A block being handed out piece by piece. The same layout is run twice:
/// once to count the bytes, with nowhere to put them, and once over the
/// RAM that was taken for that many.
pub const Bump = struct {
    /// Where the block is, or 0 while counting.
    at: usize = 0,
    /// How much of it has been handed out.
    used: usize = 0,

    /// Room for `count` of `T`, on `T`'s own boundary; null while
    /// counting, which is how a module knows to keep what it has.
    pub fn take(bump: *Bump, comptime T: type, count: usize) ?[*]T {
        const boundary: usize = @alignOf(T);
        bump.used = (bump.used + boundary - 1) & ~(boundary - 1);
        const offset = bump.used;
        bump.used += count * @sizeOf(T);
        if (bump.at == 0) return null;
        return @ptrFromInt(bump.at + offset);
    }
};

/// Every module's tables, in one order for both runs.
fn lay(bump: *Bump, count: u32) void {
    cpu.layTables(bump, count);
    cpu1.layTables(bump, count);
    context.layTables(bump, count);
    desc.layTables(bump, count);
    trap.layTables(bump, count);
    timer.layTables(bump, count);
    apic.layTables(bump, count);
    rendezvous.layTables(bump, count);
}

/// Tables for `count` cores. False where RAM has no room for them, which
/// leaves every module on the one core's worth it starts with.
///
/// INPUTS:
/// - `count` - how many the machine's tables named, core 0's included.
pub fn take(count: u32) bool {
    if (count < 2) return false;
    var counting: Bump = .{};
    lay(&counting, count);
    const at = ram.take(counting.used);
    if (at == 0) return false;
    const block: [*]u8 = @ptrFromInt(at);
    @memset(block[0..counting.used], 0);
    var over: Bump = .{ .at = at };
    lay(&over, count);
    cores = count;
    // What core 0 had in the one block of its own, and the descriptors it
    // is about to be given, now that there is a table with room for every
    // core's.
    cpu.useTables();
    desc.useTables();
    return true;
}

/// How many cores the tables hold, which is how many the kernel can run
/// on: what `take` was given, or 1 before it or where it found no room.
pub var cores: u32 = 1;
