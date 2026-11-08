// SPDX-License-Identifier: MIT
//! The requests' side of intelnet.device: the task every one of them
//! runs on, the interrupt that wakes it, and the device's six vectors
//! above AbortIO.
//!
//! **Every request runs on the device's own task**, except S2_DEVICEQUERY
//! and S2_GETSTATIONADDRESS, which touch no opener's buffers and are
//! answered where they are asked. The openers' copy calls are made only
//! on the task, so BeginIO queues the rest to it. One task serves every
//! card: a request names its unit, and the unit is the card.
//!
//! **What an interrupt does.** It takes the causes the controller
//! raised, which clears them - they would come straight back otherwise -
//! notes them in the card and signals the task. Nothing else happens
//! there: no descriptor is read, no frame is copied, no opener is
//! walked.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ExecBase = sdk.interface.exec.ExecBase;
const _intelnet = @import("_intelnet.zig");
const IntelnetBase = _intelnet.IntelnetBase;
const Card = _intelnet.Card;
const mac = @import("mac.zig");

/// Enough for a request and the openers' copy calls; nothing here
/// recurses.
pub const stack_size = 8192;
/// Above dos's processes, as the other devices' tasks are: a stack waits
/// on this, and frames should not wait in a ring for a shell.
pub const task_pri = 5;

// --- the interrupt ----------------------------------------------------------------

/// A card's interrupt. What the controller raised is taken and noted,
/// and the task is signalled; a card that raised nothing is one whose
/// interrupt line belongs to someone else this time.
pub fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const card: *Card = @ptrCast(@alignCast(is_data.?));
    // The causes go off before they are read and back on when the task
    // has emptied the rings, so one interrupt stands for a pass of the
    // rings however many frames that pass finds. A line carrying frames
    // back to back raises one interrupt apiece otherwise, which leaves
    // the task no room to empty the ring the interrupts are about.
    mac.maskCauses(card.regs, card.family);
    const causes = mac.takeCauses(card.regs, card.family) orelse {
        card.unmaskCauses();
        return 0;
    };
    var raised = _intelnet.raised_work;
    if (causes & mac.cause_lsc != 0) raised |= _intelnet.raised_link;
    // The descriptor threshold is a nudge, not a loss: it says the ring
    // is running low, which the task empties it for anyway. Only an
    // overrun means a frame was really dropped.
    if (causes & mac.cause_rxo != 0) raised |= _intelnet.raised_lost;
    card.raised |= raised;
    const base = card.base;
    if (base.ready != 0) card.sys.Signal(&base.task, base.int_mask);
    return 1;
}

/// What a card has raised since the task last looked, taken.
fn takeRaised(card: *Card) u32 {
    const sys = card.sys;
    sys.Disable();
    defer sys.Enable();
    const raised = card.raised;
    card.raised = 0;
    return raised;
}

// --- the task ---------------------------------------------------------------------

/// Every request, and every frame in and out. The port is given its
/// signal before the first message is taken, so a request that came in
/// while the device was starting is not missed.
pub fn netTask(sys: *ExecBase) callconv(.c) void {
    const base: *IntelnetBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const port = &base.port;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(base);
    sys.Disable();
    port.sig_bit = @intCast(signal);
    port.sig_task = &base.task;
    port.flags = exec.PA_SIGNAL;
    sys.Enable();

    const int_signal = sys.AllocSignal(-1);
    if (int_signal < 0) return started(base);
    base.int_mask = @as(u32, 1) << @intCast(int_signal);
    base.ready = 1;
    started(base);

    while (true) {
        for (base.cards[0..base.card_count]) |maybe| {
            const card = maybe orelse continue;
            const raised = takeRaised(card);
            if (raised == 0) continue;
            if (raised & _intelnet.raised_lost != 0) card.net.overrun();
            if (raised & _intelnet.raised_link != 0) card.linkChanged();
            card.received();
            card.sent();
            // The rings are empty: the controller may raise its causes
            // again. The interrupt that turned them off is answered by
            // this and by nothing sooner.
            card.unmaskCauses();
        }
        while (sys.GetMsg(port)) |msg| {
            const io = _intelnet.requestOf(msg);
            _intelnet.cardOf(io).net.perform(_intelnet.sanaReq(io));
        }
        _ = sys.Wait(port.sigMask() | base.int_mask);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(base: *IntelnetBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

// --- the device's vectors ---------------------------------------------------------

/// The commands the task answers.
fn queued(command: u16) bool {
    return switch (command) {
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_FLUSH,
        net.S2_CONFIGINTERFACE,
        net.S2_ADDMULTICASTADDRESS,
        net.S2_DELMULTICASTADDRESS,
        net.S2_MULTICAST,
        net.S2_BROADCAST,
        net.S2_TRACKTYPE,
        net.S2_UNTRACKTYPE,
        net.S2_GETTYPESTATS,
        net.S2_GETSPECIALSTATS,
        net.S2_GETGLOBALSTATS,
        net.S2_ONEVENT,
        net.S2_READORPHAN,
        net.S2_ONLINE,
        net.S2_OFFLINE,
        => true,
        else => false,
    };
}

pub fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const card = _intelnet.cardOf(io);
    const req = _intelnet.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => card.net.query(req),
        net.S2_GETSTATIONADDRESS => card.net.stationAddress(req),
        else => if (queued(io.command)) {
            // It will be replied, so it needs a reply port, and it is
            // not quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return card.sys.PutMsg(&card.base.port, &io.message);
            }
        } else {
            io.err = exec.IOERR_NOCMD;
        },
    }
    card.sys.ReplyIO(io);
}

/// A request the task hasn't taken yet, or one waiting in a unit - a
/// read, a write, an event - is taken back and answered as aborted. One
/// already in a send descriptor can't be stopped.
pub fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _intelnet.intelnetBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    var it = base.port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_intelnet.requestOf(msg) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (_intelnet.cardOf(io).net.abort(_intelnet.sanaReq(io))) 0 else -1;
}

pub fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _intelnet.intelnetBase(dev);
    if (base.ready == 0 or unit_number >= base.card_count) return exec.IOERR_OPENFAIL;
    const card = base.cards[unit_number] orelse return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = card.net.open(_intelnet.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    card.unit.open_cnt += 1;
    io.unit = &card.unit;
    return 0;
}

pub fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const card = _intelnet.cardOf(io);
    card.net.close(_intelnet.sanaReq(io));
    card.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, the cards' interrupts and their
/// PCI functions. The seglist it was loaded from is kept in the base for
/// the day it does go.
pub fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}
