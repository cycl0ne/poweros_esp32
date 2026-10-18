// SPDX-License-Identifier: MIT
//! rdb.library's structures and constants: the handle a disk is worked on
//! through, the partition nodes on it, and the error codes. The calls are
//! in `sdk.interface.rdb`; the blocks themselves are `sdk.dos.hardblocks`.
//!
//! OpenRDB reads what a disk says about itself - its RigidDiskBlock and
//! the chain of PartitionBlocks - into memory, as an `RDBHandle` with one
//! `RDBPartition` per partition on its list. A program reads and changes
//! them there: AddPartition and RemPartition change the list, and the
//! fields of a partition's block (its flags, its environment, its name)
//! are the program's to set directly. Nothing reaches the disk before
//! WriteRDB, which checks the whole table, gives each PartitionBlock a
//! block, puts the checksums in and writes it; CloseRDB lets everything
//! go. MountPartition puts a partition on dos's list, as a device node
//! its handler is started from.
//!
//! A file system's code can be kept in the table too: an `RDBFileSystem`
//! per DosType on the handle's second list, which AddFileSystem and
//! RemFileSystem change and WriteRDB writes as a FileSysHeaderBlock and a
//! chain of LoadSegBlocks. The partitions of that DosType run it when the
//! ROM has no handler for the DosType or an older one
//! (`sdk.dos.filesystems.storedWins`).
//!
//! The handle and its nodes are the library's allocations, handed to the
//! program until CloseRDB. A program changes what is documented as its to
//! change, and leaves the list itself to the calls.

const exec = @import("../exec/exec.zig");
const trackdisk = @import("../../devices/trackdisk.zig");
const hardblocks = @import("../dos/hardblocks.zig");
const path = @import("../dos/path.zig");

/// The library's name, for OpenLibrary.
pub const RDBNAME = "rdb.library";

// --- errors -------------------------------------------------------------------

/// What a call that can fail answers, or puts where its `err` points: 0,
/// or one of these.
pub const RDBERR_OK: i32 = 0;
/// No memory for the handle, a node or the block buffer.
pub const RDBERR_NOMEM: i32 = -1;
/// The device or unit cannot be opened, or does not answer
/// TD_GETGEOMETRY with a medium.
pub const RDBERR_DEVICE: i32 = -2;
/// A read, an erase or a write the device refused (a write-protected
/// medium, a card that went away).
pub const RDBERR_IO: i32 = -3;
/// The handle holds no RigidDiskBlock to change: the disk had none and
/// InitRDB has not made one.
pub const RDBERR_NORDB: i32 = -4;
/// A block size the medium cannot take: smaller than its erase unit, or
/// not the size of its own blocks.
pub const RDBERR_BLOCKSIZE: i32 = -5;
/// A partition name that is empty, longer than MAX_DEVICE_NAME, holds a
/// colon or a slash, or is another partition's already. MountPartition
/// also answers it when the name is taken on dos's list with every dot
/// that still fits added.
pub const RDBERR_NAME: i32 = -6;
/// Cylinders the partition may not have: outside the RigidDiskBlock's
/// usable ones, the wrong way round, or another partition's. AddPartition
/// with 0 and 0 also answers it when no cylinder is free at all.
pub const RDBERR_RANGE: i32 = -7;
/// No block left in the RigidDiskBlock's own area for another
/// PartitionBlock, or for the code of the table's file systems even with
/// the area grown up to the first partition.
pub const RDBERR_FULL: i32 = -8;
/// The medium in the unit is not the one the handle's table was read
/// from: it was taken out, or another put in, since OpenRDB. Nothing is
/// written or mounted; a new OpenRDB reads the medium that is there.
pub const RDBERR_CHANGED: i32 = -9;
/// MountPartition: a device node on dos's list already opens some of the
/// partition's blocks - the partition mounted before, or a drive over
/// the whole medium or another area that reaches into it.
pub const RDBERR_MOUNTED: i32 = -10;
/// MountPartition: no handler serves the partition's DosType, or its file
/// system cannot go on this medium or inside a partition. AddFileSystem:
/// the code is not a handler's load file for this machine.
pub const RDBERR_FILESYSTEM: i32 = -11;

// --- MountPartition -------------------------------------------------------------

/// MountPartition's flags.
/// The handler started before the call returns, so the volume is on
/// dos's list, rather than at the drive's first use.
pub const RDBMF_START: u32 = 1;

/// The name a partition is mounted under, without the colon: the
/// partition's own, or with dots added.
pub const MountName = [path.MAX_DEVICE_NAME:0]u8;

// --- the handle ---------------------------------------------------------------

/// RDBHandle.flags.
/// The disk held a sound RigidDiskBlock when it was opened, or has one
/// since WriteRDB.
pub const RDBF_FOUND: u32 = 1;
/// A chain stopped at a block that is not what it should be; what came
/// before it was read. WriteRDB writes the table as it now is.
pub const RDBF_DAMAGED: u32 = 2;
/// The disk held a RigidDiskBlock written for another block size, which
/// is left alone and counts as none.
pub const RDBF_FOREIGN: u32 = 4;
/// The table in memory is not the one on the disk: InitRDB, AddPartition
/// or RemPartition changed it since it was read or written. A program
/// that changes a field directly sets it itself, if it cares.
pub const RDBF_CHANGED: u32 = 8;

/// A disk's RigidDiskBlock and partitions, in memory. OpenRDB makes it,
/// CloseRDB frees it; the library keeps more behind it than is shown here.
pub const RDBHandle = extern struct {
    /// RDBF_*.
    flags: u32 = 0,
    /// The block the RigidDiskBlock was found in, or WriteRDB last put it
    /// in.
    block: u32 = 0,
    /// What TD_GETGEOMETRY said about the medium.
    geometry: trackdisk.DriveGeometry = .{},
    /// The RigidDiskBlock. Its vendor, product and revision strings and
    /// its flags are the program's to change; the block numbers in it are
    /// WriteRDB's, and the geometry InitRDB's.
    rdb: hardblocks.RigidDiskBlock = .{},
    /// The partitions, RDBPartition nodes in the order of the disk's
    /// chain: walk it with NextPartition, change it with AddPartition and
    /// RemPartition.
    partitions: exec.List = .{},
    /// TD_CHANGENUM when the table was read: which medium it is of.
    /// WriteRDB and MountPartition refuse when the unit's count has moved
    /// on since. 0 for a device that does not count.
    change_num: u32 = 0,
    /// The file systems kept in the table, RDBFileSystem nodes in the
    /// order of the disk's chain: walk it with NextFileSystem, change it
    /// with AddFileSystem and RemFileSystem.
    file_systems: exec.List = .{},
};

/// One partition, on its handle's list.
pub const RDBPartition = extern struct {
    /// On the handle's list; its name is the block's drive name.
    node: exec.Node = .{},
    /// The block it was read from or last written to; `end_of_list` for
    /// one WriteRDB has not written yet.
    at: u32 = hardblocks.end_of_list,
    /// The PartitionBlock. Its flags (PBFF_*), its drive name, its device
    /// flags and its environment are the program's to change; `next` and
    /// the checksum are WriteRDB's.
    block: hardblocks.PartitionBlock = .{},
};

/// One file system's code kept in the table, on its handle's list. All of
/// it is the library's: a program reads it. What the DosType is called is
/// `sdk.dos.filesystems`'s to say.
pub const RDBFileSystem = extern struct {
    /// On the handle's list; it has no name.
    node: exec.Node = .{},
    /// The block its FileSysHeaderBlock was read from or last written to;
    /// `end_of_list` for one AddFileSystem made that WriteRDB has not
    /// written yet.
    at: u32 = hardblocks.end_of_list,
    /// The FileSysHeaderBlock: the DosType it serves (`dos_type`), its
    /// version (`version`: version << 16 | revision) and where its code
    /// starts on the disk.
    header: hardblocks.FileSysHeaderBlock = .{},
    /// The code's size in bytes: the load file's, as the chain holds it.
    size: u32 = 0,
    /// The blocks the code takes on the disk; 0 for code WriteRDB has
    /// not written yet.
    blocks: u32 = 0,
};

/// The partition's drive name, as the node calls it.
pub fn partitionName(part: *const RDBPartition) [*:0]const u8 {
    return @ptrCast(&part.block.drive_name);
}
