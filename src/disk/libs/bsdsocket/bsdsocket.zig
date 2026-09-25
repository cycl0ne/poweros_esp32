// SPDX-License-Identifier: MIT
//! bsdsocket.library: the TCP/IP stack, on the disk in LIBS:.
//!
//! The library is the stack. Its base, the one on exec's list, holds the
//! interfaces, the routes, every socket and the frame pool under one
//! lock; an opener is answered a base of its own, with its descriptor
//! table, its error number and its signals, and every call runs on the
//! caller's task, holding the lock while it changes protocol state. A
//! packet to the machine itself goes round through the loopback
//! interface `lo0` without leaving the call that sent it.
//!
//! The jump table is bsdsocket_lvo.zig, the ROM tag and the standard
//! vectors bsdsocket_init.zig, the bases bsdsocket_base.zig. Each call is
//! a file under `socket/`; the protocols are `ip/` and `udp/`, the
//! interfaces `netif/`, the routes `route/`, the frames `frame/`, the
//! lock `lock/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const bsdsocket_init = @import("bsdsocket_init.zig");

comptime {
    _ = &bsdsocket_init.bsdsocket_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const bsdsocket_library_tag = bsdsocket_init.bsdsocket_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{bsdsocket_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [bsdsocket_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = bsdsocket_init.LIBRARY_VERSION_STRING.*;
