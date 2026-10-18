// SPDX-License-Identifier: MIT
//! ExAll's structures (dos/exall.h): the control that keeps
//! a listing's place, and the records ExAll packs into the caller's buffer.
//! A record has the fields of its level (ED_NAME .. ED_OWNER, each with all
//! the ones before), then its strings. Fields are pointer-sized and the size
//! 64-bit; records are aligned for their
//! pointers.
//!
//! `pack` writes one record from a FileInfoBlock. dos's ExAll packs with it
//! for a handler that has no ACTION_EXAMINE_ALL, and a handler that has
//! one packs with it too, so a listing comes out the same from either.

const dos = @import("dos.zig");
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

/// The bytes of a record's fields at a level, up to the end of its last
/// one; the strings go after them.
///
/// INPUTS:
/// - `level` - ED_NAME .. ED_OWNER.
pub fn fixedSize(level: i32) usize {
    return switch (level) {
        ED_NAME => @offsetOf(ExAllData, "name") + @sizeOf(?[*:0]u8),
        ED_TYPE => @offsetOf(ExAllData, "type") + @sizeOf(i32),
        ED_SIZE => @offsetOf(ExAllData, "size") + @sizeOf(u64),
        ED_PROTECTION => @offsetOf(ExAllData, "prot") + @sizeOf(u32),
        ED_DATE => @offsetOf(ExAllData, "ticks") + @sizeOf(i32),
        ED_COMMENT => @offsetOf(ExAllData, "comment") + @sizeOf(?[*:0]u8),
        else => @offsetOf(ExAllData, "owner_gid") + @sizeOf(u16),
    };
}

/// Packs a FileInfoBlock's entry as an ExAllData record into the buffer at
/// `pos.*`, aligned for its pointers, its name (and from ED_COMMENT on its
/// comment) after its fields, and moves `pos.*` past it. Null, and `pos.*`
/// unchanged, when it doesn't fit.
///
/// INPUTS:
/// - `buffer` - the caller's ExAll buffer.
/// - `size` - the buffer's size.
/// - `pos` - where the next record may start.
/// - `level` - which fields the record has, ED_NAME .. ED_OWNER.
/// - `fib` - the entry.
pub fn pack(buffer: [*]u8, size: usize, pos: *usize, level: i32, fib: *const dos.FileInfoBlock) ?*ExAllData {
    const base = @intFromPtr(buffer);
    const alignment: usize = @alignOf(ExAllData);
    const start = ((base + pos.* + alignment - 1) & ~(alignment - 1)) - base;
    const name = fib.file_name[0..lengthOf(&fib.file_name)];
    const comment = fib.comment[0..lengthOf(&fib.comment)];
    const fixed = fixedSize(level);
    const with_comment = level >= ED_COMMENT;
    const need = fixed + name.len + 1 + (if (with_comment) comment.len + 1 else 0);
    if (start > size or need > size - start) return null;

    const rec: *ExAllData = @ptrFromInt(base + start);
    var text: [*]u8 = buffer + start + fixed;
    rec.next = null;
    @memcpy(text[0..name.len], name);
    text[name.len] = 0;
    rec.name = @ptrCast(text);
    text += name.len + 1;
    if (level >= ED_TYPE) rec.type = fib.dir_entry_type;
    if (level >= ED_SIZE) rec.size = fib.size;
    if (level >= ED_PROTECTION) rec.prot = fib.protection;
    if (level >= ED_DATE) {
        rec.days = fib.date.days;
        rec.minute = fib.date.minute;
        rec.ticks = fib.date.tick;
    }
    if (with_comment) {
        @memcpy(text[0..comment.len], comment);
        text[comment.len] = 0;
        rec.comment = @ptrCast(text);
    }
    if (level >= ED_OWNER) {
        rec.owner_uid = fib.owner_uid;
        rec.owner_gid = fib.owner_gid;
    }
    pos.* = start + need;
    return rec;
}

/// The bytes of a NUL-terminated string in a fixed array, all of it when
/// there is no NUL.
fn lengthOf(text: []const u8) usize {
    var len: usize = 0;
    while (len < text.len and text[len] != 0) len += 1;
    return len;
}
