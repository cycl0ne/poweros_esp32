// SPDX-License-Identifier: MIT
//! paintfx.library: Paint's effects and transforms - colours changed, a
//! blur, a sharpening, a picture scaled, turned or slanted - worked on
//! pixels in memory. It lives in Paint's drawer, `PROGDIR:Libs/`, and
//! Paint opens it by that path the first time it wants one of them.
//!
//! Every call takes `sdk.paintfx.Pixels`, a view of rows of `0xAARRGGBB`
//! pixels with a pitch, so a part of a picture is worked on where it
//! lies. Where colours are mixed they are weighted by their alpha first
//! (`pixels/_pixels.zig`), so a see-through pixel lends none of its
//! colour.
//!
//! The jump table is paintfx_lvo.zig, the ROM tag, init and expunge
//! paintfx_init.zig, the base paintfx_base.zig. Each call is a file under
//! its area: `colour/` (the colour tables and matrix), `filter/` (blur
//! and sharpen, on box passes in `_filter.zig`) and `geometry/` (scaling
//! and the matrix's transform).

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const paintfx_init = @import("paintfx_init.zig");

comptime {
    _ = &paintfx_init.paintfx_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const paintfx_library_tag = paintfx_init.paintfx_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{paintfx_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [paintfx_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = paintfx_init.LIBRARY_VERSION_STRING.*;
