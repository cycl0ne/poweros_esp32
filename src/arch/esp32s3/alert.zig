// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this CPU, which the kernel installs as
//! `exec.alert_hook`: the Guru Meditation on exec's raw port (kprintf),
//! which is where a machine that has stopped is read from - it needs
//! nothing that may have broken, no display and no library. It names the
//! code the address is in - the ROM, or a file loaded from disk and the
//! offset into it, which is the address in that program's ELF - and
//! prints the alert's text. A CPU exception adds its cause and the trap
//! frame. Dead-end alerts mask interrupts and halt the core.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const DosBase = @import("../../rom/libs/dos/dos_base.zig").DosBase;
const segment = @import("../../rom/libs/dos/program/_program.zig");
const layout = @import("layout.zig");
const sdk = @import("sdk");
const trap = @import("trap.zig");

pub fn show(alert_num: u32, return_address: usize, info: ?*const exec.TrapInfo, text: ?[*:0]const u8) void {
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
    if (text) |line| exec.kprintf("*** %.96s\n", .{line});
    place(where);
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

/// Names the code `where` is in: the ROM, a file loaded from disk with the
/// offset into it, or nothing known. dos's list of loaded files is read as
/// it stands, without a lock: the machine may have stopped anywhere.
fn place(where: usize) void {
    if ((where >= layout.flashTextStart() and where < layout.flashTextEnd()) or
        (where >= layout.iramStart() and where < layout.iramEnd()))
    {
        exec.kprintf("*** in the ROM\n", .{});
        return;
    }
    if (!exec.initialized) return;
    const dos_base = findDos() orelse return;
    if (segment.codeAt(dos_base, where)) |found| {
        exec.kprintf("*** in %.40s at +0x%x\n", .{ found.name, @as(u32, @truncate(found.offset)) });
    }
}

/// dos.library's base, from exec's library list, walked by hand: the path
/// that reports a broken machine calls nothing replaceable.
fn findDos() ?*DosBase {
    var node = exec.SysBase.lib_list.first();
    while (node) |library| : (node = library.next()) {
        const name = library.name orelse continue;
        if (std.mem.eql(u8, std.mem.span(name), "dos.library")) {
            const lib: *exec.Library = @fieldParentPtr("node", library);
            return @fieldParentPtr("lib", lib);
        }
    }
    return null;
}
