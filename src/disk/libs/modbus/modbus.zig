// SPDX-License-Identifier: MIT
//! modbus.library: Modbus over RTU and TCP, on the disk in LIBS:.
//!
//! A client opens a context - an RTU bus through rs485.device
//! (OpenModbusRTU) or a TCP connection made with the program's own
//! bsdsocket.library base (OpenModbusTCP) - and asks its questions with
//! a call each; every call waits for its answer, or for the context's
//! time-out. A server (StartModbusServer) runs on a process of its own
//! and answers from tables the program hands it.
//!
//! A context is its opener's: its request and its socket are used on
//! the opener's task, so every call with it must come from that task.
//! The base is shared by every opener and holds only exec's handle.
//!
//! The jump table is modbus_lvo.zig, the ROM tag, init and expunge
//! modbus_init.zig, the base modbus_base.zig. Each call is a file under
//! its area: `context/` (opening, closing, a question of any kind),
//! `data/` (the questions by name), `server/`, `text/`. The protocol
//! itself - PDUs, RTU frames, the TCP header - is `protocol/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const modbus_init = @import("modbus_init.zig");

comptime {
    _ = &modbus_init.modbus_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const modbus_library_tag = modbus_init.modbus_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{modbus_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [modbus_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = modbus_init.LIBRARY_VERSION_STRING.*;
