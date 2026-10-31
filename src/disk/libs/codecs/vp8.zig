// SPDX-License-Identifier: MIT
//! vp8.vcodec: a codec module in LIBS:codecs/ - VP8 (RFC 6386) decoded in
//! software, on every board: every version, as WebM and Matroska carry
//! it. No board here has a chip for it.
//!
//! The ROM tag is vp8/vp8_init.zig, the decoder's glue vp8/_vp8.zig, the
//! decoder itself vp8/core.zig (built in as `vp8core`), the base, init,
//! Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const vp8_init = @import("vp8/vp8_init.zig");

comptime {
    _ = &vp8_init.vp8_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{vp8_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [vp8_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = vp8_init.LIBRARY_VERSION_STRING.*;
