// SPDX-License-Identifier: MIT
//! A controller brought up, its commands sent and their completions
//! taken, and its namespaces made units.
//!
//! **Bringing it up** is the specification's order (NVMe 1.4, 7.6.1):
//! its memory decoding and bus mastering on; the controller stopped
//! (CC.EN off, CSTS.RDY waited for); the admin queues given (AQA, ASQ,
//! ACQ); it started with 4 KiB pages and the entry sizes of 64 and 16
//! bytes, and CSTS.RDY waited for, as long as CAP.TO says. Then Identify
//! asks what it is - and what it takes of Dataset Management, where it
//! has that - Set Features asks for one pair of I/O queues, and
//! the pair is made: the completion queue first, on vector 0, the same
//! the admin queue's completions come on.
//!
//! **Its interrupt** is a vector of its own where pci.library gives one
//! (MSI-X or MSI), its INTx line where not, and a poll every millisecond
//! where neither works. On INTx the line stays raised while completions
//! wait - until the head doorbell is rung past them, not until they are
//! seen - so the server holds it back (INTMS) every time it comes and
//! the task lets it go again (INTMC) once it has taken them and rung the
//! doorbell. It does that even when no completion shows at a queue's
//! head: the task may have taken one and not rung the doorbell yet,
//! interrupted on the same core by the line it raised. A line it shares
//! is answered only when one of its queues has something.
//!
//! **Waiting** is the task's: it sleeps until the interrupt or its
//! timer's tick, then takes what came. A command that is not answered in
//! time - or a controller whose registers read as all ones, or that says
//! it failed (CSTS.CFS) - has the controller reset through pci.library
//! and brought up again, once. One that reset itself, as an SSD whose
//! power dipped does, is only given back its configuration there
//! (ResetPCIDevice). One that does not come back is given up: it is not
//! reset again, and its units' media are gone with it (task.zig).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _nvme = @import("_nvme.zig");
const NvmeBase = _nvme.NvmeBase;
const Controller = _nvme.Controller;
const Queue = _nvme.Queue;
const regs = @import("regs.zig");
const dsm = @import("dsm.zig");

/// How long an admin command may take, and how long one of the I/O
/// queue's may go without any of them answered.
pub const admin_ms: u32 = 10_000;
pub const io_ms: u32 = 30_000;

// --- bringing it up ----------------------------------------------------------------------

/// Every NVM Express function pci.library has, claimed and brought up,
/// and its namespaces made units.
pub fn findAll(base: *NvmeBase) void {
    const sys = base.sys_base;
    const pb = base.pci_base orelse return;
    var it = pb.FindPCIClass(null, pci.PCI_CLASS_STORAGE_NVME, pci.PCI_CLASS_MASK);
    while (it) |function| : (it = pb.FindPCIClass(function, pci.PCI_CLASS_STORAGE_NVME, pci.PCI_CLASS_MASK)) {
        if (base.controller_count == _nvme.max_controllers) break;
        const number: u8 = @intCast(base.controller_count);
        if (pb.ClaimPCIDevice(function, _nvme.DEVICE_NAME)) |holder| {
            sdk.exec.kprintf(sys, "%s: controller %ld: its PCI function is %s's\n", .{ _nvme.DEVICE_NAME, @as(i64, number), holder });
            continue;
        }
        const c = make(base, function, number) orelse {
            pb.ReleasePCIDevice(function);
            continue;
        };
        if (!start(c, true)) {
            sdk.exec.kprintf(sys, "%s: controller %ld: does not come up\n", .{ _nvme.DEVICE_NAME, @as(i64, number) });
            // Its memory and its server stay: what it was given is kept
            // for as long as the device is.
            continue;
        }
        c.alive = true;
        base.controllers[number] = c;
        base.controller_count += 1;
        findNamespaces(base, c);
    }
}

/// Whether the controller sees the caches: pci.library says so from 2.1
/// on.
fn coherent(base: *NvmeBase, function: *pci.PCIDevice) bool {
    const lib: *exec.Library = @ptrCast(@alignCast(base.pci_base.?));
    return lib.revision >= 1 and function.dma_coherent;
}

/// A controller's block, its queues' memory and its slots' pages: null
/// without the memory.
fn make(base: *NvmeBase, function: *pci.PCIDevice, number: u8) ?*Controller {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Controller), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const c: *Controller = @ptrCast(@alignCast(memory));
    c.* = .{
        .base = base,
        .sys = sys,
        .pb = base.pci_base.?,
        .function = function,
        .coherent = coherent(base, function),
        .task = &base.task,
        .int_signal = base.int_signal,
        .number = number,
    };
    // A page each for the admin queues, the I/O queues and Identify, and
    // three a slot.
    const fixed = 5;
    const total = fixed + 3 * _nvme.slots;
    const pages = _nvme.allocPages(c, total * _nvme.page) orelse return null;
    const page = _nvme.page;
    c.admin.commands = @ptrFromInt(pages);
    c.admin.completions = @ptrFromInt(pages + page);
    c.io.commands = @ptrFromInt(pages + 2 * page);
    c.io.completions = @ptrFromInt(pages + 3 * page);
    c.identify = @ptrFromInt(pages + 4 * page);
    for (&c.slots, 0..) |*slot, n| {
        for (&slot.pages, 0..) |*at, i| at.* = pages + (fixed + 3 * n + i) * page;
    }
    comptime std.debug.assert(_nvme.admin_entries * @sizeOf(regs.Command) <= _nvme.page);
    comptime std.debug.assert(_nvme.io_entries * @sizeOf(regs.Command) <= _nvme.page);
    return c;
}

/// The controller up and its I/O queues made; `first` the first time,
/// when its interrupt is hooked too. False where any of it fails.
pub fn start(c: *Controller, first: bool) bool {
    const sys = c.sys;
    const pb = c.pb;
    const function = c.function;
    var command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command);
    const bar = function.bars[0];
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) {
        sdk.exec.kprintf(sys, "%s: controller %ld: its registers were not placed\n", .{ _nvme.DEVICE_NAME, @as(i64, c.number) });
        return false;
    }
    c.regs = @intCast(bar.address);
    const cap = _nvme.read64(c, regs.CAP);
    if (cap == std.math.maxInt(u64)) return false;
    if (!regs.speaksNvm(cap) or regs.minPageShift(cap) != 0) {
        sdk.exec.kprintf(sys, "%s: controller %ld: no NVM command set on 4 KiB pages\n", .{ _nvme.DEVICE_NAME, @as(i64, c.number) });
        return false;
    }
    c.stride = regs.doorbellStride(cap);
    c.ready_ms = @max(regs.readyMs(cap), 500);
    const most = regs.maxEntries(cap);

    if (!stop(c)) return false;
    reset(c, &c.admin, 0, _nvme.admin_entries);
    _nvme.reg(c, regs.AQA).* = (@as(u32, _nvme.admin_entries - 1) << 16) | (_nvme.admin_entries - 1);
    _nvme.write64(c, regs.ASQ, @intFromPtr(c.admin.commands));
    _nvme.write64(c, regs.ACQ, @intFromPtr(c.admin.completions));
    _nvme.reg(c, regs.CC).* = regs.CC_EN | regs.CC_IOSQES | regs.CC_IOCQES;
    if (!waitStatus(c, regs.CSTS_RDY, regs.CSTS_RDY)) return false;

    if (first) hook(c);
    if (c.signalling == .polled) _nvme.reg(c, regs.INTMS).* = 0xFFFF_FFFF;

    if (!identify(c, regs.CNS_CONTROLLER, 0)) return false;
    const info = regs.ControllerInfo.of(c.identify[0..4096]);
    c.serial = info.serial;
    c.model = info.model;
    c.firmware = info.firmware;
    c.volatile_cache = info.volatile_cache;
    c.max_transfer = _nvme.max_transfer;
    if (info.mdts != 0 and info.mdts < 20) {
        c.max_transfer = @min(c.max_transfer, @as(u32, _nvme.page) << @intCast(info.mdts));
    }
    // What Dataset Management takes, where the controller says it (NVMe
    // 1.1 on); one that does not answer takes what the command allows.
    c.deallocates = info.dataset_management;
    c.trim_limits = .{};
    if (c.deallocates and _nvme.reg(c, regs.VS).* >= regs.VS_1_1 and identify(c, regs.CNS_CONTROLLER_NVM, 0)) {
        c.trim_limits = dsm.Limits.of(regs.NvmLimits.of(c.identify[0..4096]));
    }

    // One submission queue and one completion queue, as 0's-based counts.
    _ = admin(c, .{ .opcode = regs.ADMIN_SET_FEATURES, .cdw10 = regs.FEATURE_QUEUES, .cdw11 = 0 });
    const entries: u16 = @intCast(@min(_nvme.io_entries, most));
    reset(c, &c.io, 1, entries);
    const interrupts: u32 = if (c.signalling == .polled) 0 else regs.CQ_INTERRUPTS;
    const size = (@as(u32, entries - 1) << 16) | 1;
    if (admin(c, .{
        .opcode = regs.ADMIN_CREATE_CQ,
        .prp1 = @intFromPtr(c.io.completions),
        .cdw10 = size,
        .cdw11 = interrupts | regs.QUEUE_CONTIGUOUS,
    }) == null) return false;
    if (admin(c, .{
        .opcode = regs.ADMIN_CREATE_SQ,
        .prp1 = @intFromPtr(c.io.commands),
        .cdw10 = size,
        .cdw11 = (1 << 16) | regs.QUEUE_CONTIGUOUS,
    }) == null) return false;
    for (&c.slots) |*slot| slot.busy = false;
    return true;
}

/// The controller stopped: CC.EN off, and CSTS.RDY waited for.
fn stop(c: *Controller) bool {
    const control = _nvme.reg(c, regs.CC).*;
    if (control & regs.CC_EN != 0) _nvme.reg(c, regs.CC).* = control & ~regs.CC_EN;
    return waitStatus(c, regs.CSTS_RDY, 0);
}

/// CSTS's `mask` bits waited for to be `want`, as long as CAP.TO says;
/// false where they are not, or the controller fails on the way up.
fn waitStatus(c: *Controller, mask: u32, want: u32) bool {
    var waited: u32 = 0;
    while (true) {
        const status = _nvme.reg(c, regs.CSTS).*;
        if (status == 0xFFFF_FFFF) return false;
        if (status & mask == want) return true;
        if (want != 0 and status & regs.CSTS_CFS != 0) return false;
        if (waited >= c.ready_ms) return false;
        pause(c.base, 1000);
        waited += 1;
    }
}

/// A queue empty and at its start: its completions zeroed, so none reads
/// as new.
fn reset(c: *Controller, q: *Queue, id: u16, entries: u16) void {
    const completions = @intFromPtr(q.completions);
    @memset(@as([*]u8, @ptrFromInt(completions))[0 .. @as(usize, entries) * @sizeOf(regs.Completion)], 0);
    _nvme.toDevice(c, completions, @as(usize, entries) * @sizeOf(regs.Completion));
    q.id = id;
    q.entries = entries;
    q.tail = 0;
    q.head = 0;
    q.phase = 1;
    q.tail_doorbell = regs.tailDoorbell(id, c.stride);
    q.head_doorbell = regs.headDoorbell(id, c.stride);
}

/// Its interrupt hooked: a vector of its own, its INTx line, or neither -
/// then it is polled.
fn hook(c: *Controller) void {
    const pb = c.pb;
    const function = c.function;
    c.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = _nvme.DEVICE_NAME },
        .data = c,
        .code = @ptrCast(&intServer),
    };
    if (pb.AllocPCIVectors(function, 1) == 1 and pb.AddPCIVectorServer(function, 0, &c.int)) {
        c.signalling = .vector;
        return;
    }
    pb.FreePCIVectors(function);
    if (pb.AddPCIIntServer(function, &c.int)) {
        const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
        pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command & ~@as(u32, pci.PCI_COMMAND_INTX_DISABLE));
        c.signalling = .intx;
        return;
    }
    c.signalling = .polled;
}

/// The controller's interrupt: the task woken. On INTx the line is held
/// back until the task has taken what came and rung the doorbell (see the
/// top of the file); on a shared line it is answered only when one of its
/// queues has something.
fn intServer(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const c: *Controller = @ptrCast(@alignCast(data.?));
    var ours = true;
    if (c.signalling == .intx) {
        _nvme.reg(c, regs.INTMS).* = 1;
        ours = waiting(c, &c.admin) or waiting(c, &c.io);
    }
    if (c.task) |task| c.sys.Signal(task, c.int_signal);
    return @intFromBool(ours);
}

/// Whether a completion waits at the queue's head.
fn waiting(c: *Controller, q: *Queue) bool {
    if (q.entries == 0) return false;
    const at = &q.completions[q.head];
    _nvme.fromDevice(c, @intFromPtr(at), @sizeOf(regs.Completion));
    return at.phase() == q.phase;
}

// --- commands ----------------------------------------------------------------------------

/// `command` onto queue `q`, and its doorbell rung.
pub fn submit(c: *Controller, q: *Queue, command: regs.Command) void {
    q.commands[q.tail] = command;
    _nvme.toDevice(c, @intFromPtr(&q.commands[q.tail]), @sizeOf(regs.Command));
    q.tail += 1;
    if (q.tail == q.entries) q.tail = 0;
    _nvme.barrier();
    _nvme.reg(c, q.tail_doorbell).* = q.tail;
}

/// Every completion that came, on both queues, taken: an admin command's
/// answer kept, each slot's marked done.
pub fn reap(c: *Controller) void {
    reapQueue(c, &c.admin);
    reapQueue(c, &c.io);
    if (c.signalling == .intx) _nvme.reg(c, regs.INTMC).* = 1;
}

fn reapQueue(c: *Controller, q: *Queue) void {
    var taken = false;
    while (true) {
        const at = &q.completions[q.head];
        _nvme.fromDevice(c, @intFromPtr(at), @sizeOf(regs.Completion));
        // The phase first, the rest after it: read in one go, the id
        // could be the last lap's while the controller writes the entry,
        // and the wrong slot would be done.
        if (@as(u1, @truncate(at.status)) != q.phase) break;
        _nvme.readBarrier();
        const entry = at.*;
        q.head += 1;
        if (q.head == q.entries) {
            q.head = 0;
            q.phase ^= 1;
        }
        taken = true;
        if (q.id == 0) {
            if (entry.id == c.admin_id) {
                c.admin_done = true;
                c.admin_status = entry.code();
                c.admin_result = entry.result;
            }
        } else if (entry.id < _nvme.slots) {
            const slot = &c.slots[entry.id];
            slot.done = true;
            slot.status = entry.code();
        }
    }
    if (taken) {
        _nvme.barrier();
        _nvme.reg(c, q.head_doorbell).* = q.head;
    }
}

/// An admin command sent and its answer waited for: what it answers in
/// its completion, or null where it failed or was not answered.
pub fn admin(c: *Controller, command: regs.Command) ?u32 {
    c.admin_id +%= 1;
    var sent = command;
    sent.id = c.admin_id;
    c.admin_done = false;
    submit(c, &c.admin, sent);
    var waited: u32 = 0;
    while (true) {
        reap(c);
        if (c.admin_done) break;
        if (!sleep(c, &waited, admin_ms)) return null;
    }
    if (c.admin_status != 0) return null;
    return c.admin_result;
}

/// Identify's page `cns` for namespace `nsid`, into the controller's
/// Identify page.
fn identify(c: *Controller, cns: u32, nsid: u32) bool {
    const at = @intFromPtr(c.identify);
    _nvme.toDevice(c, at, _nvme.page);
    const answered = admin(c, .{ .opcode = regs.ADMIN_IDENTIFY, .nsid = nsid, .prp1 = at, .cdw10 = cns }) != null;
    _nvme.fromDevice(c, at, _nvme.page);
    return answered;
}

/// Whether the controller still answers and has not failed.
pub fn healthy(c: *Controller) bool {
    const status = _nvme.reg(c, regs.CSTS).*;
    return status != 0xFFFF_FFFF and status & regs.CSTS_CFS == 0 and status & regs.CSTS_RDY != 0;
}

/// The controller reset and brought up again: whether it came back. Its
/// slots are free after it. One that does not come back is given up for
/// good: a reset waits as long as pci.library and CAP.TO allow - a
/// minute and more - and tried again for each request, every block a
/// file system asked for would wait that long.
pub fn recover(c: *Controller) bool {
    sdk.exec.kprintf(c.sys, "%s: controller %ld: no answer; reset\n", .{ _nvme.DEVICE_NAME, @as(i64, c.number) });
    for (&c.slots) |*slot| slot.* = .{ .pages = slot.pages };
    c.alive = c.pb.ResetPCIDevice(c.function) and start(c, false);
    if (!c.alive) sdk.exec.kprintf(c.sys, "%s: controller %ld: did not come back; given up, its units have no medium\n", .{ _nvme.DEVICE_NAME, @as(i64, c.number) });
    return c.alive;
}

// --- waiting ------------------------------------------------------------------------------

/// The task asleep until the controller's interrupt or the timer's next
/// tick - a millisecond for a polled controller, 50 for one that signals:
/// false once `most` milliseconds have gone by in ticks.
pub fn sleep(c: *Controller, waited: *u32, most: u32) bool {
    const base = c.base;
    const sys = c.sys;
    if (!base.ticking) {
        base.tick_us = if (c.signalling == .polled) 1000 else 50_000;
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(base.tick_us);
        sys.SendIO(&base.timer_io.node);
        base.ticking = true;
    }
    _ = sys.Wait(base.int_signal | base.timer_port.?.sigMask());
    if (sys.CheckIO(&base.timer_io.node) != null) {
        _ = sys.WaitIO(&base.timer_io.node);
        base.ticking = false;
        waited.* += @max(base.tick_us / 1000, 1);
    }
    return waited.* < most;
}

/// The task kept for `us` microseconds.
pub fn pause(base: *NvmeBase, us: u32) void {
    const sys = base.sys_base;
    if (base.ticking) {
        _ = sys.WaitIO(&base.timer_io.node);
        base.ticking = false;
    }
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = sys.DoIO(&base.timer_io.node);
}

// --- namespaces ---------------------------------------------------------------------------

/// The controller's active namespaces, each a unit: in the order of their
/// IDs, where the controller lists them, and the first eight IDs where it
/// cannot.
fn findNamespaces(base: *NvmeBase, c: *Controller) void {
    var ids: [_nvme.max_units]u32 = @splat(0);
    var count: usize = 0;
    if (identify(c, regs.CNS_ACTIVE_NAMESPACES, 0)) {
        const list: *const [1024]u32 = @ptrCast(@alignCast(c.identify));
        for (list) |id| {
            if (id == 0 or count == ids.len) break;
            ids[count] = std.mem.littleToNative(u32, id);
            count += 1;
        }
    } else {
        while (count < ids.len) : (count += 1) ids[count] = @intCast(count + 1);
    }
    for (ids[0..count]) |nsid| {
        if (base.unit_count == _nvme.max_units) return;
        if (!identify(c, regs.CNS_NAMESPACE, nsid)) continue;
        const info = regs.NamespaceInfo.of(c.identify[0..4096]);
        if (info.blocks == 0) continue;
        if (info.metadata != 0 or info.block_shift < 9 or info.block_shift > 12) {
            sdk.exec.kprintf(base.sys_base, "%s: controller %ld: namespace %ld has blocks it cannot take (2^%ld bytes, %ld of metadata)\n", .{ _nvme.DEVICE_NAME, @as(i64, c.number), @as(i64, nsid), @as(i64, info.block_shift), @as(i64, info.metadata) });
            continue;
        }
        const unit = &base.units[base.unit_count];
        unit.controller = c;
        unit.nsid = nsid;
        unit.block_shift = info.block_shift;
        unit.blocks = info.blocks;
        var model: [41:0]u8 = @splat(0);
        const name = regs.trimmed(&c.model);
        @memcpy(model[0..name.len], name);
        const mib = (info.blocks << @intCast(info.block_shift)) >> 20;
        const trims: [*:0]const u8 = if (!c.deallocates) "" else switch (info.deallocated) {
            1 => ", TRIM: trimmed blocks read as zeroes",
            2 => ", TRIM: trimmed blocks read as 0xFF",
            else => ", TRIM",
        };
        sdk.exec.kprintf(base.sys_base, "%s: unit %ld: %s, namespace %ld, %ld MiB in blocks of %ld bytes%s\n", .{ _nvme.DEVICE_NAME, @as(i64, base.unit_count), @as([*:0]const u8, &model), @as(i64, nsid), @as(i64, @intCast(mib)), @as(i64, 1) << @intCast(info.block_shift), trims });
        base.unit_count += 1;
    }
}
