// SPDX-License-Identifier: MIT
//! StopModbusServer: a server stopped, waited for, and freed.

const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const ModbusBase = @import("../modbus_base.zig").ModbusBase;
const _server = @import("_server.zig");

/// Stops a server.
///
/// SYNOPSIS:
/// ```zig
/// fn StopModbusServer(base: *ModbusBase, server: ?*modbus.ModbusServer) void
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `server`: what StartModbusServer made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The server's process is told to stop (CTRL_C) and waited for: it
/// closes its device, or its connections and the port, and ends. A
/// question it is answering is answered first. The server is freed.
///
/// CONTEXT:
/// - Waits: yes, for the process.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; not the hook's, which runs on the server's
///   own process.
///
/// OWNERSHIP:
/// The tables, the lock and the hook are the program's again: nothing
/// touches them after the call.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartModbusServer`
///
/// EXAMPLES:
/// ```zig
/// mb.StopModbusServer(server);
/// ```
pub fn StopModbusServer(base: *ModbusBase, server: ?*modbus.ModbusServer) void {
    const sys = base.sys_base;
    const own = _server.serverOf(server orelse return);
    if (own.process) |process| sys.Signal(process, exec.SIGBREAKF_CTRL_C);
    sys.ObtainSemaphore(&own.alive);
    sys.ReleaseSemaphore(&own.alive);
    if (own.dos_base) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    sys.FreeVec(own);
}
