// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this CPU, which the kernel installs as
//! `exec.alert_hook`: the Guru Meditation on exec's raw port (kprintf),
//! which is where a machine that has stopped is read from - it needs
//! nothing that may have broken, no display and no library. A CPU
//! exception adds its cause and the trap frame. Dead-end alerts mask
//! interrupts and halt the core.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const sdk = @import("sdk");
const trap = @import("trap.zig");

pub fn show(alert_num: u32, return_address: usize, info: ?*const exec.TrapInfo) void {
    const dead_end = alert_num & exec.AT_DeadEnd != 0;
    // For Alert() calls `where` is a return address, whose top two bits hold
    // the windowed-ABI call size; all code runs at 0x4xxx_xxxx here. A CPU
    // exception's pc is exact.
    const where = if (info == null) (return_address & 0x3FFF_FFFF) | 0x4000_0000 else return_address;
    if (dead_end) _ = cpu.setIntlevel(15);

    const title: [:0]const u8 = if (dead_end) "Software Failure." else "Recoverable Alert.";
    var buf: [40]u8 = undefined;
    const stream = sdk.exec.fmtStream(.{ alert_num, @as(u32, @truncate(where)) });
    _ = exec.format("Guru Meditation #%08x.%08x", &stream, null, &buf);
    const guru = std.mem.span(@as([*:0]const u8, @ptrCast(&buf)));
    exec.kprintf("\n*** %s\n*** %s\n", .{ title, guru });
    if (exec.initialized) {
        const task = exec.SysBase.this_task;
        exec.kprintf("*** Task \"%s\" at 0x%08x\n", .{ task.name(), @intFromPtr(task) });
    }
    if (info) |i| {
        exec.kprintf("*** CPU exception %d (%s) at 0x%08x, address 0x%08x\n", .{ i.number, trap.causeName(i.number), i.pc, i.address });
        if (i.frame) |frame| trap.dumpFrame(@ptrCast(@alignCast(frame)));
    }

    if (dead_end) {
        exec.kprintf("*** system halted\n", .{});
        cpu.halt();
    }
}
