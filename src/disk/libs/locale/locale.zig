// SPDX-License-Identifier: MIT
//! locale.library: countries, languages and a program's strings, on the
//! disk in LIBS:.
//!
//! A locale is a country's way of writing dates, times, numbers and
//! money, and the language its words are in; the system's default one is
//! made at boot from ENV:Sys/locale.prefs (C:SetPrefs), and dos writes
//! its dates and its faults in it from then on. A catalog is a program's
//! strings in one language, looked for in each language the locale
//! prefers in turn; a program without one shows the strings built into
//! it.
//!
//! The areas: `locale/` makes, gives back and sets the locale and reads
//! its files, `strings/` hands out a language's words, `chars/` sorts
//! characters into letters, digits and the rest and changes their case,
//! `compare/` orders strings, `format/` writes and reads dates and writes
//! numbers, `catalog/` loads a program's strings, and `dos/` is what
//! stands in front of dos's DateToStr, StrToDate and Fault.
//!
//! The jump table is locale_lvo.zig, the ROM tag, init, open and expunge
//! locale_init.zig, the base and the private shapes locale_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const locale_init = @import("locale_init.zig");

comptime {
    _ = &locale_init.locale_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const locale_library_tag = locale_init.locale_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{locale_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [locale_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = locale_init.LIBRARY_VERSION_STRING.*;
