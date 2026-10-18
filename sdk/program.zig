// SPDX-License-Identifier: MIT
//! The root every program, library, device and handler for the disk is
//! compiled from (`addProgram`). It takes in the program's own root - the
//! module `program`, whose exports (`_program_entry`, the ROM tag, the
//! `$VER:` string) are what the linker keeps - and gives the whole the
//! SDK's panic handler, so that a failed safety check anywhere in it is a
//! Guru naming the check and the place.
//!
//! It also gives it memcpy, memmove and memset: exec's `CopyMem` and
//! `SetMem` (sdk/libs/exec/libc.zig), the loops the kernel has for the
//! board. A program with its own - one whose root has `own_memory_calls`
//! - keeps them.

const program = @import("program");

comptime {
    _ = program;
    if (!@hasDecl(program, "own_memory_calls")) {
        const libc = @import("sdk").exec.libc;
        @export(&libc.memcpy, .{ .name = "memcpy" });
        @export(&libc.memmove, .{ .name = "memmove" });
        @export(&libc.memset, .{ .name = "memset" });
    }
}

pub const panic = @import("sdk").exec.panic;
