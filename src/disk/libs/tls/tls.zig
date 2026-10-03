// SPDX-License-Identifier: MIT
//! tls.library: TLS 1.3 and 1.2 over stream sockets a program connected,
//! on the disk in LIBS:.
//!
//! A session is the program's: made by OpenSession over its socket, in
//! its own bsdsocket.library base, and used from its task. The handshake
//! (`protocol/client.zig`) runs inside OpenSession; the server's
//! certificates are checked (`x509/chain.zig`) against the trusted roots
//! - `SYS:Certificates/Roots`, which the build makes from Mozilla's set,
//! and the PEM files in `ENVARC:Sys/net/certificates/` - which the base
//! reads once, with the time zone the clock keeps, and shares between
//! every opener. The hashes, keys, signatures and AES-GCM are
//! crypto.library's.
//!
//! The jump table is tls_lvo.zig, the ROM tag, init and expunge
//! tls_init.zig, the base tls_base.zig. Each call is a file in
//! `session/`; the protocol in `protocol/`, the certificates in `x509/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const tls_init = @import("tls_init.zig");

comptime {
    _ = &tls_init.tls_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const tls_library_tag = tls_init.tls_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{tls_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [tls_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = tls_init.LIBRARY_VERSION_STRING.*;
