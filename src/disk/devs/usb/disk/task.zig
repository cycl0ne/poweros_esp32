// SPDX-License-Identifier: MIT
//! The device's task: every command on every unit, one after the other,
//! so a stick's transfers are never two at once and nothing here races.
//!
//! **Bringing an interface up.** A bind hands the task its interface; for
//! each logical unit the task asks INQUIRY - a unit that is not a disk is
//! let go of - and then whether a medium is in. A medium coming in is
//! asked its size (READ CAPACITY, 10 and then 16 where the medium is too
//! large for 10) and its write protection (MODE SENSE); the unit counts
//! the change and causes its handlers' change interrupts - or, for a
//! unit that has no node yet, tells the DOS process (mount.zig), which
//! makes one.
//!
//! **The poll.** While anything is bound the task looks at every unit
//! once a second with TEST UNIT READY: a card put into a reader's slot
//! comes in, one taken out goes. A stick pulled out is not a poll's to
//! find - its interface is let go of, which takes its units' media with
//! it.
//!
//! **A command that fails** says why in its sense: no medium (the unit's
//! medium has gone), write-protected, or a unit attention - the medium
//! changed, and the request is answered TDERR_DiskChanged. A device that
//! has gone answers TDERR_NoCard; a transport that broke and was reset,
//! TDERR_NotSpecified.
//!
//! **Reads and writes** go in pieces of at most `max_transfer` bytes, a
//! command each, straight into and out of the caller's buffer: the
//! controller moves bulk data through a buffer of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const td = sdk.devices.trackdisk;
const scsidisk = sdk.devices.scsidisk;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _disk = @import("_disk.zig");
const DiskBase = _disk.DiskBase;
const Unit = _disk.Unit;
const Function = _disk.Function;
const bot = @import("bot.zig");
const scsi = @import("scsi.zig");

/// How often the units are looked at.
const poll_us: u32 = 1_000_000;
/// The most one READ or WRITE moves.
const max_transfer: u32 = 64 * 1024;
/// How long a data stage may keep the task waiting, in milliseconds.
const data_ms: u32 = 20_000;
/// A short answer - INQUIRY, a sense - comes at once or not at all.
const answer_ms: u32 = 5_000;

pub fn diskTask(sys: *ExecBase) callconv(.c) void {
    const base: *DiskBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    if (!setUp(base)) return started(base);
    started(base);
    const requests = base.requests.?;
    const commands = base.commands.?;
    const timer_port = base.timer_port.?;
    while (true) {
        armPoll(base);
        _ = sys.Wait(requests.sigMask() | commands.sigMask() | timer_port.sigMask());
        while (sys.GetMsg(commands)) |msg| {
            const command: *_disk.Command = @alignCast(@fieldParentPtr("message", msg));
            const function: *Function = @ptrCast(@alignCast(command.function.?));
            switch (command.kind) {
                .bring_up => bringUp(base, function),
                .let_go => {
                    letGo(base, function);
                    sys.ReplyMsg(msg);
                },
            }
        }
        while (sys.GetMsg(requests)) |msg| {
            const io = _disk.requestOf(msg);
            serve(base, io);
            sys.ReplyIO(io);
        }
        if (base.polling and sys.CheckIO(&base.timer_io.node) != null) {
            _ = sys.WaitIO(&base.timer_io.node);
            base.polling = false;
            pollAll(base);
        }
    }
}

/// The task's ports and timer. False without them: the init then finds
/// no ports and makes no device.
fn setUp(base: *DiskBase) bool {
    const sys = base.sys_base;
    base.requests = sys.CreateMsgPort() orelse return false;
    base.commands = sys.CreateMsgPort() orelse return false;
    base.pipes = sys.CreateMsgPort() orelse return false;
    base.timer_port = sys.CreateMsgPort() orelse return false;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = base.timer_port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) {
        base.timer_port = null;
        return false;
    }
    return true;
}

fn started(base: *DiskBase) void {
    const starter = base.starter orelse return;
    base.starter = null;
    base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
}

/// The poll's timer sent, while anything is bound and it is not out.
fn armPoll(base: *DiskBase) void {
    if (base.polling) return;
    for (&base.units) |*unit| {
        if (unit.function == null) continue;
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(poll_us);
        base.sys_base.SendIO(&base.timer_io.node);
        base.polling = true;
        return;
    }
}

fn pollAll(base: *DiskBase) void {
    for (&base.units) |*unit| {
        const function = _disk.functionOf(unit) orelse continue;
        probe(base, function, unit);
    }
}

// --- an interface -------------------------------------------------------------------

/// Each of an interface's logical units identified, and its medium
/// looked at; one that is not a disk let go of.
fn bringUp(base: *DiskBase, function: *Function) void {
    for (function.units[0..function.lun_count], 0..) |slot, lun| {
        const unit = slot orelse continue;
        if (!identify(base, function, unit)) {
            release(base, function, lun);
            continue;
        }
        probe(base, function, unit);
    }
}

/// INQUIRY: whether the unit is a disk, whether its medium comes out.
fn identify(base: *DiskBase, function: *Function, unit: *Unit) bool {
    const sys = base.sys_base;
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        const answer = function.scratch[0..scsi.inquiry_bytes];
        const result = run(function, unit, scsi.inquiry().slice(), answer, true, answer_ms);
        switch (result.outcome) {
            .passed => {},
            .gone => return false,
            .failed, .broken => continue,
        }
        const said = scsi.inquiryOf(answer[0..@min(result.moved, answer.len)]) orelse continue;
        if (said.device_type != scsi.TYPE_DISK and said.device_type != scsi.TYPE_OPTICAL_MEMORY) {
            sdk.exec.kprintf(sys, "%s: a logical unit of type %u, not a disk\n", .{ _disk.DEVICE_NAME, @as(u32, said.device_type) });
            return false;
        }
        unit.device_type = said.device_type;
        unit.removable = said.removable;
        var vendor: [9]u8 = @splat(0);
        var product: [17]u8 = @splat(0);
        const vendor_name = scsi.trimmed(&said.vendor);
        const product_name = scsi.trimmed(&said.product);
        @memcpy(vendor[0..vendor_name.len], vendor_name);
        @memcpy(product[0..product_name.len], product_name);
        sdk.exec.kprintf(sys, "%s: %s: %s %s\n", .{
            _disk.DEVICE_NAME,
            @as([*:0]const u8, @ptrCast(&unit.name)),
            @as([*:0]const u8, @ptrCast(&vendor)),
            @as([*:0]const u8, @ptrCast(&product)),
        });
        return true;
    }
    return false;
}

/// An interface let go of: its units without a medium and free for the
/// next, its pipes closed. Requests still queued for its units find no
/// medium.
fn letGo(base: *DiskBase, function: *Function) void {
    const sys = base.sys_base;
    for (function.units[0..function.lun_count], 0..) |slot, lun| {
        const unit = slot orelse continue;
        if (unit.present) depart(base, unit);
        release(base, function, lun);
    }
    const ub = base.usb_base.?;
    ub.CloseUSBPipe(function.transport.bulk_in);
    ub.CloseUSBPipe(function.transport.bulk_out);
    sys.FreeMem(function, @sizeOf(Function));
}

/// Logical unit `lun`'s drive given back.
fn release(base: *DiskBase, function: *Function, lun: usize) void {
    const sys = base.sys_base;
    const unit = function.units[lun] orelse return;
    sys.ObtainSemaphore(&base.lock);
    unit.function = null;
    sys.ReleaseSemaphore(&base.lock);
    function.units[lun] = null;
}

// --- the medium ---------------------------------------------------------------------

const Readiness = enum { ready, absent, gone };

/// TEST UNIT READY, past a unit attention or two - a medium just put in,
/// a reset - which say only that something changed.
fn readiness(function: *Function, unit: *Unit) Readiness {
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        switch (run(function, unit, scsi.testUnitReady().slice(), null, false, answer_ms).outcome) {
            .passed => return .ready,
            .gone => return .gone,
            .broken => continue,
            .failed => {
                const sense = senseOf(function, unit) orelse return .absent;
                if (sense.changed()) continue;
                return .absent;
            },
        }
    }
    return .absent;
}

/// The medium looked at: one come in is taken in, one gone let go of.
fn probe(base: *DiskBase, function: *Function, unit: *Unit) void {
    switch (readiness(function, unit)) {
        .ready => if (!unit.present) arrive(base, function, unit),
        .absent => if (unit.present) depart(base, unit),
        .gone => {},
    }
}

/// A medium come in: its size and protection read, the change counted
/// and told. A medium of a size no block device serves stays out.
fn arrive(base: *DiskBase, function: *Function, unit: *Unit) void {
    const sys = base.sys_base;
    const capacity = capacityOf(function, unit) orelse return;
    if (!scsi.usable(capacity)) {
        sdk.exec.kprintf(sys, "%s: %s: blocks of %u bytes, which are not served\n", .{ _disk.DEVICE_NAME, @as([*:0]const u8, @ptrCast(&unit.name)), capacity.block_bytes });
        return;
    }
    unit.block_bytes = capacity.block_bytes;
    unit.blocks = capacity.blocks;
    const mode = function.scratch[0..scsi.mode_sense_bytes];
    const result = run(function, unit, scsi.modeSense().slice(), mode, true, answer_ms);
    unit.write_protected = result.outcome == .passed and scsi.writeProtectedOf(mode[0..@min(result.moved, mode.len)]);
    if (result.outcome == .failed) _ = senseOf(function, unit);
    unit.present = true;
    unit.change_num +%= 1;
    const megabytes = capacity.blocks * capacity.block_bytes / (1024 * 1024);
    sdk.exec.kprintf(sys, "%s: %s: %ld MB, %u-byte blocks%s\n", .{
        _disk.DEVICE_NAME,
        @as([*:0]const u8, @ptrCast(&unit.name)),
        megabytes,
        capacity.block_bytes,
        @as([*:0]const u8, if (unit.write_protected) ", write-protected" else ""),
    });
    tell(base, unit);
}

/// A medium gone: the change counted and told.
fn depart(base: *DiskBase, unit: *Unit) void {
    unit.present = false;
    unit.change_num +%= 1;
    tell(base, unit);
}

/// A medium came or went: the unit's handlers' change interrupts caused,
/// and - for a unit that has no node yet - the DOS process told, once,
/// while the last telling is still on its way.
fn tell(base: *DiskBase, unit: *Unit) void {
    const sys = base.sys_base;
    sys.AcquireLock(&base.change_lock);
    var it = unit.changes.iterator();
    while (it.next()) |node| {
        const io = _disk.requestOf(@fieldParentPtr("node", node));
        const data = _disk.stdReq(io).data orelse continue;
        sys.Cause(@ptrCast(@alignCast(data)));
    }
    sys.ReleaseLock(&base.change_lock);
    if (@atomicLoad(bool, &unit.node_made, .acquire)) return;
    const port = base.mounter orelse return;
    if (@cmpxchgStrong(u8, &unit.told, 0, 1, .acq_rel, .monotonic) != null) return;
    unit.tell.reply_port = null;
    unit.tell.length = @sizeOf(exec.Message);
    base.sys_base.PutMsg(port, &unit.tell);
}

/// READ CAPACITY: the 10-byte form, then the 16-byte one for a medium too
/// large for it.
fn capacityOf(function: *Function, unit: *Unit) ?scsi.Capacity {
    const short = function.scratch[0..scsi.capacity_10_bytes];
    const result = run(function, unit, scsi.readCapacity10().slice(), short, true, answer_ms);
    if (result.outcome != .passed) return null;
    if (scsi.capacity10Of(short[0..@min(result.moved, short.len)])) |capacity| return capacity;
    const long = function.scratch[0..scsi.capacity_16_bytes];
    const second = run(function, unit, scsi.readCapacity16().slice(), long, true, answer_ms);
    if (second.outcome != .passed) return null;
    return scsi.capacity16Of(long[0..@min(second.moved, long.len)]);
}

/// REQUEST SENSE: why the last command failed.
fn senseOf(function: *Function, unit: *Unit) ?scsi.Sense {
    const answer = function.scratch[0..scsi.sense_bytes];
    const result = run(function, unit, scsi.requestSense().slice(), answer, true, answer_ms);
    if (result.outcome != .passed) return null;
    return scsi.senseOf(answer[0..@min(result.moved, answer.len)]);
}

fn run(function: *Function, unit: *Unit, command: []const u8, data: ?[]u8, in: bool, ms: u32) bot.Result {
    const bytes = data orelse return bot.run(&function.transport, unit.lun, command, null, 0, in, ms);
    return bot.run(&function.transport, unit.lun, command, bytes.ptr, @intCast(bytes.len), in, ms);
}

// --- the requests -------------------------------------------------------------------

/// One request from the queue.
fn serve(base: *DiskBase, io: *exec.IORequest) void {
    const unit = _disk.unitOf(io);
    const req = _disk.stdReq(io);
    const function = _disk.functionOf(unit) orelse {
        if (io.command == td.TD_CHANGESTATE) {
            req.actual = 1;
        } else {
            io.err = td.TDERR_NoCard;
        }
        return;
    };
    if (io.command == scsidisk.HD_SCSICMD) return scsiCommand(function, unit, io);
    if (!unit.present) {
        if (io.command == td.TD_CHANGESTATE) {
            req.actual = 1;
        } else {
            io.err = td.TDERR_NoCard;
        }
        return;
    }
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE => readWrite(base, function, unit, io),
        td.TD_GETGEOMETRY => {
            const data = req.data orelse {
                io.err = exec.IOERR_BADADDRESS;
                return;
            };
            _disk.geometry(unit, @ptrCast(@alignCast(data)));
        },
        td.TD_GETNUMTRACKS => req.actual = unit.blocks,
        td.TD_PROTSTATUS => req.actual = @intFromBool(unit.write_protected),
        td.TD_CHANGESTATE => req.actual = 0,
        else => io.err = exec.IOERR_NOCMD,
    }
}

/// CMD_READ or CMD_WRITE, in pieces of at most `max_transfer`.
fn readWrite(base: *DiskBase, function: *Function, unit: *Unit, io: *exec.IORequest) void {
    const req = _disk.stdReq(io);
    const write = io.command == exec.CMD_WRITE;
    if (!_disk.inside(unit, req.offset, req.length)) {
        io.err = exec.IOERR_BADADDRESS;
        return;
    }
    if (write and unit.write_protected) {
        io.err = td.TDERR_WriteProt;
        return;
    }
    if (req.length == 0) return;
    const bytes: [*]u8 = @ptrCast(req.data orelse {
        io.err = exec.IOERR_BADADDRESS;
        return;
    });
    const block_bytes = unit.block_bytes;
    const piece_most: u64 = @max(max_transfer / block_bytes, 1) * block_bytes;
    var done: u64 = 0;
    while (done < req.length) {
        const piece: u32 = @intCast(@min(req.length - done, piece_most));
        const block = (req.offset + done) / block_bytes;
        const command = scsi.readWrite(write, block, piece / block_bytes);
        const result = bot.run(&function.transport, unit.lun, command.slice(), bytes + @as(usize, @intCast(done)), piece, !write, data_ms);
        switch (result.outcome) {
            .passed => if (result.moved != piece) {
                io.err = td.TDERR_NotSpecified;
                break;
            },
            .failed => {
                io.err = failure(base, function, unit);
                break;
            },
            .gone => {
                io.err = td.TDERR_NoCard;
                break;
            },
            .broken => {
                io.err = td.TDERR_NotSpecified;
                break;
            },
        }
        done += piece;
    }
    req.actual = done;
}

/// What a failed command's sense makes of it, as io_Error; a medium found
/// gone or changed is let go of here.
fn failure(base: *DiskBase, function: *Function, unit: *Unit) i8 {
    const sense = senseOf(function, unit) orelse return td.TDERR_NotSpecified;
    if (sense.noMedium()) {
        depart(base, unit);
        return td.TDERR_NoCard;
    }
    if (sense.writeProtected()) {
        unit.write_protected = true;
        return td.TDERR_WriteProt;
    }
    if (sense.changed()) {
        // Another medium, or the same one again: either way the handler
        // has to look at it afresh.
        depart(base, unit);
        probe(base, function, unit);
        return td.TDERR_DiskChanged;
    }
    return td.TDERR_NotSpecified;
}

/// HD_SCSICMD: the command block to the unit as it is.
fn scsiCommand(function: *Function, unit: *Unit, io: *exec.IORequest) void {
    const req = _disk.stdReq(io);
    if (req.length < @sizeOf(scsidisk.SCSICmd)) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    const cmd: *scsidisk.SCSICmd = @ptrCast(@alignCast(req.data orelse {
        io.err = exec.IOERR_BADADDRESS;
        return;
    }));
    const block = cmd.command orelse {
        io.err = exec.IOERR_BADADDRESS;
        return;
    };
    if (cmd.cmd_length == 0 or cmd.cmd_length > 16) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    const in = cmd.flags & scsidisk.SCSIF_READ != 0;
    const length: u32 = if (cmd.data == null) 0 else cmd.length;
    const result = bot.run(&function.transport, unit.lun, block[0..cmd.cmd_length], cmd.data, length, in, data_ms);
    cmd.cmd_actual = cmd.cmd_length;
    cmd.actual = result.moved;
    cmd.sense_actual = 0;
    req.actual = @sizeOf(scsidisk.SCSICmd);
    switch (result.outcome) {
        .passed => cmd.status = scsidisk.SCSI_STATUS_GOOD,
        .failed => {
            cmd.status = scsidisk.SCSI_STATUS_CHECK_CONDITION;
            io.err = scsidisk.HFERR_BadStatus;
            if (cmd.flags & scsidisk.SCSIF_AUTOSENSE != 0) if (cmd.sense_data) |into| {
                const room = @min(cmd.sense_length, scsi.sense_bytes);
                const sensed = run(function, unit, scsi.requestSense().slice(), function.scratch[0..scsi.sense_bytes], true, answer_ms);
                if (sensed.outcome == .passed) {
                    const got = @min(room, sensed.moved);
                    @memcpy(into[0..got], function.scratch[0..got]);
                    cmd.sense_actual = got;
                }
            };
        },
        .gone => io.err = scsidisk.HFERR_SelTimeout,
        .broken => io.err = scsidisk.HFERR_Phase,
    }
}
