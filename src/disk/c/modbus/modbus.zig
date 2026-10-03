// SPDX-License-Identifier: MIT
//! Modbus: reads or writes a device's coils, inputs or registers, over
//! RTU or TCP. Built against the SDK only.
//!
//!   Modbus ADDRESS/A/N,VALUES/N/M,COUNT/K/N,ID=UNIT/K/N,COILS/S,
//!          DISCRETE/S,INPUT/S,HOLDING/S,HOST/K,PORT/K/N,DEVICE/K,
//!          BAUD/K/N,PARITY/K,TIMEOUT/K/N
//!
//! With no VALUES it reads COUNT (1) of the table from ADDRESS and
//! prints them, an address and its value a line; with VALUES it writes
//! them there, one call for one value and one for a run. The table is
//! HOLDING registers unless COILS, DISCRETE (inputs) or INPUT
//! (registers) says otherwise; the last two can only be read.
//!
//! With HOST it speaks TCP to that host's PORT (502); without it RTU on
//! DEVICE (rs485.device) at BAUD (19200) and PARITY (EVEN, ODD or NONE).
//! ID is the device's unit (1); TIMEOUT how long an answer is waited
//! for, in milliseconds (1000).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const modbus = sdk.modbus;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ModbusBase = sdk.interface.modbus.ModbusBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Modbus";
const VERSION_STRING = "\x00$VER: Modbus 1.0 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ADDRESS/A/N,VALUES/N/M,COUNT/K/N,ID=UNIT/K/N,COILS/S,DISCRETE/S,INPUT/S,HOLDING/S,HOST/K,PORT/K/N,DEVICE/K,BAUD/K/N,PARITY/K,TIMEOUT/K/N";
const arg_address = 0;
const arg_values = 1;
const arg_count = 2;
const arg_unit = 3;
const arg_coils = 4;
const arg_discrete = 5;
const arg_input = 6;
const arg_holding = 7;
const arg_host = 8;
const arg_port = 9;
const arg_device = 10;
const arg_baud = 11;
const arg_parity = 12;
const arg_timeout = 13;
const arg_count_all = 14;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_FAILED = "%s: %s\n";
const MSG_OPEN_FAILED = "%s: can't open the connection: %s\n";
const MSG_READ_ONLY = "%s: discrete inputs and input registers can only be read\n";
const MSG_TOO_MANY = "%s: at most %u values at once\n";
const MSG_PARITY = "%s: PARITY is EVEN, ODD or NONE\n";
const MSG_BIT = "%u: %u\n";
const MSG_REGISTER = "%u: %u ($%x)\n";

/// The most values read or written at once: the most registers a read
/// takes, and as many coils.
const most = modbus.MB_MAX_READ_BITS;

const Table = enum { coils, discrete, input, holding };

fn numberArg(argv: []const usize, index: usize, default: u32) u32 {
    const pointer: ?*const i32 = @ptrFromInt(argv[index]);
    return if (pointer) |value| @bitCast(value.*) else default;
}

fn parityOf(text: [*:0]const u8) ?u32 {
    return switch (text[0] | 0x20) {
        'e' => modbus.MB_PARITY_EVEN,
        'o' => modbus.MB_PARITY_ODD,
        'n' => modbus.MB_PARITY_NONE,
        else => null,
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count_all]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const modbus_lib = sys.OpenLibrary(modbus.MODBUSNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, modbus.MODBUSNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(modbus_lib);
    const mb: *ModbusBase = @ptrCast(modbus_lib);

    const table: Table = if (argv[arg_coils] != 0) .coils else if (argv[arg_discrete] != 0) .discrete else if (argv[arg_input] != 0) .input else .holding;
    const address = numberArg(&argv, arg_address, 0);
    const unit = numberArg(&argv, arg_unit, 1);
    const timeout = numberArg(&argv, arg_timeout, 1000);

    // The values to write, if any: ReadArgs' /M gives a list of pointers.
    var values: [most]u16 = undefined;
    var value_count: u32 = 0;
    if (@as(?[*]const ?*const i32, @ptrFromInt(argv[arg_values]))) |list| {
        var i: usize = 0;
        while (list[i]) |value| : (i += 1) {
            if (value_count == modbus.MB_MAX_WRITE_REGISTERS) {
                _ = Printf(dl, MSG_TOO_MANY, .{ COMMAND_NAME, modbus.MB_MAX_WRITE_REGISTERS });
                return dos.RETURN_ERROR;
            }
            values[value_count] = @truncate(@as(u32, @bitCast(value.*)));
            value_count += 1;
        }
    }
    if (value_count > 0 and (table == .discrete or table == .input)) {
        _ = Printf(dl, MSG_READ_ONLY, .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }

    // The connection: TCP to a host, or RTU on a bus.
    var socket_lib: ?*exec.Library = null;
    defer if (socket_lib) |library| sys.CloseLibrary(library);
    var err: i32 = 0;
    const host: ?[*:0]const u8 = @ptrFromInt(argv[arg_host]);
    const context = if (host) |name| tcp: {
        socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
            return dos.RETURN_FAIL;
        };
        const sb: *SocketBase = @ptrCast(socket_lib.?);
        break :tcp mb.OpenModbusTCP(sb, &[_]utility.TagItem{
            .{ .tag = modbus.MBA_Host, .data = @intFromPtr(name) },
            .{ .tag = modbus.MBA_Port, .data = numberArg(&argv, arg_port, 502) },
            .{ .tag = modbus.MBA_Timeout, .data = timeout },
            .{},
        }, &err);
    } else rtu: {
        var parity: u32 = modbus.MB_PARITY_EVEN;
        if (@as(?[*:0]const u8, @ptrFromInt(argv[arg_parity]))) |text| {
            parity = parityOf(text) orelse {
                _ = Printf(dl, MSG_PARITY, .{COMMAND_NAME});
                return dos.RETURN_ERROR;
            };
        }
        const device: [*:0]const u8 = if (argv[arg_device] != 0) @ptrFromInt(argv[arg_device]) else sdk.devices.rs485.RS485NAME;
        break :rtu mb.OpenModbusRTU(&[_]utility.TagItem{
            .{ .tag = modbus.MBA_Device, .data = @intFromPtr(device) },
            .{ .tag = modbus.MBA_Baud, .data = numberArg(&argv, arg_baud, 19200) },
            .{ .tag = modbus.MBA_Parity, .data = parity },
            .{ .tag = modbus.MBA_Timeout, .data = timeout },
            .{},
        }, &err);
    };
    const bus = context orelse {
        _ = Printf(dl, MSG_OPEN_FAILED, .{ COMMAND_NAME, mb.ModbusErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer mb.CloseModbus(bus);

    var result: i32 = modbus.MBERR_OK;
    if (value_count > 0) {
        if (table == .coils) {
            var bits: [modbus.MB_MAX_WRITE_REGISTERS]u8 = undefined;
            for (0..value_count) |i| bits[i] = @intFromBool(values[i] != 0);
            result = if (value_count == 1) mb.WriteCoil(bus, unit, address, bits[0]) else mb.WriteCoils(bus, unit, address, value_count, &bits);
        } else {
            result = if (value_count == 1) mb.WriteRegister(bus, unit, address, values[0]) else mb.WriteRegisters(bus, unit, address, value_count, &values);
        }
    } else {
        const count = numberArg(&argv, arg_count, 1);
        switch (table) {
            .coils, .discrete => {
                var bits: [most]u8 = undefined;
                result = if (count > most) modbus.MBERR_ARGS else if (table == .coils)
                    mb.ReadCoils(bus, unit, address, count, &bits)
                else
                    mb.ReadDiscreteInputs(bus, unit, address, count, &bits);
                if (result == modbus.MBERR_OK) {
                    for (0..count) |i| _ = Printf(dl, MSG_BIT, .{ address + @as(u32, @intCast(i)), @as(u32, bits[i]) });
                }
            },
            .holding, .input => {
                result = if (count > most) modbus.MBERR_ARGS else if (table == .holding)
                    mb.ReadHoldingRegisters(bus, unit, address, count, &values)
                else
                    mb.ReadInputRegisters(bus, unit, address, count, &values);
                if (result == modbus.MBERR_OK) {
                    for (0..count) |i| _ = Printf(dl, MSG_REGISTER, .{ address + @as(u32, @intCast(i)), @as(u32, values[i]), @as(u32, values[i]) });
                }
            },
        }
    }
    if (result != modbus.MBERR_OK) {
        _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, mb.ModbusErrorText(result) });
        return if (result > 0) dos.RETURN_WARN else dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}
