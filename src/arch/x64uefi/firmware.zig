// SPDX-License-Identifier: MPL-2.0
//! What the firmware can still do once it has handed the machine over.
//!
//! A UEFI firmware leaves half of itself in memory for the system that
//! comes after it - its runtime half - and keeps that half's code and
//! data out of the memory it offers, so it goes on working as long as
//! nobody moves it. Two of its calls are wanted here, and both are one
//! call of the firmware's with a different number: the machine restarted,
//! which the firmware does better than the chipset's reset register
//! because it puts its own hardware back as it expects to find it; and
//! the machine turned off, which nothing else here can do at all. What a
//! machine of this architecture is written to in order to be off is
//! described in the firmware's tables, in the language this system does
//! not interpret - the firmware wrote that description and knows what is
//! in it.
//!
//! The two tables this needs are read field by field at their fixed
//! offsets, as the firmware's description tables are (`sdk/hardware/acpi.zig`):
//! it is two pointers, read once as the kernel starts.
//!
//! **The call is the firmware's, not this architecture's.** Its arguments
//! go in the registers the firmware's own convention names, which is not
//! the one everything else here is compiled for, so the pointer carries
//! that convention. Interrupts are off while it runs, since what it
//! touches is the firmware's and this kernel's handlers know nothing of
//! it, and they are on again afterwards for the one case where the call
//! comes back: a firmware that would not do what was asked.

const cpu = @import("cpu.zig");
const sdk = @import("sdk");
const system = sdk.hardware.system;

/// The system table's runtime half, and that half's reset call, by their
/// offsets. Both tables start with the same 24-byte header.
const SYSTEM_TABLE_RUNTIME = 88;
const RUNTIME_RESET = 104;

/// What a reset is asked to be: the machine started again from cold, or
/// the machine off.
const RESET_COLD: u32 = 0;
const RESET_OFF: u32 = 2;

/// The firmware's call: what to do, what to say it was for, and a reason
/// in words, which nothing here gives.
const ResetFn = *const fn (kind: u32, status: usize, bytes: usize, reason: ?*const anyopaque) callconv(.{ .x86_64_win = .{} }) void;

/// The call itself, once the system table has been read.
var reset_system: ?ResetFn = null;

/// The firmware's calls taken out of the system table the stub handed
/// over, and given to the SDK, where exec's restart and power.resource
/// find them. Nothing happens on a machine that handed over no system
/// table, and then the chipset's reset register is all there is.
pub fn take(system_table: usize) void {
    if (system_table == 0) return;
    const runtime = quadAt(system_table + SYSTEM_TABLE_RUNTIME);
    if (runtime == 0) return;
    const reset = quadAt(runtime + RUNTIME_RESET);
    if (reset == 0) return;
    reset_system = @ptrFromInt(reset);
    system.firmware_reset = &resetMachine;
    system.firmware_off = &powerOff;
}

/// The machine restarted by the firmware. It returns where the firmware
/// did not do it, and the caller then has the chipset's register left.
fn resetMachine() void {
    call(RESET_COLD);
}

/// The machine turned off by the firmware, which returns only where it
/// was not.
fn powerOff() void {
    call(RESET_OFF);
}

fn call(kind: u32) void {
    const reset = reset_system orelse return;
    const state = cpu.disableInterrupts();
    reset(kind, 0, 0, null);
    cpu.restoreInterrupts(state);
}

fn quadAt(at: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(at)).*;
}
