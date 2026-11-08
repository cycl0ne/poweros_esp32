// SPDX-License-Identifier: MIT
//! update.library: an installed system brought up to date from a release
//! package, on the disk in LIBS:. C:Update runs it from a shell and
//! SYS:System/Update in a window; the calls and their structures are
//! `sdk.update`.
//!
//! **Three things are compared, not two**: the list the machine was given
//! (`SYS:System/manifest`), the list in the package, and the file itself.
//!
//!     installed  file      package   what happens
//!     =          there     =         nothing; the file is not read
//!     =          gone      =         written again
//!     =          =         differs   fetched and written
//!     =          differs   any       changed here: kept, and said
//!     not in it  -         in it     new: fetched
//!     in it      -         not in it the build dropped it: deleted
//!     not in it  -         not in it the machine's own: never touched
//!
//! Where the two lists agree the file is looked for and not read, so a
//! run costs one name a path for everything the build left as it was,
//! and a file that went missing comes back. Each file is fetched to a
//! name of its own on its volume, held against the length and the CRC-32
//! the list gives, and renamed into place, so a run that is cut leaves
//! either the old file or the new one; what the build dropped goes last
//! and in reverse; and the package's list is written as the machine's
//! own at the very end, so a run that never finished looks like one that
//! never happened. Before the first file is written the system volume is
//! given a snapshot, where it keeps them.
//!
//! **The firmware's partition** (`UPD_Boot`) is written after the system
//! volume's: where the firmware starts from either of two partitions the
//! one not in use is written and tried at the next start, which
//! ConfirmUpdate on the system that comes up makes permanent; where it
//! reads one the file replaced is kept beside the new one.
//!
//! | Folder | What it holds |
//! |--------|---------------|
//! | `run/` | the run: CreateUpdate, DoUpdate, GetUpdateInfo, DeleteUpdate, and where what it says goes (`_run.zig`) |
//! | `package/` | a package's files read from a path or an address |
//! | `system/` | the three lists compared and the system volume's files written |
//! | `boot/` | the firmware's partition: its files written, ConfirmUpdate |
//!
//! The jump table is update_lvo.zig, the ROM tag, init and expunge
//! update_init.zig, the base update_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const update_init = @import("update_init.zig");

comptime {
    _ = &update_init.update_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const update_library_tag = update_init.update_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{update_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [update_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = update_init.LIBRARY_VERSION_STRING.*;
