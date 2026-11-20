// SPDX-License-Identifier: MIT
//! json.library: JSON text (RFC 8259) read into a tree of values, looked
//! through, built and changed, and written out again - into memory or a
//! file, compact or one value a line. It lives in LIBS:.
//!
//! A document's values and texts all come from one exec memory pool of
//! its own (`document/_document.zig`), so a document is given back in one
//! call, however it was made. Reading (`read/_read.zig`) goes through the
//! text once, without recursion - the array or object being read is the
//! one open, its parent the one to go back to - so nesting costs no
//! stack; writing (`write/_write.zig`) walks the tree the same way.
//! Numbers go both ways through a decimal of up to 800 digits
//! (`number/_number.zig`): read, to the double nearest the text; written,
//! in the fewest digits that read back as the same double.
//!
//! The jump table is json_lvo.zig, the ROM tag, init and expunge
//! json_init.zig, the base json_base.zig. Each call is a file under its
//! area: `read/` (text and files read), `document/` (a document made,
//! given back and given a root), `find/` (a value looked up by name,
//! index or pointer), `value/` (a value's number, text or truth),
//! `build/` (values made, copied, placed and taken out) and `write/`
//! (text and files written). `utf8/` checks and reads UTF-8 for both
//! directions.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const json_init = @import("json_init.zig");

comptime {
    _ = &json_init.json_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const json_library_tag = json_init.json_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{json_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [json_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = json_init.LIBRARY_VERSION_STRING.*;
