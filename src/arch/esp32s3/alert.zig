// SPDX-License-Identifier: MPL-2.0
//! exec's alert display on this CPU, which the kernel installs as
//! `exec.alert_hook`: the Guru Meditation on exec's raw port (kprintf),
//! which is where a machine that has stopped is read from - it needs
//! nothing that may have broken, no display and no library. It names the
//! code the address is in - the ROM, or a file loaded from disk and the
//! offset into it, which is the address in that program's ELF - and
//! prints the alert's text. A CPU exception adds its cause and the trap
//! frame. A dead-end alert of a task that may be held - not in an
//! interrupt, nothing forbidden, none of the display's locks in its hands -
//! holds that task and asks about it on the display (Software Failure:
//! Suspend or Reboot), and the machine runs on. Any other dead end keeps
//! the end of the system log in RTC memory (lastwords.zig), offers the ROM
//! debugger for a few seconds and, if nobody answers, restarts the
//! machine, whose next boot shows those last words at the head of its
//! log. A recoverable alert is shown on the display as well.
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
const _task = @import("../../rom/libs/exec/task/_task.zig");
const IntuitionBase = @import("../../rom/libs/intuition/intuition.zig").IntuitionBase;
const lastwords = @import("lastwords.zig");
const rendezvous = @import("rendezvous.zig");
const Screen = @import("../../rom/libs/intuition/screen/_screen.zig").Screen;
const LayerInfo = @import("../../rom/libs/layers/layerinfo/_layerinfo.zig").LayerInfo;

/// The chip's part of the ROM debugger: everything in it that needs an
/// instruction or knows this chip's map. exec may not reach in here, so
/// it is handed over instead, as the alert hook is.
pub const debug_hardware: debug.DebugHardware = .{
    .stop = stopHere,
    .go = goOn,
    .halt = cpu.halt,
    .reboot = rebootHere,
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
    const asking = dead_end and canAsk(info != null);
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
        if (info == null) displayRecoverable(alert_num, guru, text);
        return;
    }
    if (asking) {
        endAlertOutput();
        keep(alert_num, guru, text, info);
        const base = exec.SysBase;
        exec.kprintf("*** task held, and asked about on the display\n", .{});
        // The task is held - waiting for nothing - and the requester is the
        // helper's. A CPU exception holds it from here: it never runs
        // another instruction, and the exception's exit switches to the
        // next task. A call from the task holds it where it is.
        if (info != null) {
            _task.blockCurrent(base, base.cpu().this_task, 0);
            base.iface().Signal(helper.task, helper.mask);
            return;
        }
        base.iface().Signal(helper.task, helper.mask);
        _ = base.iface().Wait(0);
        unreachable;
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

// --- a task that failed: Software Failure ------------------------------------

/// What a failed task is asked about with, kept from its alert for the
/// helper. One at a time: a second failure while one is being asked about
/// stops the machine.
const Failure = struct {
    task: ?*exec.Task = null,
    alert_num: u32 = 0,
    guru: [40]u8 = @splat(0),
    detail: [100]u8 = @splat(0),
};
var failure: Failure = .{};
var failing = false;

/// The task that puts the Software Failure requester up: the failed task
/// is held and cannot, and a task that waits for an answer is what a
/// requester needs. It is started at boot and waits for `mask`.
const Helper = struct {
    task: *exec.Task = undefined,
    mask: u32 = 0,
    tcb: exec.Task = .{},
};
var helper: Helper = .{};

/// How much stack the helper has: a requester's call and its formatting.
const helper_stack = 8192;

/// The helper started; until it is, a failed task stops the machine.
pub fn startHelper() void {
    const sys = exec.SysBase.iface();
    const stack = sys.AllocMem(helper_stack, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return;
    helper.tcb = .{
        .node = .{ .type = .task, .pri = 10, .name = "software failure" },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + helper_stack,
    };
    helper.task = &helper.tcb;
    _ = sys.AddTask(&helper.tcb, &helperMain, null);
}

fn helperMain(sys_base: *sdk.interface.exec.ExecBase) callconv(.c) void {
    const bit = sys_base.AllocSignal(-1);
    if (bit < 0) return;
    helper.mask = @as(u32, 1) << @intCast(bit);
    while (true) {
        _ = sys_base.Wait(helper.mask);
        askAbout(sys_base);
    }
}

/// Whether the running task may be held and asked about: it is a task,
/// out of any interrupt (a CPU exception counts as one level, taken from
/// the task's own code), with interrupts on and nothing forbidden; it is
/// neither the helper nor intuition's input task, which answers
/// requesters; intuition is in the system; and the task holds none of the
/// locks the input task needs to put a requester up and take it down -
/// held for good, it would keep them. Otherwise the machine is stopped.
fn canAsk(exception: bool) bool {
    if (failing or !exec.initialized or helper.mask == 0) return false;
    const base = exec.SysBase;
    if (base.cpu().int_depth != @intFromBool(exception)) return false;
    // Waiting for the answer must be possible: switching on, nothing
    // masked, no spinlock held.
    if (base.multitasking == 0 or base.cpu().id_nest_cnt >= 0 or base.cpu().hold_count != 0) return false;
    const task = base.cpu().this_task;
    if (task == helper.task) return false;
    if (std.mem.eql(u8, task.name(), "intuition input")) return false;
    const ib = findIntuition() orelse return false;
    return !holdsDisplayLocks(ib, task);
}

/// Intuition's base, if it is in the system.
fn findIntuition() ?*IntuitionBase {
    var node = exec.SysBase.lib_list.first();
    while (node) |library| : (node = library.next()) {
        const name = library.name orelse continue;
        if (std.mem.eql(u8, std.mem.span(name), "intuition.library")) {
            const lib: *exec.Library = @fieldParentPtr("node", library);
            return @fieldParentPtr("lib", lib);
        }
    }
    return null;
}

/// Whether a task holds intuition's screen list or any lock of a screen's
/// layers.
fn holdsDisplayLocks(ib: *IntuitionBase, task: *exec.Task) bool {
    if (ib.screen_lock.owner == task) return true;
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const screen: *Screen = @ptrCast(@alignCast(n));
        const info: *LayerInfo = @ptrCast(@alignCast(screen.layer_info));
        if (info.lock.owner == task) return true;
        var lock = info.locks.first();
        while (lock) |l| : (lock = l.next()) {
            const semaphore: *exec.SignalSemaphore = @fieldParentPtr("link", l);
            if (semaphore.owner == task) return true;
        }
    }
    return false;
}

/// The failure kept for the helper: the task, its number, the Guru line,
/// and what went wrong in words - the alert's text, or a CPU exception's
/// cause and address.
fn keep(alert_num: u32, guru: []const u8, text: ?[*:0]const u8, info: ?*const exec.TrapInfo) void {
    failing = true;
    failure = .{ .task = exec.SysBase.cpu().this_task, .alert_num = alert_num };
    const take = @min(guru.len, failure.guru.len - 1);
    @memcpy(failure.guru[0..take], guru[0..take]);
    if (text) |line| {
        const words = std.mem.span(line);
        const room = @min(words.len, failure.detail.len - 1);
        @memcpy(failure.detail[0..room], words[0..room]);
    } else if (info) |i| {
        const stream = sdk.exec.fmtStream(.{ trap.causeName(i.number).ptr, @as(u32, @truncate(i.address)) });
        _ = exec.format("%s at 0x%08x", &stream, null, &failure.detail);
    }
}

/// The Software Failure requester for the held task, on the helper:
/// Suspend leaves it held for good - it stops, everything else runs on,
/// and what it holds stays where it is - and Reboot starts the machine
/// again.
fn askAbout(sys: *sdk.interface.exec.ExecBase) void {
    defer failing = false;
    const task = failure.task orelse return;
    var name: [*:0]const u8 = task.name().ptr;
    if (task.node.type == .process) {
        const process: *sdk.dos.Process = @ptrCast(@alignCast(task));
        if (process.cli) |cli| if (cli.command_name) |command| if (command[0] != 0) {
            name = command;
        };
    }
    // The name cut so the message fits its buffer: the guru line and the
    // detail are bounded already.
    var short: [61]u8 = @splat(0);
    var length: usize = 0;
    while (name[length] != 0 and length < short.len - 1) : (length += 1) short[length] = name[length];
    var message: [256]u8 = undefined;
    const stream = sdk.exec.fmtStream(.{ @as([*:0]const u8, @ptrCast(&short)), @as([*:0]const u8, @ptrCast(&failure.guru)), @as([*:0]const u8, @ptrCast(&failure.detail)) });
    _ = exec.format("%s has failed.\n%s\n%s\nWait for disk activity to finish.", &stream, null, &message);

    const library = sys.OpenLibrary("intuition.library", 0) orelse return;
    defer sys.CloseLibrary(library);
    const ib: *sdk.interface.intuition.IntuitionBase = @ptrCast(library);
    const easy = sdk.intuition.EasyStruct{
        .title = "Software Failure",
        .text_format = "%s",
        .gadget_format = "Suspend|Reboot",
    };
    const args = sdk.exec.fmtStream(.{@as([*:0]const u8, @ptrCast(&message))});
    // 1 is Suspend, 0 the rightmost, Reboot - with the log's end kept for
    // the next boot to show.
    if (ib.EasyRequestArgs(null, &easy, null, &args) == 0) {
        lastwords.save();
        sys.ColdReboot();
    }
}

/// Whether an alert is on the display now: one raised while it is up is
/// printed only.
var displaying = false;

/// How long a recoverable alert waits on the display for an answer, in
/// frames of a 60 Hz display: ten seconds, so a board nobody watches goes
/// on by itself.
const recoverable_frames = 600;

/// A recoverable alert on the display as well, through intuition's
/// TimedDisplayAlert: a box with the alert's title, its number and its
/// text, answered by a press or a touch or by the time running out. Only
/// where waiting for that is safe - a task raised it, not an interrupt;
/// interrupts are on and no spinlock is held; it is not intuition's input
/// task, whose events answer it - and only with intuition already in the
/// system: it is opened by name, and never loaded for this.
fn displayRecoverable(alert_num: u32, guru: []const u8, text: ?[*:0]const u8) void {
    if (displaying or !exec.initialized) return;
    const base = exec.SysBase;
    if (base.cpu().int_depth != 0) return;
    if (base.multitasking == 0 or base.cpu().id_nest_cnt >= 0 or base.cpu().hold_count != 0) return;
    const task = base.cpu().this_task;
    if (std.mem.eql(u8, task.name(), "intuition input")) return;
    if (!hasLibrary("intuition.library")) return;
    const sys = base.iface();
    const library = sys.OpenLibrary("intuition.library", 0) orelse return;
    defer sys.CloseLibrary(library);
    const ib: *sdk.interface.intuition.IntuitionBase = @ptrCast(library);

    var message: [256]u8 = undefined;
    var at: usize = 0;
    for ([_][]const u8{ "Recoverable Alert.   Left button or left half: go on\n", guru, "\n", if (text) |line| std.mem.span(line) else "" }) |part| {
        const room = message.len - 1 - at;
        const take = @min(part.len, room);
        @memcpy(message[at..][0..take], part[0..take]);
        at += take;
    }
    message[at] = 0;
    displaying = true;
    defer displaying = false;
    _ = ib.TimedDisplayAlert(alert_num, @ptrCast(&message), 40, recoverable_frames);
}

/// Whether a library of that name is in exec's list, opened or not.
fn hasLibrary(name: []const u8) bool {
    var node = exec.SysBase.lib_list.first();
    while (node) |library| : (node = library.next()) {
        const found = library.name orelse continue;
        if (std.mem.eql(u8, std.mem.span(found), name)) return true;
    }
    return false;
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
