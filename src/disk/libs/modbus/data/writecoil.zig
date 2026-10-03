// SPDX-License-Identifier: MIT
//! WriteCoil: one coil set or cleared.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");
const pdu = @import("../protocol/pdu.zig");

/// Sets or clears one coil.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteCoil(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
///   on TCP.
/// - `address`: the coil, from 0.
/// - `value`: not 0 to set it, 0 to clear it.
///
/// RESULT:
/// MBERR_OK once the device has repeated the question, as it does to
/// say it is done; the device's exception (MBEX_*, above 0); or, below
/// 0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
/// MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for an address past 65535. To unit 0
/// on RTU the write is broadcast to every device, none answers, and
/// MBERR_OK means it was sent.
///
/// BEHAVIOR:
/// One question, function 0x05: the coil as 0xFF00 for on, 0 for off.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: the task that opened the context.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteCoils`, `ReadCoils`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.WriteCoil(bus, 1, 3, 1); // the fourth lamp on
/// ```
pub fn WriteCoil(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32 {
    if (address > 0xFFFF) return modbus.MBERR_ARGS;
    var exchange: _data.Exchange = .{};
    exchange.asked = pdu.writeOneQuestion(modbus.MBFC_WRITE_SINGLE_COIL, address, value, &exchange.question);
    return _data.write(context, unit, &exchange);
}
