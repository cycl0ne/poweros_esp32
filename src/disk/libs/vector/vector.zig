// SPDX-License-Identifier: MIT
//! vector.library: shapes with smooth edges drawn onto a program's pens,
//! on the disk in LIBS:.
//!
//! A program builds a path in its own units (`path/`): contours of lines
//! and curves, kept as given. It draws the path onto a canvas
//! (`canvas/`) - its own pens and the library's working memory for them -
//! through a matrix, filled by a rule or stroked, in a paint. The drawing
//! itself is the `vector` module (`draw/`), which makes no call of exec's
//! or dos's: the library hands it exec's memory, and the host tests and
//! tools use it as it is.
//!
//! The jump table is vector_lvo.zig, the ROM tag, init and expunge
//! vector_init.zig, the base vector_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const vector_init = @import("vector_init.zig");

comptime {
    _ = &vector_init.vector_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const vector_library_tag = vector_init.vector_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{vector_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [vector_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = vector_init.LIBRARY_VERSION_STRING.*;
