// SPDX-License-Identifier: MIT
//! The device's task: the controllers brought up, then every request on
//! every unit, one after the other.
//!
//! **A read or a write** goes in pieces of at most the controller's
//! largest transfer, up to `slots` of them out on its I/O queue at once:
//! as one is answered the next goes. Each piece is described by its PRP
//! entries (prp.zig) - the caller's own pages, and, where the controller
//! does not see the caches, the device's head and tail pages for what of
//! it shares a cache line with something else. A
//! piece that fails ends the request once the others out are answered;
//! a controller that stops answering is reset and the request sent again,
//! once.
//!
//! **CMD_UPDATE** is Flush where the controller has a volatile write
//! cache, and answered at once where it has none: what it was given is on
//! the medium already.
//!
//! **TDCMD_TRIM** is Dataset Management, its ranges deallocated: as many
//! ranges a command as the controller takes (dsm.zig), one command out at
//! a time. A controller without it answers IOERR_NOCMD.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _nvme = @import("_nvme.zig");
const NvmeBase = _nvme.NvmeBase;
const Controller = _nvme.Controller;
const Unit = _nvme.Unit;
const regs = @import("regs.zig");
const prp = @import("prp.zig");
const dsm = @import("dsm.zig");
const controller = @import("controller.zig");

pub fn nvmeTask(sys: *ExecBase) callconv(.c) void {
    const base: *NvmeBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    if (!setUp(base)) return started(base);
    controller.findAll(base);
    started(base);
    const requests = base.requests.?;
    while (true) {
        _ = sys.WaitPort(requests);
        while (sys.GetMsg(requests)) |msg| {
            const io = _nvme.requestOf(msg);
            serve(base, io);
            sys.ReplyIO(io);
        }
    }
}

/// The task's port, its timer and its interrupt signal. False without
/// them: the init then finds no port and makes no device.
fn setUp(base: *NvmeBase) bool {
    const sys = base.sys_base;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    base.int_signal = @as(u32, 1) << @intCast(signal);
    const timer_port = sys.CreateMsgPort() orelse return false;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = timer_port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) return false;
    base.timer_port = timer_port;
    base.requests = sys.CreateMsgPort() orelse return false;
    return true;
}

fn started(base: *NvmeBase) void {
    const starter = base.starter orelse return;
    base.starter = null;
    base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
}

fn serve(base: *NvmeBase, io: *exec.IORequest) void {
    const unit = _nvme.unitOf(io);
    const c = unit.controller orelse {
        io.err = td.TDERR_BadUnitNum;
        return;
    };
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE => readWrite(base, c, unit, io),
        exec.CMD_UPDATE => flush(c, unit, io),
        td.TDCMD_TRIM => trim(c, unit, io),
        else => io.err = exec.IOERR_NOCMD,
    }
}

// --- reads and writes ---------------------------------------------------------------------

/// How a request's commands ended: all done, one failed with its status,
/// or the controller stopped answering.
const Outcome = union(enum) {
    done,
    failed: u15,
    lost,
};

fn readWrite(base: *NvmeBase, c: *Controller, unit: *Unit, io: *exec.IORequest) void {
    _ = base;
    const req = _nvme.stdReq(io);
    if (!_nvme.inside(unit, req.offset, req.length)) {
        io.err = exec.IOERR_BADADDRESS;
        return;
    }
    if (req.length == 0) return;
    const data = req.data orelse {
        io.err = exec.IOERR_BADADDRESS;
        return;
    };
    var outcome: Outcome = .lost;
    if (c.alive) outcome = transfer(c, unit, io.command == exec.CMD_WRITE, @intFromPtr(data), req.offset, req.length);
    if (outcome == .lost and controller.recover(c)) {
        outcome = transfer(c, unit, io.command == exec.CMD_WRITE, @intFromPtr(data), req.offset, req.length);
    }
    switch (outcome) {
        .done => req.actual = req.length,
        .failed => |status| io.err = errorOf(status),
        .lost => io.err = td.TDERR_NotSpecified,
    }
}

/// A piece out on a slot: where it is in the caller's buffer, and how
/// its edges went.
const Piece = struct {
    data: usize = 0,
    bytes: u32 = 0,
    plan: prp.Plan = .{ .prp1 = 0, .entries = 0 },
};

/// `length` bytes between the caller's buffer at `data` and the unit's
/// medium at `offset`.
fn transfer(c: *Controller, unit: *Unit, write: bool, data: usize, offset: u64, length: u64) Outcome {
    var pieces: [_nvme.slots]Piece = @splat(.{});
    var next: u64 = 0;
    var out: u32 = 0;
    var failure: ?u15 = null;
    var waited: u32 = 0;
    while (true) {
        // As many pieces out as there are slots free, until one fails.
        for (&c.slots, &pieces, 0..) |*slot, *piece, id| {
            if (slot.busy or next == length or failure != null) continue;
            const at = data + @as(usize, @intCast(next));
            const bytes = prp.pieceOf(at, length - next, c.max_transfer, _nvme.page);
            piece.* = .{ .data = at, .bytes = bytes };
            send(c, unit, slot, piece, @intCast(id), write, offset + next);
            next += bytes;
            out += 1;
        }
        if (out == 0) break;
        controller.reap(c);
        var answered = false;
        for (&c.slots, &pieces) |*slot, *piece| {
            if (!slot.busy or !slot.done) continue;
            slot.busy = false;
            out -= 1;
            answered = true;
            if (slot.status != 0) {
                if (failure == null) failure = slot.status;
                continue;
            }
            if (!write) receive(c, slot, piece);
        }
        if (answered) {
            waited = 0;
            continue;
        }
        if (!controller.healthy(c) or !controller.sleep(c, &waited, controller.io_ms)) {
            for (&c.slots) |*slot| slot.busy = false;
            return .lost;
        }
    }
    if (failure) |status| return .{ .failed = status };
    return .done;
}

/// A piece on its slot: its edges copied out for a write, the caches
/// and the memory made one over what the controller reads or writes
/// where it does not see the caches, and its command sent.
fn send(c: *Controller, unit: *Unit, slot: *_nvme.Slot, piece: *Piece, id: u16, write: bool, offset: u64) void {
    const own = prp.Pages{ .head = slot.pages[0], .tail = slot.pages[1], .list = slot.pages[2] };
    const list: *[_nvme.page / 8]u64 = @ptrFromInt(own.list);
    const line = if (c.coherent) prp.dword else prp.cache_line;
    const plan = prp.plan(piece.data, piece.bytes, _nvme.page, line, own, list);
    piece.plan = plan;
    const head: [*]u8 = @ptrFromInt(own.head);
    const tail: [*]u8 = @ptrFromInt(own.tail);
    const caller: [*]u8 = @ptrFromInt(piece.data);
    if (write) {
        @memcpy(head[plan.head_offset..][0..plan.head], caller[0..plan.head]);
        @memcpy(tail[0..plan.tail], caller[piece.bytes - plan.tail ..][0..plan.tail]);
    }
    // Written back where the processor wrote, for a read too: a line it
    // holds dirty must not be written over what the controller puts
    // there.
    _nvme.toDevice(c, own.head + plan.head_offset, plan.head);
    _nvme.toDevice(c, own.tail, plan.tail);
    _nvme.toDevice(c, piece.data + plan.head, piece.bytes - plan.head - plan.tail);
    if (plan.entries > 2) {
        for (list[0 .. plan.entries - 1]) |*entry| entry.* = std.mem.nativeToLittle(u64, entry.*);
        _nvme.toDevice(c, own.list, (plan.entries - 1) * 8);
    }
    const lba = offset / unit.blockBytes();
    const blocks: u32 = piece.bytes / unit.blockBytes();
    slot.busy = true;
    slot.done = false;
    slot.status = 0;
    controller.submit(c, &c.io, .{
        .opcode = if (write) regs.NVM_WRITE else regs.NVM_READ,
        .id = id,
        .nsid = unit.nsid,
        .prp1 = plan.prp1,
        .prp2 = plan.prp2,
        .cdw10 = @truncate(lba),
        .cdw11 = @truncate(lba >> 32),
        .cdw12 = blocks - 1,
    });
}

/// A read's piece answered: the caches' copy of what the controller
/// wrote dropped where it does not see them, and its edges copied in
/// from the head and tail pages.
fn receive(c: *const Controller, slot: *_nvme.Slot, piece: *const Piece) void {
    const plan = piece.plan;
    _nvme.fromDevice(c, piece.data + plan.head, piece.bytes - plan.head - plan.tail);
    _nvme.fromDevice(c, slot.pages[0] + plan.head_offset, plan.head);
    _nvme.fromDevice(c, slot.pages[1], plan.tail);
    const head: [*]const u8 = @ptrFromInt(slot.pages[0]);
    const tail: [*]const u8 = @ptrFromInt(slot.pages[1]);
    const caller: [*]u8 = @ptrFromInt(piece.data);
    @memcpy(caller[0..plan.head], head[plan.head_offset..][0..plan.head]);
    @memcpy(caller[piece.bytes - plan.tail ..][0..plan.tail], tail[0..plan.tail]);
}

// --- commands without data ---------------------------------------------------------------

/// CMD_UPDATE: Flush, where the controller has a cache that needs it.
fn flush(c: *Controller, unit: *Unit, io: *exec.IORequest) void {
    if (!c.volatile_cache) return;
    const command = regs.Command{ .opcode = regs.NVM_FLUSH, .nsid = unit.nsid };
    const status = (if (c.alive) one(c, command) else null) orelse
        (if (controller.recover(c)) one(c, command) else null) orelse {
        io.err = td.TDERR_NotSpecified;
        return;
    };
    if (status != 0) io.err = errorOf(status);
}

/// TDCMD_TRIM: the blocks deallocated, a command at a time, the list of
/// its ranges in slot 0's list page.
fn trim(c: *Controller, unit: *Unit, io: *exec.IORequest) void {
    const req = _nvme.stdReq(io);
    if (!c.deallocates) {
        io.err = exec.IOERR_NOCMD;
        return;
    }
    if (!_nvme.inside(unit, req.offset, req.length)) {
        io.err = exec.IOERR_BADADDRESS;
        return;
    }
    const page = c.slots[0].pages[2];
    const list: *[dsm.most_ranges]regs.Range = @ptrFromInt(page);
    var lba = req.offset >> @intCast(unit.block_shift);
    var left = req.length >> @intCast(unit.block_shift);
    var recovered = false;
    while (left != 0) {
        const filled = dsm.fill(list, lba, left, c.trim_limits);
        _nvme.toDevice(c, page, filled.ranges * @sizeOf(regs.Range));
        const command = regs.Command{
            .opcode = regs.NVM_DATASET_MANAGEMENT,
            .nsid = unit.nsid,
            .prp1 = page,
            .cdw10 = filled.ranges - 1,
            .cdw11 = regs.DSM_DEALLOCATE,
        };
        // A controller that stops answering is reset, and the command
        // sent again: once a request.
        const status = (if (c.alive) one(c, command) else null) orelse {
            if (recovered or !controller.recover(c)) {
                io.err = td.TDERR_NotSpecified;
                return;
            }
            recovered = true;
            continue;
        };
        if (status != 0) {
            io.err = errorOf(status);
            return;
        }
        lba += filled.blocks;
        left -= filled.blocks;
    }
    req.actual = req.length;
}

/// `command` alone on slot 0, and its answer waited for: its status, or
/// null where the controller stopped answering.
fn one(c: *Controller, command: regs.Command) ?u15 {
    const slot = &c.slots[0];
    slot.busy = true;
    slot.done = false;
    slot.status = 0;
    var sent = command;
    sent.id = 0;
    controller.submit(c, &c.io, sent);
    var waited: u32 = 0;
    while (true) {
        controller.reap(c);
        if (slot.done) break;
        if (!controller.healthy(c) or !controller.sleep(c, &waited, controller.io_ms)) break;
    }
    slot.busy = false;
    return if (slot.done) slot.status else null;
}

/// A failed command's status as the request's error.
fn errorOf(status: u15) i8 {
    if (regs.statusType(status) == regs.SCT_GENERIC) {
        switch (regs.statusCode(status)) {
            regs.SC_LBA_RANGE => return exec.IOERR_BADADDRESS,
            regs.SC_WRITE_PROTECTED => return td.TDERR_WriteProt,
            else => {},
        }
    }
    return td.TDERR_NotSpecified;
}
