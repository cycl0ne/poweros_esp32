// SPDX-License-Identifier: MIT
//! WriteRegister: one holding register set.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");
const pdu = @import("../protocol/pdu.zig");

/// Sets one holding register.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteRegister(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 broadcasts to all; 0 to 255
///   on TCP.
/// - `address`: the register, from 0.
/// - `value`: what it is set to, 0 to 65535.
///
/// RESULT:
/// MBERR_OK once the device has repeated the question, as it does to
/// say it is done; the device's exception (MBEX_*, above 0); or, below
/// 0, what kept it from being answered: MBERR_TIMEOUT, MBERR_CRC,
/// MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or MBERR_ARGS for an address or a value past 65535. To unit 0
/// on RTU the write is broadcast to every device, none answers, and
/// MBERR_OK means it was sent.
///
/// BEHAVIOR:
/// One question, function 0x06.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
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
/// `WriteRegisters`, `ReadHoldingRegisters`
///
/// EXAMPLES:
/// ```zig
/// const result = mb.WriteRegister(bus, 1, 40, 1500); // a set point
/// ```
pub fn WriteRegister(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, address: u32, value: u32) i32 {
    if (address > 0xFFFF or value > 0xFFFF) return modbus.MBERR_ARGS;
    var exchange: _data.Exchange = .{};
    exchange.asked = pdu.writeOneQuestion(modbus.MBFC_WRITE_SINGLE_REGISTER, address, value, &exchange.question);
    return _data.write(context, unit, &exchange);
}
