// SPDX-License-Identifier: MIT
//! datatypes.library: a file opened by what is in it, on the disk in
//! LIBS:.
//!
//! A file is recognised against the descriptors `C:AddDataTypes` read
//! into the list (`type/`), and what it is becomes an object of the
//! class that kind names (`object/`). The object is a BOOPSI gadget, so
//! a program adds it to a window and the contents are drawn, scrolled
//! and played without the program knowing the format.
//!
//! datatypesclass, which every format's class is made from, is here:
//! `class/`. It holds what every kind of contents has in common - how
//! much there is, how much is shown, what it is called - and leaves the
//! rest to the class that knows the format. Laying out is done on a
//! process of its own (`layout/`), because whoever asks for it may not
//! wait.
//!
//! The rest: `attrs/` sets and reads an object's attributes and sends
//! it methods, `draw/` draws one somewhere that is not its window, and
//! `text/` is the library's own words.
//!
//! The jump table is datatypes_lvo.zig, the ROM tag, init, open and
//! expunge datatypes_init.zig, the base datatypes_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const datatypes_init = @import("datatypes_init.zig");

comptime {
    _ = &datatypes_init.datatypes_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const datatypes_library_tag = datatypes_init.datatypes_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{datatypes_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [datatypes_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = datatypes_init.LIBRARY_VERSION_STRING.*;
