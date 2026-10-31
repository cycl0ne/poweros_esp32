// SPDX-License-Identifier: MIT
//! mjpeg.vcodec: a codec module in LIBS:codecs/ - Motion JPEG decoded in
//! software, on every board: baseline pictures, grey or with their colour
//! at full size or halved.
//!
//! The ROM tag is mjpeg/mjpeg_init.zig, the decoder mjpeg/_mjpeg.zig
//! (jpeg.datatype's decoder, built in as `jpegdecode`), the base, init,
//! Expunge and jump table every module shares module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const mjpeg_init = @import("mjpeg/mjpeg_init.zig");

comptime {
    _ = &mjpeg_init.mjpeg_vcodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a codec module, not a command\n", .{mjpeg_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [mjpeg_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = mjpeg_init.LIBRARY_VERSION_STRING.*;
