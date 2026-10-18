// SPDX-License-Identifier: MIT
//! The RigidDiskBlock and what hangs off it (devices/hardblocks.h): the
//! blocks at the start of a disk that say what the disk is, where its
//! partitions are and which file system belongs on each, field for field
//! as devices/hardblocks.h has them.
//!
//! They are not part of any partition, so nothing a program can reach ever
//! sees them. The root is the RigidDiskBlock, which a driver finds by
//! looking at the first RDB_LOCATION_LIMIT blocks of the medium; from there
//! a chain of PartitionBlocks says what to mount, and a chain of
//! FileSysHeaderBlocks (with the code in LoadSegBlocks) says what to mount
//! it with. Each block carries its own identifier and a checksum, so a disk
//! that holds none of this is recognised at once.
//!
//! What we do with them: flash.device reads the RDB when it starts and
//! hands a device node per partition to expansion.library (MakeDosNode,
//! AddBootNode), which dos.library takes in at boot - which is how `DH0:`
//! comes to exist. It is what makes a second partition, or another file
//! system on the same chip, a matter of writing blocks rather than of
//! changing the kernel. A file system's code kept in the table - a
//! FileSysHeaderBlock with its LoadSegBlocks - is what the partitions of
//! its DosType run when the ROM has no handler for it or an older one
//! (`sdk.dos.filesystems.storedWins`).
//!
//! Made for this machine:
//! - Little-endian, like everything else here, so a disk does not travel to
//!   a big-endian machine.
//! - **A block is the medium's erase unit** (`rdb_BlockBytes`, 4096 on our
//!   flash), not 512. On flash the smallest thing that can be rewritten is
//!   a whole sector, so two of these blocks in one sector would mean
//!   rewriting one to change the other. Each structure still uses only its
//!   first 256 bytes.
//! - `pb_DriveName` is a C string in its 32 bytes, not a BSTR.
//! - `pb_Environment` is a `DosEnvec` (sdk/libs/dos/filehandler.zig), not 17
//!   untyped longwords; ours has no de_SecOrg and counts bytes rather than
//!   longwords.
//! - No `rdb_DriveInit`, no bad-block replacement: the flash chip does its
//!   own sparing, and there is nothing to call.

const std = @import("std");
const DosEnvec = @import("filehandler.zig").DosEnvec;

/// The identifiers, as four characters.
pub const IDNAME_RIGIDDISK: u32 = 0x5244_534B; // 'RDSK'
pub const IDNAME_BADBLOCK: u32 = 0x4241_4442; // 'BADB'
pub const IDNAME_PARTITION: u32 = 0x5041_5254; // 'PART'
pub const IDNAME_FILESYSHEADER: u32 = 0x4653_4844; // 'FSHD'
pub const IDNAME_LOADSEG: u32 = 0x4C53_4547; // 'LSEG'

/// How many blocks from the start of the medium a RigidDiskBlock may be in.
pub const RDB_LOCATION_LIMIT: u32 = 16;

/// A block number that is not one: zero is a valid block, so the empty list
/// is all ones.
pub const end_of_list: u32 = 0xFFFF_FFFF;

/// rdb_Flags.
pub const RDBFF_LAST: u32 = 1;
pub const RDBFF_LASTLUN: u32 = 2;
pub const RDBFF_LASTTID: u32 = 4;
pub const RDBFF_NORESELECT: u32 = 8;
pub const RDBFF_DISKID: u32 = 0x10;
pub const RDBFF_CTRLRID: u32 = 0x20;

/// pb_Flags.
pub const PBFF_BOOTABLE: u32 = 1;
pub const PBFF_NOMOUNT: u32 = 2;

/// struct RigidDiskBlock: the root of it all, 256 bytes of a block.
pub const RigidDiskBlock = extern struct {
    id: u32 = IDNAME_RIGIDDISK,
    /// rdb_SummedLongs: how many longwords the checksum covers.
    summed_longs: u32 = @sizeOf(RigidDiskBlock) / 4,
    /// rdb_ChkSum: the longwords before it sum to zero with it.
    checksum: i32 = 0,
    /// rdb_HostID: the SCSI target a host adapter's driver uses; 7 is what
    /// a host adapter carries, and nothing here reads it.
    host_id: u32 = 7,
    /// rdb_BlockBytes: the size of the blocks these numbers count.
    block_bytes: u32 = 0,
    flags: u32 = 0,

    /// rdb_BadBlockList, rdb_PartitionList, rdb_FileSysHeaderList,
    /// rdb_DriveInit: block numbers, or end_of_list.
    bad_block_list: u32 = end_of_list,
    partition_list: u32 = end_of_list,
    file_sys_header_list: u32 = end_of_list,
    drive_init: u32 = end_of_list,
    reserved1: [6]u32 = @splat(end_of_list),

    // What the medium physically is.
    cylinders: u32 = 0,
    sectors: u32 = 0,
    heads: u32 = 0,
    interleave: u32 = 1,
    park: u32 = 0,
    reserved2: [3]u32 = @splat(0),
    write_pre_comp: u32 = 0,
    reduced_write: u32 = 0,
    step_rate: u32 = 0,
    reserved3: [5]u32 = @splat(0),

    // What of it may be used, and for what.
    /// rdb_RDBBlocksLo/Hi: the blocks these structures live in.
    rdb_blocks_lo: u32 = 0,
    rdb_blocks_hi: u32 = 0,
    /// rdb_LoCylinder/HiCylinder: the cylinders partitions may use.
    lo_cylinder: u32 = 0,
    hi_cylinder: u32 = 0,
    /// rdb_CylBlocks: blocks per cylinder (heads × sectors).
    cyl_blocks: u32 = 0,
    auto_park_seconds: u32 = 0,
    reserved4: [2]u32 = @splat(0),

    // Who made it.
    disk_vendor: [8]u8 = @splat(0),
    disk_product: [16]u8 = @splat(0),
    disk_revision: [4]u8 = @splat(0),
    controller_vendor: [8]u8 = @splat(0),
    controller_product: [16]u8 = @splat(0),
    controller_revision: [4]u8 = @splat(0),
    reserved5: [10]u32 = @splat(0),
};

/// struct PartitionBlock: one partition, and the environment the file
/// system on it is mounted with.
pub const PartitionBlock = extern struct {
    id: u32 = IDNAME_PARTITION,
    summed_longs: u32 = @sizeOf(PartitionBlock) / 4,
    checksum: i32 = 0,
    host_id: u32 = 7,
    /// pb_Next: the next PartitionBlock, or end_of_list.
    next: u32 = end_of_list,
    flags: u32 = 0,
    reserved1: [2]u32 = @splat(0),
    /// pb_DevFlags: OpenDevice's flags for this partition.
    dev_flags: u32 = 0,
    /// pb_DriveName: what the device node is called (`DH0`), a C string.
    drive_name: [32]u8 = @splat(0),
    reserved2: [15]u32 = @splat(0),
    /// pb_Environment: the geometry and parameters the handler is given.
    environment: DosEnvec = .{},
    // The environment's own reserved longs. It has two more fields than it
    // had (de_Baud and de_Control, in their standard places), so this is
    // two shorter and the block is the size it always was - a partition
    // written before them reads back with both zero, which is what "not
    // asked for" is.
    e_reserved: [14]u32 = @splat(0),

    /// The drive name as a slice, without the NULs after it.
    pub fn name(pb: *const PartitionBlock) []const u8 {
        return std.mem.sliceTo(&pb.drive_name, 0);
    }
};

/// struct FileSysHeaderBlock: a file system's code kept in the table, for
/// the partitions whose de_DosType is `dos_type`: its version and the
/// first LoadSegBlock of the load file. One per DosType; they are chained
/// from rdb_FileSysHeaderList.
pub const FileSysHeaderBlock = extern struct {
    id: u32 = IDNAME_FILESYSHEADER,
    summed_longs: u32 = @sizeOf(FileSysHeaderBlock) / 4,
    checksum: i32 = 0,
    host_id: u32 = 7,
    next: u32 = end_of_list,
    flags: u32 = 0,
    reserved1: [2]u32 = @splat(0),
    /// fhb_DosType: the partition's de_DosType this one answers for.
    dos_type: u32 = 0,
    /// fhb_Version: release << 16 | revision.
    version: u32 = 0,
    /// fhb_PatchFlags: which of the fields below to put into the device
    /// node. Only the code is taken (FHBF_SEGLIST); the node keeps its
    /// own stack size and priority.
    patch_flags: u32 = 0,
    node_type: u32 = 0,
    task: u32 = 0,
    lock: u32 = 0,
    handler: u32 = 0,
    stack_size: u32 = 0,
    priority: i32 = 0,
    startup: i32 = 0,
    /// fhb_SegListBlocks: the first LoadSegBlock of the code.
    seg_list_blocks: i32 = @bitCast(end_of_list),
    /// fhb_GlobalVec: BCPL's, which we have none of.
    global_vec: i32 = -1,
    reserved2: [23]u32 = @splat(0),
    reserved3: [21]u32 = @splat(0),
};

/// fhb_PatchFlags: the node's code (dn_SegList) is the header's.
pub const FHBF_SEGLIST: u32 = 1 << 7;

/// struct LoadSegBlock: a piece of a file system's code. The data runs from
/// the end of this header to the end of the longwords the checksum covers,
/// the whole block but in the chain's last (123 longwords in a 512-byte
/// block); the pieces in chain order are the load file.
pub const LoadSegBlock = extern struct {
    id: u32 = IDNAME_LOADSEG,
    summed_longs: u32 = 0,
    checksum: i32 = 0,
    host_id: u32 = 7,
    next: u32 = end_of_list,
};

/// How many bytes of code a LoadSegBlock in a block of `block_bytes`
/// holds.
pub fn loadSegRoom(block_bytes: u32) u32 {
    return block_bytes - @sizeOf(LoadSegBlock);
}

/// The code a LoadSegBlock holds, from its block's bytes: what follows its
/// header up to the end of the longwords its checksum covers. Null for a
/// block that is not a sound LoadSegBlock: its identifier, a count of
/// longwords from the header's to the block's, and the checksum over
/// them.
///
/// INPUTS:
/// - `block` - the whole block.
pub fn loadSegData(block: []const u8) ?[]const u8 {
    if (block.len < @sizeOf(LoadSegBlock)) return null;
    if (std.mem.readInt(u32, block[0..4], .little) != IDNAME_LOADSEG) return null;
    const longs = std.mem.readInt(u32, block[4..8], .little);
    if (longs < @sizeOf(LoadSegBlock) / 4 or longs > block.len / 4) return null;
    if (sumLongs(block[0 .. longs * 4]) != 0) return null;
    return block[@sizeOf(LoadSegBlock) .. longs * 4];
}

/// A LoadSegBlock made in `block`: its header, `data` (at most
/// `loadSegRoom` bytes) and zeroes to the block's end, with its checksum;
/// `next` is the chain's next block. The checksum covers the whole block
/// where the data fills it, and the data's longwords where it does not.
///
/// INPUTS:
/// - `block` - the whole block, written over.
/// - `data` - the piece of the load file.
/// - `next` - the next LoadSegBlock's number, or `end_of_list`.
pub fn makeLoadSeg(block: []u8, data: []const u8, next: u32) void {
    @memset(block, 0);
    const head_longs = @sizeOf(LoadSegBlock) / 4;
    const data_longs: u32 = @intCast((data.len + 3) / 4);
    const longs: u32 = if (data.len == loadSegRoom(@intCast(block.len))) @intCast(block.len / 4) else head_longs + data_longs;
    const head: LoadSegBlock = .{ .summed_longs = longs, .next = next };
    @memcpy(block[0..@sizeOf(LoadSegBlock)], std.mem.asBytes(&head));
    @memcpy(block[@sizeOf(LoadSegBlock)..][0..data.len], data);
    const total = sumLongs(block[0 .. longs * 4]);
    std.mem.writeInt(i32, block[8..12], @bitCast(0 -% total), .little);
}

/// The longwords of `bytes`, summed.
fn sumLongs(bytes: []const u8) u32 {
    var total: u32 = 0;
    var at: usize = 0;
    while (at + 4 <= bytes.len) : (at += 4) total +%= std.mem.readInt(u32, bytes[at..][0..4], .little);
    return total;
}

/// struct BadBlockBlock's header; the pairs follow it to the end of the
/// block. Nothing writes one: the flash chip spares its own bad blocks.
pub const BadBlockBlock = extern struct {
    id: u32 = IDNAME_BADBLOCK,
    summed_longs: u32 = 0,
    checksum: i32 = 0,
    host_id: u32 = 7,
    next: u32 = end_of_list,
    reserved: u32 = 0,
};

pub const BadBlockEntry = extern struct {
    bad_block: u32 = 0,
    good_block: u32 = 0,
};

// --- checksums ---------------------------------------------------------------

/// The longwords of a block, summed: a sound block's first
/// `summed_longs` of them add up to zero.
fn sum(block: anytype) u32 {
    const bytes: [*]const u8 = @ptrCast(block);
    const longs = @min(block.summed_longs, @sizeOf(@TypeOf(block.*)) / 4);
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < longs) : (i += 1) {
        total +%= std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }
    return total;
}

/// The value a block's checksum field must hold: what makes the rest sum to
/// zero. The field is taken as it stands, so zero it first or call this on
/// a block whose checksum is already right and get the same answer.
pub fn checksumOf(block: anytype) i32 {
    var copy = block.*;
    copy.checksum = 0;
    return @bitCast(0 -% sum(&copy));
}

/// Whether a block's identifier and checksum are right.
pub fn sound(block: anytype, id: u32) bool {
    if (block.id != id) return false;
    if (block.summed_longs < 5 or block.summed_longs > @sizeOf(@TypeOf(block.*)) / 4) return false;
    return sum(block) == 0;
}

comptime {
    // The sizes the blocks on a disk have.
    if (@sizeOf(RigidDiskBlock) != 256) @compileError("the RigidDiskBlock is not 256 bytes");
    if (@sizeOf(PartitionBlock) != 256) @compileError("the PartitionBlock is not 256 bytes");
    if (@sizeOf(FileSysHeaderBlock) != 256) @compileError("the FileSysHeaderBlock is not 256 bytes");
}
