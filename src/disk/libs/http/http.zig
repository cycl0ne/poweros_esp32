// SPDX-License-Identifier: MIT
//! http.library: HTTP/1.1 requests, over plain connections or TLS, on
//! the disk in LIBS:.
//!
//! A program makes a client with its own bsdsocket.library base, and its
//! requests through the client: each is sent, the head of its answer
//! read and redirects followed by OpenRequest, its body read by
//! ReadRequest - decoded from its chunks and, when asked, unpacked - and
//! its connection kept by CloseRequest for the next request to the same
//! server. A body too large to hand over in one piece is written with
//! WriteRequest before the answer is read.
//!
//! The jump table is http_lvo.zig, the ROM tag, init and expunge
//! http_init.zig, the base http_base.zig. Each call is a file under its
//! area: `client/` (on `_client.zig`), `request/` (on `_request.zig`,
//! the request and its answer as they go back and forth); the
//! connections are `connection/_connection.zig`, and HTTP's text is
//! `protocol/_protocol.zig`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const http_init = @import("http_init.zig");

comptime {
    _ = &http_init.http_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const http_library_tag = http_init.http_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{http_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [http_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = http_init.LIBRARY_VERSION_STRING.*;
