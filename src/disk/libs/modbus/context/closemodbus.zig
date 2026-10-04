// SPDX-License-Identifier: MIT
//! CloseModbus: a client's context closed and freed.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _context = @import("_context.zig");

/// Closes a client's context.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseModbus(base: *ModbusBase, context: ?*modbus.ModbusContext) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `context`: what OpenModbusRTU or OpenModbusTCP made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// An RTU context's device is closed; a TCP context's connection is
/// closed if the library made it. The context is freed.
///
/// CONTEXT:
/// - Waits: yes, on the device.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the context.
///
/// OWNERSHIP:
/// The context is gone after the call. A socket the program gave with
/// MBA_Socket is still the program's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenModbusRTU`, `OpenModbusTCP`
///
/// EXAMPLES:
/// ```zig
/// mb.CloseModbus(bus);
/// ```
pub fn CloseModbus(_: *ModbusBase, context: ?*modbus.ModbusContext) void {
    const public = context orelse return;
    _context.destroy(_context.contextOf(public));
}
