// SPDX-License-Identifier: MIT
//! What the USB serial class drivers share: a device whose units are
//! serial lines with serial.device's API (sdk/devices/serialunit.zig),
//! each a USB serial adapter's while one is plugged in. A driver -
//! `ftdi.zig`, `acm.zig` - is a `Kind`: which adapters it takes, how
//! their line is set, how their input comes; everything else is here.
//!
//! **Units are lines, not adapters.** An adapter bound takes the lowest
//! free unit; pulled out, it leaves the unit without a line - a read
//! waits, a write fails with SerErr_NoDSR - until the next one comes. A
//! program may open a unit before anything is plugged in, as it may a
//! serial port with nothing on its cable.
//!
//! **Input** is the driver's task's: it keeps one read outstanding on
//! each adapter's bulk IN endpoint, a packet at a time - a character
//! typed is not held back until a buffer fills - and hands what came to
//! the kind, which gives the bytes and what the adapter said of its
//! line to the unit. An adapter with a notification endpoint (CDC-ACM)
//! has a read kept on that as well.
//!
//! **Output and the line's settings** are done on the caller's task, as
//! a UART's are: a CMD_WRITE is a bulk transfer the caller waits for,
//! with a reply port of its own; SDCMD_SETPARAMS and SDCMD_BREAK are the
//! kind's control transfers. They hold `bind_lock` shared; an adapter
//! that goes takes it exclusively before it is freed, after its
//! transfers have been aborted, so nothing waits out a timeout on an
//! adapter that is no longer there.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const usbclass = sdk.devices.usbclass;
const serial = sdk.devices.serial;
const serialunit = sdk.devices.serialunit;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;

/// The lines there can be.
pub const max_units = 4;
/// The task that keeps the reads: beside dos's processes, as a serial
/// line's reader is waited on by a program.
const task_stack = 4096;
const task_pri = 5;

/// The endpoints an adapter is driven through, as the kind found them.
pub const Endpoints = struct {
    in: u8,
    out: u8,
    /// An interrupt IN endpoint with the line's state, or 0.
    notify: u8 = 0,
};

/// A command to the task.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .start,
    adapter: ?*anyopaque = null,

    pub const Kind = enum(u32) { start, let_go };
};

pub fn Driver(comptime Kind: type) type {
    return struct {
        /// A unit's line: the adapter on it, while there is one.
        pub const Line = struct {
            base: *Base,
            adapter: ?*Adapter = null,

            pub fn write(line: *Line, sys: *ExecBase, bytes: []const u8) bool {
                const base = line.base;
                sys.ObtainSemaphoreShared(&base.bind_lock);
                defer sys.ReleaseSemaphore(&base.bind_lock);
                const adapter = line.adapter orelse return false;
                if (@atomicLoad(u8, &adapter.leaving, .acquire) != 0) return false;
                const port = sys.CreateMsgPort() orelse return false;
                defer sys.DeleteMsgPort(port);
                const io = &adapter.bulk_out.io;
                io.std.req.message.reply_port = port;
                io.std.data = @ptrCast(@constCast(bytes.ptr));
                io.std.length = bytes.len;
                io.std.actual = 0;
                io.nak_timeout = 0;
                _ = sys.DoIO(&io.std.req);
                return io.std.req.err == 0;
            }

            pub fn setLine(line: *Line, sys: *ExecBase, params: *const serialunit.Params) void {
                const base = line.base;
                sys.ObtainSemaphoreShared(&base.bind_lock);
                defer sys.ReleaseSemaphore(&base.bind_lock);
                const adapter = line.adapter orelse return;
                if (@atomicLoad(u8, &adapter.leaving, .acquire) != 0) return;
                Kind.setLine(base.ub(), adapter, params);
            }

            /// The adapter's lines as it last said them; with no adapter,
            /// none is active.
            pub fn lineStatus(line: *Line) u16 {
                const adapter = line.adapter orelse return serial.IO_STATF_CD | serial.IO_STATF_DSR | serial.IO_STATF_CTS;
                return @atomicLoad(u16, &adapter.modem, .acquire);
            }

            pub fn check(line: *const Line, x: *const serial.IOExtSer) i8 {
                _ = line;
                return Kind.check(x);
            }

            pub fn sendBreak(line: *Line, sys: *ExecBase, microseconds: u32) bool {
                const base = line.base;
                sys.ObtainSemaphoreShared(&base.bind_lock);
                defer sys.ReleaseSemaphore(&base.bind_lock);
                const adapter = line.adapter orelse return false;
                return Kind.sendBreak(base.ub(), sys, adapter, microseconds);
            }
        };

        pub const Unit = serialunit.Unit(Line);

        /// A bound adapter.
        pub const Adapter = struct {
            base: *Base,
            device: *usb.USBDevice,
            bulk_in: *usb.USBPipe,
            bulk_out: *usb.USBPipe,
            notify: ?*usb.USBPipe = null,
            unit: *Unit,
            /// The interfaces the kind drives it through.
            interface_number: u8,
            /// Set by the unbind: no transfer is sent after it.
            leaving: u8 = 0,
            /// Whether the reads are out.
            reading: bool = false,
            notifying: bool = false,
            /// io_Status's line bits as the adapter last said them.
            modem: u16 = 0,
            in_buffer: [512]u8 = undefined,
            notify_buffer: [16]u8 = undefined,
            /// The kind's own.
            state: Kind.State = .{},
            start: Command = .{},
        };

        pub const Base = extern struct {
            dev: exec.Device,
            sys_base: *ExecBase,
            seg_list: ?*anyopaque = null,
            usb_base: ?*UsbBase = null,
            /// The units, a block of them.
            units_memory: ?*anyopaque = null,
            /// The task that keeps the reads, and its stack.
            task: exec.Task = .{},
            stack: ?*anyopaque = null,
            /// Its ports: the pipes' replies, commands.
            pipes: ?*exec.MsgPort = null,
            commands: ?*exec.MsgPort = null,
            starter: ?*exec.Task = null,
            start_signal: i8 = -1,
            pad: [3]u8 = .{ 0, 0, 0 },
            /// Who is on which unit: written by a bind (the bus's process)
            /// and the task.
            lock: exec.SignalSemaphore = .{},
            /// Held shared by whatever uses an adapter from a caller's
            /// task, exclusively by its unbind.
            bind_lock: exec.SignalSemaphore = .{},

            pub fn ub(base: *Base) *UsbBase {
                return base.usb_base.?;
            }

            pub fn units(base: *Base) *[max_units]Unit {
                return @ptrCast(@alignCast(base.units_memory.?));
            }
        };

        fn baseOf(dev: *exec.Device) *Base {
            return @alignCast(@fieldParentPtr("dev", dev));
        }

        // --- the device ---------------------------------------------------------

        pub fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
            _ = flags;
            const base = baseOf(dev);
            // usb.library's open, for the two class calls: no line.
            if (unit_number == usbclass.USBCLASS_UNIT_BIND) {
                dev.open_cnt += 1;
                dev.flags &= ~exec.LIBF_DELEXP;
                io.unit = null;
                return 0;
            }
            if (unit_number >= max_units) return exec.IOERR_OPENFAIL;
            const err = base.units()[unit_number].open(io);
            if (err != 0) return err;
            dev.open_cnt += 1;
            dev.flags &= ~exec.LIBF_DELEXP;
            return 0;
        }

        pub fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
            if (io.unit != null) Unit.of(io).close(io);
            dev.open_cnt -= 1;
            return null;
        }

        /// The device stays: a program may hold a line for good.
        pub fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
            return null;
        }

        pub fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
            if (io.unit == null) {
                io.err = exec.IOERR_NOCMD;
                return baseOf(dev).sys_base.ReplyIO(io);
            }
            Unit.of(io).beginIO(io);
        }

        pub fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
            _ = dev;
            if (io.unit == null) return -1;
            return Unit.of(io).abortIO(io);
        }

        // --- the class driver's calls -----------------------------------------------

        /// An adapter the kind takes: its pipes opened, the lowest free
        /// unit given it, its line set up from the unit's parameters, and
        /// the task handed it to read from.
        pub fn bind(base: *Base, binding: *usb.USBBinding) bool {
            const sys = base.sys_base;
            const ub = base.usb_base orelse return false;
            const device = binding.device.?;
            const interface = binding.interface.?;
            const endpoints = Kind.accept(ub, device, interface) orelse return false;
            const pipes = base.pipes orelse return false;

            const memory = sys.AllocMem(@sizeOf(Adapter), exec.MEMF_CLEAR) orelse return false;
            const adapter: *Adapter = @ptrCast(@alignCast(memory));
            const bulk_in = ub.OpenUSBPipe(device, endpoints.in, pipes);
            const bulk_out = ub.OpenUSBPipe(device, endpoints.out, pipes);
            const notify = if (endpoints.notify != 0) ub.OpenUSBPipe(device, endpoints.notify, pipes) else null;
            if (bulk_in == null or bulk_out == null or (endpoints.notify != 0 and notify == null)) {
                ub.CloseUSBPipe(bulk_in);
                ub.CloseUSBPipe(bulk_out);
                ub.CloseUSBPipe(notify);
                sys.FreeMem(memory, @sizeOf(Adapter));
                return false;
            }

            sys.ObtainSemaphore(&base.lock);
            const unit = for (base.units()) |*u| {
                if (u.line.adapter == null) break u;
            } else null;
            if (unit) |u| {
                adapter.* = .{
                    .base = base,
                    .device = device,
                    .bulk_in = bulk_in.?,
                    .bulk_out = bulk_out.?,
                    .notify = notify,
                    .unit = u,
                    .interface_number = interface.interface_number,
                };
                Kind.start(ub, adapter, &u.params);
                u.line.adapter = adapter;
            }
            sys.ReleaseSemaphore(&base.lock);
            const u = unit orelse {
                ub.CloseUSBPipe(bulk_in);
                ub.CloseUSBPipe(bulk_out);
                ub.CloseUSBPipe(notify);
                sys.FreeMem(memory, @sizeOf(Adapter));
                return false;
            };
            binding.driver_data = adapter;
            binding.unit = unitNumber(base, u);
            adapter.start = .{ .kind = .start, .adapter = adapter };
            adapter.start.message.length = @sizeOf(Command);
            sys.PutMsg(base.commands.?, &adapter.start.message);
            return true;
        }

        fn unitNumber(base: *Base, unit: *const Unit) u32 {
            for (base.units(), 0..) |*u, number| if (u == unit) return @intCast(number);
            return 0;
        }

        /// An adapter let go of: its transfers aborted at once, then the
        /// task waited for while it takes the adapter off its unit.
        pub fn unbind(base: *Base, binding: *usb.USBBinding) void {
            const sys = base.sys_base;
            const raw = binding.driver_data orelse return;
            const adapter: *Adapter = @ptrCast(@alignCast(raw));
            @atomicStore(u8, &adapter.leaving, 1, .release);
            _ = sys.AbortIO(&adapter.bulk_in.io.std.req);
            _ = sys.AbortIO(&adapter.bulk_out.io.std.req);
            if (adapter.notify) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
            const reply = sys.CreateMsgPort() orelse return;
            defer sys.DeleteMsgPort(reply);
            var command = Command{ .kind = .let_go, .adapter = raw };
            command.message.reply_port = reply;
            command.message.length = @sizeOf(Command);
            sys.PutMsg(base.commands.?, &command.message);
            _ = sys.WaitPort(reply);
            _ = sys.GetMsg(reply);
            binding.driver_data = null;
        }

        // --- the task ---------------------------------------------------------------

        pub fn task(sys: *ExecBase) callconv(.c) void {
            const base: *Base = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
            base.pipes = sys.CreateMsgPort();
            base.commands = sys.CreateMsgPort();
            started(base);
            const pipes = base.pipes orelse return;
            const commands = base.commands orelse return;
            while (true) {
                _ = sys.Wait(pipes.sigMask() | commands.sigMask());
                while (sys.GetMsg(commands)) |msg| {
                    const command: *Command = @alignCast(@fieldParentPtr("message", msg));
                    const adapter: *Adapter = @ptrCast(@alignCast(command.adapter.?));
                    switch (command.kind) {
                        .start => {
                            read(adapter);
                            notifyRead(adapter);
                        },
                        .let_go => {
                            letGo(base, adapter);
                            sys.ReplyMsg(msg);
                        },
                    }
                }
                while (sys.GetMsg(pipes)) |msg| replied(base, msg);
            }
        }

        fn started(base: *Base) void {
            const starter = base.starter orelse return;
            base.starter = null;
            base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
        }

        /// A read came back: what it brought to the kind, and the read sent
        /// again - not for an adapter being let go of.
        fn replied(base: *Base, msg: *exec.Message) void {
            const ub = base.ub();
            for (base.units()) |*u| {
                const adapter = u.line.adapter orelse continue;
                if (msg == &adapter.bulk_in.io.std.req.message) {
                    adapter.reading = false;
                    const io = &adapter.bulk_in.io;
                    switch (io.std.req.err) {
                        0 => Kind.received(adapter, adapter.in_buffer[0..@intCast(io.std.actual)]),
                        usbhc.UHIOERR_STALL => _ = ub.ClearUSBStall(adapter.bulk_in),
                        else => {},
                    }
                    if (!gone(io.std.req.err)) read(adapter);
                    return;
                }
                const pipe = adapter.notify orelse continue;
                if (msg == &pipe.io.std.req.message) {
                    adapter.notifying = false;
                    if (pipe.io.std.req.err == 0) {
                        Kind.notified(adapter, adapter.notify_buffer[0..@intCast(pipe.io.std.actual)]);
                    }
                    if (!gone(pipe.io.std.req.err)) notifyRead(adapter);
                    return;
                }
            }
        }

        fn gone(err: i8) bool {
            return err == usbhc.UHIOERR_DETACHED or err == exec.IOERR_ABORTED;
        }

        /// A packet read from the bulk IN endpoint.
        fn read(adapter: *Adapter) void {
            if (@atomicLoad(u8, &adapter.leaving, .acquire) != 0) return;
            const io = &adapter.bulk_in.io;
            io.std.data = &adapter.in_buffer;
            io.std.length = @min(@max(io.max_packet, 1), adapter.in_buffer.len);
            io.std.actual = 0;
            io.nak_timeout = 0;
            adapter.reading = true;
            adapter.base.sys_base.SendIO(&io.std.req);
        }

        /// The notification endpoint's next report asked for.
        fn notifyRead(adapter: *Adapter) void {
            if (@atomicLoad(u8, &adapter.leaving, .acquire) != 0) return;
            const pipe = adapter.notify orelse return;
            const io = &pipe.io;
            io.std.data = &adapter.notify_buffer;
            io.std.length = @min(@max(io.max_packet, 1), adapter.notify_buffer.len);
            io.std.actual = 0;
            adapter.notifying = true;
            adapter.base.sys_base.SendIO(&io.std.req);
        }

        /// An adapter let go of, on the task: its reads back, nobody left
        /// using it, its unit without a line, its pipes closed.
        fn letGo(base: *Base, adapter: *Adapter) void {
            const sys = base.sys_base;
            const ub = base.ub();
            if (adapter.reading) _ = sys.WaitIO(&adapter.bulk_in.io.std.req);
            if (adapter.notifying) if (adapter.notify) |pipe| {
                _ = sys.WaitIO(&pipe.io.std.req);
            };
            adapter.reading = false;
            adapter.notifying = false;
            sys.ObtainSemaphore(&base.bind_lock);
            sys.ObtainSemaphore(&base.lock);
            adapter.unit.line.adapter = null;
            sys.ReleaseSemaphore(&base.lock);
            sys.ReleaseSemaphore(&base.bind_lock);
            ub.CloseUSBPipe(adapter.bulk_in);
            ub.CloseUSBPipe(adapter.bulk_out);
            ub.CloseUSBPipe(adapter.notify);
            sys.FreeMem(adapter, @sizeOf(Adapter));
        }

        // --- the start --------------------------------------------------------------

        /// usb.library opened, the units made, the task started and waited
        /// for. Null when any of it cannot be had.
        pub fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) ?*exec.Device {
            const base = baseOf(dev);
            base.sys_base = sys;
            base.seg_list = seg_list;
            sys.InitSemaphore(&base.lock);
            sys.InitSemaphore(&base.bind_lock);
            base.usb_base = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return null);
            base.units_memory = sys.AllocMem(@sizeOf([max_units]Unit), exec.MEMF_CLEAR) orelse return null;
            for (base.units()) |*u| u.init(sys, dev.node.name.?, .{ .base = base }, serialunit.defaultParams(Kind.default_baud));

            const signal = sys.AllocSignal(-1);
            if (signal < 0) return null;
            defer sys.FreeSignal(signal);
            base.start_signal = signal;
            const stack = sys.AllocMem(task_stack, exec.MEMF_CLEAR) orelse return null;
            base.stack = stack;
            base.task = .{
                .node = .{ .type = .task, .pri = task_pri, .name = dev.node.name },
                .sp_lower = @intFromPtr(stack),
                .sp_upper = @intFromPtr(stack) + task_stack,
            };
            base.starter = sys.FindTask(null);
            _ = sys.AddTask(&base.task, &task, null);
            _ = sys.Wait(@as(u32, 1) << @intCast(signal));
            if (base.pipes == null or base.commands == null) return null;
            return dev;
        }

        /// A control transfer on endpoint 0 of the adapter's device, from
        /// the caller's task: whether it was answered.
        pub fn control(ub: *UsbBase, adapter: *Adapter, request_type: u8, request: u8, value: u16, index: u16, data: ?*anyopaque, length: u16) bool {
            const setup = usb.SetupPacket{ .request_type = request_type, .request = request, .value = value, .index = index, .length = length };
            return ub.DoUSBControl(adapter.device, &setup, data, null) == 0;
        }
    };
}

/// `microseconds` waited out on timer.device, from the caller's task: a
/// break's time.
pub fn delayMicros(sys: *ExecBase, microseconds: u32) void {
    const timer = sdk.devices.timer;
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    var request: timer.TimeRequest = .{};
    request.node.message.reply_port = port;
    request.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &request.node, 0) != 0) return;
    defer sys.CloseDevice(&request.node);
    request.node.command = timer.TR_ADDREQUEST;
    request.time = timer.TimeVal.fromMicros(microseconds);
    _ = sys.DoIO(&request.node);
}
