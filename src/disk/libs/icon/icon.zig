// SPDX-License-Identifier: MIT
//! icon.library: icons, on the disk in LIBS:. It reads, writes and frees
//! them, gives a file without an icon the default that fits it, and keeps
//! one copy of a default picture however many files share it.
//!
//! **An icon** is `<name>.info` beside the file, drawer or volume it
//! belongs to: a PNG whose `icOn` chunk holds its fields as text
//! (`sdk.icon.file`). Its picture is decoded once into four bytes a pixel
//! (`picture/`), counted by its users and shared; its fields are made
//! into a `DiskObject` in one block with their strings (`object/`).
//!
//! **The defaults** (`default/`) are a disk's, a drawer's, a tool's, a
//! project's and the trash's - built in, and each replaced by
//! `ENV:Sys/def_<name>.info` - and a script's and each group of files
//! datatypes.library knows, which only a file gives. The base keeps what
//! it read and reads it again only when the file changed.
//!
//! The jump table is icon_lvo.zig, the ROM tag, init and expunge
//! icon_init.zig, the base icon_base.zig. The calls are under `object/`,
//! `default/`, `tooltype/` and `name/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const icon_init = @import("icon_init.zig");

comptime {
    _ = &icon_init.icon_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const icon_library_tag = icon_init.icon_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{icon_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [icon_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = icon_init.LIBRARY_VERSION_STRING.*;
