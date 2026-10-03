// SPDX-License-Identifier: MIT
//! Host tests of modbus.library as a whole: the library made from its
//! ROM tag on the ROM's exec, opened as a program opens it, and spoken
//! to through its jump table - against a bus device of its own here,
//! which answers the frames written to it as a device at unit 5 would,
//! from tables of its own, or damages the answer, or says nothing.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const utility = sdk.utility;
const rs485 = sdk.devices.rs485;
const ExecBase = sdk.interface.exec.ExecBase;
const ModbusBase = sdk.interface.modbus.ModbusBase;
const modbus_init = @import("../modbus_init.zig");
const pdu = @import("../protocol/pdu.zig");
const rtu = @import("../protocol/rtu.zig");
const host = @import("host_rom");
const kexec = host.exec;

const testing = std.testing;

test {
    _ = @import("../modbus_lvo.zig");
}

// --- the bus ----------------------------------------------------------------------

const BUS_NAME = "mbtest.device";
/// The unit the bus's one device answers as.
const device_unit = 5;

const Behaviour = enum(u8) { answer, damage, silent };

const Bus = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    unit: exec.Unit = .{},
    behaviour: Behaviour = .answer,
    pad0: [3]u8 = @splat(0),
    /// The answer waiting for the next read, and its length.
    pending: [rtu.max_frame]u8 = undefined,
    pending_length: u32 = 0,
    /// What SETPARAMS was given.
    baud: u32 = 0,
    gap: u32 = 0,
    parity: u8 = 0,
    pad: [3]u8 = @splat(0),
    frames_written: u32 = 0,
    holding: [8]u16 = .{ 10, 11, 12, 13, 14, 15, 16, 17 },
    coils: [8]u8 = .{ 1, 0, 0, 1, 0, 0, 0, 0 },
};

fn busOf(dev: *exec.Device) *Bus {
    return @fieldParentPtr("dev", dev);
}

fn busInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const bus = busOf(dev);
    const header = dev.*;
    bus.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn busOpen(dev: *exec.Device, io: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    if (unit != 0) return exec.IOERR_OPENFAIL;
    io.unit = &busOf(dev).unit;
    dev.open_cnt += 1;
    return 0;
}

fn busClose(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

fn busExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = busOf(dev).sys;
    if (dev.node.pred != null) sys.Remove(&dev.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn busBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    const bus = busOf(dev);
    const io: *rs485.IORS485 = @ptrCast(@alignCast(request));
    request.err = serve(bus, io);
    if (request.flags & exec.IOF_QUICK == 0) bus.sys.ReplyMsg(&request.message);
}

/// A frame written is answered at once, as the device would; the answer
/// waits for the read.
fn serve(bus: *Bus, io: *rs485.IORS485) i8 {
    switch (io.std.req.command) {
        rs485.RS485CMD_SETPARAMS => {
            bus.baud = io.baud;
            bus.gap = io.gap;
            bus.parity = io.parity;
            return 0;
        },
        exec.CMD_CLEAR => {
            bus.pending_length = 0;
            return 0;
        },
        exec.CMD_WRITE => {
            bus.frames_written += 1;
            const length: usize = @intCast(io.std.length);
            const frame = @as([*]const u8, @ptrCast(io.std.data.?))[0..length];
            const opened = rtu.open(frame) orelse return 0;
            if (opened.unit != device_unit and opened.unit != modbus.MB_BROADCAST) return 0;
            var answer: [modbus.MB_MAX_PDU]u8 = undefined;
            const served = pdu.serve(.{ .holding = &bus.holding, .holding_count = bus.holding.len, .coils = &bus.coils, .coil_count = bus.coils.len }, opened.pdu, &answer);
            if (opened.unit == modbus.MB_BROADCAST or bus.behaviour == .silent) return 0;
            bus.pending_length = @intCast(rtu.frame(device_unit, answer[0..served.length], &bus.pending));
            if (bus.behaviour == .damage) bus.pending[1] ^= 0x40;
            io.std.actual = io.std.length;
            return 0;
        },
        exec.CMD_READ => {
            if (bus.pending_length == 0) return rs485.RS485ERR_TIMEOUT;
            const length = bus.pending_length;
            @memcpy(@as([*]u8, @ptrCast(io.std.data.?))[0..length], bus.pending[0..length]);
            io.std.actual = length;
            bus.pending_length = 0;
            return 0;
        },
        else => return exec.IOERR_NOCMD,
    }
}

fn busAbortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return 0;
}

const bus_vectors = [_]*const anyopaque{
    exec.vec(busOpen),
    exec.vec(busClose),
    exec.vec(busExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(busBeginIO),
    exec.vec(busAbortIO),
};

const bus_table = exec.InitTable{
    .data_size = @sizeOf(Bus),
    .vectors = &bus_vectors,
    .vector_count = bus_vectors.len,
    .init = &busInit,
};

const bus_tag: exec.Resident = .{
    .match_tag = &bus_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = BUS_NAME,
    .id_string = "mbtest.device 1.0",
    .init = &bus_table,
};

// --- the rig --------------------------------------------------------------------

/// exec, utility.library, the bus and the library; the base the tests
/// open is theirs.
const Rig = struct {
    sys: *ExecBase,
    ub: *host.utility.UtilityBase,
    library: *exec.Library,
    bus: *Bus,
    mb: *ModbusBase,

    fn init() !Rig {
        const ub = try host.utility.setUp();
        const sys = kexec.SysBase.iface();
        const device = kexec.InitResident(kexec.SysBase, &bus_tag, null) orelse return error.NoDevice;
        const made = kexec.InitResident(kexec.SysBase, &modbus_init.modbus_library_tag, null) orelse return error.NoLibrary;
        const opened = sys.OpenLibrary(modbus.MODBUSNAME, 1) orelse return error.NoBase;
        return .{
            .sys = sys,
            .ub = ub,
            .library = @ptrCast(@alignCast(made)),
            .bus = busOf(@ptrCast(@alignCast(device))),
            .mb = @ptrCast(opened),
        };
    }

    /// The library closed and expunged, the bus removed, utility.library
    /// freed, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.mb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        _ = rig.sys.RemDevice(&rig.bus.dev);
        try host.utility.tearDown(rig.ub);
        kexec.deinit();
    }

    fn open(rig: *Rig) !*modbus.ModbusContext {
        var err: i32 = 99;
        const context = rig.mb.OpenModbusRTU(&[_]utility.TagItem{
            .{ .tag = modbus.MBA_Device, .data = @intFromPtr(BUS_NAME) },
            .{ .tag = modbus.MBA_Baud, .data = 9600 },
            .{},
        }, &err) orelse return error.NotOpened;
        try testing.expectEqual(modbus.MBERR_OK, err);
        return context;
    }
};

test "questions asked of a device on the bus, through the jump table" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const bus = try rig.open();
    defer rig.mb.CloseModbus(bus);
    try testing.expectEqual(@as(u32, 9600), rig.bus.baud);
    try testing.expectEqual(@as(u32, 35), rig.bus.gap);
    try testing.expectEqual(rs485.RS485_PARITY_EVEN, rig.bus.parity);

    var registers: [3]u16 = undefined;
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.ReadHoldingRegisters(bus, device_unit, 2, 3, &registers));
    try testing.expectEqualSlices(u16, &.{ 12, 13, 14 }, &registers);

    const values = [_]u16{ 0xAAAA, 0x5555 };
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.WriteRegisters(bus, device_unit, 6, 2, &values));
    try testing.expectEqual(@as(u16, 0x5555), rig.bus.holding[7]);
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.WriteRegister(bus, device_unit, 0, 99));
    try testing.expectEqual(@as(u16, 99), rig.bus.holding[0]);

    var coils: [4]u8 = undefined;
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.WriteCoil(bus, device_unit, 1, 1));
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.ReadCoils(bus, device_unit, 0, 4, &coils));
    try testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1 }, &coils);

    var read: [2]u16 = undefined;
    const write = [_]u16{7};
    const transfer = modbus.ModbusReadWrite{ .read_address = 0, .read_count = 2, .read = &read, .write_address = 1, .write_count = 1, .write = &write };
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.ReadWriteRegisters(bus, device_unit, &transfer));
    try testing.expectEqualSlices(u16, &.{ 99, 7 }, &read);

    // The device's exception, and a function it does not have, raw.
    try testing.expectEqual(modbus.MBEX_ILLEGAL_ADDRESS, rig.mb.ReadHoldingRegisters(bus, device_unit, 7, 2, &registers));
    var question_bytes = [_]u8{0x11};
    var answer_bytes: [modbus.MB_MAX_PDU]u8 = undefined;
    const question = modbus.ModbusPdu{ .data = &question_bytes, .length = 1, .size = 1 };
    var answer = modbus.ModbusPdu{ .data = &answer_bytes, .size = answer_bytes.len };
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.ModbusTransaction(bus, device_unit, &question, &answer));
    try testing.expectEqualSlices(u8, &.{ 0x91, 1 }, answer_bytes[0..answer.length]);
}

test "what keeps a question from being answered" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const bus = try rig.open();
    defer rig.mb.CloseModbus(bus);
    var registers: [2]u16 = undefined;

    // Nobody at unit 3.
    try testing.expectEqual(modbus.MBERR_TIMEOUT, rig.mb.ReadHoldingRegisters(bus, 3, 0, 1, &registers));
    rig.bus.behaviour = .damage;
    try testing.expectEqual(modbus.MBERR_CRC, rig.mb.ReadHoldingRegisters(bus, device_unit, 0, 1, &registers));
    rig.bus.behaviour = .silent;
    try testing.expectEqual(modbus.MBERR_TIMEOUT, rig.mb.ReadHoldingRegisters(bus, device_unit, 0, 1, &registers));
    rig.bus.behaviour = .answer;

    // A broadcast write is sent and not waited for; a broadcast read is
    // refused, since nobody answers it.
    const written = rig.bus.frames_written;
    try testing.expectEqual(modbus.MBERR_OK, rig.mb.WriteRegister(bus, modbus.MB_BROADCAST, 4, 1234));
    try testing.expectEqual(written + 1, rig.bus.frames_written);
    try testing.expectEqual(@as(u16, 1234), rig.bus.holding[4]);
    try testing.expectEqual(modbus.MBERR_ARGS, rig.mb.ReadHoldingRegisters(bus, modbus.MB_BROADCAST, 0, 1, &registers));

    try testing.expectEqual(modbus.MBERR_ARGS, rig.mb.ReadHoldingRegisters(bus, device_unit, 0, 126, &registers));
    try testing.expectEqual(modbus.MBERR_ARGS, rig.mb.WriteRegister(bus, device_unit, 0, 0x10000));

    var err: i32 = 0;
    try testing.expect(rig.mb.OpenModbusRTU(&[_]utility.TagItem{
        .{ .tag = modbus.MBA_Device, .data = @intFromPtr("none.device") },
        .{},
    }, &err) == null);
    try testing.expectEqual(modbus.MBERR_DEVICE, err);
    try testing.expectEqualStrings("no answer came", std.mem.span(rig.mb.ModbusErrorText(modbus.MBERR_TIMEOUT)));
    try testing.expectEqualStrings("the device has no such address", std.mem.span(rig.mb.ModbusErrorText(modbus.MBEX_ILLEGAL_ADDRESS)));
}
