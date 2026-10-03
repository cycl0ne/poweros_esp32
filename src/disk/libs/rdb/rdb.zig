// SPDX-License-Identifier: MIT
//! rdb.library: a disk's RigidDiskBlock and its partitions, read into
//! memory, changed there and written back, on the disk in LIBS:.
//!
//! OpenRDB opens a unit of any block device that answers TD_GETGEOMETRY,
//! CMD_READ and CMD_WRITE (and TDCMD_ERASE where the medium wants it),
//! reads the table into a handle and keeps the unit open; the partitions
//! are nodes on the handle's list, and the program changes them in place.
//! WriteRDB checks the table, gives each PartitionBlock a block and writes
//! it. The blocks the library does not manage - file system headers, their
//! code, bad-block lists - stay where they are, and no PartitionBlock is
//! put over them.
//!
//! A handle is its opener's: every allocation and the open unit are in it,
//! so the base is shared by every opener and holds only exec's handle.
//!
//! The jump table is rdb_lvo.zig, the ROM tag, init and expunge
//! rdb_init.zig, the base rdb_base.zig. Each call is a file under its
//! area: `handle/` (open, close), `table/` (a fresh table, writing it),
//! `partition/` (the list).

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const rdb_init = @import("rdb_init.zig");

comptime {
    _ = &rdb_init.rdb_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const rdb_library_tag = rdb_init.rdb_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{rdb_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [rdb_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = rdb_init.LIBRARY_VERSION_STRING.*;
