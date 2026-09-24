// SPDX-License-Identifier: MPL-2.0
//! The units of serial.device and usbserial.device: one serial port each,
//! with serial.device's API (sdk/devices/serial.zig). serial.zig
//! describes the commands. Each device's ROM
//! tag (serial.zig, usbserial.zig) names its ports and gets a base with one
//! unit per port; the jump table (`vectors`) is the same for both.
//!
//! Input comes in by interrupt: each port's receive interrupt goes to
//! exec's AddIntServer. The unit's server puts the bytes into the unit's
//! buffer and fills its waiting CMD_READs, first come first served.
//!
//! The code builds against the SDK: the device keeps the SysBase its init
//! gets and calls exec (and timer.device) through the SDK's interfaces.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const timer = sdk.devices.timer;
const uart = @import("uart.zig");
const usbjtag = @import("usbjtag.zig");
const vec = exec.vec;
const types = sdk.devices.serial;
const IOExtSer = types.IOExtSer;

/// A unit's port: one of the chip's UARTs, or the USB-Serial-JTAG port,
/// which has no line (no rate, frame or breaks).
pub const Port = enum(u32) {
    uart0,
    uart1,
    uart2,
    usb,

    /// The UART, or null for the USB port.
    fn uartPort(port: Port) ?uart.Port {
        return switch (port) {
            .uart0 => .uart0,
            .uart1 => .uart1,
            .uart2 => .uart2,
            .usb => null,
        };
    }

    fn source(port: Port) u32 {
        return if (port.uartPort()) |p| p.source() else usbjtag.source;
    }

    /// A UART's clock and boot-up line (the USB port needs nothing).
    fn setUp(port: Port) void {
        if (port.uartPort()) |p| uart.setUp(p);
    }

    fn enableRx(port: Port) void {
        if (port.uartPort()) |p| uart.enableRx(p) else usbjtag.enableRx();
    }

    fn disableRx(port: Port) void {
        if (port.uartPort()) |p| uart.disableRx(p) else usbjtag.disableRx();
    }

    fn read(port: Port) ?u8 {
        return if (port.uartPort()) |p| uart.read(p) else usbjtag.read();
    }

    /// What the port's receive interrupt raised (cleared), or null.
    fn takeRxInterrupt(port: Port) ?uart.RxEvents {
        if (port.uartPort()) |p| return uart.takeRxInterrupt(p);
        return if (usbjtag.takeRxInterrupt()) .{} else null;
    }

    /// Polled.
    fn write(port: Port, bytes: []const u8) void {
        if (port.uartPort()) |p| {
            for (bytes) |c| uart.putTo(p, c);
        } else {
            for (bytes) |c| usbjtag.put(c);
            usbjtag.flush();
        }
    }
};

/// The slowest rate and the chip's fastest.
const min_baud = 112;
const max_baud = 5_000_000;
/// The smallest input buffer.
const min_rbuf_len = 64;

/// A unit's parameters: what SDCMD_SETPARAMS sets and OpenDevice shows.
const Params = extern struct {
    ctl_char: u32,
    rbuf_len: u32,
    ext_flags: u32,
    baud: u32,
    brk_time: u32,
    term_array: [8]u8,
    read_len: u8,
    write_len: u8,
    stop_bits: u8,
    /// The io_SerFlags that stay with the unit (unit_flags).
    ser_flags: u8,
};

/// The io_SerFlags the unit keeps. EOFMODE and QUEUEDBRK count per request,
/// SHARED per open.
const unit_flags: u8 = types.SERF_PARTY_ON | types.SERF_PARTY_ODD | types.SERF_XDISABLED | types.SERF_RAD_BOOGIE;

/// The boot-up parameters: 115200 8N1 (uart.setUp's line), a 512-byte
/// buffer, break (250 ms) and control characters, xON/xOFF off.
const default_params: Params = .{
    .ctl_char = types.SER_DEFAULT_CTLCHAR,
    .rbuf_len = 512,
    .ext_flags = 0,
    .baud = uart.default_baud,
    .brk_time = 250_000,
    .term_array = @splat(0),
    .read_len = 8,
    .write_len = 8,
    .stop_bits = 1,
    .ser_flags = types.SERF_XDISABLED,
};

/// A unit: one port.
const SerialUnit = extern struct {
    /// Its port (PA_IGNORE) holds the waiting CMD_READs.
    unit: exec.Unit,
    base: *SerialBase,
    port: Port,
    params: Params,
    /// Opened with SERF_SHARED: more openers with SERF_SHARED may come.
    shared: u32,
    /// Set by CMD_STOP, cleared by CMD_START and CMD_RESET.
    stopped: u32,
    /// io_Status's port state: IO_STATF_OVERRUN, _WROTEBREAK, _READBREAK,
    /// _XOFFWRITE.
    status: u16,
    /// A receive error (SerErr_*) for the read in progress or the next one.
    pending_err: i8,
    pad: u8,
    /// The CMD_WRITEs (and queued breaks) that CMD_STOP holds until
    /// CMD_START.
    write_queue: exec.List,
    /// The port's receive interrupt server.
    int: exec.Interrupt,
    /// The input buffer: io_RBufLen bytes while the unit is open, `count`
    /// of them from `start` on, wrapping around.
    buffer: ?[*]u8,
    buffer_size: u32,
    start: u32,
    count: u32,
    /// The SDCMD_BREAK in progress, and whether AbortIO ended it.
    breaking: ?*exec.IORequest,
    break_aborted: u32,
    /// timer.device for breaks: its request, the port its reply comes to
    /// (PA_SOFTINT), and the software interrupt that ends the break.
    timer_open: u32,
    brk_timer: timer.TimeRequest,
    brk_port: exec.MsgPort,
    brk_int: exec.Interrupt,
};

/// A device's base: the Device and SysBase; its units follow it
/// (unitsOf).
pub const SerialBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit_count: u32,
};

const units_offset = std.mem.alignForward(usize, @sizeOf(SerialBase), @alignOf(SerialUnit));

/// The base's size with `count` units: the device's InitTable data_size.
pub fn dataSize(comptime count: usize) usize {
    return units_offset + count * @sizeOf(SerialUnit);
}

fn unitsOf(sb: *SerialBase) []SerialUnit {
    const first: [*]SerialUnit = @ptrCast(@alignCast(@as([*]u8, @ptrCast(sb)) + units_offset));
    return first[0..sb.unit_count];
}

fn serialBase(dev: *exec.Device) *SerialBase {
    return @fieldParentPtr("dev", dev);
}

/// The unit an open request is on.
fn unitOf(io: *exec.IORequest) *SerialUnit {
    return @fieldParentPtr("unit", io.unit.?);
}

fn sysOf(u: *SerialUnit) *ExecBase {
    return u.base.sys_base;
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

/// Requests are IOExtSers.
fn serReq(io: *exec.IORequest) *IOExtSer {
    return @fieldParentPtr("io_ser", stdReq(io));
}

/// The request a node on a unit's port or write queue belongs to.
fn requestOf(node: *exec.Node) *exec.IORequest {
    const msg: *exec.Message = @fieldParentPtr("node", node);
    return @fieldParentPtr("message", msg);
}

// --- the input buffer ---------------------------------------------------

/// A received byte into the buffer; dropped while the unit isn't open. A
/// full buffer is an overrun. From the interrupt server, or with Disable
/// held.
fn store(u: *SerialUnit, c: u8) void {
    const buffer = u.buffer orelse return;
    if (u.count == u.buffer_size) {
        u.status |= types.IO_STATF_OVERRUN;
        setError(u, types.SerErr_BufOverflow);
        return;
    }
    buffer[(u.start + u.count) % u.buffer_size] = c;
    u.count += 1;
}

/// The oldest buffered byte (there is one). Disable held.
fn takeByte(u: *SerialUnit) u8 {
    const c = u.buffer.?[u.start];
    u.start = (u.start + 1) % u.buffer_size;
    u.count -= 1;
    return c;
}

/// A receive error for the read in progress or the next one; the first
/// one counts.
fn setError(u: *SerialUnit, err: i8) void {
    if (u.pending_err == 0) u.pending_err = err;
}

/// A new, empty input buffer of `size` bytes for the old one. False, and
/// the old one stays, without the memory. Task level.
fn newBuffer(u: *SerialUnit, size: u32) bool {
    const sys = sysOf(u);
    const mem = sys.AllocMem(size, exec.MEMF_ANY) orelse return false;
    sys.Disable();
    const old = u.buffer;
    const old_size = u.buffer_size;
    u.buffer = @ptrCast(mem);
    u.buffer_size = size;
    u.start = 0;
    u.count = 0;
    sys.Enable();
    if (old) |b| sys.FreeMem(b, old_size);
    return true;
}

fn freeBuffer(u: *SerialUnit) void {
    const sys = sysOf(u);
    sys.Disable();
    const old = u.buffer;
    u.buffer = null;
    u.count = 0;
    sys.Enable();
    if (old) |b| sys.FreeMem(b, u.buffer_size);
}

/// The buffered input into what the read `x` still wants. True once it is
/// done: io_Length bytes, or in EOF mode a termination character (it is
/// part of the data). Disable held.
fn fill(u: *SerialUnit, x: *IOExtSer) bool {
    const req = &x.io_ser;
    const data: [*]u8 = @ptrCast(req.data.?);
    const eof = x.ser_flags & types.SERF_EOFMODE != 0;
    while (req.actual < req.length and u.count != 0) {
        const c = takeByte(u);
        data[@intCast(req.actual)] = c;
        req.actual += 1;
        if (eof and std.mem.indexOfScalar(u8, &u.params.term_array, c) != null) return true;
    }
    return req.actual == req.length;
}

/// A pending receive error ends the read `io` with it, the read in
/// progress; the read-break and overrun state go with it. Disable
/// held.
fn takeError(u: *SerialUnit, io: *exec.IORequest) bool {
    if (u.pending_err == 0) return false;
    io.err = u.pending_err;
    u.pending_err = 0;
    u.status &= ~(types.IO_STATF_READBREAK | types.IO_STATF_OVERRUN);
    return true;
}

// --- requests -------------------------------------------------------------

/// Reply, unless the caller asked for IOF_QUICK and it's done in BeginIO.
fn termIO(u: *SerialUnit, io: *exec.IORequest) void {
    sysOf(u).ReplyIO(io);
}

/// Whether `io` can wait: it will be replied, so it needs a reply port.
/// Without one it fails now with IOERR_NOREPLYPORT; done
/// later, it would go into memory the caller may have reused, since WaitIO
/// can't wait for it.
fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK; // done now: no reply
    return false;
}

/// The unit's parameters into the IOExtSer, as OpenDevice and CMD_RESET
/// show them.
fn showParams(u: *SerialUnit, x: *IOExtSer) void {
    const p = &u.params;
    x.ctl_char = p.ctl_char;
    x.rbuf_len = p.rbuf_len;
    x.ext_flags = p.ext_flags;
    x.baud = p.baud;
    x.brk_time = p.brk_time;
    x.term_array = p.term_array;
    x.read_len = p.read_len;
    x.write_len = p.write_len;
    x.stop_bits = p.stop_bits;
    x.ser_flags = p.ser_flags | if (u.shared != 0) types.SERF_SHARED else 0;
    x.status = 0;
}

/// The unit's line onto its UART (the USB port has none).
fn applyLine(u: *SerialUnit) void {
    const port = u.port.uartPort() orelse return;
    const p = &u.params;
    uart.setLine(port, .{
        .baud = p.baud,
        .bits = p.read_len,
        .parity = if (p.ser_flags & types.SERF_PARTY_ON == 0) .none else if (p.ser_flags & types.SERF_PARTY_ODD != 0) .odd else .even,
        .stop_bits = p.stop_bits,
        .xon_xoff = p.ser_flags & types.SERF_XDISABLED == 0,
        .xon = @truncate(p.ctl_char >> 24),
        .xoff = @truncate(p.ctl_char >> 16),
    });
}

/// A device's init routine's work: a unit per port, each port set up (a
/// UART's clock, reset and boot-up line, unless it is up already) with its
/// receive interrupt on.
pub fn initDevice(dev: *exec.Device, sys_base: *ExecBase, ports: []const Port) void {
    const sb = serialBase(dev);
    sb.sys_base = sys_base;
    sb.unit_count = @intCast(ports.len);
    for (unitsOf(sb), ports) |*u, port| {
        u.base = sb;
        u.port = port;
        u.params = default_params;
        u.shared = 0;
        u.stopped = 0;
        u.status = 0;
        u.pending_err = 0;
        u.buffer = null;
        u.buffer_size = 0;
        u.start = 0;
        u.count = 0;
        u.breaking = null;
        u.break_aborted = 0;
        u.timer_open = 0;
        u.unit.msg_port.flags = exec.PA_IGNORE; // the device looks at it itself
        u.unit.msg_port.msg_list.init(.message);
        u.write_queue.init(.message);
        port.setUp();
        // Empty the port's FIFO (there is no buffer until the first open).
        // The receive interrupt stays off until its server is in place: one
        // raised before its source is routed is lost.
        port.disableRx();
        while (port.read()) |_| {}
        u.int = .{
            .node = .{ .type = .interrupt, .name = dev.node.name },
            .data = u,
            .code = vec(rxServer),
        };
        sys_base.AddIntServer(port.source(), &u.int);
        port.enableRx();
    }
}

/// Unit `unit_number` for an IOExtSer. Exclusive, unless it and every
/// opener before set SERF_SHARED. The first opener gets a fresh buffer.
/// The request's parameters are filled in from the unit.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return exec.IOERR_OPENFAIL;
    // A request that says it is too small would be written past its end.
    if (io.message.length != 0 and io.message.length < @sizeOf(IOExtSer)) return exec.IOERR_BADLENGTH;
    const u = &unitsOf(sb)[unit_number];
    const x = serReq(io);
    const shared = x.ser_flags & types.SERF_SHARED != 0;
    if (x.ser_flags & types.SERF_7WIRE != 0) return types.SerErr_InvParam;
    if (u.unit.open_cnt != 0 and !(shared and u.shared != 0)) return types.SerErr_DevBusy;
    if (u.unit.open_cnt == 0) {
        if (!newBuffer(u, u.params.rbuf_len)) return types.SerErr_BufErr;
        u.shared = @intFromBool(shared);
        u.pending_err = 0;
        u.status = 0;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    u.unit.open_cnt += 1;
    io.unit = &u.unit;
    showParams(u, x);
    return 0;
}

/// A request that still waits is aborted first. The unit's last close
/// frees its buffer and closes timer.device; the last close of a device
/// RemDevice marked LIBF_DELEXP expunges it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const u = unitOf(io);
    _ = remRequest(u, io);
    u.unit.open_cnt -= 1;
    if (u.unit.open_cnt == 0) {
        if (u.timer_open != 0) {
            sysOf(u).CloseDevice(&u.brk_timer.node);
            u.timer_open = 0;
        }
        freeBuffer(u);
        u.stopped = 0;
    }
    dev.open_cnt -= 1;
    if (dev.open_cnt == 0 and dev.flags & exec.LIBF_DELEXP != 0) return expunge(dev);
    return null;
}

/// While open, it only marks itself LIBF_DELEXP for the last close.
/// Otherwise it stops the receive interrupts, takes out its servers (exec
/// releases the sources), leaves the device list and frees its base.
/// InitResident can make it again from the ROM tag. The UARTs stay set up,
/// and kernel output goes on.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    if (dev.open_cnt != 0) {
        dev.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sb = serialBase(dev);
    const sys = sb.sys_base;
    for (unitsOf(sb)) |*u| {
        sys.Disable();
        u.port.disableRx();
        sys.Enable();
        sys.RemIntServer(u.port.source(), &u.int);
    }
    sys.Remove(&dev.node);
    // The jump table and the base, as MakeLibrary allocated them.
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null; // no seglist: the code is in ROM
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const u = unitOf(io);
    const x = serReq(io);
    io.err = 0;
    x.io_ser.actual = 0;
    switch (io.command) {
        exec.CMD_READ => return startRead(u, x),
        exec.CMD_WRITE => {
            if (u.stopped != 0) return hold(u, io);
            waitBreak(u);
            write(u, &x.io_ser);
        },
        exec.CMD_STOP => u.stopped = 1,
        exec.CMD_START => startIO(u),
        exec.CMD_CLEAR => clearInput(u),
        exec.CMD_FLUSH => flushQueued(u),
        exec.CMD_RESET => reset(u, x),
        types.SDCMD_QUERY => query(u, x),
        types.SDCMD_BREAK => return breakCmd(u, x),
        types.SDCMD_SETPARAMS => setParams(u, x),
        else => io.err = exec.IOERR_NOCMD,
    }
    termIO(u, io);
}

/// CMD_READ: takes what is buffered (unless the unit is stopped or other
/// reads wait), and is done at once if that completes it or an error is
/// pending; else it waits on the unit's port for the rest.
fn startRead(u: *SerialUnit, x: *IOExtSer) void {
    const sys = sysOf(u);
    const io = &x.io_ser.req;
    if (x.io_ser.length == 0) return termIO(u, io);
    if (x.io_ser.data == null) {
        io.err = exec.IOERR_BADADDRESS;
        return termIO(u, io);
    }
    sys.Disable();
    // Reads that wait already come first.
    const done = u.stopped == 0 and u.unit.msg_port.msg_list.first() == null and (fill(u, x) or takeError(u, io));
    if (done or !canWait(io)) {
        sys.Enable();
        return termIO(u, io);
    }
    io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
    sys.PutMsg(&u.unit.msg_port, &io.message); // NT_MESSAGE, for WaitIO
    sys.Enable();
}

/// A request CMD_STOP holds (a write, or a break with SERF_QUEUEDBRK): onto
/// the write queue until CMD_START. Done at once if CMD_START came in the
/// meantime.
fn hold(u: *SerialUnit, io: *exec.IORequest) void {
    const sys = sysOf(u);
    sys.Disable();
    if (u.stopped != 0 and canWait(io)) {
        io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
        io.message.node.type = .message; // for WaitIO, as PutMsg does
        // A queued request is a message again, as PutMsg would make it:
        // WaitIO looks at the node's type, and the reply left there by
        // its last use would let a caller past before this one has run.
        io.message.node.type = .message;
        sys.AddTail(&u.write_queue, &io.message.node);
        sys.Enable();
        return;
    }
    sys.Enable();
    if (io.err != 0) return termIO(u, io);
    doHeld(u, io);
}

/// What a held request does, once it may.
fn doHeld(u: *SerialUnit, io: *exec.IORequest) void {
    if (io.command == types.SDCMD_BREAK) return startBreak(u, io);
    waitBreak(u);
    write(u, stdReq(io));
    termIO(u, io);
}

/// CMD_WRITE, polled: io_Length bytes, or up to a NUL for -1, as they are.
fn write(u: *SerialUnit, req: *exec.IOStdReq) void {
    if (req.length == 0) return;
    const data: [*]const u8 = @ptrCast(req.data orelse {
        req.req.err = exec.IOERR_BADADDRESS;
        return;
    });
    const bytes = if (req.length == types.LENGTH_NUL_TERMINATED)
        std.mem.span(@as([*:0]const u8, @ptrCast(data)))
    else
        data[0..@intCast(req.length)];
    u.port.write(bytes);
    req.actual = @intCast(bytes.len);
}

/// CMD_START: the held requests, in order and in the caller's time, then
/// the buffered input to the waiting reads.
fn startIO(u: *SerialUnit) void {
    const sys = sysOf(u);
    u.stopped = 0;
    while (true) {
        sys.Disable();
        const node = if (u.stopped == 0) sys.RemHead(&u.write_queue) else null;
        sys.Enable();
        doHeld(u, requestOf(node orelse break));
    }
    serveReads(u);
}

/// CMD_CLEAR: drop the buffered input.
fn clearInput(u: *SerialUnit) void {
    sysOf(u).Disable();
    u.start = 0;
    u.count = 0;
    sysOf(u).Enable();
}

/// CMD_FLUSH: the queued requests replied with IOERR_ABORTED, but not the
/// active ones: the read being filled and the first held request
/// stay, and so does a break in progress.
fn flushQueued(u: *SerialUnit) void {
    for ([_]*exec.List{ &u.unit.msg_port.msg_list, &u.write_queue }) |list| {
        while (true) {
            sysOf(u).Disable();
            var it = list.iterator();
            _ = it.next(); // the active one
            const node = it.next();
            if (node) |n| sysOf(u).Remove(n);
            sysOf(u).Enable();
            abortRequest(u, requestOf(node orelse break));
        }
    }
}

/// Every waiting request, reads and held ones, replied with IOERR_ABORTED.
fn flushAll(u: *SerialUnit) void {
    for ([_]*exec.List{ &u.unit.msg_port.msg_list, &u.write_queue }) |list| {
        while (true) {
            sysOf(u).Disable();
            const node = sysOf(u).RemHead(list);
            sysOf(u).Enable();
            abortRequest(u, requestOf(node orelse break));
        }
    }
}

/// CMD_RESET: everything aborted, a break in progress too; the boot-up
/// parameters, on the line as well, and a buffer of their size; the
/// parameters go into the request.
fn reset(u: *SerialUnit, x: *IOExtSer) void {
    flushAll(u);
    abortBreak(u);
    u.params = default_params;
    applyLine(u);
    if (!newBuffer(u, default_params.rbuf_len)) {
        u.params.rbuf_len = u.buffer_size;
        clearInput(u);
    }
    u.pending_err = 0;
    u.status = 0;
    u.stopped = 0;
    showParams(u, x);
}

/// Replied with IOERR_ABORTED; io_Actual keeps what a read got so far.
fn abortRequest(u: *SerialUnit, io: *exec.IORequest) void {
    io.err = exec.IOERR_ABORTED;
    termIO(u, io);
}

/// A waiting request (a read, a held one, or the break in progress) ended
/// with IOERR_ABORTED. False if it isn't waiting.
fn remRequest(u: *SerialUnit, io: *exec.IORequest) bool {
    const sys = sysOf(u);
    if (u.breaking == io) {
        abortBreak(u);
        return true;
    }
    sys.Disable();
    const found = for ([_]*exec.List{ &u.unit.msg_port.msg_list, &u.write_queue }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            if (node == &io.message.node) break;
        } else continue;
        break true;
    } else false;
    if (found) sys.Remove(&io.message.node);
    sys.Enable();
    if (found) abortRequest(u, io);
    return found;
}

/// AbortIO: 0 if the request was aborted, -1 if it wasn't waiting.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    _ = dev;
    return if (remRequest(unitOf(io), io)) 0 else -1;
}

// --- SDCMD_QUERY and SDCMD_SETPARAMS -------------------------------------

/// SDCMD_QUERY: the bytes waiting, the lines and the port's state. The
/// query clears the break flags.
fn query(u: *SerialUnit, x: *IOExtSer) void {
    const sys = sysOf(u);
    sys.Disable();
    x.io_ser.actual = u.count;
    x.status = u.status | lineStatus(u);
    u.status &= ~(types.IO_STATF_READBREAK | types.IO_STATF_WROTEBREAK);
    sys.Enable();
}

/// io_Status's line bits, clear for an active line. The UARTs have no
/// carrier detect: CD is never active there. The USB port's lines count as
/// active.
fn lineStatus(u: *SerialUnit) u16 {
    const port = u.port.uartPort() orelse return 0;
    const l = uart.lines(port);
    var bits: u16 = types.IO_STATF_CD;
    if (l.dsr_n) bits |= types.IO_STATF_DSR;
    if (l.cts_n) bits |= types.IO_STATF_CTS;
    if (l.rts_n) bits |= types.IO_STATF_RTS;
    if (l.dtr_n) bits |= types.IO_STATF_DTR;
    return bits;
}

/// Whether requests are active or queued on the unit.
fn busy(u: *SerialUnit) bool {
    return u.unit.msg_port.msg_list.first() != null or u.write_queue.first() != null or u.breaking != null;
}

/// SDCMD_SETPARAMS: while the unit is busy only the xON/xOFF
/// switch is taken (and the answer is SerErr_DevBusy anyway). RAD_BOOGIE
/// turns xON/xOFF off; mark or space parity turns parity on. The new
/// io_SerFlags go back into the request.
fn setParams(u: *SerialUnit, x: *IOExtSer) void {
    const io = &x.io_ser.req;
    var flags = x.ser_flags;
    if (flags & types.SERF_RAD_BOOGIE != 0) flags |= types.SERF_XDISABLED;
    if (x.ext_flags & types.SEXTF_MSPON != 0) flags |= types.SERF_PARTY_ON;
    if (busy(u)) {
        u.params.ser_flags = (u.params.ser_flags & ~types.SERF_XDISABLED) | (flags & types.SERF_XDISABLED);
        applyLine(u);
        io.err = types.SerErr_DevBusy;
        return;
    }
    io.err = checkParams(u, x, flags);
    if (io.err != 0) return;
    if (x.rbuf_len != u.params.rbuf_len and !newBuffer(u, x.rbuf_len)) {
        io.err = types.SerErr_BufErr;
        return;
    }
    u.params = .{
        .ctl_char = x.ctl_char,
        .rbuf_len = x.rbuf_len,
        .ext_flags = x.ext_flags,
        .baud = x.baud,
        .brk_time = x.brk_time,
        .term_array = x.term_array,
        .read_len = x.read_len,
        .write_len = x.write_len,
        .stop_bits = x.stop_bits,
        .ser_flags = flags & unit_flags,
    };
    applyLine(u);
    x.ser_flags = flags;
}

/// The parameters' own checks, then what a UART can do. 0 if they pass.
fn checkParams(u: *SerialUnit, x: *IOExtSer, flags: u8) i8 {
    if (x.read_len == 0 or x.read_len > 8 or x.write_len == 0 or x.write_len > 8 or x.stop_bits > 2) return types.SerErr_InvParam;
    if (x.baud < min_baud or x.baud > max_baud or x.ctl_char == 0 or x.brk_time == 0) return types.SerErr_InvParam;
    if (x.rbuf_len < min_rbuf_len) return types.SerErr_BufErr;
    if (flags & types.SERF_7WIRE != 0) return types.SerErr_InvParam;
    if (u.port.uartPort() != null) {
        // One frame for both directions: 5 to 8 bits, 1 or 2 stop bits,
        // odd or even parity only.
        if (x.read_len != x.write_len or x.read_len < 5 or x.stop_bits == 0) return types.SerErr_InvParam;
        if (x.ext_flags & types.SEXTF_MSPON != 0) return types.SerErr_InvParam;
    }
    return 0;
}

// --- SDCMD_BREAK ----------------------------------------------------------

/// SDCMD_BREAK: at once, or with SERF_QUEUEDBRK behind what CMD_STOP holds.
/// The USB port has no line to hold low.
fn breakCmd(u: *SerialUnit, x: *IOExtSer) void {
    const io = &x.io_ser.req;
    if (u.port.uartPort() == null) {
        io.err = exec.IOERR_NOCMD;
        return termIO(u, io);
    }
    if (x.ser_flags & types.SERF_QUEUEDBRK != 0 and u.stopped != 0) return hold(u, io);
    startBreak(u, io);
}

/// Wait until the break in progress is over; its end comes in a software
/// interrupt. (Writes don't queue: they are done inside BeginIO.)
fn waitBreak(u: *SerialUnit) void {
    const breaking: *volatile ?*exec.IORequest = &u.breaking;
    while (breaking.* != null) {}
}

/// The line low for io_BrkTime µs: timer.device's reply ends it
/// (breakDone).
fn startBreak(u: *SerialUnit, io: *exec.IORequest) void {
    const sys = sysOf(u);
    waitBreak(u); // one at a time
    if (!openTimer(u)) {
        io.err = types.SerErr_TimerErr;
        return termIO(u, io);
    }
    if (!canWait(io)) return termIO(u, io);
    io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
    io.message.node.type = .message; // for WaitIO
    u.break_aborted = 0;
    uart.setBreak(u.port.uartPort().?, true);
    sys.Disable();
    u.breaking = io;
    sys.Enable();
    u.brk_timer.node.command = timer.TR_ADDREQUEST;
    u.brk_timer.time = timer.TimeVal.fromMicros(u.params.brk_time);
    sys.SendIO(&u.brk_timer.node);
}

/// timer.device for the unit's breaks, opened at the first one.
fn openTimer(u: *SerialUnit) bool {
    if (u.timer_open != 0) return true;
    u.brk_int = .{
        .node = .{ .type = .interrupt, .name = u.base.dev.node.name },
        .data = u,
        .code = vec(breakDone),
    };
    u.brk_port = .{ .flags = exec.PA_SOFTINT, .sig_task = &u.brk_int };
    u.brk_port.msg_list.init(.message);
    u.brk_timer = .{ .node = .{ .message = .{ .reply_port = &u.brk_port, .length = @sizeOf(timer.TimeRequest) } } };
    if (sysOf(u).OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &u.brk_timer.node, 0) != 0) return false;
    u.timer_open = 1;
    return true;
}

/// The break's timer request came back (the time is up, or AbortIO): the
/// line goes back to idle and the SDCMD_BREAK is replied. A software
/// interrupt.
fn breakDone(is_data: ?*anyopaque) callconv(.c) void {
    const u: *SerialUnit = @ptrCast(@alignCast(is_data.?));
    const sys = sysOf(u);
    while (sys.GetMsg(&u.brk_port)) |_| {}
    const io = u.breaking orelse return;
    uart.setBreak(u.port.uartPort().?, false);
    u.breaking = null;
    if (u.break_aborted != 0) {
        io.err = exec.IOERR_ABORTED;
    } else {
        u.status |= types.IO_STATF_WROTEBREAK;
    }
    termIO(u, io);
}

/// End the break in progress early: its timer request comes back aborted,
/// and breakDone replies the break with IOERR_ABORTED.
fn abortBreak(u: *SerialUnit) void {
    if (u.breaking == null) return;
    u.break_aborted = 1;
    _ = sysOf(u).AbortIO(&u.brk_timer.node);
}

// --- input ------------------------------------------------------------------

/// A unit's receive interrupt server: the port's bytes into the buffer, its
/// events into io_Status and the pending error, then the waiting reads
/// served (not while stopped).
fn rxServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const u: *SerialUnit = @ptrCast(@alignCast(is_data.?));
    const events = u.port.takeRxInterrupt() orelse return 0; // not ours
    while (u.port.read()) |c| store(u, c);
    if (events.brk) {
        u.status |= types.IO_STATF_READBREAK;
        setError(u, types.SerErr_DetectedBreak);
    }
    if (events.parity_error) setError(u, types.SerErr_ParityErr);
    if (events.frame_error) setError(u, types.SerErr_LineErr);
    if (events.overflow) {
        u.status |= types.IO_STATF_OVERRUN;
        setError(u, types.SerErr_BufOverflow);
    }
    if (events.xoff) u.status |= types.IO_STATF_XOFFWRITE;
    if (events.xon) u.status &= ~types.IO_STATF_XOFFWRITE;
    serveReads(u);
    return 1;
}

/// The buffered input to the waiting CMD_READs, first come first served,
/// unless the unit is stopped. A read is replied, after Enable (as
/// timer.device's IntEnd does), once it is done or an error ends it.
fn serveReads(u: *SerialUnit) void {
    const sys = sysOf(u);
    while (true) {
        sys.Disable();
        const first = if (u.stopped == 0) u.unit.msg_port.msg_list.first() else null;
        const node = first orelse {
            sys.Enable();
            return;
        };
        const io = requestOf(node);
        if (!(fill(u, serReq(io)) or takeError(u, io))) { // wants more
            sys.Enable();
            return;
        }
        sys.Remove(node);
        sys.Enable();
        termIO(u, io);
    }
}

/// The jump table both devices use.
pub const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};
