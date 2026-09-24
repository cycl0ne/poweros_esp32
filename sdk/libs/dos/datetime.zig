// SPDX-License-Identifier: MIT
//! Dates as strings (dos/datetime.h): the DateTime block DateToStr and
//! StrToDate work on, its formats and its flags.
//!
//! The year has four digits. A two-digit year names a date only within one
//! century, and a range such as 78-99 and 00-45 ends in a cliff; a date
//! here is written and read with its century, as the system's `$VER:`
//! strings already are. A two-digit year is still read, 78-99 as 1978-1999
//! and the rest as the 2000s, so a script that types "16-Sep-26" still
//! means 2026. That makes the longest date string "16-Sep-2026", 11
//! characters, and LEN_DATSTRING (16) still holds it.

const DateStamp = @import("dos.zig").DateStamp;

/// The bytes each of a DateTime's three strings needs, the NUL included.
pub const LEN_DATSTRING: usize = 16;

// dat_Flags
/// DTB_SUBST: DateToStr writes "Today", "Monday", ... where it can.
pub const DTB_SUBST: u8 = 0;
pub const DTF_SUBST: u8 = 1 << DTB_SUBST;
/// DTB_FUTURE: StrToDate reads a weekday name as the coming one, not the
/// one just gone. DateToStr ignores it.
pub const DTB_FUTURE: u8 = 1;
pub const DTF_FUTURE: u8 = 1 << DTB_FUTURE;

// dat_Format
/// dd-mmm-yyyy.
pub const FORMAT_DOS: u8 = 0;
/// yyyy-mm-dd.
pub const FORMAT_INT: u8 = 1;
/// mm-dd-yyyy.
pub const FORMAT_USA: u8 = 2;
/// dd-mm-yyyy.
pub const FORMAT_CDN: u8 = 3;
pub const FORMAT_MAX: u8 = FORMAT_CDN;

/// struct DateTime: a DateStamp and the three strings it is written to or
/// read from. A null string is one the caller doesn't want (DateToStr) or
/// doesn't give (StrToDate); each buffer holds LEN_DATSTRING bytes.
pub const DateTime = extern struct {
    /// dat_Stamp: the date itself.
    stamp: DateStamp = .{},
    /// dat_Format: FORMAT_*; anything else is read as FORMAT_DOS.
    format: u8 = FORMAT_DOS,
    /// dat_Flags: DTF_*.
    flags: u8 = 0,
    /// dat_StrDay: the day of the week ("Monday").
    str_day: ?[*:0]u8 = null,
    /// dat_StrDate: the date, as `format` has it.
    str_date: ?[*:0]u8 = null,
    /// dat_StrTime: the time, "hh:mm:ss".
    str_time: ?[*:0]u8 = null,
};
