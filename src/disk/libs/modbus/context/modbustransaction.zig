// SPDX-License-Identifier: MIT
//! ModbusTransaction: any question, as its PDU, and the answer's PDU.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _context = @import("_context.zig");

/// Asks a unit a question of any kind.
///
/// SYNOPSIS:
/// ```zig
/// fn ModbusTransaction(base: *ModbusBase, context: *modbus.ModbusContext, unit: u32, question: *const modbus.ModbusPdu, answer: *modbus.ModbusPdu) i32
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `context`: the bus or connection.
/// - `unit`: the device asked: 1 to 247 on RTU (0 broadcasts), 0 to 255
///   on TCP.
/// - `question`: the PDU, the function code first; `length` bytes of
///   `data`, at most MB_MAX_PDU.
/// - `answer`: where the answer's PDU goes: `data` with room for `size`
///   bytes. `length` is set.
///
/// RESULT:
/// MBERR_OK with the answer in `answer`, the function code first - an
/// exception too, its code's top bit set, is an answer here. Below 0
/// when no answer came (MBERR_TIMEOUT, MBERR_CRC, MBERR_IO,
/// MBERR_CLOSED), or for a PDU that is empty or too long, or an answer
/// that does not fit `size` (MBERR_ARGS, MBERR_REPLY).
///
/// BEHAVIOR:
/// The PDU is sent as it is, wrapped for the transport, and the answer
/// is unwrapped and handed back without being looked into: for the
/// functions the library has no call for.
///
/// CONTEXT:
/// - Waits: yes, for the answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the context.
///
/// OWNERSHIP:
/// Both PDUs are the caller's.
///
/// NOTES:
/// A broadcast on RTU has no answer: `length` is 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadHoldingRegisters`, `ReadWriteRegisters`
///
/// EXAMPLES:
/// ```zig
/// // Report Server ID (function 17).
/// var question_bytes = [_]u8{0x11};
/// var answer_bytes: [modbus.MB_MAX_PDU]u8 = undefined;
/// const question = modbus.ModbusPdu{ .data = &question_bytes, .length = 1, .size = 1 };
/// var answer = modbus.ModbusPdu{ .data = &answer_bytes, .size = answer_bytes.len };
/// if (mb.ModbusTransaction(bus, 1, &question, &answer) == modbus.MBERR_OK) {
///     // answer_bytes[0..answer.length]
/// }
/// ```
pub fn ModbusTransaction(_: *ModbusBase, context: *modbus.ModbusContext, unit: u32, question: *const modbus.ModbusPdu, answer: *modbus.ModbusPdu) i32 {
    answer.length = 0;
    if (question.length == 0 or question.length > modbus.MB_MAX_PDU) return modbus.MBERR_ARGS;
    var length: usize = 0;
    const result = _context.transact(_context.contextOf(context), unit, question.data[0..question.length], answer.data[0..answer.size], &length);
    answer.length = @intCast(length);
    return result;
}
