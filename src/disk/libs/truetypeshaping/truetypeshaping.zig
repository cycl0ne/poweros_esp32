// SPDX-License-Identifier: MIT
//! truetypeshaping.library: a run of glyphs shaped by a font's layout
//! tables, on the disk in LIBS:.
//!
//! A font opened by truetype.library hands out its tables, and this
//! library reads three of them (`shape/`): `GDEF`, which sorts the
//! glyphs into bases, ligatures and marks; `GSUB`, whose lookups replace
//! glyphs; and `GPOS`, whose lookups move them. A call finds the lookups
//! of the features it was asked for under the run's script and language,
//! applies them in the font's order to a buffer of its own, and writes
//! the buffer back as the shaped run: each glyph's number, its advance,
//! its offsets and the part of the text it stands for.
//!
//! Nothing is kept between two calls and nothing of the font is written,
//! so one outline is shaped with by any number of tasks at once. The
//! font is reached only through truetype.library's calls, which the
//! base holds open.
//!
//! The jump table is truetypeshaping_lvo.zig, the ROM tag, init and
//! expunge truetypeshaping_init.zig, the base truetypeshaping_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const truetypeshaping_init = @import("truetypeshaping_init.zig");

comptime {
    _ = &truetypeshaping_init.truetypeshaping_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const truetypeshaping_library_tag = truetypeshaping_init.truetypeshaping_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{truetypeshaping_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [truetypeshaping_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = truetypeshaping_init.LIBRARY_VERSION_STRING.*;
