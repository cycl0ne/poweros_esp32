// SPDX-License-Identifier: MIT
//! ExAll's structures (dos/exall.h): the control that keeps
//! a listing's place, and the records ExAll packs into the caller's buffer.
//! A record has the fields of its level (ED_NAME .. ED_OWNER, each with all
//! the ones before), then its strings. Fields are pointer-sized and the size
//! 64-bit; records are aligned for their
//! pointers.

const Hook = @import("../utility/utility.zig").Hook;

// ExAll's levels: what goes into each record.
pub const ED_NAME: i32 = 1;
pub const ED_TYPE: i32 = 2;
pub const ED_SIZE: i32 = 3;
pub const ED_PROTECTION: i32 = 4;
pub const ED_DATE: i32 = 5;
pub const ED_COMMENT: i32 = 6;
pub const ED_OWNER: i32 = 7;

/// struct ExAllData: one entry. The last of a buffer has `next` null.
pub const ExAllData = extern struct {
    /// ed_Next
    next: ?*ExAllData = null,
    /// ed_Name (ED_NAME)
    name: ?[*:0]u8 = null,
    /// ed_Type: ST_* (ED_TYPE)
    type: i32 = 0,
    /// ed_Size (ED_SIZE)
    size: u64 align(4) = 0,
    /// ed_Prot: FIBF_* (ED_PROTECTION)
    prot: u32 = 0,
    /// ed_Days, ed_Mins, ed_Ticks (ED_DATE)
    days: i32 = 0,
    minute: i32 = 0,
    ticks: i32 = 0,
    /// ed_Comment (ED_COMMENT)
    comment: ?[*:0]u8 = null,
    /// ed_OwnerUID, ed_OwnerGID (ED_OWNER)
    owner_uid: u16 = 0,
    owner_gid: u16 = 0,
};

/// struct ExAllControl: from AllocDosObject(DOS_EXALLCONTROL), so that
/// `last_key` starts at 0.
pub const ExAllControl = extern struct {
    /// eac_Entries: how many records this call put in the buffer (may be 0
    /// while more come).
    entries: u32 = 0,
    /// eac_LastKey: the handler's (or dos's emulation's) place; 0 to
    /// start, and not to be touched while ExAll answers true.
    last_key: usize = 0,
    /// eac_MatchString: a pattern from utility's ParsePatternNoCase; only
    /// the entries it matches come.
    match_string: ?[*:0]const u8 = null,
    /// eac_MatchFunc: called with (hook, the level, the filled-in record);
    /// 0 leaves the entry out.
    match_func: ?*Hook = null,
};
