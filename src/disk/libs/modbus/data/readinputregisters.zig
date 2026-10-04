// SPDX-License-Identifier: MIT
//! ReadInputRegisters: a run of input registers.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");

/// Reads a run of a device's input registers.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadInputRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) i32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
/// - `address`: the first register, from 0.
/// - `count`: how many, 1 to 125.
/// - `values`: room for `count` registers.
///
/// RESULT:
/// MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
/// below 0, what kept the question from being answered: MBERR_TIMEOUT,
/// MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
/// count of 0 or past 125, a run past address 65535, or unit 0 on
/// RTU, where nobody answers.
///
/// BEHAVIOR:
/// One question, function 0x04, and its answer unpacked - big-endian on the wire, the machine's own order here. `values` is
/// left as it was unless the answer is MBERR_OK.
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
/// `ReadHoldingRegisters`
///
/// EXAMPLES:
/// ```zig
/// var temperature: [1]u16 = undefined;
/// const result = mb.ReadInputRegisters(bus, 1, 0, 1, &temperature);
/// ```
pub fn ReadInputRegisters(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u16) i32 {
    return _data.readRegisters(context, unit, modbus.MBFC_READ_INPUT_REGISTERS, address, count, values);
}
