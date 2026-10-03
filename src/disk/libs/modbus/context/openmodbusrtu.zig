// SPDX-License-Identifier: MIT
//! OpenModbusRTU: a client on an RTU bus, its device opened and its line
//! set.

const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const utility = sdk.utility;
const rs485 = sdk.devices.rs485;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _context = @import("_context.zig");
const rtu = @import("../protocol/rtu.zig");

/// Opens a client on an RTU bus.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenModbusRTU(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags`: the bus, all optional:
///   - MBA_Device (`[*:0]const u8`): the device, `rs485.device`.
///   - MBA_DeviceUnit (u32): its unit, 0.
///   - MBA_Baud (u32): bits per second, 19200.
///   - MBA_Parity (u32): MB_PARITY_EVEN, MB_PARITY_ODD or
///     MB_PARITY_NONE; even, as the protocol has it.
///   - MBA_StopBits (u32): 1 or 2; 1.
///   - MBA_Timeout (u32): how long a question waits for its answer, in
///     milliseconds; 1000.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The context, with the device open and its line set; `err` is then
/// MBERR_OK. Null for no memory (MBERR_NOMEM), for a device that cannot
/// be opened or refuses the line (MBERR_DEVICE), or for a time-out of 0
/// (MBERR_ARGS).
///
/// BEHAVIOR:
/// The device is opened exclusively and set to the line asked for: eight
/// data bits, the parity and stop bits given, and a frame ending at a
/// quiet line of three and a half characters - or of 1750 µs above
/// 19200 bit/s, as the protocol fixes it there.
///
/// CONTEXT:
/// - Waits: yes, on the device.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do. The context's reply port is the caller's,
///   so every call with it must come from the same task.
///
/// OWNERSHIP:
/// The context and the open device are the caller's until CloseModbus.
///
/// NOTES:
/// The device is a bus for one client: a second context on it fails
/// until the first is closed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenModbusTCP`, `CloseModbus`, `ReadHoldingRegisters`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const bus = mb.OpenModbusRTU(&[_]utility.TagItem{
///     .{ .tag = modbus.MBA_Baud, .data = 9600 },
///     .{},
/// }, &err) orelse return err;
/// defer mb.CloseModbus(bus);
/// ```
pub fn OpenModbusRTU(base: *ModbusBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*modbus.ModbusContext {
    var reason: i32 = modbus.MBERR_OK;
    const context = open(base, tags, &reason);
    if (err) |into| into.* = reason;
    return context;
}

fn open(base: *ModbusBase, tags: ?[*]const utility.TagItem, reason: *i32) ?*modbus.ModbusContext {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const device: [*:0]const u8 = @ptrFromInt(ub.GetTagData(modbus.MBA_Device, @intFromPtr(rs485.RS485NAME.ptr), tags));
    const device_unit: u32 = @intCast(ub.GetTagData(modbus.MBA_DeviceUnit, 0, tags));
    const baud: u32 = @intCast(ub.GetTagData(modbus.MBA_Baud, 19200, tags));
    const parity: u32 = @intCast(ub.GetTagData(modbus.MBA_Parity, modbus.MB_PARITY_EVEN, tags));
    const stop_bits: u32 = @intCast(ub.GetTagData(modbus.MBA_StopBits, 1, tags));
    const timeout: u32 = @intCast(ub.GetTagData(modbus.MBA_Timeout, 1000, tags));
    if (timeout == 0 or parity > modbus.MB_PARITY_ODD or (stop_bits != 1 and stop_bits != 2)) {
        reason.* = modbus.MBERR_ARGS;
        return null;
    }

    const context = _context.create(base, .rtu) orelse {
        reason.* = modbus.MBERR_NOMEM;
        return null;
    };
    context.timeout = timeout;
    const failed = fail: {
        context.port = sys.CreateMsgPort() orelse break :fail modbus.MBERR_NOMEM;
        const request = sys.CreateIORequest(context.port, @sizeOf(rs485.IORS485)) orelse break :fail modbus.MBERR_NOMEM;
        const io: *rs485.IORS485 = @ptrCast(@alignCast(request));
        context.io = io;
        if (sys.OpenDevice(device, device_unit, &io.std.req, 0) != 0) break :fail modbus.MBERR_DEVICE;
        context.device_open = true;

        const character_bits = 1 + 8 + @as(u32, if (parity != modbus.MB_PARITY_NONE) 1 else 0) + stop_bits;
        io.std.req.command = rs485.RS485CMD_SETPARAMS;
        io.baud = baud;
        io.data_bits = 8;
        io.parity = @intCast(parity);
        io.stop_bits = @intCast(stop_bits);
        io.gap = rtu.gapTenths(baud, character_bits);
        if (sys.DoIO(&io.std.req) != 0) break :fail modbus.MBERR_DEVICE;
        return @ptrCast(context);
    };
    _context.destroy(context);
    reason.* = failed;
    return null;
}
