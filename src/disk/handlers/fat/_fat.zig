// SPDX-License-Identifier: MIT
//! What the two file systems in this handler share: the medium they work
//! over, the errors a caller is given, and the three conversions that sit
//! between what is on the medium and what dos expects.
//!
//! **The area.** `fat-handler` serves one device node and reads whichever
//! volume is on it. The two formats are separate bodies of code -
//! `fat32/` and `exfat/` - because they share a name and very little
//! else: different directory entries, a bitmap instead of a table scan
//! for free space, an up-case table on the medium instead of fixed case
//! rules, and a flag that lets a file have no chain at all. What they do
//! share is everything below them, and that is here and in `cache.zig`.
//!
//! **The medium** is duck-typed, as the other handler's is, so both file
//! systems are tested on the host against `testmedia.zig` and given
//! sd.device on the machine. It must offer
//!
//!     blockSize() u32          blocks() u64
//!     read(lba: u64, count: u32, into: []u8) bool
//!     write(lba: u64, count: u32, from: []const u8) bool
//!     writable() bool          present() bool      changeNum() u32
//!     alloc(u32) ?[]u8         free([]u8)          now() DateStamp
//!
//! There is no `erase`: a card needs none. There is no `bytes`: a card
//! cannot be read as memory.
//!
//! **Two of the three conversions invert, in opposite senses**, which is
//! the kind of thing that is wrong for months before anyone notices. See
//! `protectionOf` and `dateOf`.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const fat = dos.fat;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ClockData = sdk.utility.ClockData;

/// What a packet is answered with.
pub const Answer = struct {
    /// Pointer-wide: a lock goes back in it.
    res1: isize,
    res2: i32,
};

pub fn yes() Answer {
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

pub fn no(code: i32) Answer {
    return .{ .res1 = dos.DOSFALSE, .res2 = code };
}

pub const Error = error{
    NotFound,
    WrongType,
    InvalidName,
    InUse,
    Exists,
    NotEmpty,
    DeleteProtected,
    WriteProtected,
    NoMemory,
    DiskFull,
    SeekError,
    InvalidLock,
    NoMoreEntries,
    NotImplemented,
    /// The medium said no, or what is on it does not make sense.
    MediumFailed,
};

/// The dos error a file system error answers with.
pub fn codeOf(e: Error) i32 {
    return switch (e) {
        error.NotFound => dos.ERROR_OBJECT_NOT_FOUND,
        error.WrongType => dos.ERROR_OBJECT_WRONG_TYPE,
        error.InvalidName => dos.ERROR_INVALID_COMPONENT_NAME,
        error.InUse => dos.ERROR_OBJECT_IN_USE,
        error.Exists => dos.ERROR_OBJECT_EXISTS,
        error.NotEmpty => dos.ERROR_DIRECTORY_NOT_EMPTY,
        error.DeleteProtected => dos.ERROR_DELETE_PROTECTED,
        error.WriteProtected => dos.ERROR_DISK_WRITE_PROTECTED,
        error.NoMemory => dos.ERROR_NO_FREE_STORE,
        error.DiskFull => dos.ERROR_DISK_FULL,
        error.SeekError => dos.ERROR_SEEK_ERROR,
        error.InvalidLock => dos.ERROR_INVALID_LOCK,
        error.NoMoreEntries => dos.ERROR_NO_MORE_ENTRIES,
        error.NotImplemented => dos.ERROR_ACTION_NOT_KNOWN,
        error.MediumFailed => dos.ERROR_NOT_A_DOS_DISK,
    };
}

// --- the attribute byte ------------------------------------------------------

/// The attribute bits a directory entry carries. Both formats use the
/// same byte for the first six, which is the one thing about their
/// directory entries that is alike.
pub const ATTR_READ_ONLY: u8 = 1 << 0;
pub const ATTR_HIDDEN: u8 = 1 << 1;
pub const ATTR_SYSTEM: u8 = 1 << 2;
pub const ATTR_VOLUME_LABEL: u8 = 1 << 3;
pub const ATTR_DIRECTORY: u8 = 1 << 4;
pub const ATTR_ARCHIVE: u8 = 1 << 5;
/// An entry with all four of the first bits set is not a file at all: it
/// is one piece of a long name. Every scan must know this, because such
/// an entry would otherwise read as a volume label.
pub const ATTR_LONG_NAME: u8 = ATTR_READ_ONLY | ATTR_HIDDEN | ATTR_SYSTEM | ATTR_VOLUME_LABEL;

/// The protection bits for an attribute byte.
///
/// **Two inversions meet here, in opposite directions.**
///
/// The first: a protection bit that is *set* means the operation is
/// *denied*, so a read-only file comes back with write and delete set.
/// Read and execute are never set, because nothing in the attribute byte
/// forbids either.
///
/// The second: the archive bits mean opposite things. The attribute bit
/// means "this file is waiting to be archived"; the protection bit means
/// "this file has been archived". So the protection bit starts set and is
/// cleared when the attribute bit is present.
pub fn protectionOf(attr: u8) u32 {
    var bits: u32 = dos.FIBF_ARCHIVE;
    if (attr & ATTR_READ_ONLY != 0) bits |= dos.FIBF_WRITE | dos.FIBF_DELETE;
    if (attr & ATTR_ARCHIVE != 0) bits &= ~dos.FIBF_ARCHIVE;
    return bits;
}

/// The attribute byte for a set of protection bits, keeping everything in
/// `was` that the protection bits say nothing about - hidden, system, and
/// whether the entry is a directory. Writing a whole fresh byte here is
/// what loses a file's hidden bit the first time anything touches it.
pub fn attributeOf(bits: u32, was: u8) u8 {
    var attr = was;
    if (bits & (dos.FIBF_WRITE | dos.FIBF_DELETE) != 0) {
        attr |= ATTR_READ_ONLY;
    } else {
        attr &= ~ATTR_READ_ONLY;
    }
    if (bits & dos.FIBF_ARCHIVE != 0) {
        attr &= ~ATTR_ARCHIVE;
    } else {
        attr |= ATTR_ARCHIVE;
    }
    return attr;
}

// --- the date ----------------------------------------------------------------

/// Ticks in a second, as a DateStamp counts them.
pub const ticks_per_second: u32 = 50;
/// Seconds in a day, which is what utility.library's calendar counts in.
pub const secs_per_day: u32 = 24 * 60 * 60;

/// The day number of 1 January 1980, where a date on this medium starts
/// counting: two years of 365 days after the day a DateStamp counts
/// from. It is what a stamp that is not a date comes back as.
pub const dos_epoch_days: i32 = 365 * 2;

/// The first and last years a date on the medium can hold: the field is
/// seven bits counted from 1980.
pub const year_first: u32 = 1980;
pub const year_last: u32 = year_first + 127;

/// The date and time words a medium stores, unpacked.
pub const Stamp = struct {
    time: u16,
    date: u16,
};

/// A DateStamp for the date and time words on the medium.
///
/// Both words are handed to the calendar at once, because one entry's
/// date and time are one moment and `ClockData` holds both.
///
/// **A stamp of all zeroes is not a date.** A great many tools write one
/// when they have no clock, and it unpacks to month 0 and day 0.
/// `CheckDate` converts a date there and back and compares, so it
/// answers 0 for that one and for the 31st of February alike, and the
/// moment comes back as the start of 1980 rather than as arithmetic on
/// nonsense.
pub fn dateOf(ub: *UtilityBase, stamp: Stamp) dos.DateStamp {
    // Clamped before the calendar sees them: they come off a medium, and
    // an hour of 30 would otherwise be refused along with the date. Each
    // one is bound to a u32 of its own rather than clamped where it is
    // used, because @min answers the narrowest type that holds its
    // result and the arithmetic after it would not fit.
    const two_seconds: u32 = @min(@as(u32, stamp.time & 0x1F), 29);
    const minutes: u32 = @min(@as(u32, (stamp.time >> 5) & 0x3F), 59);
    const hours: u32 = @min(@as(u32, (stamp.time >> 11) & 0x1F), 23);
    const clock: ClockData = .{
        .sec = @intCast(two_seconds * 2),
        .min = @intCast(minutes),
        .hour = @intCast(hours),
        .mday = @intCast(stamp.date & 0x1F),
        .month = @intCast((stamp.date >> 5) & 0x0F),
        .year = @intCast(year_first + ((stamp.date >> 9) & 0x7F)),
    };
    // The count starts in 1978 and this medium's dates start in 1980, so
    // nothing real here ever comes to 0 seconds: a 0 is a refusal.
    const seconds = ub.CheckDate(&clock);
    if (seconds == 0) return .{ .days = dos_epoch_days, .minute = 0, .tick = 0 };
    return .{
        .days = @intCast(seconds / secs_per_day),
        .minute = @intCast(seconds % secs_per_day / 60),
        .tick = @intCast(seconds % 60 * ticks_per_second),
    };
}

/// The date and time words for a DateStamp. A moment the medium cannot
/// hold - before 1980, or past the 127 years its seven bits reach - is
/// clamped rather than wrapped, because a wrapped year reads as a real
/// date and a clamped one reads as a wrong one.
pub fn stampOf(ub: *UtilityBase, when: dos.DateStamp) Stamp {
    const days: u32 = @intCast(@max(when.days, 0));
    const minute: u32 = @intCast(@max(@min(when.minute, 24 * 60 - 1), 0));
    const tick: u32 = @intCast(@max(when.tick, 0));
    // Past this the seconds do not fit in the 32 bits the calendar takes,
    // and the year is far past what the medium holds anyway.
    if (days > 0xFFFF_FFFF / secs_per_day) return lastStamp();

    var clock: ClockData = .{};
    ub.Amiga2Date(days * secs_per_day + minute * 60 + tick / ticks_per_second, &clock);
    if (clock.year < year_first) return firstStamp();
    if (clock.year > year_last) return lastStamp();
    return .{
        .time = @intCast((@as(u32, clock.hour) << 11) | (@as(u32, clock.min) << 5) | (clock.sec / 2)),
        .date = @intCast(((@as(u32, clock.year) - year_first) << 9) | (@as(u32, clock.month) << 5) | clock.mday),
    };
}

/// The earliest moment the medium holds: the start of 1980.
pub fn firstStamp() Stamp {
    return .{ .time = 0, .date = (1 << 5) | 1 };
}

/// The latest: the end of the last year its seven bits reach.
pub fn lastStamp() Stamp {
    return .{
        .time = (23 << 11) | (59 << 5) | 29,
        .date = (127 << 9) | (12 << 5) | 31,
    };
}

// --- names -------------------------------------------------------------------

/// The byte that marks a directory entry as erased.
pub const entry_erased: u8 = 0xE5;
/// The byte that marks the end of a directory: nothing past it is in use.
pub const entry_end: u8 = 0x00;
/// What a name whose first character really is `entry_erased` is stored
/// as, so that it is not read as an erased entry.
pub const entry_escaped: u8 = 0x05;

/// The first byte of a stored name, as it should be read: the escape put
/// back.
pub fn firstStored(byte: u8) u8 {
    return if (byte == entry_escaped) entry_erased else byte;
}

/// The first byte of a name, as it should be stored: a name that really
/// begins with the erase marker is escaped, or the entry would read as a
/// deleted one and the file would vanish.
pub fn firstToStore(byte: u8) u8 {
    return if (byte == entry_erased) entry_escaped else byte;
}

/// A character upper-cased, for the case rules of a name. Only the
/// letters this system can express in one byte.
pub fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - ('a' - 'A') else char;
}
