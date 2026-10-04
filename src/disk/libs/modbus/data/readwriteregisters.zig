// SPDX-License-Identifier: MIT
//! ReadWriteRegisters: holding registers written, then others read, in one exchange.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _data = @import("_data.zig");
const pdu = @import("../protocol/pdu.zig");
const _context = @import("../context/_context.zig");

/// Writes holding registers and reads others in one exchange.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadWriteRegisters(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, transfer: *const modbus.ModbusReadWrite) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device: 1 to 247 on RTU, 0 to 255 on TCP.
/// - `transfer`: `write_count` registers (1 to 121) from `write` to
///   `write_address`, and `read_count` (1 to 125) from `read_address`
///   into `read`.
///
/// RESULT:
/// MBERR_OK with `read` filled; the device's exception (MBEX_*, above
/// 0); or, below 0, what kept the question from being answered:
/// MBERR_TIMEOUT, MBERR_CRC, MBERR_REPLY, MBERR_IO, MBERR_CLOSED - or
/// MBERR_ARGS for a count out of range, a run past address 65535, or
/// unit 0 on RTU.
///
/// BEHAVIOR:
/// One question, function 0x17. The device writes first and reads
/// after, so a run that overlaps reads what was just written.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the context.
///
/// OWNERSHIP:
/// `transfer` and its buffers are the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadHoldingRegisters`, `WriteRegisters`
///
/// EXAMPLES:
/// ```zig
/// const command = [_]u16{1};
/// var status: [4]u16 = undefined;
/// const transfer = modbus.ModbusReadWrite{
///     .write_address = 0, .write_count = 1, .write = &command,
///     .read_address = 10, .read_count = 4, .read = &status,
/// };
/// const result = mb.ReadWriteRegisters(bus, 1, &transfer);
/// ```
pub fn ReadWriteRegisters(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, transfer: *const modbus.ModbusReadWrite) i32 {
    const read_count = transfer.read_count;
    const write_count = transfer.write_count;
    if (read_count == 0 or read_count > modbus.MB_MAX_READ_REGISTERS or transfer.read_address > 0xFFFF or read_count > 0x10000 - transfer.read_address) return modbus.MBERR_ARGS;
    if (write_count == 0 or write_count > modbus.MB_MAX_READWRITE_REGISTERS or transfer.write_address > 0xFFFF or write_count > 0x10000 - transfer.write_address) return modbus.MBERR_ARGS;
    if (unit == modbus.MB_BROADCAST and _context.contextOf(context).transport == .rtu) return modbus.MBERR_ARGS;
    var exchange: _data.Exchange = .{};
    exchange.asked = pdu.readWriteQuestion(transfer, &exchange.question);
    const asked = _data.ask(context, unit, &exchange);
    if (asked != modbus.MBERR_OK) return asked;
    return pdu.takeRegisters(exchange.answerPdu(), read_count, transfer.read);
}
