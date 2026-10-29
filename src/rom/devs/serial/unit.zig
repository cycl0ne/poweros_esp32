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
//! UART's registers, the break, the modem lines - their pads, and their
//! input, which comes in by interrupt: each port's receive interrupt goes
//! to exec's AddIntServer, and the server hands the bytes and what the
//! port saw to the unit.
//!
//! A UART's pads are the board's: its UART part (PARTKIND_UART) for the
//! unit, PART_BusUnit the unit's number, names them in PART_PinDataOut and
//! PART_PinDataIn (`findPads`). The unit's first open takes them from
//! gpio.resource and joins them to the UART through the GPIO matrix; its
//! last close lets the TX pad go and gives both back. UART0's pads are
//! exec's raw port's, set up before any driver, and are never moved. A
//! unit without pads runs its UART unjoined: QEMU joins its serial ports
//! to the UARTs whatever pads are routed.
//!
//! The code builds against the SDK: the device keeps the SysBase its init
//! gets and calls exec (and timer.device) through the SDK's interfaces.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const uart = sdk.hardware.uart;
/// The USB-Serial-JTAG port, on the chips that have one: the ESP32s. A
/// machine under SBI or PSCI firmware has none, and its stand-in never has
/// input.
const usbjtag = switch (sdk.hardware.chip) {
    .esp32s3, .esp32p4 => @import("usbjtag.zig"),
    .rv64sbi, .a64psci => no_usbjtag,
};
const no_usbjtag = struct {
    pub const source: u32 = 0;
    pub fn put(_: u8) void {}
    pub fn flush() void {}
    pub fn read() ?u8 {
        return null;
    }
    pub fn enableRx() void {}
    pub fn disableRx() void {}
    pub fn takeRxInterrupt() bool {
        return false;
    }
};
const pads = sdk.hardware.gpio;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const vec = exec.vec;
const types = sdk.devices.serial;
const serialunit = sdk.devices.serialunit;
const IOExtSer = types.IOExtSer;

/// A unit's port: one of the chip's UARTs - three on the ESP32-S3, five
/// on the ESP32-P4 - or the USB-Serial-JTAG port, which has no line (no
/// rate, frame or breaks).
pub const Port = enum(u32) {
    uart0,
    uart1,
    uart2,
    uart3,
    uart4,
    usb,

    /// The UART, or null for the USB port and a UART this chip lacks.
    fn uartPort(port: Port) ?uart.Port {
        return switch (port) {
            .usb => null,
            inline else => |known| if (@hasField(uart.Port, @tagName(known)))
                @field(uart.Port, @tagName(known))
            else
                null,
        };
    }

    /// The chip's UARTs as ports, in their order: serial.device's units.
    pub const uarts = blk: {
        const fields = @typeInfo(uart.Port).@"enum".fields;
        var list: [fields.len]Port = undefined;
        for (fields, 0..) |field, index| list[index] = @field(Port, field.name);
        break :blk list;
    };

    fn source(port: Port) u32 {
        return if (port.uartPort()) |p| p.source() else usbjtag.source;
    }

    /// Whether the port has no interrupt of its own and is read on every
    /// VBLANK instead (its UART's `polled`, where the chip has it).
    fn polled(port: Port) bool {
        if (comptime !@hasDecl(uart.Port, "polled")) return false;
        return if (port.uartPort()) |p| p.polled() else false;
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

/// No pad: a unit whose board names none.
const no_pad: u8 = 0xFF;

/// A unit's line: its port, and the pads its board joins it to.
const Line = struct {
    port: Port,
    tx_pad: u8 = no_pad,
    rx_pad: u8 = no_pad,

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
            .node = .{ .type = .interrupt, .name = dev.node.name, .pri = if (port.polled()) poll_pri else 0 },
            .data = pu,
            .code = if (port.polled()) vec(pollServer) else vec(rxServer),
        };
        sys_base.AddIntServer(port.source(), &pu.int);
        port.enableRx();
    }
}

/// The pads of the board's UART parts, each in the unit its PART_BusUnit
/// names (the part's place among the UARTs without one). A part for a
/// unit the device lacks, for UART0, or with a line that is not a pad of
/// the chip is passed over. Nothing is taken yet: the unit's first open
/// does that.
pub fn findPads(dev: *exec.Device, sys_base: *ExecBase) void {
    const sb = serialBase(dev);
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys_base.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys_base.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys_base.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part = eb.FindBoardPart(null, st.PARTKIND_UART, st.CHIP_ANY);
    while (part) |found| : (part = eb.FindBoardPart(found, st.PARTKIND_UART, st.CHIP_ANY)) {
        const number = ub.GetTagData(st.PART_BusUnit, found.unit, found.tags);
        if (number >= sb.unit_count) continue;
        const line = &unitsOf(sb)[number].serial.line;
        if (line.port == .uart0 or line.port.uartPort() == null) continue;
        const tx = expansion.BoardPin.of(ub.GetTagData(st.PART_PinDataOut, 0, found.tags));
        const rx = expansion.BoardPin.of(ub.GetTagData(st.PART_PinDataIn, 0, found.tags));
        if (tx.kind != expansion.boardpin.BPIN_GPIO or rx.kind != expansion.boardpin.BPIN_GPIO) continue;
        line.tx_pad = tx.number;
        line.rx_pad = rx.number;
    }
}

/// A unit's pads taken from gpio.resource and joined to its UART, for its
/// first open: false when another driver holds one. A unit without pads
/// has nothing to take.
fn takePads(sb: *SerialBase, line: *const Line) bool {
    // A chip whose pads gpio.resource does not hand out has none to take.
    if (comptime gpio_resource.GPIO_PADS == 0) return true;
    if (line.tx_pad == no_pad) return true;
    const port = line.port.uartPort() orelse return true;
    const sys = sb.sys_base;
    const port_pads = [_]u8{ line.tx_pad, line.rx_pad };
    if (sys.OpenResource(gpio_resource.GPIONAME)) |resource| {
        const gb: *GpioBase = @ptrCast(@alignCast(resource));
        if (gpio_resource.allocPads(gb, &port_pads, sb.dev.node.name.?)) |refused| {
            exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ sb.dev.node.name.?, refused.pad, refused.holder });
            return false;
        }
    }
    pads.toMatrix(line.tx_pad);
    pads.connectOut(line.tx_pad, uart.txSignal(port), false);
    pads.outputEnable(line.tx_pad, true);
    pads.toMatrix(line.rx_pad);
    pads.inputEnable(line.rx_pad, true);
    pads.pullUp(line.rx_pad, true);
    pads.connectIn(uart.rxSignal(port), line.rx_pad);
    return true;
}

/// A unit's pads given back at its last close: the TX pad no longer
/// driven, the UART's RX reading a high line, both pads free for another
/// driver.
fn givePads(sb: *SerialBase, line: *const Line) void {
    if (comptime gpio_resource.GPIO_PADS == 0) return;
    if (line.tx_pad == no_pad) return;
    const port = line.port.uartPort() orelse return;
    pads.outputEnable(line.tx_pad, false);
    pads.connectIn(uart.rxSignal(port), pads.in_high);
    const sys = sb.sys_base;
    if (sys.OpenResource(gpio_resource.GPIONAME)) |resource| {
        const gb: *GpioBase = @ptrCast(@alignCast(resource));
        gpio_resource.freePads(gb, &.{ line.tx_pad, line.rx_pad });
    }
}

/// Unit `unit_number`, opened as the SDK's unit opens it. Its first open
/// takes its pads (SerErr_DevBusy when another driver holds them).
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return exec.IOERR_OPENFAIL;
    const pu = &unitsOf(sb)[unit_number];
    const first = pu.serial.unit.open_cnt == 0;
    if (first and !takePads(sb, &pu.serial.line)) return types.SerErr_DevBusy;
    const err = pu.serial.open(io);
    if (err != 0) {
        if (first) givePads(sb, &pu.serial.line);
        return err;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
}

/// The unit's last close gives its pads back. The last close of a device
/// RemDevice marked LIBF_DELEXP expunges it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const serial = SerialUnit.of(io);
    serial.close(io);
    if (serial.unit.open_cnt == 0) givePads(serialBase(dev), &serial.line);
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

/// Unit `unit_number`'s writes held - one under way finished first - until
/// `releaseWrites`: how usbserial.device gives up its port between two
/// writes. From a task.
pub fn holdWrites(dev: *exec.Device, unit_number: u32) void {
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return;
    unitsOf(sb)[unit_number].serial.holdWrites();
}

/// Unit `unit_number`'s writes going again.
pub fn releaseWrites(dev: *exec.Device, unit_number: u32) void {
    const sb = serialBase(dev);
    if (unit_number >= sb.unit_count) return;
    unitsOf(sb)[unit_number].serial.releaseWrites();
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

/// A polled port's server's priority on VBLANK's chain: ahead of
/// timer.device's, which answers every VBLANK and ends the chain.
const poll_pri: i8 = 10;

/// A polled port's server (`Port.polled`), on VBLANK's chain: what the
/// port holds is taken as its interrupt would have had it, and VBLANK goes
/// on down the chain to timer.device. At 50 Hz the 32-byte FIFO keeps up
/// with 1600 bytes a second: typing, not a paste.
fn pollServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = rxServer(is_data, int_number);
    return 0;
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
