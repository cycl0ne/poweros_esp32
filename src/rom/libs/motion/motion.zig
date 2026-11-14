// SPDX-License-Identifier: MPL-2.0
//! motion.library: a clock for things that move.
//!
//! One task with one timer.device request runs every animation and timer
//! that is due (`clock/_clock.zig`). The task is made the first time
//! something is due; while nothing is, no request is out and it sleeps.
//! Each call is a file of its own in a folder per area. The jump table is
//! motion_lvo.zig, the ROM tag and init motion_init.zig, the base
//! motion_base.zig. This file holds the names the rest of the kernel
//! reaches the library by; the tests of it working as a whole are in
//! tests.zig, which the ROM's host tests take in by itself: they bring
//! exec up by its path, and this file must build with the SDK alone.
//!
//! The library is a ROM module where a board's ROM lists it and a load
//! file, `LIBS:motion.library`, where it does not: built from this file
//! either way. Whoever opens it first on such a board waits for the file
//! to be loaded.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;

const motion_base = @import("motion_base.zig");
const motion_init = @import("motion_init.zig");
const _clock = @import("clock/_clock.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from motion.library.
comptime {
    _ = &motion_init.motion_library_tag;
}

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
fn programEntry(sys: *sdk.interface.exec.ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a library, not a command\n", .{motion_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [motion_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = motion_init.LIBRARY_VERSION_STRING.*;

/// Whether this is the ROM's copy: the kernel's root lists the ROM's
/// modules, a program's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

// The file's entry and its version string, which only the file has: in
// the ROM there is no file, and the host tests build this file beside
// the other modules, whose names are the same.
comptime {
    if (!in_rom and !@import("builtin").is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

/// The library's base.
pub const MotionBase = motion_base.MotionBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = motion_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const motion_library_tag = motion_init.motion_library_tag;
