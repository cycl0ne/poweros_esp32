// SPDX-License-Identifier: MPL-2.0
//! The units of serial.device and usbserial.device: one port each - a
//! UART, or the USB-Serial-JTAG port - with serial.device's API
//! (sdk/devices/serial.zig), which the SDK's serial unit
//! (sdk/devices/serialunit.zig) gives every unit; serial.zig describes
//! the commands. Each device's ROM tag (serial.zig, usbserial.zig) names
//! its ports and gets a base with one unit per port; the jump table
//! (`vectors`) is the same for both.
//!
//! What is here is the ports' own: their line - the rate and frame on a
//! UART's registers, the break, the modem lines - and their input, which
//! comes in by interrupt: each port's receive interrupt goes to exec's
//! AddIntServer, and the server hands the bytes and what the port saw to
//! the unit.
//!
//! The code builds against the SDK: the device keeps the SysBase its init
//! gets and calls exec (and timer.device) through the SDK's interfaces.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const uart = sdk.hardware.uart;
const usbjtag = @import("usbjtag.zig");
const vec = exec.vec;
const types = sdk.devices.serial;
const serialunit = sdk.devices.serialunit;
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

/// The chip's fastest rate.
const max_baud = 5_000_000;

/// A unit's line: its port.
const Line = struct {
    port: Port,

    pub fn write(line: *Line, sys: *ExecBase, bytes: []const u8) bool {
        _ = sys;
        line.port.write(bytes);
        return true;
    }

    /// The unit's line onto its UART (the USB port has none).
    pub fn setLine(line: *Line, sys: *ExecBase, params: *const serialunit.Params) void {
        _ = sys;
        const port = line.port.uartPort() orelse return;
        uart.setLine(port, .{
            .baud = params.baud,
            .bits = params.read_len,
            .parity = switch (params.parity()) {
                .odd => .odd,
                .even => .even,
                else => .none,
            },
            .stop_bits = params.stop_bits,
            .xon_xoff = params.xonXoff(),
            .xon = @truncate(params.ctl_char >> 24),
            .xoff = @truncate(params.ctl_char >> 16),
        });
    }

    /// io_Status's line bits, clear for an active line. The UARTs have no
    /// carrier detect: CD is never active there. The USB port's lines
    /// count as active.
    pub fn lineStatus(line: *Line) u16 {
        const port = line.port.uartPort() orelse return 0;
        const l = uart.lines(port);
        var bits: u16 = types.IO_STATF_CD;
        if (l.dsr_n) bits |= types.IO_STATF_DSR;
        if (l.cts_n) bits |= types.IO_STATF_CTS;
        if (l.rts_n) bits |= types.IO_STATF_RTS;
        if (l.dtr_n) bits |= types.IO_STATF_DTR;
        return bits;
    }

    /// What a UART can do: one frame for both directions, 5 to 8 bits,
    /// 1 or 2 stop bits, odd or even parity only, up to its fastest rate.
    pub fn check(line: *const Line, x: *const IOExtSer) i8 {
        if (line.port.uartPort() == null) return 0;
        if (x.read_len != x.write_len or x.read_len < 5 or x.stop_bits == 0) return types.SerErr_InvParam;
        if (x.ext_flags & types.SEXTF_MSPON != 0) return types.SerErr_InvParam;
        if (x.baud > max_baud) return types.SerErr_InvParam;
        return 0;
    }

    /// A UART's line held low, or let go. The USB port has no line.
    pub fn setBreak(line: *Line, on: bool) bool {
        const port = line.port.uartPort() orelse return false;
        uart.setBreak(port, on);
        return true;
    }
};

const SerialUnit = serialunit.Unit(Line);

/// A unit and its port's receive interrupt server.
const PortUnit = struct {
    serial: SerialUnit,
    int: exec.Interrupt,
};

/// A device's base: the Device and SysBase; its units follow it
/// (unitsOf).
pub const SerialBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit_count: u32,
};

const units_offset = std.mem.alignForward(usize, @sizeOf(SerialBase), @alignOf(PortUnit));

/// The base's size with `count` units: the device's InitTable data_size.
pub fn dataSize(comptime count: usize) usize {
    return units_offset + count * @sizeOf(PortUnit);
}

fn unitsOf(sb: *SerialBase) []PortUnit {
    const first: [*]PortUnit = @ptrCast(@alignCast(@as([*]u8, @ptrCast(sb)) + units_offset));
    return first[0..sb.unit_count];
}

fn serialBase(dev: *exec.Device) *SerialBase {
    return @fieldParentPtr("dev", dev);
}

/// A device's init routine's work: a unit per port, each port set up (a
/// UART's clock, reset and boot-up line, unless it is up already) with its
/// receive interrupt on.
pub fn initDevice(dev: *exec.Device, sys_base: *ExecBase, ports: []const Port) void {
    const sb = serialBase(dev);
    sb.sys_base = sys_base;
    sb.unit_count = @intCast(ports.len);
    for (unitsOf(sb), ports) |*pu, port| {
        pu.serial.init(sys_base, dev.node.name.?, .{ .port = port }, serialunit.defaultParams(uart.default_baud));
        // Inside Disable: the bus clock and reset are SYSTEM's registers,
        // shared with the other core's drivers.
        sys_base.Disable();
        port.setUp();
        sys_base.Enable();
        // Empty the port's FIFO (there is no buffer until the first open).
        // The receive interrupt stays off until its server is in place: one
        // raised before its source is routed is lost.
        port.disableRx();
        while (port.read()) |_| {}
        pu.int = .{
            .node = .{ .type = .interrupt, .name = dev.node.name },
            .data = pu,
            .code = vec(rxServer),
        };
        sys_base.AddIntServer(port.source(), &pu.int);
        port.enableRx();
    }
}

/// Unit `unit_number`, opened as the SDK's unit opens it.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return exec.IOERR_OPENFAIL;
    const err = unitsOf(sb)[unit_number].serial.open(io);
    if (err != 0) return err;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
}

/// The last close of a device RemDevice marked LIBF_DELEXP expunges it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    SerialUnit.of(io).close(io);
    dev.open_cnt -= 1;
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
    for (unitsOf(sb)) |*pu| {
        sys.Disable();
        pu.serial.line.port.disableRx();
        sys.Enable();
        sys.RemIntServer(pu.serial.line.port.source(), &pu.int);
    }
    sys.DetachLibrary(dev);
    // The jump table and the base, as MakeLibrary allocated them.
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null; // no seglist: the code is in ROM
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    SerialUnit.of(io).beginIO(io);
}

/// AbortIO: 0 if the request was aborted, -1 if it wasn't waiting.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    _ = dev;
    return SerialUnit.of(io).abortIO(io);
}

/// `bytes` to unit `unit_number`'s port beside its requests, not through
/// one: how usbserial.device writes the system log's copy. The unit's
/// writes and these go out whole, one after another. From a task.
pub fn writeAside(dev: *exec.Device, unit_number: u32, bytes: []const u8) void {
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return;
    unitsOf(sb)[unit_number].serial.writeAside(bytes);
}

/// A unit's receive interrupt server: the port's bytes and what it saw
/// to the unit, which serves the waiting reads.
fn rxServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const pu: *PortUnit = @ptrCast(@alignCast(is_data.?));
    const port = pu.serial.line.port;
    const events = port.takeRxInterrupt() orelse return 0; // not ours
    var bytes: [64]u8 = undefined;
    var count: usize = 0;
    while (port.read()) |c| {
        bytes[count] = c;
        count += 1;
        if (count == bytes.len) {
            pu.serial.input(&bytes, .{});
            count = 0;
        }
    }
    pu.serial.input(bytes[0..count], .{
        .brk = events.brk,
        .parity_error = events.parity_error,
        .frame_error = events.frame_error,
        .overflow = events.overflow,
        .xoff = events.xoff,
        .xon = events.xon,
    });
    return 1;
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
