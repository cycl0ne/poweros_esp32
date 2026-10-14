// SPDX-License-Identifier: MIT
//! wpa.library: a Wi-Fi station's WPA2-Personal side, for a driver whose
//! radio leaves it to the host - on the disk in LIBS:.
//!
//! The network's key comes from its passphrase (`key/`); the station's
//! RSN element from the access point's (`element/`); the 4-way and group
//! key handshakes run on the EAPOL frames the driver hands in, and ask the
//! driver through its hook to send the replies, install the keys and open
//! the port (`handshake/`). The hashes, AES key unwrap, PBKDF2 and the
//! nonces are crypto.library's.
//!
//! The jump table is wpa_lvo.zig, the ROM tag, init and expunge
//! wpa_init.zig, the base wpa_base.zig. Each call is a file in its area's
//! folder.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const wpa_init = @import("wpa_init.zig");

comptime {
    _ = &wpa_init.wpa_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const wpa_library_tag = wpa_init.wpa_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{wpa_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [wpa_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = wpa_init.LIBRARY_VERSION_STRING.*;
