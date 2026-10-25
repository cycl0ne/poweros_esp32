// SPDX-License-Identifier: MIT
//! The file systems there is a handler for, by DosType: which handler a
//! drive's de_DosType asks for, where each file system may go, and which
//! one a medium that is mounted whole gets.
//!
//! **The handlers.** The flash file system's is in the ROM; posfs's and
//! FAT's are loaded from HANDLERS: the first time a drive needs them. FAT's
//! takes every FAT DosType (`MSD`, `MSH`, any last byte), and posfs's both
//! of posfs's (`POS\0`, `POS\1`), so each stands here once.
//!
//! **A file system a partition table brings** (a FileSysHeaderBlock for
//! the DosType, sdk/libs/dos/hardblocks.zig) is what the table's
//! partitions of that DosType run, ahead of the handler named here, when
//! the ROM has no handler for the DosType or an older one (`storedWins`).
//! It may also be for a DosType this table does not know.
//!
//! **Where each may go.**
//! - The flash file system writes a log a block is erased for: only a
//!   medium with an erase unit (the flash disk).
//! - FAT erases nothing and writes its blocks over in place: never a
//!   medium with an erase unit.
//! - posfs goes on either.
//!
//! A DosType whose area begins with a partition table - `MSH`, `POS\1` -
//! is a whole medium's. A partition of a RigidDiskBlock has its volume
//! from its first block on, so it is `MSD` or `POS\0` there.
//!
//! **A medium mounted whole**, a card or a stick without a RigidDiskBlock,
//! gets what its first block says (`wholeMediumChoice`): posfs for a posfs
//! label or a partition table with a posfs partition, and FAT for anything
//! else - FAT's handler reads a partition table and the boot sector of its
//! first FAT partition, and says what is wrong when there is neither.

const dos = @import("dos.zig");
const posfs = @import("posfs/posfs.zig");
const resident = @import("../exec/resident.zig");
const TaskFn = @import("../exec/tasks.zig").TaskFn;
const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// The handlers' names, as dos finds them: among its segments for the
/// flash file system, in HANDLERS: for the others.
pub const flashfs_handler = "flashfs-handler";
pub const fat_handler = "fat-handler";

/// A file system there is a handler for.
pub const FileSystem = struct {
    /// The DosType it is named by: a partition's (`MSD\0`, `POS\0`).
    dos_type: u32,
    /// The handler that serves it.
    handler: [*:0]const u8,
    /// Its name, as a program shows it.
    name: [*:0]const u8,
    /// It only works on a medium with an erase unit.
    needs_erase: bool = false,
    /// It never works on a medium with an erase unit.
    never_erase: bool = false,
};

/// Every file system there is a handler for, in the order a program
/// offers them.
pub const all = [_]FileSystem{
    .{ .dos_type = posfs.ID_POSFS_DISK, .handler = posfs.HANDLER_NAME, .name = "posfs" },
    .{ .dos_type = dos.flashfs.ID_FLASHFS_DISK, .handler = flashfs_handler, .name = "Flash file system", .needs_erase = true },
    .{ .dos_type = dos.ID_MSDOS_DISK, .handler = fat_handler, .name = "FAT", .never_erase = true },
};

/// The file system a DosType names, or null for one there is no handler
/// for.
///
/// INPUTS:
/// - `dos_type` - a drive's de_DosType.
pub fn of(dos_type: u32) ?*const FileSystem {
    const wanted = if (dos.fat.isFatType(dos_type))
        dos.ID_MSDOS_DISK
    else if (posfs.isPosfsType(dos_type))
        posfs.ID_POSFS_DISK
    else
        dos_type;
    for (&all) |*file_system| {
        if (file_system.dos_type == wanted) return file_system;
    }
    return null;
}

/// The handler for a DosType, or null for one there is none for.
///
/// INPUTS:
/// - `dos_type` - a drive's de_DosType.
pub fn handlerFor(dos_type: u32) ?[*:0]const u8 {
    const file_system = of(dos_type) orelse return null;
    return file_system.handler;
}

/// A handler's version as fhb_Version holds it - version << 16 |
/// revision - from its ROM tag: rt_Version, and the revision its ID string
/// gives.
///
/// INPUTS:
/// - `tag` - the handler's ROM tag.
pub fn versionOf(tag: *const resident.Resident) u32 {
    const version = @as(u32, tag.version) << 16;
    const id = tag.id_string orelse return version;
    var length: usize = 0;
    while (id[length] != 0) length += 1;
    return version | resident.revisionOf(id[0..length]);
}

/// The version of the ROM's handler for a DosType (`versionOf`), or null
/// when the ROM has none: the DosType names no handler, or the one it
/// names is loaded from the disk.
///
/// INPUTS:
/// - `sys` - exec, for FindResident.
/// - `dos_type` - a partition's de_DosType.
pub fn romVersion(sys: *ExecBase, dos_type: u32) ?u32 {
    const name = handlerFor(dos_type) orelse return null;
    const tag = sys.FindResident(name) orelse return null;
    return versionOf(tag);
}

/// The code of the ROM's handler of that name, or null when the ROM has
/// none. A node that names the handler gets it as its entry
/// (DosListHandler.entry), which dos starts ahead of looking for the name
/// among its segments and in HANDLERS:, so a drive runs the ROM's
/// handler whatever dos lists.
///
/// INPUTS:
/// - `sys` - exec, for FindResident.
/// - `handler` - the handler's name (`handlerFor`), or null.
pub fn romEntry(sys: *ExecBase, handler: ?[*:0]const u8) ?TaskFn {
    const tag = sys.FindResident(handler orelse return null) orelse return null;
    if (tag.type != .handler) return null;
    const rh: *const resident.ResidentHandler = @fieldParentPtr("resident", tag);
    return rh.handler;
}

/// Whether the file system a partition table brings for a DosType is the
/// one its partitions run: the ROM has no handler for the DosType, or the
/// table's is newer than the ROM's.
///
/// INPUTS:
/// - `stored` - the table's version, fhb_Version.
/// - `rom` - the ROM's handler's (`versionOf`), or null when the ROM has
///   none.
pub fn storedWins(stored: u32, rom: ?u32) bool {
    const in_rom = rom orelse return true;
    return stored > in_rom;
}

/// Whether a DosType says its area begins with a partition table, which
/// only a whole medium has.
///
/// INPUTS:
/// - `dos_type` - a drive's de_DosType.
pub fn wholeMediumOnly(dos_type: u32) bool {
    return dos.fat.partitionedType(dos_type) or posfs.partitionedType(dos_type);
}

/// Whether a DosType's file system can serve an area of a medium.
///
/// INPUTS:
/// - `dos_type` - the area's de_DosType.
/// - `erase_size` - the medium's erase unit, TD_GETGEOMETRY's
///   `erase_size`: 0 for a medium that erases for itself.
/// - `whole` - the area is the whole medium, rather than a partition of a
///   RigidDiskBlock.
pub fn suits(dos_type: u32, erase_size: u32, whole: bool) bool {
    const file_system = of(dos_type) orelse return false;
    if (!whole and wholeMediumOnly(dos_type)) return false;
    if (file_system.needs_erase and erase_size == 0) return false;
    if (file_system.never_erase and erase_size != 0) return false;
    return true;
}

/// What a medium mounted whole gets: a handler and the DosType its node is
/// made with.
pub const Choice = struct {
    handler: [*:0]const u8,
    dos_type: u32,
};

/// The file system a medium mounted whole gets, from its first block: a
/// posfs label gives posfs over the whole medium (`POS\0`), a partition
/// table with a posfs partition gives posfs in it (`POS\1`), and anything
/// else - a FAT table, a FAT volume, a block that could not be read (an
/// empty slice) - FAT with a partition table first (`MSH\0`), as cards and
/// sticks are sold.
///
/// INPUTS:
/// - `first_block` - the medium's first block, or an empty slice when it
///   could not be read.
pub fn wholeMediumChoice(first_block: []const u8) Choice {
    if (posfs.table.isLabel(first_block)) return .{ .handler = posfs.HANDLER_NAME, .dos_type = posfs.ID_POSFS_DISK };
    if (posfs.table.volumeIn(first_block) != null) return .{ .handler = posfs.HANDLER_NAME, .dos_type = posfs.ID_POSFS_MBR };
    return .{ .handler = fat_handler, .dos_type = dos.ID_MSDOS_DISK_HD };
}
