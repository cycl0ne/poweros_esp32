// SPDX-License-Identifier: MIT
//! A SCSI command sent to a disk unit (devices/scsidisk.h): `HD_SCSICMD`,
//! which a block device that speaks SCSI underneath answers beside the
//! block commands (sdk/devices/trackdisk.zig) - usb/disk.device does.
//!
//!   HD_SCSICMD   io_Data a `SCSICmd`, io_Length its size. The command
//!                block goes to the unit as it is; the data phase reads
//!                into `data` (SCSIF_READ) or writes from it, at most
//!                `length` bytes. `status` is the SCSI status, `actual`
//!                the bytes moved; with SCSIF_AUTOSENSE a command that
//!                ends in CHECK CONDITION has its sense read into
//!                `sense_data`. io_Error is HFERR_BadStatus for any
//!                status but GOOD.
//!
//! The command reaches the unit's own logical unit; a program that sends
//! a write or a format to a unit a handler sits on is on its own.
//!
//! The lengths are 32-bit, where the structure's first form had 16-bit
//! ones.

/// The command, in the slot after the block commands.
pub const HD_SCSICMD: u16 = 28;

/// struct SCSICmd: one command and its data.
pub const SCSICmd = extern struct {
    /// scsi_Data: the data phase's bytes.
    data: ?[*]u8 = null,
    /// scsi_Length: how many there may be.
    length: u32 = 0,
    /// scsi_Actual: how many moved.
    actual: u32 = 0,
    /// scsi_Command: the command block.
    command: ?[*]const u8 = null,
    /// scsi_CmdLength: its bytes - 6, 10, 12 or 16.
    cmd_length: u32 = 0,
    /// scsi_CmdActual: how many were sent.
    cmd_actual: u32 = 0,
    /// scsi_Flags: SCSIF_*.
    flags: u8 = 0,
    /// scsi_Status: the SCSI status the command ended with (0: GOOD,
    /// 2: CHECK CONDITION).
    status: u8 = 0,
    pad: u16 = 0,
    /// scsi_SenseData: where SCSIF_AUTOSENSE puts the sense.
    sense_data: ?[*]u8 = null,
    /// scsi_SenseLength: room there; scsi_SenseActual: how much came.
    sense_length: u32 = 0,
    sense_actual: u32 = 0,
};

/// scsi_Flags: the data phase writes (from `data`) - or, with SCSIF_READ,
/// reads (into it).
pub const SCSIF_WRITE: u8 = 0;
pub const SCSIF_READ: u8 = 1;
/// The sense read after a CHECK CONDITION.
pub const SCSIF_AUTOSENSE: u8 = 2;

/// scsi_Status.
pub const SCSI_STATUS_GOOD: u8 = 0x00;
pub const SCSI_STATUS_CHECK_CONDITION: u8 = 0x02;

/// io_Error.
pub const HFERR_SelfUnit: i8 = 40;
pub const HFERR_DMA: i8 = 41;
/// The device answered out of turn: the transport was reset.
pub const HFERR_Phase: i8 = 42;
pub const HFERR_Parity: i8 = 43;
/// The device did not answer at all.
pub const HFERR_SelTimeout: i8 = 44;
/// The command ended with a status other than GOOD.
pub const HFERR_BadStatus: i8 = 45;
pub const HFERR_NoBoard: i8 = 50;
