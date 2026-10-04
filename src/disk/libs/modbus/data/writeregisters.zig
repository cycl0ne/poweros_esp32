// SPDX-License-Identifier: MIT
//! WriteRegisters: a run of holding registers set.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");
const pdu = @import("../protocol/pdu.zig");

/// Sets a run of holding registers.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u16) i32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
///   on TCP.
/// - `address`: the first register, from 0.
/// - `count`: how many, 1 to 123.
/// - `values`: `count` registers.
///
/// RESULT:
/// MBERR_OK once the device has repeated the question, as it does to
/// say it is done; the device's exception (MBEX_*, above 0); or, below
/// 0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
/// MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a count of 0 or past 123, or a run past address 65535. To unit 0
/// on RTU the write is broadcast to every device, none answers, and
/// MBERR_OK means it was sent.
///
/// BEHAVIOR:
/// One question, function 0x10.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the context.
///
/// OWNERSHIP:
/// `values` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteRegister`, `ReadWriteRegisters`
///
/// EXAMPLES:
/// ```zig
/// const limits = [_]u16{ 100, 900 };
/// const result = mb.WriteRegisters(bus, 1, 10, limits.len, &limits);
/// ```
pub fn WriteRegisters(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]const u16) i32 {
    if (count == 0 or count > modbus.MB_MAX_WRITE_REGISTERS or address > 0xFFFF or count > 0x10000 - address) return modbus.MBERR_ARGS;
    var exchange: _data.Exchange = .{};
    exchange.asked = pdu.writeRegistersQuestion(address, count, values, &exchange.question);
    return _data.write(context, unit, &exchange);
}
