// SPDX-License-Identifier: MIT
//! av1.vcodec: a codec module in LIBS:codecs/ - AV1 decoded in
//! software, on every board: every profile (Main, High and Professional:
//! 8, 10 and 12 bits; monochrome, 4:2:0, 4:2:2 and 4:4:4) and every tool,
//! film grain too, as MP4, WebM and Matroska carry it. No board here has
//! a chip for it.
//!
//! The ROM tag is av1/av1_init.zig, the decoder's glue av1/_av1.zig, the
//! decoder itself av1/core.zig (built in as `av1core`), the base, init,
//! Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const av1_init = @import("av1/av1_init.zig");

comptime {
    _ = &av1_init.av1_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{av1_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [av1_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = av1_init.LIBRARY_VERSION_STRING.*;
