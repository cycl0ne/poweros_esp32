// SPDX-License-Identifier: MIT
//! ReadDiscreteInputs: a run of discrete inputs, a byte each.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");

/// Reads a run of a device's discrete inputs.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadDiscreteInputs(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
/// - `address`: the first input, from 0.
/// - `count`: how many, 1 to 2000.
/// - `values`: room for `count` bytes, each set to 0 or 1.
///
/// RESULT:
/// MBERR_OK with `values` filled; the device's exception (MBEX_*, above 0); or,
/// below 0, what kept the question from being answered: MBERR_TIMEOUT,
/// MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for a
/// count of 0 or past 2000, a run past address 65535, or unit 0 on
/// RTU, where nobody answers.
///
/// BEHAVIOR:
/// One question, function 0x02, and its answer unpacked - eight bits to a byte on the wire, a byte each here. `values` is
/// left as it was unless the answer is MBERR_OK.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Forbid: must not be held.
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
/// `ReadCoils`
///
/// EXAMPLES:
/// ```zig
/// var switches: [4]u8 = undefined;
/// const result = mb.ReadDiscreteInputs(bus, 1, 0, 4, &switches);
/// ```
pub fn ReadDiscreteInputs(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, count: u32, values: [*]u8) i32 {
    return _data.readBits(context, unit, modbus.MBFC_READ_DISCRETE_INPUTS, address, count, values);
}
