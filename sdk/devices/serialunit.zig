// SPDX-License-Identifier: MPL-2.0
//! A serial unit: serial.device's API (sdk/devices/serial.zig) over any
//! line - a UART, the USB-Serial-JTAG port, a USB serial adapter - so a
//! program cannot tell the lines apart. serial.device, usbserial.device
//! and the USB serial class drivers each keep their units with this and
//! give it their line; the requests are handled here alike.
//!
//! **A line** is a type with what only the line can do:
//!
//!   write(line, sys, bytes) bool        the bytes sent, from the caller's
//!                                       task; false when there is no line
//!   setLine(line, sys, params) void     the rate and the frame
//!   lineStatus(line) u16                io_Status's line bits, clear for
//!                                       an active line
//!   check(line, request) i8             what the line cannot do, as a
//!                                       SerErr_*; 0 for what it can
//!
//! and one of two breaks: `setBreak(line, on) bool` - the line held low
//! from the caller and let go from the break's timer, in a software
//! interrupt, so it must not wait (a UART's) - or `sendBreak(line, sys,
//! microseconds) bool`, a break the line times itself from the caller's
//! task (a USB adapter's, a control transfer). Either answers false for
//! a line without a break, and SDCMD_BREAK then IOERR_NOCMD.
//!
//! **Input** comes in through `input`: bytes, and what the line saw
//! besides (a break, a parity or frame error, an overrun, xON/xOFF),
//! from the line's interrupt or a task of the driver's alike. It goes
//! into the unit's buffer and to the waiting CMD_READs, first come first
//! served. The buffer, the reads and the status are guarded by Disable,
//! as the interrupt that may feed them requires.
//!
//! **Writes are done in BeginIO**, on the caller's task, a writer at a
//! time (`write_lock`): a CMD_WRITE is answered once its bytes are out.

const exec = @import("../libs/exec/exec.zig");
const ExecBase = @import("../interface/exec.zig").ExecBase;
const timer_interface = @import("../interface/timer.zig");
const timer = @import("timer.zig");
const types = @import("serial.zig");
const IOExtSer = types.IOExtSer;
const vec = exec.vec;

/// The slowest rate, and the fastest any line here is asked for.
const min_baud = 112;
const max_baud = 12_000_000;
/// The smallest input buffer.
const min_rbuf_len = 64;

/// A unit's parameters: what SDCMD_SETPARAMS sets and OpenDevice shows.
pub const Params = extern struct {
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

    /// The frame's parity, as a line sets it.
    pub fn parity(params: *const Params) enum { none, odd, even, mark, space } {
        if (params.ser_flags & types.SERF_PARTY_ON == 0) return .none;
        if (params.ext_flags & types.SEXTF_MSPON != 0) return if (params.ext_flags & types.SEXTF_MARK != 0) .mark else .space;
        return if (params.ser_flags & types.SERF_PARTY_ODD != 0) .odd else .even;
    }

    /// Whether xON/xOFF is on.
    pub fn xonXoff(params: *const Params) bool {
        return params.ser_flags & types.SERF_XDISABLED == 0;
    }
};

/// The io_SerFlags the unit keeps. EOFMODE and QUEUEDBRK count per request,
/// SHARED per open.
const unit_flags: u8 = types.SERF_PARTY_ON | types.SERF_PARTY_ODD | types.SERF_XDISABLED | types.SERF_RAD_BOOGIE;

/// The boot-up parameters at `baud`: 8N1, a 512-byte buffer, break
/// (250 ms) and control characters, xON/xOFF off.
pub fn defaultParams(baud: u32) Params {
    return .{
        .ctl_char = types.SER_DEFAULT_CTLCHAR,
        .rbuf_len = 512,
        .ext_flags = 0,
        .baud = baud,
        .brk_time = 250_000,
        .term_array = @splat(0),
        .read_len = 8,
        .write_len = 8,
        .stop_bits = 1,
        .ser_flags = types.SERF_XDISABLED,
    };
}

/// What a line saw besides its bytes.
pub const Events = struct {
    brk: bool = false,
    parity_error: bool = false,
    frame_error: bool = false,
    overflow: bool = false,
    xoff: bool = false,
    xon: bool = false,
};

/// A unit on a line of type `Line`.
pub fn Unit(comptime Line: type) type {
    return struct {
        const Self = @This();
        const line_times_break = @hasDecl(Line, "sendBreak");

        /// Its port (PA_IGNORE) holds the waiting CMD_READs.
        unit: exec.Unit = .{},
        sys: *ExecBase,
        /// The device's name, for the interrupts' nodes.
        name: [*:0]const u8,
        line: Line,
        params: Params,
        /// What CMD_RESET goes back to.
        defaults: Params,
        /// Opened with SERF_SHARED: more openers with SERF_SHARED may come.
        shared: bool = false,
        /// Set by CMD_STOP, cleared by CMD_START and CMD_RESET.
        stopped: bool = false,
        /// io_Status's port state: IO_STATF_OVERRUN, _WROTEBREAK,
        /// _READBREAK, _XOFFWRITE.
        status: u16 = 0,
        /// A receive error (SerErr_*) for the read in progress or the next.
        pending_err: i8 = 0,
        /// The CMD_WRITEs (and queued breaks) that CMD_STOP holds until
        /// CMD_START.
        write_queue: exec.List = .{},
        /// Held for each write to the line, so that one writer's bytes go
        /// out together: a CMD_WRITE's, or one beside the requests
        /// (`writeAside`).
        write_lock: exec.SignalSemaphore = .{},
        /// The input buffer: io_RBufLen bytes while the unit is open,
        /// `count` of them from `start` on, wrapping around.
        buffer: ?[*]u8 = null,
        buffer_size: u32 = 0,
        start: u32 = 0,
        count: u32 = 0,
        /// The SDCMD_BREAK in progress, and whether AbortIO ended it.
        breaking: ?*exec.IORequest = null,
        break_aborted: bool = false,
        /// timer.device for breaks a line holds low: its request, the port
        /// its reply comes to (PA_SOFTINT), and the software interrupt
        /// that ends the break.
        timer_open: bool = false,
        brk_timer: timer.TimeRequest = .{},
        brk_port: exec.MsgPort = .{},
        brk_int: exec.Interrupt = .{},

        /// A unit on `line`, its parameters `defaults`.
        pub fn init(u: *Self, sys: *ExecBase, name: [*:0]const u8, line: Line, defaults: Params) void {
            u.* = .{ .sys = sys, .name = name, .line = line, .params = defaults, .defaults = defaults };
            u.unit.msg_port.flags = exec.PA_IGNORE; // looked at here, not signalled
            u.unit.msg_port.msg_list.init(.message);
            u.write_queue.init(.message);
            sys.InitSemaphore(&u.write_lock);
        }

        pub fn of(io: *exec.IORequest) *Self {
            return @fieldParentPtr("unit", io.unit.?);
        }

        fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
            return @alignCast(@fieldParentPtr("req", io));
        }

        /// Requests are IOExtSers.
        fn serReq(io: *exec.IORequest) *IOExtSer {
            return @fieldParentPtr("io_ser", stdReq(io));
        }

        /// The request a node on the unit's port or write queue belongs to.
        fn requestOf(node: *exec.Node) *exec.IORequest {
            const msg: *exec.Message = @fieldParentPtr("node", node);
            return @fieldParentPtr("message", msg);
        }

        // --- the input buffer -----------------------------------------------

        /// What came in on the line: its bytes into the buffer (dropped
        /// while the unit is not open; a full buffer is an overrun), what
        /// it saw into io_Status and the pending error, and the waiting
        /// reads served. From the line's interrupt or a task.
        pub fn input(u: *Self, bytes: []const u8, events: Events) void {
            const sys = u.sys;
            sys.Disable();
            for (bytes) |c| u.store(c);
            if (events.brk) {
                u.status |= types.IO_STATF_READBREAK;
                u.setError(types.SerErr_DetectedBreak);
            }
            if (events.parity_error) u.setError(types.SerErr_ParityErr);
            if (events.frame_error) u.setError(types.SerErr_LineErr);
            if (events.overflow) {
                u.status |= types.IO_STATF_OVERRUN;
                u.setError(types.SerErr_BufOverflow);
            }
            if (events.xoff) u.status |= types.IO_STATF_XOFFWRITE;
            if (events.xon) u.status &= ~types.IO_STATF_XOFFWRITE;
            sys.Enable();
            u.serveReads();
        }

        /// A received byte into the buffer. Disable held.
        fn store(u: *Self, c: u8) void {
            const buffer = u.buffer orelse return;
            if (u.count == u.buffer_size) {
                u.status |= types.IO_STATF_OVERRUN;
                u.setError(types.SerErr_BufOverflow);
                return;
            }
            buffer[(u.start + u.count) % u.buffer_size] = c;
            u.count += 1;
        }

        /// The oldest buffered byte (there is one). Disable held.
        fn takeByte(u: *Self) u8 {
            const c = u.buffer.?[u.start];
            u.start = (u.start + 1) % u.buffer_size;
            u.count -= 1;
            return c;
        }

        /// A receive error for the read in progress or the next one; the
        /// first one counts.
        fn setError(u: *Self, err: i8) void {
            if (u.pending_err == 0) u.pending_err = err;
        }

        /// A new, empty input buffer of `size` bytes for the old one.
        /// False, and the old one stays, without the memory. Task level.
        fn newBuffer(u: *Self, size: u32) bool {
            const sys = u.sys;
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

        fn freeBuffer(u: *Self) void {
            const sys = u.sys;
            sys.Disable();
            const old = u.buffer;
            u.buffer = null;
            u.count = 0;
            sys.Enable();
            if (old) |b| sys.FreeMem(b, u.buffer_size);
        }

        fn isTerminator(u: *const Self, c: u8) bool {
            for (u.params.term_array) |t| if (t == c) return true;
            return false;
        }

        /// The buffered input into what the read `x` still wants. True
        /// once it is done: io_Length bytes, or in EOF mode a termination
        /// character (it is part of the data). Disable held.
        fn fill(u: *Self, x: *IOExtSer) bool {
            const req = &x.io_ser;
            const data: [*]u8 = @ptrCast(req.data.?);
            const eof = x.ser_flags & types.SERF_EOFMODE != 0;
            while (req.actual < req.length and u.count != 0) {
                const c = u.takeByte();
                data[@intCast(req.actual)] = c;
                req.actual += 1;
                if (eof and u.isTerminator(c)) return true;
            }
            return req.actual == req.length;
        }

        /// A pending receive error ends the read `io` with it; the
        /// read-break and overrun state go with it. Disable held.
        fn takeError(u: *Self, io: *exec.IORequest) bool {
            if (u.pending_err == 0) return false;
            io.err = u.pending_err;
            u.pending_err = 0;
            u.status &= ~(types.IO_STATF_READBREAK | types.IO_STATF_OVERRUN);
            return true;
        }

        // --- requests -----------------------------------------------------------

        /// Replied, unless the caller asked for IOF_QUICK and it is done
        /// in BeginIO.
        fn termIO(u: *Self, io: *exec.IORequest) void {
            u.sys.ReplyIO(io);
        }

        /// Whether `io` can wait: it will be replied, so it needs a reply
        /// port. Without one it fails now with IOERR_NOREPLYPORT; done
        /// later, it would go into memory the caller may have reused,
        /// since WaitIO can't wait for it.
        fn canWait(io: *exec.IORequest) bool {
            if (io.message.reply_port != null) return true;
            io.err = exec.IOERR_NOREPLYPORT;
            io.flags |= exec.IOF_QUICK; // done now: no reply
            return false;
        }

        /// The unit's parameters into the IOExtSer, as OpenDevice and
        /// CMD_RESET show them.
        fn showParams(u: *Self, x: *IOExtSer) void {
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
            x.ser_flags = p.ser_flags | if (u.shared) types.SERF_SHARED else 0;
            x.status = 0;
        }

        /// The unit opened for an IOExtSer. Exclusive, unless it and every
        /// opener before set SERF_SHARED. The first opener gets a fresh
        /// buffer. The request's parameters are filled in from the unit.
        /// The device counts its own opens.
        pub fn open(u: *Self, io: *exec.IORequest) i32 {
            // A request that says it is too small would be written past its end.
            if (io.message.length != 0 and io.message.length < @sizeOf(IOExtSer)) return exec.IOERR_BADLENGTH;
            const x = serReq(io);
            const shared = x.ser_flags & types.SERF_SHARED != 0;
            if (x.ser_flags & types.SERF_7WIRE != 0) return types.SerErr_InvParam;
            if (u.unit.open_cnt != 0 and !(shared and u.shared)) return types.SerErr_DevBusy;
            if (u.unit.open_cnt == 0) {
                if (!u.newBuffer(u.params.rbuf_len)) return types.SerErr_BufErr;
                u.shared = shared;
                u.pending_err = 0;
                u.status = 0;
            }
            u.unit.open_cnt += 1;
            io.unit = &u.unit;
            u.showParams(x);
            return 0;
        }

        /// A request that still waits is aborted first. The unit's last
        /// close frees its buffer and closes timer.device.
        pub fn close(u: *Self, io: *exec.IORequest) void {
            _ = u.remRequest(io);
            u.unit.open_cnt -= 1;
            if (u.unit.open_cnt == 0) {
                if (u.timer_open) {
                    u.sys.CloseDevice(&u.brk_timer.node);
                    u.timer_open = false;
                }
                u.freeBuffer();
                u.stopped = false;
            }
        }

        pub fn beginIO(u: *Self, io: *exec.IORequest) void {
            const x = serReq(io);
            io.err = 0;
            x.io_ser.actual = 0;
            switch (io.command) {
                exec.CMD_READ => return u.startRead(x),
                exec.CMD_WRITE => {
                    if (u.stopped) return u.hold(io);
                    u.waitBreak();
                    u.write(&x.io_ser);
                },
                exec.CMD_STOP => u.stopped = true,
                exec.CMD_START => u.startIO(),
                exec.CMD_CLEAR => u.clearInput(),
                exec.CMD_FLUSH => u.flushQueued(),
                exec.CMD_RESET => u.reset(x),
                types.SDCMD_QUERY => u.query(x),
                types.SDCMD_BREAK => return u.breakCmd(x),
                types.SDCMD_SETPARAMS => u.setParams(x),
                else => io.err = exec.IOERR_NOCMD,
            }
            u.termIO(io);
        }

        /// CMD_READ: takes what is buffered (unless the unit is stopped
        /// or other reads wait), and is done at once if that completes it
        /// or an error is pending; else it waits on the unit's port.
        fn startRead(u: *Self, x: *IOExtSer) void {
            const sys = u.sys;
            const io = &x.io_ser.req;
            if (x.io_ser.length == 0) return u.termIO(io);
            if (x.io_ser.data == null) {
                io.err = exec.IOERR_BADADDRESS;
                return u.termIO(io);
            }
            sys.Disable();
            // Reads that wait already come first.
            const done = !u.stopped and u.unit.msg_port.msg_list.first() == null and (u.fill(x) or u.takeError(io));
            if (done or !canWait(io)) {
                sys.Enable();
                return u.termIO(io);
            }
            io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
            sys.PutMsg(&u.unit.msg_port, &io.message); // NT_MESSAGE, for WaitIO
            sys.Enable();
        }

        /// A request CMD_STOP holds (a write, or a break with
        /// SERF_QUEUEDBRK): onto the write queue until CMD_START. Done at
        /// once if CMD_START came in the meantime.
        fn hold(u: *Self, io: *exec.IORequest) void {
            const sys = u.sys;
            sys.Disable();
            if (u.stopped and canWait(io)) {
                io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
                // A queued request is a message again, as PutMsg would
                // make it: WaitIO looks at the node's type, and the reply
                // left there by its last use would let a caller past
                // before this one has run.
                io.message.node.type = .message;
                sys.AddTail(&u.write_queue, &io.message.node);
                sys.Enable();
                return;
            }
            sys.Enable();
            if (io.err != 0) return u.termIO(io);
            u.doHeld(io);
        }

        /// What a held request does, once it may.
        fn doHeld(u: *Self, io: *exec.IORequest) void {
            if (io.command == types.SDCMD_BREAK) return u.startBreak(io);
            u.waitBreak();
            u.write(stdReq(io));
            u.termIO(io);
        }

        /// CMD_WRITE: io_Length bytes, or up to a NUL for -1, as they are.
        fn write(u: *Self, req: *exec.IOStdReq) void {
            if (req.length == 0) return;
            const data: [*]const u8 = @ptrCast(req.data orelse {
                req.req.err = exec.IOERR_BADADDRESS;
                return;
            });
            var length: usize = 0;
            if (req.length == types.LENGTH_NUL_TERMINATED) {
                while (data[length] != 0) length += 1;
            } else {
                length = @intCast(req.length);
            }
            if (!u.writeLocked(data[0..length])) {
                req.req.err = types.SerErr_NoDSR;
                return;
            }
            req.actual = length;
        }

        /// `bytes` to the line, with nobody else's in between.
        fn writeLocked(u: *Self, bytes: []const u8) bool {
            const sys = u.sys;
            sys.ObtainSemaphore(&u.write_lock);
            defer sys.ReleaseSemaphore(&u.write_lock);
            return u.line.write(sys, bytes);
        }

        /// `bytes` to the line beside the unit's requests, not through
        /// one: how usbserial.device writes the system log's copy. The
        /// unit's writes and these go out whole, one after another. From
        /// a task.
        pub fn writeAside(u: *Self, bytes: []const u8) void {
            _ = u.writeLocked(bytes);
        }

        /// The writes held: a write under way finished first, and no other
        /// begun until `releaseWrites`, so the caller changes the line
        /// between two of them - usbserial.device gives up its port so.
        /// From a task.
        pub fn holdWrites(u: *Self) void {
            u.sys.ObtainSemaphore(&u.write_lock);
        }

        /// The writes going again after `holdWrites`.
        pub fn releaseWrites(u: *Self) void {
            u.sys.ReleaseSemaphore(&u.write_lock);
        }

        /// CMD_START: the held requests, in order and in the caller's time,
        /// then the buffered input to the waiting reads.
        fn startIO(u: *Self) void {
            const sys = u.sys;
            u.stopped = false;
            while (true) {
                sys.Disable();
                const node = if (!u.stopped) sys.RemHead(&u.write_queue) else null;
                sys.Enable();
                u.doHeld(requestOf(node orelse break));
            }
            u.serveReads();
        }

        /// CMD_CLEAR: drop the buffered input.
        fn clearInput(u: *Self) void {
            u.sys.Disable();
            u.start = 0;
            u.count = 0;
            u.sys.Enable();
        }

        /// CMD_FLUSH: the queued requests replied with IOERR_ABORTED, but
        /// not the active ones: the read being filled and the first held
        /// request stay, and so does a break in progress.
        fn flushQueued(u: *Self) void {
            for ([_]*exec.List{ &u.unit.msg_port.msg_list, &u.write_queue }) |list| {
                while (true) {
                    u.sys.Disable();
                    var it = list.iterator();
                    _ = it.next(); // the active one
                    const node = it.next();
                    if (node) |n| u.sys.Remove(n);
                    u.sys.Enable();
                    u.abortRequest(requestOf(node orelse break));
                }
            }
        }

        /// Every waiting request, reads and held ones, replied with
        /// IOERR_ABORTED.
        pub fn flushAll(u: *Self) void {
            for ([_]*exec.List{ &u.unit.msg_port.msg_list, &u.write_queue }) |list| {
                while (true) {
                    u.sys.Disable();
                    const node = u.sys.RemHead(list);
                    u.sys.Enable();
                    u.abortRequest(requestOf(node orelse break));
                }
            }
        }

        /// CMD_RESET: everything aborted, a break in progress too; the
        /// boot-up parameters, on the line as well, and a buffer of their
        /// size; the parameters go into the request.
        fn reset(u: *Self, x: *IOExtSer) void {
            u.flushAll();
            u.abortBreak();
            u.params = u.defaults;
            u.line.setLine(u.sys, &u.params);
            if (!u.newBuffer(u.defaults.rbuf_len)) {
                u.params.rbuf_len = u.buffer_size;
                u.clearInput();
            }
            u.pending_err = 0;
            u.status = 0;
            u.stopped = false;
            u.showParams(x);
        }

        /// Replied with IOERR_ABORTED; io_Actual keeps what a read got so
        /// far.
        fn abortRequest(u: *Self, io: *exec.IORequest) void {
            io.err = exec.IOERR_ABORTED;
            u.termIO(io);
        }

        /// A waiting request (a read, a held one, or the break in
        /// progress) ended with IOERR_ABORTED. False if it isn't waiting.
        fn remRequest(u: *Self, io: *exec.IORequest) bool {
            const sys = u.sys;
            if (u.breaking == io) {
                u.abortBreak();
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
            if (found) u.abortRequest(io);
            return found;
        }

        /// AbortIO: 0 if the request was aborted, -1 if it wasn't waiting.
        pub fn abortIO(u: *Self, io: *exec.IORequest) i32 {
            return if (u.remRequest(io)) 0 else -1;
        }

        // --- SDCMD_QUERY and SDCMD_SETPARAMS ----------------------------------

        /// SDCMD_QUERY: the bytes waiting, the lines and the unit's state.
        /// The query clears the break flags.
        fn query(u: *Self, x: *IOExtSer) void {
            const sys = u.sys;
            const lines = u.line.lineStatus();
            sys.Disable();
            x.io_ser.actual = u.count;
            x.status = u.status | lines;
            u.status &= ~(types.IO_STATF_READBREAK | types.IO_STATF_WROTEBREAK);
            sys.Enable();
        }

        /// Whether requests are active or queued on the unit.
        fn busy(u: *Self) bool {
            return u.unit.msg_port.msg_list.first() != null or u.write_queue.first() != null or u.breaking != null;
        }

        /// SDCMD_SETPARAMS: while the unit is busy only the xON/xOFF switch
        /// is taken (and the answer is SerErr_DevBusy anyway). RAD_BOOGIE
        /// turns xON/xOFF off; mark or space parity turns parity on. The
        /// new io_SerFlags go back into the request.
        fn setParams(u: *Self, x: *IOExtSer) void {
            const io = &x.io_ser.req;
            var flags = x.ser_flags;
            if (flags & types.SERF_RAD_BOOGIE != 0) flags |= types.SERF_XDISABLED;
            if (x.ext_flags & types.SEXTF_MSPON != 0) flags |= types.SERF_PARTY_ON;
            if (u.busy()) {
                u.params.ser_flags = (u.params.ser_flags & ~types.SERF_XDISABLED) | (flags & types.SERF_XDISABLED);
                u.line.setLine(u.sys, &u.params);
                io.err = types.SerErr_DevBusy;
                return;
            }
            io.err = u.checkParams(x, flags);
            if (io.err != 0) return;
            if (x.rbuf_len != u.params.rbuf_len and !u.newBuffer(x.rbuf_len)) {
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
            u.line.setLine(u.sys, &u.params);
            x.ser_flags = flags;
        }

        /// The parameters' own checks, then what the line can do. 0 if
        /// they pass.
        fn checkParams(u: *Self, x: *IOExtSer, flags: u8) i8 {
            if (x.read_len == 0 or x.read_len > 8 or x.write_len == 0 or x.write_len > 8 or x.stop_bits > 2) return types.SerErr_InvParam;
            if (x.baud < min_baud or x.baud > max_baud or x.ctl_char == 0 or x.brk_time == 0) return types.SerErr_InvParam;
            if (x.rbuf_len < min_rbuf_len) return types.SerErr_BufErr;
            if (flags & types.SERF_7WIRE != 0) return types.SerErr_InvParam;
            return u.line.check(x);
        }

        // --- SDCMD_BREAK --------------------------------------------------------

        /// SDCMD_BREAK: at once, or with SERF_QUEUEDBRK behind what
        /// CMD_STOP holds.
        fn breakCmd(u: *Self, x: *IOExtSer) void {
            const io = &x.io_ser.req;
            if (x.ser_flags & types.SERF_QUEUEDBRK != 0 and u.stopped) return u.hold(io);
            u.startBreak(io);
        }

        /// Wait until the break in progress is over; its end comes in a
        /// software interrupt. (Writes don't queue: they are done inside
        /// BeginIO.)
        fn waitBreak(u: *Self) void {
            const breaking: *volatile ?*exec.IORequest = &u.breaking;
            while (breaking.* != null) {}
        }

        /// A break of io_BrkTime µs: one the line times itself, sent from
        /// here; or the line held low until timer.device's reply ends it
        /// (breakDone).
        fn startBreak(u: *Self, io: *exec.IORequest) void {
            if (line_times_break) {
                if (!u.line.sendBreak(u.sys, u.params.brk_time)) {
                    io.err = exec.IOERR_NOCMD;
                } else {
                    u.status |= types.IO_STATF_WROTEBREAK;
                }
                return u.termIO(io);
            }
            const sys = u.sys;
            u.waitBreak(); // one at a time
            if (!u.openTimer()) {
                io.err = types.SerErr_TimerErr;
                return u.termIO(io);
            }
            if (!canWait(io)) return u.termIO(io);
            if (!u.line.setBreak(true)) {
                io.err = exec.IOERR_NOCMD;
                return u.termIO(io);
            }
            io.flags &= ~exec.IOF_QUICK; // not done yet: it will be replied
            io.message.node.type = .message; // for WaitIO
            u.break_aborted = false;
            sys.Disable();
            u.breaking = io;
            sys.Enable();
            u.brk_timer.node.command = timer.TR_ADDREQUEST;
            u.brk_timer.time = timer.TimeVal.fromMicros(u.params.brk_time);
            sys.SendIO(&u.brk_timer.node);
        }

        /// timer.device for the unit's breaks, opened at the first one.
        fn openTimer(u: *Self) bool {
            if (u.timer_open) return true;
            u.brk_int = .{
                .node = .{ .type = .interrupt, .name = u.name },
                .data = u,
                .code = vec(breakDone),
            };
            u.brk_port = .{ .flags = exec.PA_SOFTINT, .sig_task = &u.brk_int };
            u.brk_port.msg_list.init(.message);
            u.brk_timer = .{ .node = .{ .message = .{ .reply_port = &u.brk_port, .length = @sizeOf(timer.TimeRequest) } } };
            if (u.sys.OpenDevice(timer_interface.NAME, timer.UNIT_MICROHZ, &u.brk_timer.node, 0) != 0) return false;
            u.timer_open = true;
            return true;
        }

        /// The break's timer request came back (the time is up, or
        /// AbortIO): the line goes back to idle and the SDCMD_BREAK is
        /// replied. A software interrupt.
        fn breakDone(is_data: ?*anyopaque) callconv(.c) void {
            const u: *Self = @ptrCast(@alignCast(is_data.?));
            const sys = u.sys;
            while (sys.GetMsg(&u.brk_port)) |_| {}
            const io = u.breaking orelse return;
            _ = u.line.setBreak(false);
            u.breaking = null;
            if (u.break_aborted) {
                io.err = exec.IOERR_ABORTED;
            } else {
                u.status |= types.IO_STATF_WROTEBREAK;
            }
            u.termIO(io);
        }

        /// End the break in progress early: its timer request comes back
        /// aborted, and breakDone replies the break with IOERR_ABORTED.
        fn abortBreak(u: *Self) void {
            if (u.breaking == null) return;
            u.break_aborted = true;
            _ = u.sys.AbortIO(&u.brk_timer.node);
        }

        // --- input ----------------------------------------------------------------

        /// The buffered input to the waiting CMD_READs, first come first
        /// served, unless the unit is stopped. A read is replied, after
        /// Enable, once it is done or an error ends it.
        pub fn serveReads(u: *Self) void {
            const sys = u.sys;
            while (true) {
                sys.Disable();
                const first = if (!u.stopped) u.unit.msg_port.msg_list.first() else null;
                const node = first orelse {
                    sys.Enable();
                    return;
                };
                const io = requestOf(node);
                if (!(u.fill(serReq(io)) or u.takeError(io))) { // wants more
                    sys.Enable();
                    return;
                }
                sys.Remove(node);
                sys.Enable();
                u.termIO(io);
            }
        }
    };
}
