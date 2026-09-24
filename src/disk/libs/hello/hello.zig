// SPDX-License-Identifier: MIT
//! hello.library on the disk: the same library the ROM has a copy of,
//! built as a load file instead. What it is for is proving that a module
//! can come off a disk at all - `OpenLibrary("hello.library", 1)` finds
//! nothing on exec's list, ramlib loads this, and the second look finds it.
//!
//! A module in a file is a program in every way but one: it is linked the
//! same, loaded the same and relocated the same, and the only thing that
//! makes it a module is the ROM tag in it. Its entry is never called - the
//! shell will not run a file whose tag says library - so it is a stub that
//! says so and stops.
//!
//! The tag's vectors are relocated against the instruction bus and its
//! strings against the data bus, both by the loader, so nothing here has to
//! know where it ended up.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const LIBRARY_NAME = "hello.library";
const LIBRARY_VERSION = 2;
const LIBRARY_REVISION = 0;
const BUILD_DATE = "17.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// This library's base: exec's, and the file it came out of.
const HelloBase = extern struct {
    lib: exec.Library,
    /// What LoadSeg made, handed to the init and kept for the expunge.
    seg_list: ?*anyopaque = null,
};

/// LibInit: exec has copied the tag's name, version and ID string into the
/// base. `seg_list` is what the library was loaded from.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Library {
    const base: *HelloBase = @fieldParentPtr("lib", lib);
    base.seg_list = seg_list;
    lib.revision = LIBRARY_REVISION;
    // Its own function, through the jump table exec has just built out of
    // the vectors in this file: proof that a call into loaded code lands
    // where it should, which is the whole question a module in a file
    // asks.
    const HelloFn = *const fn (*exec.Library) callconv(.c) [*:0]const u8;
    const answer = lib.vector(HelloFn, exec.libraries.lvo(4))(lib);
    sdk.exec.kprintf(sys, "%s %d.%d from a file, base at 0x%08x: %s\n", .{
        lib.name(),
        lib.version,
        lib.revision,
        @intFromPtr(lib),
        answer,
    });
    return lib;
}

/// The library's own function, in the first slot after the standard four.
fn hello(lib: *exec.Library) callconv(.c) [*:0]const u8 {
    _ = lib;
    return "hello from the disk";
}

/// The four standard vectors. The SDK has Open, Close and ExtFunc, which
/// every library does the same way; Expunge is the library's own, because
/// only it knows what it took. This one took a file: it keeps the seglist
/// its init was given and hands it back when it is expunged, which is what
/// tells whoever is unloading where the memory is. Nothing expunges a
/// loaded module yet, so that path is written and not yet walked.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        // Somebody still has it: go when the last one closes.
        lib.flags |= exec.libraries.LIBF_DELEXP;
        return null;
    }
    const base: *HelloBase = @fieldParentPtr("lib", lib);
    return base.seg_list;
}

const vectors = [_]*const anyopaque{
    exec.libraries.vec(exec.libraries.libOpen),
    exec.libraries.vec(exec.libraries.libClose),
    exec.libraries.vec(expunge),
    exec.libraries.vec(exec.libraries.libExtFunc),
    exec.libraries.vec(hello),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(HelloBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: a module in a file is made when something asks
/// for it, not at a boot phase. The priority orders nothing here.
///
/// It is in `.resident`, which program.ld KEEPs: nothing in the file refers
/// to the tag - whoever loads the file finds it by looking for it - so
/// without that the linker collects it and the file is a module with no
/// module in it.
export const hello_library_tag: exec.Resident linksection(".resident") = exec.Resident{
    .match_tag = &hello_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A module is not a command. Whoever runs this file gets nothing done and
/// a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld KEEPs.
export const version_tag: [LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = LIBRARY_VERSION_STRING.*;
