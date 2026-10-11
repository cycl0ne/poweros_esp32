// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this chip, which the kernel installs as
//! `exec.alert_hook`, and the chip's part of the ROM debugger
//! (`debug_hardware`).
//!
//! The Guru Meditation goes out on exec's raw port (kprintf), which is
//! where a machine that has stopped is read from - it needs nothing that
//! may have broken. It prints the alert's numbers and text, where the
//! address is, the task that raised it, and for a CPU exception its cause,
//! the trap frame and the call chain by frame pointers. A dead end holds
//! the other core still, keeps the end of the system log in LP RAM
//! (lastwords.zig), offers the ROM debugger for a few seconds and, if
//! nobody answers, restarts the machine, whose next boot shows those last
//! words at the head of its log; a recoverable alert is printed and the
//! machine runs on.
//!
//! Every line of an alert goes out, whatever level the log keeps.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
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
    offset.* = 0;
    return if (layout.inKernel(address)) "the ROM" else null;
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
    if (layout.inKernel(where)) exec.kprintf("*** in the ROM\n", .{});
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
    if (!dead_end) return;
    lastwords.save();
    if (debug.offer()) {
        debug.enter(.dead_end, if (info) |trap_info| trap_info.frame else null, 0);
        exec.kprintf("*** system halted\n", .{});
        cpu.halt();
    }
    exec.kprintf("*** restarting\n", .{});
    sdk.hardware.system.resetChip();
}

/// The return addresses up the frame-pointer chain from `fp`: each frame
/// keeps its return address at fp - 4 and the frame before at fp - 8.
fn callChain(start: usize) void {
    var fp = start;
    var depth: u32 = 0;
    exec.kprintf("*** called from:", .{});
    while (depth < 12) : (depth += 1) {
        if (fp & 3 != 0 or !readableHere(fp -% 8) or !readableHere(fp -% 4)) break;
        const ret = @as(*const volatile u32, @ptrFromInt(fp - 4)).*;
        const next = @as(*const volatile u32, @ptrFromInt(fp - 8)).*;
        if (ret == 0 or !layout.inKernel(ret)) break;
        exec.kprintf(" 0x%08x", .{ret});
        if (next <= fp) break;
        fp = next;
    }
    exec.kprintf("\n", .{});
}
