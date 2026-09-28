// SPDX-License-Identifier: MIT
//! The root every program, library, device and handler for the disk is
//! compiled from (`addProgram`). It takes in the program's own root - the
//! module `program`, whose exports (`_program_entry`, the ROM tag, the
//! `$VER:` string) are what the linker keeps - and gives the whole the
//! SDK's panic handler, so that a failed safety check anywhere in it is a
//! Guru naming the check and the place.

comptime {
    _ = @import("program");
}

pub const panic = @import("sdk").exec.panic;
