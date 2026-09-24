// SPDX-License-Identifier: MIT
//! Block devices (devices/trackdisk.h): the commands and structures a disk
//! device answers and a file system sends. The names and slots are
//! trackdisk.device's; what is past them is marked as an addition.
//!
//!   CMD_READ         reads io_Length bytes from io_Offset into io_Data.
//!   CMD_WRITE        writes io_Length bytes from io_Data at io_Offset.
//!                    The range must be erased first on a medium that needs
//!                    it (TD_GETGEOMETRY's erase_size says so).
//!   CMD_UPDATE       writes what is still buffered out to the medium.
//!   CMD_CLEAR        drops what is buffered without writing it.
//!   TD_FORMAT        writes (or erases) whole tracks, io_Length at a time.
//!   TD_PROTSTATUS    io_Actual: not 0 if the medium is write-protected.
//!   TD_CHANGENUM     io_Actual: how often the medium has been changed.
//!   TD_CHANGESTATE   io_Actual: 0 if a medium is in.
//!   TD_GETGEOMETRY   fills a DriveGeometry.
//!   TD_GETNUMTRACKS  io_Actual: the tracks (cylinders) of the unit.
//!   TDCMD_ERASE      ours: erases the blocks io_Offset..io_Offset+io_Length.
//!
//! What the medium being flash, not a floppy, changes:
//! - io_Offset and io_Length are 64-bit (exec's IOStdReq), so a unit may be
//!   larger than 4 GiB and no LBA games are needed.
//! - TDCMD_ERASE and DriveGeometry's `erase_size` and `map_base` are added:
//!   flash must be erased before it is written, and the medium can be read
//!   through the CPU's address space without a request at all.
//! - No motor, seek, index or raw-track commands (TD_MOTOR, TD_SEEK,
//!   TD_RAWREAD, TD_RAWWRITE, TD_GETDRIVETYPE), no removal interrupts
//!   (TD_ADDCHANGEINT, TD_REMCHANGEINT) and no ETD_* (the extended requests
//!   that check a change number). A unit whose medium can be taken out
//!   says so in DGF_REMOVABLE and answers TD_CHANGESTATE and TD_CHANGENUM
//!   for real; a file system that wants to know asks before each packet,
//!   rather than being told by an interrupt.
//! - No TDERR_* past the ones a solid-state medium can give, and one more
//!   of ours for the medium that is not there at all.

const exec = @import("../libs/exec/exec.zig");

/// The block devices that speak this API: the board's flash (unit 0 is
/// the flash disk) and the card slot.
pub const FLASHNAME = "flash.device";
pub const SDNAME = "sd.device";

/// The bytes of a TD_SECTOR-sized block. Our units report their own block
/// size in the DriveGeometry; this is only the traditional default.
pub const TD_SECTOR: u32 = 512;

/// The commands after exec's standard ones, in trackdisk.device's slots.
pub const TD_NAME: u16 = exec.CMD_NONSTD;
pub const TD_MOTOR: u16 = exec.CMD_NONSTD + 1;
pub const TD_SEEK: u16 = exec.CMD_NONSTD + 2;
pub const TD_FORMAT: u16 = exec.CMD_NONSTD + 3;
pub const TD_REMOVE: u16 = exec.CMD_NONSTD + 4;
pub const TD_CHANGENUM: u16 = exec.CMD_NONSTD + 5;
pub const TD_CHANGESTATE: u16 = exec.CMD_NONSTD + 6;
pub const TD_PROTSTATUS: u16 = exec.CMD_NONSTD + 7;
pub const TD_RAWREAD: u16 = exec.CMD_NONSTD + 8;
pub const TD_RAWWRITE: u16 = exec.CMD_NONSTD + 9;
pub const TD_GETDRIVETYPE: u16 = exec.CMD_NONSTD + 10;
pub const TD_GETNUMTRACKS: u16 = exec.CMD_NONSTD + 11;
pub const TD_ADDCHANGEINT: u16 = exec.CMD_NONSTD + 12;
pub const TD_REMCHANGEINT: u16 = exec.CMD_NONSTD + 13;
pub const TD_GETGEOMETRY: u16 = exec.CMD_NONSTD + 14;
pub const TD_EJECT: u16 = exec.CMD_NONSTD + 15;
/// An addition: erase the blocks a write is going to use. A medium that
/// needs no erasing answers it as a no-op.
pub const TDCMD_ERASE: u16 = exec.CMD_NONSTD + 16;

/// io_Error, in trackdisk.device's slots (32 on): only the ones a solid-state medium
/// can give.
pub const TDERR_NotSpecified: i8 = 20;
pub const TDERR_NoSecHdr: i8 = 21;
pub const TDERR_BadSecPreamble: i8 = 22;
pub const TDERR_BadSecID: i8 = 23;
pub const TDERR_BadHdrSum: i8 = 24;
pub const TDERR_BadSecSum: i8 = 25;
pub const TDERR_TooFewSecs: i8 = 26;
pub const TDERR_BadSecHdr: i8 = 27;
pub const TDERR_WriteProt: i8 = 28;
pub const TDERR_DiskChanged: i8 = 29;
pub const TDERR_SeekError: i8 = 30;
pub const TDERR_NoMem: i8 = 31;
pub const TDERR_BadUnitNum: i8 = 32;
pub const TDERR_BadDriveType: i8 = 33;
pub const TDERR_DriveInUse: i8 = 34;
pub const TDERR_PostReset: i8 = 35;
/// An addition: no medium in the unit at all. A removable unit answers it
/// to every command that would touch the medium, which is how a handler
/// tells an empty slot from a fault.
pub const TDERR_NoCard: i8 = 36;

/// struct DriveGeometry: what TD_GETGEOMETRY tells about a unit. The
/// fields that count bytes are 64-bit, and the last three are additions.
pub const DriveGeometry = extern struct {
    /// dg_SectorSize: the bytes of one block, the unit of io_Offset and
    /// io_Length.
    sector_size: u32 = 0,
    /// dg_TotalSectors
    total_sectors: u64 align(4) = 0,
    /// dg_Cylinders
    cylinders: u32 = 0,
    /// dg_CylSectors: the blocks of one cylinder.
    cyl_sectors: u32 = 0,
    /// dg_Heads
    heads: u32 = 0,
    /// dg_TrackSectors
    track_sectors: u32 = 0,
    /// dg_BufMemType: the memory a buffer for this unit should be in.
    buf_mem_type: u32 = 0,
    /// dg_DeviceType: DG_DIRECT_ACCESS and the like.
    device_type: u8 = 0,
    /// dg_Flags: DGF_REMOVABLE.
    flags: u8 = 0,
    reserved: u16 = 0,
    /// An addition: the bytes one erase takes, and the alignment TDCMD_ERASE
    /// wants. 0 if the medium needs no erasing.
    erase_size: u32 = 0,
    /// An addition: the bytes one write programs at a time (flash's page).
    /// 0 if the medium has no such unit.
    write_size: u32 = 0,
    /// An addition: the unit's first byte in the CPU's address space, if it
    /// can be read there directly, else 0. A file system may read through
    /// it instead of sending CMD_READ; writing there does nothing.
    map_base: usize = 0,
};

/// dg_DeviceType: SCSI's device type numbers.
pub const DG_DIRECT_ACCESS: u8 = 0;
pub const DG_SEQUENTIAL_ACCESS: u8 = 1;
pub const DG_CDROM: u8 = 5;
pub const DG_OPTICAL_DISK: u8 = 7;

/// dg_Flags.
pub const DGF_REMOVABLE: u8 = 1;
