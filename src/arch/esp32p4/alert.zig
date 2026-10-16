// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this chip, which the kernel installs as
//! `exec.alert_hook`, and the chip's part of the ROM debugger
//! (`debug_hardware`).
//!
//! The Guru Meditation goes out on exec's raw port (kprintf), which is
//! where a machine that has stopped is read from - it needs nothing that
//! may have broken. It prints the alert's numbers and text, the code the
//! address is in - the ROM, or a file loaded from disk and the offset into
//! it, which is the address in that program's ELF - the task that raised
//! it, and for a CPU exception its cause, the trap frame and the call
//! chain by frame pointers, each return address named the same way. The
//! ROM debugger names addresses with it too. A dead-end alert of a task
//! that may be held is handed to exec's Software Failure
//! (`exec.failure`): the task is held and asked about on the display -
//! Suspend, Kill or Reboot - and the machine runs on. Any other dead end
//! holds the other core still, keeps the end of the system log in LP RAM
//! (lastwords.zig), offers the ROM debugger for a few seconds and, if
//! nobody answers, restarts the machine, whose next boot shows those last
//! words at the head of its log. A recoverable alert is printed and shown
//! on the display as well, and the machine runs on.
//!
//! Every line of an alert goes out, whatever level the log keeps.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const DosBase = @import("../../rom/libs/dos/dos_base.zig").DosBase;
const segment = @import("../../rom/libs/dos/program/_program.zig");
const sdk = @import("sdk");
const trap = @import("trap.zig");
const rawio = @import("../../rom/libs/exec/rawio/_rawio.zig");
const debug = @import("../../rom/libs/exec/debug/_debug.zig");
const debugexc = @import("debugexc.zig");
const rendezvous = @import("rendezvous.zig");
const lastwords = @import("lastwords.zig");
const layout = @import("layout.zig");
const systimer = sdk.hardware.systimer;

/// How long a failing machine waits for the other core to park: some tens
/// of milliseconds.
const hold_spins: u32 = 4_000_000;

/// The chip's part of the ROM debugger: everything in it that needs an
/// instruction or knows this chip's map.
pub const debug_hardware: debug.DebugHardware = .{
    .stop = stopHere,
    .go = goOn,
    .halt = cpu.halt,
    .reboot = rebootHere,
    .keepLastWords = lastwords.save,
    .showFrame = showFrameHere,
    .frameAt = frameAtHere,
    .framePointerAt = framePointerAtHere,
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
    const saved = cpu.disableInterrupts();
    _ = rendezvous.holdOtherWithin(hold_spins);
    return saved;
}

fn goOn(saved: u32) void {
    rendezvous.releaseOther();
    cpu.restoreInterrupts(saved);
}

fn rebootHere() void {
    sdk.hardware.system.resetChip();
}

fn showFrameHere(frame: *const anyopaque, put: sdk.exec.PutChProc, data: ?*anyopaque) void {
    trap.dumpFrameTo(@ptrCast(@alignCast(frame)), put, data);
}

/// Where the stopped code was: its pc, its stack pointer, its return
/// address.
fn frameAtHere(frame: *const anyopaque, pc: *usize, sp: *usize, ret: *usize) void {
    const f: *const trap.Frame = @ptrCast(@alignCast(frame));
    pc.* = f.mepc;
    sp.* = f.x[2];
    ret.* = f.x[1];
}

/// The stopped code's frame pointer (s0), where its call chain starts.
fn framePointerAtHere(frame: *const anyopaque) usize {
    const f: *const trap.Frame = @ptrCast(@alignCast(frame));
    return f.x[8];
}

fn whereIsHere(address: usize, offset: *usize) ?[*:0]const u8 {
    const found = whereIs(address);
    if (!found.known) return null;
    offset.* = found.offset;
    return found.name;
}

/// Whether an address can be read at all, by the chip's windows rather
/// than by the kernel's layout.
fn readableHere(address: usize) bool {
    const map = sdk.hardware.map;
    if (address >= map.DRAM_START and address < map.DRAM_END) return true;
    if (address >= map.PSRAM_START and address < map.PSRAM_END) return true;
    if (address >= map.FLASH_START and address < map.FLASH_END) return true;
    if (address >= map.ROM_START and address < map.ROM_END) return true;
    return false;
}

pub fn show(alert_num: u32, where: usize, info: ?*const exec.TrapInfo, text: ?[*:0]const u8) void {
    const dead_end = alert_num & exec.AT_DeadEnd != 0;
    // A task that failed where it may wait is asked about on the display,
    // and the machine runs on; anything else stops it. A trap with no
    // frame - one on a stack with no room - has nothing to hold the task
    // at.
    const resumable = if (info) |trap_info| trap_info.frame != null else true;
    const asking = dead_end and resumable and exec.failure.canAsk(exec.SysBase, info != null);
    // A dead end stops the machine: the other core is held still too, so
    // what is printed is what was.
    if (dead_end and !asking) {
        _ = cpu.disableInterrupts();
        _ = rendezvous.holdOtherWithin(hold_spins);
    }
    rawio.unfiltered = true;

    const title: [*:0]const u8 = if (dead_end) "Software Failure." else "Recoverable Alert.";
    var buf: [40]u8 = @splat(0);
    const stream = sdk.exec.fmtStream(.{ alert_num, @as(u32, @truncate(where)) });
    _ = exec.format("Guru Meditation #%08x.%08x", &stream, null, &buf);
    const guru = untilNul(&buf);
    exec.kprintf("\n*** %s\n*** %s\n", .{ title, @as([*:0]const u8, @ptrCast(&buf)) });
    if (text) |line| exec.kprintf("*** %.96s\n", .{line});
    place(where);
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
        if (trap_info.frame) |frame| {
            const f: *const trap.Frame = @ptrCast(@alignCast(frame));
            trap.dumpFrame(f);
            callChain(f.x[8]);
        }
    }
    if (!dead_end) {
        rawio.unfiltered = false;
        if (info == null) exec.failure.displayRecoverable(exec.SysBase, alert_num, guru, text);
        return;
    }
    if (asking) {
        // Held: a CPU exception's task comes back here and the exception's
        // exit switches to the next task; a task that called Alert does
        // not come back.
        rawio.unfiltered = false;
        var detail: [100]u8 = @splat(0);
        exec.failure.hold(exec.SysBase, alert_num, guru, describe(text, info, &detail), info != null);
        return;
    }
    lastwords.save();
    if (debug.offer()) {
        debug.enter(.dead_end, if (info) |trap_info| trap_info.frame else null, 0);
        exec.kprintf("*** system halted\n", .{});
        cpu.halt();
    }
    exec.kprintf("*** restarting\n", .{});
    sdk.hardware.system.resetChip();
}

/// What went wrong in words, for the Software Failure requester: the
/// alert's text, or a CPU exception's cause and the address it named.
fn describe(text: ?[*:0]const u8, info: ?*const exec.TrapInfo, into: *[100]u8) []const u8 {
    if (text) |line| {
        var length: usize = 0;
        while (line[length] != 0) length += 1;
        return line[0..length];
    }
    const trap_info = info orelse return "";
    const stream = sdk.exec.fmtStream(.{ trap.causeName(trap_info.number).ptr, @as(u32, @truncate(trap_info.address)) });
    _ = exec.format("%s at 0x%08x", &stream, null, into);
    return untilNul(into);
}

/// A buffer `exec.format` wrote, up to its NUL.
fn untilNul(buffer: []const u8) []const u8 {
    var length: usize = 0;
    while (length < buffer.len and buffer[length] != 0) length += 1;
    return buffer[0..length];
}

/// The return addresses up the frame-pointer chain from `fp`, a line
/// each with the code it is in: each frame keeps its return address at
/// fp - 4 and the frame before at fp - 8. The chain ends at an address
/// in no code.
fn callChain(start: usize) void {
    var fp = start;
    var depth: u32 = 0;
    exec.kprintf("*** called from:\n", .{});
    while (depth < 12) : (depth += 1) {
        if (fp & 3 != 0 or !readableHere(fp -% 8) or !readableHere(fp -% 4)) break;
        const ret = @as(*const volatile u32, @ptrFromInt(fp - 4)).*;
        const next = @as(*const volatile u32, @ptrFromInt(fp - 8)).*;
        if (ret == 0) break;
        const found = whereIs(ret);
        if (!found.known) break;
        if (found.offset == 0) {
            exec.kprintf("***   0x%08x in %s\n", .{ ret, found.name.? });
        } else {
            exec.kprintf("***   0x%08x in %.40s at +0x%x\n", .{ ret, found.name.?, @as(u32, @truncate(found.offset)) });
        }
        if (next <= fp) break;
        fp = next;
    }
}

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
    if (layout.inKernel(where)) return .{ .name = "the ROM", .known = true };
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
        if (sameName(name, "dos.library")) {
            const lib: *exec.Library = @fieldParentPtr("node", library);
            return @fieldParentPtr("lib", lib);
        }
    }
    return null;
}

fn sameName(name: [*:0]const u8, wanted: [:0]const u8) bool {
    for (wanted, 0..) |char, index| {
        if (name[index] != char) return false;
    }
    return name[wanted.len] == 0;
}
