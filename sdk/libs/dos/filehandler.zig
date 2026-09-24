// SPDX-License-Identifier: MIT
//! Mounting (dos/filehandler.h): what a device node tells the handler it
//! starts about the device under it: two structures.
//!
//! A device node's `startup` (dol_Startup) points at a FileSysStartupMsg,
//! and the handler gets it as ACTION_STARTUP's dp_Arg2. Its fields are
//! exactly OpenDevice's arguments, plus the environment: the medium's
//! geometry and the file system's parameters. There is no MountList and
//! no DEVS:, so dos's init writes the one for DH0: itself.
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

    /// The blocks of the partition: (high_cyl - low_cyl + 1) cylinders.
    pub fn blocks(env: *const DosEnvec) u64 {
        const cylinders = env.high_cyl + 1 - env.low_cyl;
        return @as(u64, cylinders) * env.surfaces * env.blocks_per_track;
    }

    /// The byte a block starts at on the medium.
    pub fn byteOf(env: *const DosEnvec, block: u64) u64 {
        const first = @as(u64, env.low_cyl) * env.surfaces * env.blocks_per_track;
        return (first + block) * env.size_block;
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
