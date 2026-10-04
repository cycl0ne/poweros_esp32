// SPDX-License-Identifier: MIT
//! ModbusErrorText: what an error or exception code means, in words.

const sdk = @import("sdk");
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;

/// Says what a code the library answered means.
///
/// SYNOPSIS:
/// ```zig
/// fn ModbusErrorText(base: *ModbusBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `code`: an MBERR_* or an MBEX_* a call answered.
///
/// RESULT:
/// A short sentence without a full stop, "unknown error" for a code the
/// library does not have.
///
/// BEHAVIOR:
/// The text is the library's, the same for every caller.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none needed.
/// - Process: any.
///
/// OWNERSHIP:
/// The text is the library's and stays while it is open; it is not
/// freed.
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
/// const result = mb.ReadHoldingRegisters(bus, 1, 0, 2, &registers);
/// if (result != modbus.MBERR_OK) _ = dos.stdio.Printf(dl, "Modbus: %s\n", .{mb.ModbusErrorText(result)});
/// ```
pub fn ModbusErrorText(_: *ModbusBase, code: i32) [*:0]const u8 {
    return switch (code) {
        modbus.MBERR_OK => "done",
        modbus.MBEX_ILLEGAL_FUNCTION => "the device does not do that function",
        modbus.MBEX_ILLEGAL_ADDRESS => "the device has no such address",
        modbus.MBEX_ILLEGAL_VALUE => "the device refused the value",
        modbus.MBEX_DEVICE_FAILURE => "the device failed",
        modbus.MBEX_ACKNOWLEDGE => "the device took it and is still working",
        modbus.MBEX_DEVICE_BUSY => "the device is busy",
        modbus.MBEX_GATEWAY_PATH => "the gateway has no way to the device",
        modbus.MBEX_GATEWAY_TARGET => "the device behind the gateway did not answer",
        modbus.MBERR_TIMEOUT => "no answer came",
        modbus.MBERR_CRC => "the answer was damaged on the line",
        modbus.MBERR_REPLY => "the answer did not fit the question",
        modbus.MBERR_IO => "the device or the connection failed",
        modbus.MBERR_ARGS => "an address, a count or a value out of range",
        modbus.MBERR_NOMEM => "not enough memory",
        modbus.MBERR_CONNECT => "no connection could be made",
        modbus.MBERR_HOST => "the host was not found",
        modbus.MBERR_DEVICE => "the bus's device could not be opened",
        modbus.MBERR_CLOSED => "the other side closed the connection",
        else => "unknown error",
    };
}
