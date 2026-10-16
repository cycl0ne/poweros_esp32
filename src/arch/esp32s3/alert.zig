// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this CPU, which the kernel installs as
//! `exec.alert_hook`: the Guru Meditation on exec's raw port (kprintf),
//! which is where a machine that has stopped is read from - it needs
//! nothing that may have broken, no display and no library. It names the
//! code the address is in - the ROM, or a file loaded from disk and the
//! offset into it, which is the address in that program's ELF - and
//! prints the alert's text. A CPU exception adds its cause and the trap
//! frame. A dead-end alert of a task that may be held is handed to exec's
//! Software Failure (`exec.failure`): the task is held and asked about on
//! the display - Suspend, Kill or Reboot - and the machine runs on. Any
//! other dead end keeps the end of the system log in RTC memory
//! (lastwords.zig), offers the ROM debugger for a few seconds and, if
//! nobody answers, restarts the machine, whose next boot shows those last
//! words at the head of its log. A recoverable alert is shown on the
//! display as well.
//!
//! Every line of an alert goes out, whatever level the log keeps.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const DosBase = @import("../../rom/libs/dos/dos_base.zig").DosBase;
const segment = @import("../../rom/libs/dos/program/_program.zig");
const layout = @import("layout.zig");
const sdk = @import("sdk");
const trap = @import("trap.zig");
const rawio = @import("../../rom/libs/exec/rawio/_rawio.zig");
const debug = @import("../../rom/libs/exec/debug/_debug.zig");
const debugexc = @import("debugexc.zig");
const lastwords = @import("lastwords.zig");
const rendezvous = @import("rendezvous.zig");

/// The chip's part of the ROM debugger: everything in it that needs an
/// instruction or knows this chip's map. exec may not reach in here, so
/// it is handed over instead, as the alert hook is.
pub const debug_hardware: debug.DebugHardware = .{
    .stop = stopHere,
    .go = goOn,
    .halt = cpu.halt,
    .reboot = rebootHere,
    .keepLastWords = lastwords.save,
    .showFrame = showFrameHere,
    .frameAt = frameAtHere,
    .whereIs = whereIsHere,
    .readable = readableHere,
    .setBreakpoint = debugexc.setBreakpoint,
    .breakpointAt = debugexc.breakpointAt,
    .setWatchpoint = debugexc.setWatchpoint,
    .step = debugexc.step,
    .resumeFrom = debugexc.resumeFrom,
    .clearAll = debugexc.clearAll,
    .breakpoints = debugexc.breakpoints,
    .watchpoints = debugexc.watchpoints,
    .causeName = debugexc.causeName,
};

/// The debugger has the machine: this core's interrupts masked, and the
/// other core held still - unless it does not answer, being stuck itself.
fn stopHere() u32 {
    const saved = cpu.setIntlevel(15);
    _ = rendezvous.holdOtherWithin(hold_spins);
    return saved;
}

fn goOn(saved: u32) void {
    rendezvous.releaseOther();
    cpu.restorePs(saved);
}

/// How long a failing machine waits for the other core to park: some tens
/// of milliseconds.
const hold_spins: u32 = 4_000_000;

fn rebootHere() void {
    exec.SysBase.iface().ColdReboot();
}

fn showFrameHere(frame: *const anyopaque, put: sdk.exec.PutChProc, data: ?*anyopaque) void {
    trap.dumpFrameTo(@ptrCast(@alignCast(frame)), put, data);
}

/// Where the stopped code was: its pc, its stack pointer, and the return
/// address in a0 - which carries the window's call size in its top two
/// bits.
fn frameAtHere(frame: *const anyopaque, pc: *usize, sp: *usize, ret: *usize) void {
    const f: *const trap.Frame = @ptrCast(@alignCast(frame));
    pc.* = f.pc;
    sp.* = f.a[1];
    ret.* = f.a[0];
}

fn whereIsHere(address: usize, offset: *usize) ?[*:0]const u8 {
    const found = whereIs(address);
    if (!found.known) return null;
    offset.* = found.offset;
    return found.name;
}

/// Whether an address can be read at all, by the chip's windows rather
/// than by the kernel's layout: a stack above the heap and a buffer a
/// driver was given are both readable, and the debugger is asked about
/// them exactly when the lists that would say so are not to be trusted.
fn readableHere(address: usize) bool {
    const map = sdk.hardware.map;
    if (address >= map.DRAM_START and address < map.DRAM_END) return true;
    if (address >= map.IRAM_START and address < map.IRAM_END) return true;
    if (address >= map.PSRAM_START and address < map.PSRAM_END) return true;
    if (address >= map.FLASH_START and address < map.FLASH_END) return true;
    return false;
}

pub fn show(alert_num: u32, return_address: usize, info: ?*const exec.TrapInfo, text: ?[*:0]const u8) void {
    const dead_end = alert_num & exec.AT_DeadEnd != 0;
    // For Alert() calls `where` is a return address, whose top two bits hold
    // the windowed-ABI call size; all code runs at 0x4xxx_xxxx here. A CPU
    // exception's pc is exact.
    const where = if (info == null) (return_address & 0x3FFF_FFFF) | 0x4000_0000 else return_address;
    // A task that failed where it may wait is asked about on the display,
    // and the machine runs on; anything else stops it.
    const asking = dead_end and exec.failure.canAsk(exec.SysBase, info != null);
    // A dead end stops the machine: the other core is held still too, so
    // what is printed is what was.
    if (dead_end and !asking) {
        _ = cpu.setIntlevel(15);
        _ = rendezvous.holdOtherWithin(hold_spins);
    }

    // An alert is copied to the chip's own USB port as well as the raw
    // one: both boards' console is that port, and what a Guru says is
    // the one thing worth reading on a board with a single cable. And it
    // is written whatever level the log keeps.
    rawio.mirror = &rawio.usb_jtag_raw_io;
    rawio.unfiltered = true;

    const title: [:0]const u8 = if (dead_end) "Software Failure." else "Recoverable Alert.";
    var buf: [40]u8 = undefined;
    const stream = sdk.exec.fmtStream(.{ alert_num, @as(u32, @truncate(where)) });
    _ = exec.format("Guru Meditation #%08x.%08x", &stream, null, &buf);
    const guru = std.mem.span(@as([*:0]const u8, @ptrCast(&buf)));
    exec.kprintf("\n*** %s\n*** %s\n", .{ title, guru });
    if (text) |line| exec.kprintf("*** %.96s\n", .{line});
    place(where);
    if (exec.initialized) {
        const task = exec.SysBase.cpu().this_task;
        exec.kprintf("*** Task \"%s\" at 0x%08x\n", .{ task.name(), @intFromPtr(task) });
    }
    if (info) |i| {
        exec.kprintf("*** CPU exception %d (%s) at 0x%08x, address 0x%08x\n", .{ i.number, trap.causeName(i.number), i.pc, i.address });
        if (i.frame) |frame| trap.dumpFrame(@ptrCast(@alignCast(frame)));
    }

    if (!dead_end) {
        endAlertOutput();
        if (info == null) exec.failure.displayRecoverable(exec.SysBase, alert_num, guru, text);
        return;
    }
    if (asking) {
        // Held: a CPU exception's task comes back here and the exception's
        // exit switches to the next task; a task that called Alert does
        // not come back.
        endAlertOutput();
        var detail: [100]u8 = @splat(0);
        exec.failure.hold(exec.SysBase, alert_num, guru, describe(text, info, &detail), info != null);
        return;
    }
    // The log's end kept over the reset, then the debugger offered before
    // the machine is given up: an unattended board waits a few seconds and
    // restarts, and its next boot shows what this one ended with. Left
    // from the debugger, it stays stopped.
    lastwords.save();
    if (debug.offer()) {
        debug.enter(.dead_end, if (info) |i| @ptrCast(@alignCast(i.frame)) else null, 0);
        exec.kprintf("*** system halted\n", .{});
        cpu.halt();
    }
    exec.kprintf("*** restarting\n", .{});
    restart();
}

/// An alert's output over: the USB console's copy and the log's level as
/// the log's settings say again.
fn endAlertOutput() void {
    rawio.unfiltered = false;
    rawio.setMirror();
}

/// The software system reset, straight to the register: exec may be what
/// broke. RTC memory, and the last words in it, survive it.
fn restart() noreturn {
    const hardware = sdk.hardware;
    hardware.system.core1Off();
    hardware.mmio.reg(hardware.rtc_cntl.OPTIONS0).* |= hardware.rtc_cntl.OPTIONS0_SW_SYS_RST;
    while (true) {}
}

/// What went wrong in words, for the Software Failure requester: the
/// alert's text, or a CPU exception's cause and the address it named.
fn describe(text: ?[*:0]const u8, info: ?*const exec.TrapInfo, into: *[100]u8) []const u8 {
    if (text) |line| return std.mem.span(line);
    const trap_info = info orelse return "";
    const stream = sdk.exec.fmtStream(.{ trap.causeName(trap_info.number).ptr, @as(u32, @truncate(trap_info.address)) });
    _ = exec.format("%s at 0x%08x", &stream, null, into);
    return std.mem.sliceTo(into, 0);
}

/// Where an address is, for whoever wants to print it: the ROM, a file
/// loaded from disk and the offset into it, or nothing known.
pub const Where = struct {
    /// The ROM, or the file's name.
    name: ?[*:0]const u8 = null,
    /// How far into that file, 0 for the ROM.
    offset: usize = 0,
    /// Whether the address is in code at all.
    known: bool = false,
};

/// What code an address is in. dos's list of loaded files is read as it
/// stands, without a lock: the machine may have stopped anywhere.
pub fn whereIs(where: usize) Where {
    if ((where >= layout.flashTextStart() and where < layout.flashTextEnd()) or
        (where >= layout.iramStart() and where < layout.iramEnd()))
    {
        return .{ .name = "the ROM", .known = true };
    }
    if (!exec.initialized) return .{};
    const dos_base = findDos() orelse return .{};
    if (segment.codeAt(dos_base, where)) |found| {
        return .{ .name = found.name, .offset = found.offset, .known = true };
    }
    return .{};
}

/// The line a Guru prints for where it stopped.
fn place(where: usize) void {
    const found = whereIs(where);
    if (!found.known) return;
    if (found.offset == 0) {
        exec.kprintf("*** in %s\n", .{found.name.?});
    } else {
        exec.kprintf("*** in %.40s at +0x%x\n", .{ found.name.?, @as(u32, @truncate(found.offset)) });
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
