// SPDX-License-Identifier: MIT
//! paintio.library: Paint's projects and pictures read from files and
//! written to them. It lives in Paint's drawer, `PROGDIR:Libs/`, and Paint
//! opens it by that path the first time it opens or saves something.
//!
//! A project is written as an IFF `FORM PNTG` (iffparse.library), each
//! layer's pixels packed by compression.library; a picture is read through
//! datatypes, whatever its format, and written as a PNG or an ILBM by
//! png.datatype and the picture group's own class. The types and the
//! file's chunks are in `sdk.paintio`.
//!
//! The jump table is paintio_lvo.zig, the ROM tag, init and expunge
//! paintio_init.zig, the base paintio_base.zig. Each call is a file under
//! its area: `project/` (on the format's parts, `_project.zig`) and
//! `picture/` (on datatypes, `_picture.zig`).

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const paintio_init = @import("paintio_init.zig");

comptime {
    _ = &paintio_init.paintio_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const paintio_library_tag = paintio_init.paintio_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{paintio_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [paintio_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = paintio_init.LIBRARY_VERSION_STRING.*;
