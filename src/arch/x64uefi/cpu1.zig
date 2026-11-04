// SPDX-License-Identifier: MPL-2.0
//! The other cores. The kernel runs on the boot core alone for now: this
//! file is what the rest of the system asks about them, and it answers
//! that there is one.
//!
//! **Why they are not started yet.** On the other two 64-bit machines the
//! firmware starts a core: one call with the core's id and the address to
//! enter, and the core comes up in the same state the boot core is in. This
//! architecture has no such call. A core is started by its own interrupt
//! controller - an INIT, then a start-up message naming a page below the
//! first mebibyte - and it comes up as the machine's oldest processor did,
//! in sixteen-bit real mode, so what it enters is a piece of code that puts
//! it through the two mode changes the boot firmware already did for the
//! boot core, on a page of memory the kernel has to keep below 1 MiB for
//! it. That is a piece of work of its own and it is the one the list calls
//! item 8; nothing above exec needs it, and exec runs on one core where
//! there is one.
//!
//! What the cores the firmware's tables name are is read all the same
//! (`takeCores`), so the machine can say what it has.

const cpu = @import("cpu.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");

const max_cores = exec_base.max_cores;

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// How many cores there are for it, the boot core's included
/// (`takeCores`): what the machine has, not what is running.
pub var found: u32 = 1;

/// Whether another core is running.
pub fn isUp() bool {
    return false;
}

/// The cores the firmware's tables name, the boot core left out, made
/// cores 1 on - as many as exec keeps state for. Their controller ids are
/// what starting one will want.
pub fn takeCores(ids: []const u32, boot: u32) void {
    for (ids) |id| {
        if (id == boot) continue;
        if (found == max_cores) break;
        cpu.lapic_ids[found] = id;
        found += 1;
    }
}

/// Core `core` started on the stack that ends at `stack_top`. There is no
/// way to start one yet, so this says so and nothing happens.
pub fn start(_: u32, _: usize) bool {
    return false;
}

/// Why a core did not start, for the boot's line.
pub fn answerName(_: i64) [*:0]const u8 {
    return "this kernel starts no second core yet";
}
