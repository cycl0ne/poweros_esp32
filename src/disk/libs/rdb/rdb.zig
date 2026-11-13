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
//! put over them. MountPartition puts a partition on dos's list as a
//! device node, with the handler its DosType asks for.
//!
//! A disk with a GPT and no RigidDiskBlock of its own is read through its
//! GPT: the GPT's partitions are nodes of the handle too, and the table
//! is the one in the GPT's PowerOS container, read and written through a
//! window that counts its blocks from the container's first. The GPT
//! calls read, change, mount and write the GPT itself.
//!
//! A handle is its opener's: every allocation and the open unit are in it,
//! so the base is shared by every opener and holds only exec's handle.
//!
//! The jump table is rdb_lvo.zig, the ROM tag, init and expunge
//! rdb_init.zig, the base rdb_base.zig. Each call is a file under its
//! area: `handle/` (open, close), `table/` (a fresh table, writing it),
//! `partition/` (the list, and mounting a partition), `filesystem/` (the
//! file systems kept in the table), `gpt/` (the GPT: its partitions,
//! mounting one, a fresh GPT, writing it).

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
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{rdb_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [rdb_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = rdb_init.LIBRARY_VERSION_STRING.*;

/// Whether this is the ROM's copy: the kernel's root lists the ROM's
/// modules, a program's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

// The file's entry and its version string, which only the file has: in
// the ROM there is no file, and every module the ROM takes from the disk
// would bring its own by the same names.
comptime {
    if (!in_rom) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}
