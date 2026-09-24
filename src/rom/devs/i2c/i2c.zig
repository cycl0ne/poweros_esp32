// SPDX-License-Identifier: MPL-2.0
//! i2c.device: the chip's two I2C controllers as units 0 and 1.
//!
//! A unit is a bus, and a bus carries one transfer at a time. That is the
//! whole design: every request that touches the wire goes on the unit's
//! queue, the head of the queue owns the controller, and the next one
//! starts when the head is done. There is no task and no semaphore - the
//! queue is the arbitration, and the controller's interrupt is what moves
//! it along.
//!
//! A request is marked with where it stands (IOF_QUEUED, IOF_CURRENT,
//! IOF_DONE), so AbortIO can tell a request that has not begun from the
//! one on the wire, and so finishing a request twice - a reply racing an
//! abort - does nothing the second time.
//!
//! **Short transfers never leave BeginIO.** Most of what an I2C bus is
//! used for is two or three bytes: set a register, read a register, poke a
//! pin on an expander. At 400 kHz that is under 100 microseconds, less
//! than it costs to put a message on a port, switch to another task and
//! switch back. So when the caller allows quick I/O and the bus is free,
//! BeginIO starts the transfer and spins on the controller for up to
//! `spin_us` with the controller's interrupt switched off. If it finishes
//! inside that window the caller gets the result with IOF_QUICK still set
//! and nothing was queued, signalled or scheduled. If it does not, the
//! request loses IOF_QUICK, the interrupt is switched on, and it finishes
//! the ordinary way - which is what a long transfer, a slow bus or a slave
//! that stretches the clock gets.
//!
//! A transfer longer than the 32-byte FIFO is sent in chunks: each command
//! list ends in END instead of STOP, which raises END_DETECT and leaves
//! the bus held while the next chunk is loaded. `advance` is the one place
//! that happens, and both the spin and the interrupt server call it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.devices.i2c;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const intbits = sdk.hardware.intbits;
const ExecBase = sdk.interface.exec.ExecBase;
const hw = @import("hw.zig");
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const regs = sdk.hardware.i2c;
const systimer = sdk.hardware.systimer;

pub const DEVICE_NAME = types.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "16.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// How long BeginIO will spin on the controller before it gives the
/// request to the interrupt. A two-byte exchange at 400 kHz is about
/// 70 microseconds and a register read about 100, so this covers what the
/// bus is mostly used for and gives up on anything longer.
const spin_us: u64 = 250;

/// Nine pulses is what frees a slave that is holding SDA down: enough for
/// it to finish the byte it thinks it is sending.
const clear_pulses: u32 = 9;

const vec = exec.libraries.vec;

/// Which half of a transfer is on the wire.
const phase_idle: u8 = 0;
const phase_write: u8 = 1;
const phase_read: u8 = 2;

/// One controller: its queue, its parameters and the transfer in flight.
const I2CUnit = extern struct {
    unit: exec.Unit,
    /// The interrupt server on the controller's own line.
    int: exec.Interrupt,
    /// Back to the device, for SysBase.
    base: *I2CBase = undefined,
    /// Which controller, as hw.Port.
    port: u8 = 0,
    /// The pads, or PIN_KEEP when the unit has none yet.
    scl_pin: u8 = types.PIN_KEEP,
    sda_pin: u8 = types.PIN_KEEP,
    /// The controller has been set up with the parameters below.
    ready: u8 = 0,
    /// CMD_STOP: requests are taken but none is started.
    stopped: u8 = 0,
    /// A transfer is on the wire.
    busy: u8 = 0,
    /// The next chunk opens with a (repeated) START and the address.
    first: u8 = 0,
    /// phase_*
    phase: u8 = phase_idle,
    /// SCL in Hz.
    speed: u32 = types.SPEED_DEFAULT,
    /// The slave of the transfer in flight.
    addr: u16 = 0,
    /// What is left to write, and what has gone.
    wr: ?[*]const u8 = null,
    wr_len: u32 = 0,
    wr_done: u32 = 0,
    /// What is left to read, and what has come in.
    rd: ?[*]u8 = null,
    rd_len: u32 = 0,
    rd_done: u32 = 0,
    /// What ended the transfer, for the request the queue's head holds.
    err: i8 = 0,
    /// The interrupt server is on its line: from the unit's first open, so
    /// a controller nothing uses holds no CPU line.
    hooked: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
};

/// The device's base: both units, one device.
const I2CBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase = undefined,
    /// gpio.resource, which the units' pads are taken from; null on a
    /// machine without it, where nothing is taken.
    gpio_base: ?*GpioBase = null,
    units: [types.UNIT_COUNT]I2CUnit,
};

fn i2cBase(dev: *exec.Device) *I2CBase {
    return @fieldParentPtr("dev", dev);
}

/// The unit a request belongs to.
fn unitOf(io: *exec.IORequest) *I2CUnit {
    const unit = io.unit.?;
    return @fieldParentPtr("unit", unit);
}

fn portOf(u: *I2CUnit) hw.Port {
    return @enumFromInt(@as(u1, @intCast(u.port)));
}

fn sysOf(u: *I2CUnit) *ExecBase {
    return u.base.sys_base;
}

fn i2cReq(io: *exec.IORequest) *types.IOExtI2C {
    const std_req: *exec.IOStdReq = @alignCast(@fieldParentPtr("req", io));
    return @fieldParentPtr("req", std_req);
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a node on the unit's queue belongs to.
fn requestOf(node: *exec.Node) *exec.IORequest {
    const msg: *exec.Message = @fieldParentPtr("node", node);
    return @fieldParentPtr("message", msg);
}

/// The request that owns the controller, if there is one.
fn headOf(u: *I2CUnit) ?*exec.IORequest {
    const node = u.unit.msg_port.msg_list.first() orelse return null;
    return requestOf(node);
}

// --- the transfer ---------------------------------------------------------

/// The next command list into the controller's registers, and away. The
/// bytes of a write go into the TX FIFO first; a read's come back through
/// the RX FIFO, which is why a chunk is never longer than the FIFO.
fn fill(u: *I2CUnit) void {
    const port = portOf(u);
    var c: u32 = 0;
    if (u.phase == phase_write) {
        var n: u32 = 0;
        if (u.first != 0) {
            hw.setCmd(port, c, hw.cmd(.restart, 0, false, false));
            c += 1;
            hw.push(port, @truncate(u.addr << 1)); // bit 0 clear: writing
            n = 1;
            u.first = 0;
        }
        while (n < regs.FIFO_LEN and u.wr_done < u.wr_len) : (n += 1) {
            hw.push(port, u.wr.?[u.wr_done]);
            u.wr_done += 1;
        }
        hw.setCmd(port, c, hw.cmd(.write, n, true, false));
        c += 1;
        if (u.wr_done >= u.wr_len and u.rd_len == 0) {
            hw.setCmd(port, c, hw.cmd(.stop, 0, false, false));
        } else {
            hw.setCmd(port, c, hw.cmd(.end, 0, false, false));
        }
    } else {
        if (u.first != 0) {
            hw.setCmd(port, c, hw.cmd(.restart, 0, false, false));
            c += 1;
            hw.push(port, @truncate((u.addr << 1) | 1)); // bit 0 set: reading
            hw.setCmd(port, c, hw.cmd(.write, 1, true, false));
            c += 1;
            u.first = 0;
        }
        var n = u.rd_len - u.rd_done;
        if (n > regs.FIFO_LEN) n = regs.FIFO_LEN;
        if (u.rd_done + n >= u.rd_len) {
            // The last byte of the whole read is left unacknowledged: that
            // is how a master tells a slave to stop sending.
            if (n > 1) {
                hw.setCmd(port, c, hw.cmd(.read, n - 1, false, false));
                c += 1;
            }
            hw.setCmd(port, c, hw.cmd(.read, 1, false, true));
            c += 1;
            hw.setCmd(port, c, hw.cmd(.stop, 0, false, false));
        } else {
            hw.setCmd(port, c, hw.cmd(.read, n, false, false));
            c += 1;
            hw.setCmd(port, c, hw.cmd(.end, 0, false, false));
        }
    }
    hw.start(port);
}

/// What the RX FIFO holds, into the caller's buffer.
fn drainRx(u: *I2CUnit) void {
    const port = portOf(u);
    while (u.rd_done < u.rd_len and hw.rxCount(port) > 0) {
        u.rd.?[u.rd_done] = hw.pop(port);
        u.rd_done += 1;
    }
}

/// One turn of the controller's state machine: an error ends the transfer,
/// a completion ends it, and an END means another chunk goes out. Returns
/// the request that is finished, still on the queue. Disable held, or at
/// interrupt level.
fn advance(u: *I2CUnit) ?*exec.IORequest {
    if (u.busy == 0) return null;
    const port = portOf(u);
    const raw = hw.intRaw(port);
    if (raw & hw.INT_MASTER == 0) return null;

    if (raw & hw.INT_ERRORS != 0) {
        u.err = if (raw & regs.INT_NACK != 0)
            types.I2CErr_NoAck
        else if (raw & regs.INT_ARBITRATION_LOST != 0)
            types.I2CErr_ArbLost
        else
            types.I2CErr_Timeout;
        hw.fsmReset(port);
        u.busy = 0;
        return headOf(u);
    }

    if (raw & regs.INT_TRANS_COMPLETE != 0) {
        if (u.phase == phase_read) drainRx(u);
        hw.intClear(port, regs.INT_TRANS_COMPLETE | regs.INT_END_DETECT);
        u.err = 0;
        u.busy = 0;
        return headOf(u);
    }

    // END_DETECT: the bus is held, the next chunk goes out.
    if (u.phase == phase_read) drainRx(u);
    hw.intClear(port, regs.INT_END_DETECT);
    if (u.phase == phase_write and u.wr_done >= u.wr_len and u.rd_len > 0) {
        u.phase = phase_read;
        u.first = 1;
    }
    fill(u);
    return null;
}

/// The transfer `io` asks for, onto the wire. Disable held. `silent` keeps
/// the controller's interrupt off, which is what the caller that means to
/// spin on it wants.
fn startTransfer(u: *I2CUnit, io: *exec.IORequest, silent: bool) void {
    const port = portOf(u);
    const req = i2cReq(io);
    u.addr = req.address;
    u.err = 0;
    u.wr_done = 0;
    u.rd_done = 0;
    switch (io.command) {
        exec.CMD_WRITE => {
            u.wr = @ptrCast(req.req.data);
            u.wr_len = @intCast(req.req.length);
            u.rd = null;
            u.rd_len = 0;
        },
        exec.CMD_READ => {
            u.wr = null;
            u.wr_len = 0;
            u.rd = @ptrCast(req.req.data);
            u.rd_len = @intCast(req.req.length);
        },
        types.I2CCMD_WRITEREAD => {
            u.wr = @ptrCast(req.wr_data);
            u.wr_len = req.wr_length;
            u.rd = @ptrCast(req.req.data);
            u.rd_len = @intCast(req.req.length);
        },
        else => { // I2CCMD_PROBE: the address and nothing else
            u.wr = null;
            u.wr_len = 0;
            u.rd = null;
            u.rd_len = 0;
        },
    }
    // A read with nothing to write first still opens with the address, so
    // the write phase is only skipped when there is a read to do.
    u.phase = if (u.wr_len == 0 and u.rd_len > 0) phase_read else phase_write;
    u.first = 1;
    u.busy = 1;
    hw.fifoReset(port);
    hw.intClear(port, 0xFFFF_FFFF);
    hw.intEnable(port, if (silent) 0 else hw.INT_MASTER);
    fill(u);
}

/// The head of the queue onto the wire, if there is one and the unit is
/// running. Disable held.
fn startHead(u: *I2CUnit) void {
    if (u.stopped != 0 or u.busy != 0) return;
    const io = headOf(u) orelse return;
    startTransfer(u, io, false);
}

// --- the queue ------------------------------------------------------------

/// Off the queue and back to its caller. Set IOF_DONE once, so an abort
/// racing a completion does nothing the second time, and hand the
/// controller to whatever is next.
fn endCommand(u: *I2CUnit, io: *exec.IORequest, err: i8) void {
    const sys = sysOf(u);
    sys.Disable();
    if (io.flags & exec.IOF_DONE != 0) {
        sys.Enable();
        return;
    }
    io.flags |= exec.IOF_DONE;
    io.err = err;
    const req = stdReq(io);
    switch (io.command) {
        exec.CMD_READ, types.I2CCMD_WRITEREAD => req.actual = u.rd_done,
        types.I2CCMD_PROBE => {
            // A silent address is an answer, not a failure.
            req.actual = if (err == types.I2CErr_NoAck) 0 else 1;
            if (err == types.I2CErr_NoAck) io.err = 0;
        },
        else => req.actual = u.wr_done,
    }
    const was_current = io.flags & exec.IOF_CURRENT != 0;
    if (io.flags & (exec.IOF_CURRENT | exec.IOF_QUEUED) != 0) {
        sys.Remove(&io.message.node);
        io.flags &= ~(exec.IOF_CURRENT | exec.IOF_QUEUED);
    }
    if (was_current) {
        if (headOf(u)) |next| next.flags |= exec.IOF_CURRENT;
        startHead(u);
    }
    sys.Enable();
    sys.ReplyIO(io);
}

/// One turn of the state machine, and the request it finished replied.
fn serve(u: *I2CUnit) void {
    const sys = sysOf(u);
    sys.Disable();
    const finished = advance(u);
    const err = u.err;
    sys.Enable();
    if (finished) |io| endCommand(u, io, err);
}

/// The controller's interrupt: whatever it raised, acted on. A line that
/// raises something with no transfer on it is quietened rather than left
/// to ask again, since these are level interrupts.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const u: *I2CUnit = @ptrCast(@alignCast(is_data.?));
    const port = portOf(u);
    if (hw.intRaw(port) & hw.INT_MASTER == 0) return 0; // not ours
    if (u.busy == 0) {
        hw.intEnable(port, 0);
        hw.intClear(port, 0xFFFF_FFFF);
        return 1;
    }
    serve(u);
    return 1;
}

/// Whether the bus is free to start a transfer on.
///
/// A transfer started on a bus that a slave is still holding may never
/// raise an interrupt at all - not even the controller's timeout, which
/// counts a line that stops moving rather than one that never started - and
/// a request waiting for that completion would wait for ever. So a held bus
/// is reset once and looked at again, and a request that still cannot have
/// it is refused rather than queued behind a completion that cannot come.
fn busReady(u: *I2CUnit) bool {
    const sys = sysOf(u);
    sys.Disable();
    defer sys.Enable();
    // A transfer of ours is on the wire: this request queues behind it and
    // starts when that one ends.
    if (u.busy != 0) return true;
    const port = portOf(u);
    if (!hw.busBusy(port)) return true;
    hw.fsmReset(port);
    return !hw.busBusy(port);
}

/// Whether `io` can wait: it will be replied, so it needs a reply port.
fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK; // done now: no reply
    return false;
}

/// A bus command onto the unit's queue, and, if it is now the head and the
/// unit is free, onto the wire. A caller that allows quick I/O then spins
/// on the controller for `spin_us` rather than waiting to be signalled.
fn submit(u: *I2CUnit, io: *exec.IORequest) void {
    const sys = sysOf(u);
    if (!canWait(io)) return sys.ReplyIO(io);
    const quick = io.flags & exec.IOF_QUICK != 0;

    sys.Disable();
    io.flags &= ~(exec.IOF_CURRENT | exec.IOF_QUEUED | exec.IOF_DONE);
    // A queued request is a message again, as PutMsg would make it:
    // WaitIO looks at the node's type, and the reply left there by
    // its last use would let a caller past before this one has run.
    io.message.node.type = .message;
    sys.AddTail(&u.unit.msg_port.msg_list, &io.message.node);
    const mine = u.unit.msg_port.msg_list.first() == &io.message.node;
    io.flags |= if (mine) exec.IOF_CURRENT else exec.IOF_QUEUED;
    const spinning = mine and quick and u.stopped == 0 and u.busy == 0;
    if (spinning) {
        startTransfer(u, io, true);
    } else {
        io.flags &= ~exec.IOF_QUICK; // it will be replied
        startHead(u);
    }
    sys.Enable();
    if (!spinning) return;

    // Nothing else can finish this request: the controller's interrupt is
    // off and this is the only one looking at it.
    const deadline = systimer.uptimeUs() + spin_us;
    while (io.flags & exec.IOF_DONE == 0) {
        if (hw.intRaw(portOf(u)) & hw.INT_MASTER != 0) serve(u);
        if (systimer.uptimeUs() >= deadline) break;
    }
    sys.Disable();
    if (io.flags & exec.IOF_DONE == 0) {
        // Too slow for quick I/O. It gets a reply and the interrupt.
        io.flags &= ~exec.IOF_QUICK;
        hw.intEnable(portOf(u), hw.INT_MASTER);
    }
    sys.Enable();
}

// --- the commands that don't use the queue --------------------------------

/// The unit's parameters, and the controller set up from them.
fn setParams(u: *I2CUnit, io: *exec.IORequest) void {
    const req = i2cReq(io);
    const speed = if (req.speed == 0) u.speed else req.speed;
    const scl = if (req.scl_pin == types.PIN_KEEP) u.scl_pin else req.scl_pin;
    const sda = if (req.sda_pin == types.PIN_KEEP) u.sda_pin else req.sda_pin;
    if (speed < types.SPEED_MIN or speed > types.SPEED_MAX) {
        io.err = types.I2CErr_InvParam;
        return;
    }
    if (scl == types.PIN_KEEP or sda == types.PIN_KEEP or scl == sda) {
        io.err = types.I2CErr_InvParam;
        return;
    }
    const gpio = @import("sdk").hardware.gpio;
    if (scl > gpio.max_pin or sda > gpio.max_pin) {
        io.err = types.I2CErr_InvParam;
        return;
    }
    if (u.busy != 0) {
        io.err = exec.IOERR_UNITBUSY;
        return;
    }
    if (!movePads(u, scl, sda)) {
        io.err = types.I2CErr_InvParam;
        return;
    }
    u.speed = speed;
    u.scl_pin = scl;
    u.sda_pin = sda;
    u.ready = if (hw.setUp(portOf(u), u.speed, u.scl_pin, u.sda_pin)) 1 else 0;
    if (u.ready == 0) io.err = types.I2CErr_InvParam;
}

/// The unit's pads, taken from gpio.resource: the new pair taken before
/// the old is given back, so a refusal leaves the unit as it was. False
/// when another driver holds one of the new pads.
fn movePads(u: *I2CUnit, scl: u8, sda: u8) bool {
    if (scl == u.scl_pin and sda == u.sda_pin) return true;
    const gb = u.base.gpio_base orelse return true;
    const old = [_]u8{ u.scl_pin, u.sda_pin };
    // A pad the unit already has is not asked for again.
    var wanted: [2]u8 = undefined;
    var count: usize = 0;
    for ([_]u8{ scl, sda }) |pad| {
        if (pad != old[0] and pad != old[1]) {
            wanted[count] = pad;
            count += 1;
        }
    }
    if (gpio_resource.allocPads(gb, wanted[0..count], DEVICE_NAME)) |refused| {
        sdk.exec.kprintf(u.base.sys_base, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, refused.pad, refused.holder });
        return false;
    }
    for (old) |pad| {
        if (pad != types.PIN_KEEP and pad != scl and pad != sda) gb.FreeGPIO(pad);
    }
    return true;
}

fn getParams(u: *I2CUnit, io: *exec.IORequest) void {
    const req = i2cReq(io);
    req.speed = u.speed;
    req.scl_pin = u.scl_pin;
    req.sda_pin = u.sda_pin;
}

/// Free a bus a slave is holding down, and set the controller up again.
fn clearBus(u: *I2CUnit, io: *exec.IORequest) void {
    if (u.busy != 0) {
        io.err = exec.IOERR_UNITBUSY;
        return;
    }
    if (u.ready == 0) {
        io.err = types.I2CErr_InvParam;
        return;
    }
    const port = portOf(u);
    hw.fsmReset(port);
    hw.clearBus(port, clear_pulses);
    // Nine pulses at the slowest speed this unit takes is well under a
    // millisecond; the deadline is there so a dead controller cannot hang
    // the caller.
    const deadline = systimer.uptimeUs() + 20_000;
    while (!hw.busClearDone(port) and systimer.uptimeUs() < deadline) {}
    _ = hw.setUp(port, u.speed, u.scl_pin, u.sda_pin);
}

/// Every request that has not begun, back with IOERR_ABORTED. The one on
/// the wire goes too: the controller is reset under it.
fn flush(u: *I2CUnit) void {
    const sys = sysOf(u);
    // Held stopped while the queue drains, so that ending one request does
    // not start the next one only for the next turn to abort it.
    const was_stopped = u.stopped;
    u.stopped = 1;
    defer u.stopped = was_stopped;
    while (true) {
        sys.Disable();
        const node = u.unit.msg_port.msg_list.first() orelse {
            sys.Enable();
            return;
        };
        const io = requestOf(node);
        if (io.flags & exec.IOF_CURRENT != 0 and u.busy != 0) {
            hw.fsmReset(portOf(u));
            u.busy = 0;
        }
        sys.Enable();
        endCommand(u, io, exec.IOERR_ABORTED);
    }
}

// --- the device -----------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const u = unitOf(io);
    const req = i2cReq(io);
    io.err = 0;
    req.req.actual = 0;

    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE, types.I2CCMD_WRITEREAD, types.I2CCMD_PROBE => {
            if (u.ready == 0) {
                io.err = types.I2CErr_InvParam;
            } else if (req.address > 0x7F or req.flags != 0) {
                io.err = types.I2CErr_InvParam;
            } else if (req.req.length > 0 and req.req.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (io.command == types.I2CCMD_WRITEREAD and
                req.wr_length > 0 and req.wr_data == null)
            {
                io.err = exec.IOERR_BADADDRESS;
            } else if (io.command == exec.CMD_READ and req.req.length == 0) {
                // Nothing to fetch, so nothing goes on the wire.
            } else if (!busReady(u)) {
                io.err = types.I2CErr_BusBusy;
            } else {
                return submit(u, io);
            }
        },
        types.I2CCMD_SETPARAMS => setParams(u, io),
        types.I2CCMD_GETPARAMS => getParams(u, io),
        exec.CMD_CLEAR => clearBus(u, io),
        exec.CMD_STOP => u.stopped = 1,
        exec.CMD_START => {
            u.stopped = 0;
            const sys = sysOf(u);
            sys.Disable();
            startHead(u);
            sys.Enable();
        },
        exec.CMD_FLUSH => flush(u),
        exec.CMD_RESET => {
            u.stopped = 1;
            flush(u);
            if (u.ready != 0) _ = hw.setUp(portOf(u), u.speed, u.scl_pin, u.sda_pin);
            u.stopped = 0;
        },
        exec.CMD_UPDATE => {}, // nothing is buffered
        else => io.err = exec.IOERR_NOCMD,
    }
    sysOf(u).ReplyIO(io);
}

/// A request that has not begun comes off the queue; the one on the wire
/// is stopped by resetting the controller under it, which is the only way
/// to take a transfer off an I2C bus.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    _ = dev;
    const u = unitOf(io);
    const sys = sysOf(u);
    sys.Disable();
    if (io.flags & (exec.IOF_CURRENT | exec.IOF_QUEUED) == 0) {
        sys.Enable();
        return -1;
    }
    if (io.flags & exec.IOF_CURRENT != 0 and u.busy != 0) {
        hw.fsmReset(portOf(u));
        u.busy = 0;
    }
    sys.Enable();
    endCommand(u, io, exec.IOERR_ABORTED);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = i2cBase(dev);
    if (unit_number >= types.UNIT_COUNT) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(types.IOExtI2C)) return exec.IOERR_OPENFAIL;
    const u = &base.units[unit_number];
    if (u.hooked == 0) {
        base.sys_base.AddIntServer(intbits.INTB_I2C_EXT0 + unit_number, &u.int);
        u.hooked = 1;
    }
    if (u.ready == 0 and u.scl_pin != types.PIN_KEEP and u.sda_pin != types.PIN_KEEP) {
        // A controller the machine does not have answers its registers
        // with zero. Opening a unit onto one would mean waiting for an
        // interrupt that can never come, so it fails here instead.
        if (!hw.setUp(portOf(u), u.speed, u.scl_pin, u.sda_pin)) return exec.IOERR_OPENFAIL;
        u.ready = 1;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    u.unit.open_cnt += 1;
    io.unit = &u.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const u = unitOf(io);
    u.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its interrupt servers are on the chip's lines and the
/// units hold pads that other drivers share.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The two units, their queues and their interrupt servers, made ready,
/// and the pads of the buses the board wires taken from gpio.resource. No
/// controller is touched and no CPU line taken here: that waits for the
/// unit's first Open.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const base = i2cBase(dev);
    base.sys_base = sys_base;
    base.gpio_base = @ptrCast(@alignCast(sys_base.OpenResource(gpio_resource.GPIONAME)));
    for (&base.units, 0..) |*u, i| {
        u.* = .{
            .unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } },
            .int = .{
                .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
                .data = u,
                .code = &intServer,
            },
            .base = base,
            .port = @intCast(i),
        };
        u.unit.msg_port.msg_list.init(.message);
    }
    boardBuses(base);
    return dev;
}

/// Each unit the board wires as an I2C bus comes up on its pads: the
/// board's first bus part is unit 0, its second unit 1. A unit the board
/// has no bus for waits for SETPARAMS, as does one whose lines are not
/// pads of the chip or whose pads another driver holds.
fn boardBuses(base: *I2CBase) void {
    const sys = base.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part = eb.FindBoardPart(null, st.PARTKIND_I2CBUS, st.CHIP_ANY);
    while (part) |bus| : (part = eb.FindBoardPart(bus, st.PARTKIND_I2CBUS, st.CHIP_ANY)) {
        if (bus.unit >= base.units.len) break;
        const scl = expansion.BoardPin.of(ub.GetTagData(st.PART_PinSCL, 0, bus.tags));
        const sda = expansion.BoardPin.of(ub.GetTagData(st.PART_PinSDA, 0, bus.tags));
        if (scl.kind != expansion.boardpin.BPIN_GPIO or sda.kind != expansion.boardpin.BPIN_GPIO) continue;
        const u = &base.units[bus.unit];
        if (!movePads(u, scl.number, sda.number)) continue;
        u.scl_pin = scl.number;
        u.sda_pin = sda.number;
    }
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(I2CBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start, before dos.library: a driver that wants the bus is welcome
/// to open it as soon as it comes up.
export const i2c_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &i2c_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 35,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
