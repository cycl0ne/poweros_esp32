// SPDX-License-Identifier: MIT
//! Mounting (dos/filehandler.h): what a device node tells the handler it
//! starts about the device under it: two structures.
//!
//! A device node's `startup` (dol_Startup) points at a FileSysStartupMsg,
//! and the handler gets it as ACTION_STARTUP's dp_Arg2. Its fields are
//! exactly OpenDevice's arguments, plus the environment: the medium's
//! geometry and the file system's parameters. A disk's partition gets its
//! pair from expansion.library's MakeDosNode, a mountlist entry from
//! C:Mount.
//!
//! The shape:
//! - Names are C strings, not BSTRs, and the pointers are pointers, not
//!   BPTRs.
//! - `size_block` is in bytes.
//! - `low_cyl`/`high_cyl` and the block counts are 32-bit, but a device
//!   addresses bytes with a 64-bit io_Offset, so nothing here limits a
//!   medium to 4 GiB.
//! - No de_BootBlocks (there is no boot block) and no de_SecOrg, which is
//!   always 0. de_Baud and de_Control are here, in their DE_* slots, and
//!   mean what they say: a handler on a serial port is
//!   given the line's speed and shape (see `control` below).
//!
//! **The area.** A file system works on the blocks the environment gives
//! it, from `low_cyl` to `high_cyl`, and on nothing else: that is what
//! keeps a partition table and the partitions beside it out of its
//! reach. An environment with both at 0 (a mountlist entry that names no
//! cylinders) gives the whole medium, as large as the device says it is
//! (`wholeMedium`) - which, for a medium that changes, is asked again for
//! each one. The handler is told what is in its area by `dos_type` too,
//! and reads it from there rather than looking for itself.

/// struct FileSysStartupMsg: the device the handler works on.
pub const FileSysStartupMsg = extern struct {
    /// fssm_Unit: OpenDevice's unit number.
    unit: u32 = 0,
    /// fssm_Device: the exec device's name, for OpenDevice.
    device: ?[*:0]const u8 = null,
    /// fssm_Environ: the geometry and parameters below.
    environ: ?*const DosEnvec = null,
    /// fssm_Flags: OpenDevice's flags.
    flags: u32 = 0,
};

/// Below this a device node's dol_Startup is a plain number (RAW:'s 1, a
/// window's 0), not a FileSysStartupMsg: no structure lives in the first
/// page.
pub const startup_numbers: usize = 0x1000;

/// A device node's dol_Startup as a FileSysStartupMsg, or null where it is
/// none: zero, a plain number, or a value no structure could sit at.
///
/// INPUTS:
/// - `startup` - the node's `misc.handler.startup`.
pub fn startupOf(startup: usize) ?*const FileSysStartupMsg {
    if (startup < startup_numbers) return null;
    if (startup % @alignOf(FileSysStartupMsg) != 0) return null;
    return @ptrFromInt(startup);
}

/// Whether a startup message opens this unit of this device: the same
/// unit, and the same device by what it is called - the part of each name
/// after its last `/` or `:`, which is the name exec has it under; the
/// path before it only says where its file is loaded from, so
/// `DEVS:usb/disk.device` is `disk.device`.
///
/// INPUTS:
/// - `startup` - a device node's FileSysStartupMsg.
/// - `device` - the device's name, as OpenDevice is given it.
/// - `unit` - its unit.
pub fn opensUnit(startup: *const FileSysStartupMsg, device: [*:0]const u8, unit: u32) bool {
    if (startup.unit != unit) return false;
    const named = startup.device orelse return false;
    const one = deviceName(named);
    const other = deviceName(device);
    var index: usize = 0;
    while (one[index] == other[index]) : (index += 1) {
        if (one[index] == 0) return true;
    }
    return false;
}

/// What a device is called: its name past the last `/` or `:` in it.
fn deviceName(name: [*:0]const u8) [*:0]const u8 {
    var start: usize = 0;
    var index: usize = 0;
    while (name[index] != 0) : (index += 1) {
        if (name[index] == '/' or name[index] == ':') start = index + 1;
    }
    return name[start..];
}

/// Whether two areas of one medium share a block. One that is the whole
/// medium (`wholeMedium`), or a missing environment, which leaves the
/// area unknown, shares one with every area.
///
/// INPUTS:
/// - `one` - an area's environment, or null.
/// - `other` - the other's, or null.
pub fn sharesBlocks(one: ?*const DosEnvec, other: ?*const DosEnvec) bool {
    const first = one orelse return true;
    const second = other orelse return true;
    if (first.wholeMedium() or second.wholeMedium()) return true;
    const first_bytes = bytesOf(first);
    const second_bytes = bytesOf(second);
    return first_bytes.start < second_bytes.end and second_bytes.start < first_bytes.end;
}

/// The bytes an area covers on its medium, from `start` up to `end`;
/// saturated rather than overflowing, for an environment read off a
/// medium that says what it likes.
fn bytesOf(env: *const DosEnvec) struct { start: u64, end: u64 } {
    const cylinder = @as(u64, env.surfaces) *| env.blocks_per_track *| env.size_block;
    if (env.high_cyl < env.low_cyl) return .{ .start = 0, .end = 0 };
    return .{ .start = @as(u64, env.low_cyl) *| cylinder, .end = (@as(u64, env.high_cyl) + 1) *| cylinder };
}

/// struct DosEnvec: a medium's geometry and a file system's parameters, as
/// a MountList entry gives them. `table_size` says how many of the fields
/// after it are filled in (DE_* below), so a handler can tell what it got.
pub const DosEnvec = extern struct {
    /// de_TableSize: the last field's index, DE_* below.
    table_size: u32 = DE_DOSTYPE,
    /// de_SizeBlock: the bytes of one block.
    size_block: u32 = 512,
    /// de_Surfaces: heads of the drive.
    surfaces: u32 = 1,
    /// de_SectorPerBlock: sectors to one block; 1 for everything we have.
    sector_per_block: u32 = 1,
    /// de_BlocksPerTrack
    blocks_per_track: u32 = 1,
    /// de_Reserved: blocks at the start the file system doesn't use (the
    /// boot block on a floppy).
    reserved: u32 = 0,
    /// de_PreAlloc: blocks at the end it doesn't use.
    pre_alloc: u32 = 0,
    /// de_Interleave
    interleave: u32 = 0,
    /// de_LowCyl: the partition's first cylinder.
    low_cyl: u32 = 0,
    /// de_HighCyl: its last one.
    high_cyl: u32 = 0,
    /// de_NumBuffers: how many blocks the file system may cache.
    num_buffers: u32 = 0,
    /// de_BufMemType: the memory those buffers want (MEMF_*).
    buf_mem_type: u32 = 0,
    /// de_MaxTransfer: the most bytes one request may move.
    max_transfer: u32 = 0x7FFF_FFFF,
    /// de_Mask: the addresses DMA can reach.
    mask: u32 = 0xFFFF_FFFF,
    /// de_BootPri: where this device stands when a boot device is chosen.
    boot_pri: i32 = 0,
    /// de_DosType: which file system, as ID_DOS_DISK and the like.
    dos_type: u32 = 0,
    /// de_Baud: the line speed, for a handler on a serial port. 0: leave
    /// the port as it is.
    baud: u32 = 0,
    /// de_Control: the rest of the line's shape, as four bytes - the data
    /// bits, the parity, the stop bits and the handshake, which is what
    /// `"8N1/NONE"` says. Parity is 'N', 'E' or 'O'; the handshake is 'N'
    /// (none), 'R' (RTS/CTS) or 'X' (xON/xOFF). 0 in any of the four means
    /// "leave that as the port has it", and 0 altogether means the line
    /// was never spoken of.
    ///
    /// Not a string: a partition block on a medium cannot carry one - a
    /// pointer read off a disk is nothing. Four bytes
    /// say everything the string does, and C:Mount's
    /// `Control = "8N1/NONE"` writes them.
    control: u32 = 0,

    /// The blocks of the partition: (high_cyl - low_cyl + 1) cylinders,
    /// none when `high_cyl` is below `low_cyl`.
    pub fn blocks(env: *const DosEnvec) u64 {
        if (env.high_cyl < env.low_cyl) return 0;
        const cylinders = @as(u64, env.high_cyl - env.low_cyl) + 1;
        return cylinders *| env.surfaces *| env.blocks_per_track;
    }

    /// The byte a block starts at on the medium.
    pub fn byteOf(env: *const DosEnvec, block: u64) u64 {
        const first = @as(u64, env.low_cyl) * env.surfaces * env.blocks_per_track;
        return (first + block) * env.size_block;
    }

    /// Whether the area is the whole medium rather than cylinders of it:
    /// no cylinder given, `low_cyl` and `high_cyl` both 0. `blocks` and
    /// `byteOf` then mean nothing, and the device's geometry says how
    /// large the area is.
    pub fn wholeMedium(env: *const DosEnvec) bool {
        return env.low_cyl == 0 and env.high_cyl == 0;
    }
};

/// de_TableSize's values: the index of the last field that is filled in.
pub const DE_TABLESIZE: u32 = 0;
pub const DE_SIZEBLOCK: u32 = 1;
pub const DE_SURFACES: u32 = 2;
pub const DE_SECTORPERBLOCK: u32 = 3;
pub const DE_BLOCKSPERTRACK: u32 = 4;
pub const DE_RESERVEDBLKS: u32 = 5;
pub const DE_PREFAC: u32 = 6;
pub const DE_INTERLEAVE: u32 = 7;
pub const DE_LOWCYL: u32 = 8;
pub const DE_UPPERCYL: u32 = 9;
pub const DE_NUMBUFFERS: u32 = 10;
pub const DE_MEMBUFTYPE: u32 = 11;
pub const DE_MAXTRANSFER: u32 = 12;
pub const DE_MASK: u32 = 13;
pub const DE_BOOTPRI: u32 = 14;
pub const DE_DOSTYPE: u32 = 15;
pub const DE_BAUD: u32 = 16;
pub const DE_CONTROL: u32 = 17;

/// de_Control's four bytes.
pub inline fn controlWord(data_bits: u8, parity: u8, stop_bits: u8, handshake: u8) u32 {
    return @as(u32, data_bits) |
        (@as(u32, parity) << 8) |
        (@as(u32, stop_bits) << 16) |
        (@as(u32, handshake) << 24);
}
pub inline fn controlDataBits(control: u32) u8 {
    return @truncate(control);
}
pub inline fn controlParity(control: u32) u8 {
    return @truncate(control >> 8);
}
pub inline fn controlStopBits(control: u32) u8 {
    return @truncate(control >> 16);
}
/// 'N' none, 'R' RTS/CTS, 'X' xON/xOFF.
pub inline fn controlHandshake(control: u32) u8 {
    return @truncate(control >> 24);
}
