// SPDX-License-Identifier: MIT
//! h264.vcodec: a codec module in LIBS:codecs/ - H.264 decoded in
//! software, on every board: every profile and every format the standard
//! has, for the boards without a chip for it and the streams their chip
//! refuses.
//!
//! The ROM tag is h264/h264_init.zig, the decoder's glue h264/_h264.zig,
//! the decoder itself h264/core.zig (built in as `h264core`), the base,
//! init, Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const h264_init = @import("h264/h264_init.zig");

comptime {
    _ = &h264_init.h264_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{h264_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [h264_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = h264_init.LIBRARY_VERSION_STRING.*;
