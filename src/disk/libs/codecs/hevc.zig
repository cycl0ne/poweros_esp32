// SPDX-License-Identifier: MIT
//! hevc.vcodec: a codec module in LIBS:codecs/ - H.265 decoded in
//! software, on every board: Main, Main 10, Main Still Picture and the
//! range extensions' profiles (4:0:0 to 4:4:4, up to 16 bits), for the
//! boards without a chip for it and the streams their chip refuses.
//!
//! The ROM tag is hevc/hevc_init.zig, the decoder's glue hevc/_hevc.zig,
//! the decoder itself hevc/core.zig (built in as `hevccore`), the base,
//! init, Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const hevc_init = @import("hevc/hevc_init.zig");

comptime {
    _ = &hevc_init.hevc_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{hevc_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [hevc_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = hevc_init.LIBRARY_VERSION_STRING.*;
