// SPDX-License-Identifier: MIT
//! ModbusServer: a Modbus device of sixteen of each table, on the bus or
//! on the network, until CTRL-C. Built against the SDK only.
//!
//!   ModbusServer TCP/S,PORT/K/N,UNIT/K/N,DEVICE/K,BAUD/K/N,PARITY/K
//!
//! Holding register 0 counts the seconds the server has run; the input
//! registers hold 100 to 115, the discrete inputs alternate, starting
//! with 1. What a client writes is printed - the function, how many and
//! the first address - the last write of each fifth of a second.
//!
//! With TCP it listens on PORT (502) and answers every unit; without it
//! it is unit UNIT (1) on DEVICE (rs485.device) at BAUD (19200) and
//! PARITY (EVEN, ODD or NONE).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const modbus = sdk.modbus;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ModbusBase = sdk.interface.modbus.ModbusBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ModbusServer";
const VERSION_STRING = "\x00$VER: ModbusServer 1.0 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TCP/S,PORT/K/N,UNIT/K/N,DEVICE/K,BAUD/K/N,PARITY/K";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_FAILED = "%s: %s\n";
const MSG_TCP = "%s: answering on port %u - CTRL-C stops\n";
const MSG_RTU = "%s: unit %u on %s - CTRL-C stops\n";
const MSG_WROTE = "%s: function %u wrote %u from %u\n";
const MSG_PARITY = "%s: PARITY is EVEN, ODD or NONE\n";

const size = 16;

/// The tables, the lock over them, and the last write, which the hook
/// leaves for the program to print.
const Device = struct {
    coils: [size]u8 = @splat(0),
    discrete: [size]u8 = undefined,
    holding: [size]u16 = @splat(0),
    input: [size]u16 = undefined,
    lock: exec.SignalSemaphore = .{},
    hook: utility.Hook = .{},
    sys: *ExecBase,
    program: *exec.Task,
    last: modbus.ModbusWrite = .{},
};

/// The server's hook: on its process, so it only keeps the write and
/// signals the program, which prints it.
fn wrote(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const device: *Device = @ptrCast(@alignCast(hook.data.?));
    const write: *const modbus.ModbusWrite = @ptrCast(@alignCast(message.?));
    device.sys.Forbid();
    device.last = write.*;
    device.sys.Permit();
    device.sys.Signal(device.program, exec.SIGBREAKF_CTRL_F);
    return 0;
}

fn numberArg(argv: []const usize, index: usize, default: u32) u32 {
    const pointer: ?*const i32 = @ptrFromInt(argv[index]);
    return if (pointer) |value| @bitCast(value.*) else default;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
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

    var device: Device = .{ .sys = sys, .program = sys.FindTask(null).? };
    for (0..size) |i| {
        device.discrete[i] = @intFromBool(i % 2 == 0);
        device.input[i] = @intCast(100 + i);
    }
    sys.InitSemaphore(&device.lock);
    device.hook = .{ .entry = &wrote, .data = &device };

    const tcp = argv[0] != 0;
    const port = numberArg(&argv, 1, 502);
    const unit = numberArg(&argv, 2, 1);
    const device_name: [*:0]const u8 = if (argv[3] != 0) @ptrFromInt(argv[3]) else sdk.devices.rs485.RS485NAME;
    var parity: u32 = modbus.MB_PARITY_EVEN;
    if (@as(?[*:0]const u8, @ptrFromInt(argv[5]))) |text| {
        parity = switch (text[0] | 0x20) {
            'e' => modbus.MB_PARITY_EVEN,
            'o' => modbus.MB_PARITY_ODD,
            'n' => modbus.MB_PARITY_NONE,
            else => {
                _ = Printf(dl, MSG_PARITY, .{COMMAND_NAME});
                return dos.RETURN_ERROR;
            },
        };
    }

    var err: i32 = 0;
    const server = mb.StartModbusServer(&[_]utility.TagItem{
        .{ .tag = modbus.MBS_Transport, .data = if (tcp) modbus.MBT_TCP else modbus.MBT_RTU },
        .{ .tag = modbus.MBS_Unit, .data = if (tcp) 0 else unit },
        .{ .tag = modbus.MBA_Port, .data = port },
        .{ .tag = modbus.MBA_Device, .data = @intFromPtr(device_name) },
        .{ .tag = modbus.MBA_Baud, .data = numberArg(&argv, 4, 19200) },
        .{ .tag = modbus.MBA_Parity, .data = parity },
        .{ .tag = modbus.MBS_Coils, .data = @intFromPtr(&device.coils) },
        .{ .tag = modbus.MBS_CoilCount, .data = size },
        .{ .tag = modbus.MBS_DiscreteInputs, .data = @intFromPtr(&device.discrete) },
        .{ .tag = modbus.MBS_DiscreteCount, .data = size },
        .{ .tag = modbus.MBS_HoldingRegisters, .data = @intFromPtr(&device.holding) },
        .{ .tag = modbus.MBS_HoldingCount, .data = size },
        .{ .tag = modbus.MBS_InputRegisters, .data = @intFromPtr(&device.input) },
        .{ .tag = modbus.MBS_InputCount, .data = size },
        .{ .tag = modbus.MBS_Lock, .data = @intFromPtr(&device.lock) },
        .{ .tag = modbus.MBS_Hook, .data = @intFromPtr(&device.hook) },
        .{},
    }, &err) orelse {
        _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, mb.ModbusErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer mb.StopModbusServer(server);
    if (tcp) _ = Printf(dl, MSG_TCP, .{ COMMAND_NAME, port }) else _ = Printf(dl, MSG_RTU, .{ COMMAND_NAME, unit, device_name });

    // A second at a time, in fifths so a CTRL-C or a write is seen soon.
    var fifths: u32 = 0;
    while (true) {
        dl.Delay(10);
        const came = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_F);
        if (came & exec.SIGBREAKF_CTRL_C != 0) break;
        if (came & exec.SIGBREAKF_CTRL_F != 0) {
            sys.Forbid();
            const last = device.last;
            sys.Permit();
            _ = Printf(dl, MSG_WROTE, .{ COMMAND_NAME, last.function, last.count, last.address });
        }
        fifths += 1;
        if (fifths % 5 == 0) {
            sys.ObtainSemaphore(&device.lock);
            device.holding[0] +%= 1;
            sys.ReleaseSemaphore(&device.lock);
        }
    }
    return dos.RETURN_OK;
}
