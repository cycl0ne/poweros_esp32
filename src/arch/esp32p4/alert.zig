// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this chip, which the kernel installs as
//! `exec.alert_hook`: the Guru Meditation on exec's raw port (kprintf),
//! which is where a machine that has stopped is read from - it needs
//! nothing that may have broken. It prints the alert's numbers and text,
//! the task that raised it, and for a CPU exception its cause and the trap
//! frame. A dead end holds the other core still, keeps the end of the
//! system log in LP RAM (lastwords.zig) and restarts the machine a few
//! seconds later, whose next boot shows those last words at the head of
//! its log; a recoverable alert is printed and the machine runs on.
//!
//! Every line of an alert goes out, whatever level the log keeps.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const sdk = @import("sdk");
const trap = @import("trap.zig");
const rawio = @import("../../rom/libs/exec/rawio/_rawio.zig");
const rendezvous = @import("rendezvous.zig");
const lastwords = @import("lastwords.zig");
const systimer = @import("sdk").hardware.systimer;

/// How long a failing machine waits for the other core to park: some tens
/// of milliseconds.
const hold_spins: u32 = 4_000_000;

pub fn show(alert_num: u32, where: usize, info: ?*const exec.TrapInfo, text: ?[*:0]const u8) void {
    const dead_end = alert_num & exec.AT_DeadEnd != 0;
    // A dead end stops the machine: the other core is held still too, so
    // what is printed is what was.
    if (dead_end) {
        _ = cpu.disableInterrupts();
        _ = rendezvous.holdOtherWithin(hold_spins);
    }
    rawio.unfiltered = true;
    defer rawio.unfiltered = false;

    const title: [*:0]const u8 = if (dead_end) "Software Failure." else "Recoverable Alert.";
    exec.kprintf("\n*** %s\n*** Guru Meditation #%08x.%08x\n", .{ title, alert_num, @as(u32, @truncate(where)) });
    if (text) |line| exec.kprintf("*** %.96s\n", .{line});
    if (exec.initialized) {
        const task = exec.SysBase.cpu().this_task;
        exec.kprintf("*** Task \"%s\" at 0x%08x on core %d\n", .{ task.name(), @intFromPtr(task), cpu.coreId() });
    }
    if (info) |trap_info| {
        exec.kprintf("*** CPU exception %d (%s) at 0x%08x, address 0x%08x\n", .{
            trap_info.number,
            trap.causeName(trap_info.number).ptr,
            trap_info.pc,
            trap_info.address,
        });
        if (trap_info.frame) |frame| trap.dumpFrame(@ptrCast(@alignCast(frame)));
    }
    if (!dead_end) return;
    lastwords.save();
    exec.kprintf("*** restarting in %d seconds\n", .{restart_seconds});
    systimer.spinUs(restart_seconds * 1_000_000);
    sdk.hardware.system.resetChip();
}

/// How long a dead end stays on the console before the machine restarts.
const restart_seconds = 5;
