// SPDX-License-Identifier: MIT
//! vp9.vcodec: a codec module in LIBS:codecs/ - VP9 decoded in
//! software, on every board: every profile (8, 10 and 12 bits; 4:2:0,
//! 4:2:2, 4:4:0 and 4:4:4), as WebM and Matroska carry it. No board here
//! has a chip for it.
//!
//! The ROM tag is vp9/vp9_init.zig, the decoder's glue vp9/_vp9.zig, the
//! decoder itself vp9/core.zig (built in as `vp9core`), the base, init,
//! Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const vp9_init = @import("vp9/vp9_init.zig");

comptime {
    _ = &vp9_init.vp9_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{vp9_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [vp9_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = vp9_init.LIBRARY_VERSION_STRING.*;
