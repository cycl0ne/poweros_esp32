// SPDX-License-Identifier: MIT
//! The flash file system's on-media format, shared by the handler
//! (src/rom/handler/flashfs) and the host tool that builds a disk image
//! (tools/mkfs), so the two cannot drift apart.
//!
//! The packets, the locks and the FileInfoBlock are dos's - a program
//! cannot tell this from RAM: - and the layout on the medium is made for
//! flash.
//!
//! **Why a log.** Flash clears bits by writing and sets them only by
//! erasing a whole 4 KiB sector, which takes tens of milliseconds with the
//! caches off (docs/flash.md). A file system that writes blocks in place
//! turns every SetProtection into read-modify-erase-write of a sector. This
//! one only ever appends: a change is a record after the last one, and the
//! newest record about a thing wins. Erasing happens when the collector
//! reclaims a sector whose records are all superseded, which also spreads
//! the wear, and a power cut leaves a half-written record that fails its
//! checksum and ends the log - the state before it is intact, so there is
//! no validator to write.
//!
//!     sector 0        the superblock: magic, the volume's name and date
//!     sector 1..n-1   segments, one erase unit each
//!                       header: magic, seq, erases, checksum
//!                       records: meta / data / trunc / kill, each checked
//!
//! `seq` gives the order the segments were filled in, so replaying them in
//! that order replays the log. Reading all of it at mount costs nothing:
//! flash.device maps the medium into the data window.
//!
//! Every number is little-endian, the chip's and the host tool's order.

const DateStamp = @import("dos.zig").DateStamp;

/// ID_FLASHFS_DISK: what Info answers in id_DiskType, and what a
/// partition's de_DosType holds so the RDB says which file system is on it.
/// In the shape of ID_DOS_DISK ("DOS\0"), with letters of its own so it is
/// never taken for another file system: "FLS\0".
pub const ID_FLASHFS_DISK: u32 = 0x464C_5300;

/// The superblock's magic, "FLS0".
pub const super_magic: u32 = 0x464C_5330;
/// A segment header's magic, "FSEG". Not "LSEG": that is the identifier of
/// the RDB's own LoadSegBlock (sdk/libs/dos/hardblocks.zig), and two things on
/// one disk should not answer to the same four letters.
pub const segment_magic: u32 = 0x4653_4547;
/// The format this code writes and reads.
pub const format_version: u32 = 1;

/// The longest name and comment, as RAM: has them.
pub const max_name = 30;
pub const max_comment = 79;

/// The root directory's inode. Inodes are handed out from there up and are
/// never reused, so a stale lock or FileInfoBlock cannot point at a new
/// object.
pub const root_inode: u32 = 1;

/// Sector 0: what the volume is. Written by format (and by a relabel) and
/// then left alone - it is the one thing that is not a log.
pub const Super = extern struct {
    magic: u32 = super_magic,
    version: u32 = format_version,
    /// The erase unit, and so the size of a segment.
    sector_size: u32 = 0,
    /// How many sectors the volume has, this one included.
    sectors: u32 = 0,
    /// When it was formatted.
    created: DateStamp = .{},
    /// The volume's name, NUL-padded (what doslist shows and locks point
    /// at).
    name: [max_name + 2]u8 = [_]u8{0} ** (max_name + 2),
    /// crc32 of every byte before it.
    checksum: u32 = 0,

    pub fn nameLen(s: *const Super) usize {
        for (s.name, 0..) |c, i| {
            if (c == 0) return i;
        }
        return s.name.len;
    }
};

/// A segment's first bytes. `seq` counts up over the volume's whole life:
/// the segment with the highest one is the log's head. It comes first so
/// that nothing lies between the fields: a checksum must never cover
/// padding, whose contents a compiler does not promise (it cost an
/// afternoon).
pub const SegmentHeader = extern struct {
    /// Which turn this segment had. 0 is never used, so a sector of zeros
    /// is not a segment.
    seq: u64 = 0,
    magic: u32 = segment_magic,
    /// How often this sector has been erased, for the wear the collector
    /// spreads.
    erases: u32 = 0,
    /// crc32 of the bytes before it.
    checksum: u32 = 0,
};

/// A structure's bytes up to its checksum field, which is what the checksum
/// is of. Everything checksummed here is laid out so that the fields lie
/// end to end, with no padding between them: what a compiler leaves in
/// padding is not defined, and it does not survive a copy.
pub fn checked(value: anytype) []const u8 {
    const T = @TypeOf(value.*);
    const p: [*]const u8 = @ptrCast(value);
    return p[0..@offsetOf(T, "checksum")];
}

/// The checksum a structure should carry.
pub fn checksumOf(value: anytype) u32 {
    return crc32(checked(value));
}

comptime {
    // The layout is the format: it must be the same in the kernel and in
    // the host tool that builds a disk image, and no field may sit behind
    // padding that the checksum would then cover.
    const std = @import("std");
    if (@sizeOf(Super) != 64 or @offsetOf(Super, "checksum") != 60) {
        @compileError("the superblock's layout moved: " ++ std.fmt.comptimePrint("{d}/{d}", .{ @sizeOf(Super), @offsetOf(Super, "checksum") }));
    }
    if (@sizeOf(SegmentHeader) != 24 or @offsetOf(SegmentHeader, "checksum") != 16) {
        @compileError("the segment header's layout moved");
    }
    if (@sizeOf(RecordHeader) != 12 or @sizeOf(Meta) != 36 or @sizeOf(Data) != 16 or @sizeOf(Trunc) != 16 or @sizeOf(Kill) != 4) {
        @compileError("a record's layout moved");
    }
}

/// What a record says.
pub const Kind = enum(u16) {
    /// An object is there and this is everything about it but its data:
    /// its name, where it hangs, its protection, date, comment. A later one
    /// supersedes an earlier one.
    meta = 1,
    /// These bytes are at this offset of this file. A later one wins over
    /// an earlier one for the bytes they share.
    data = 2,
    /// The file is this long now: what is past it is gone, and what is
    /// before it and never written reads as zero.
    trunc = 3,
    /// The object is gone.
    kill = 4,
    /// Nothing more in this segment: the rest is padding.
    end = 5,
    _,
};

/// Every record starts with this. The payload follows, padded out to four
/// bytes; the padding is not counted in `length` and not checksummed.
pub const RecordHeader = extern struct {
    kind: Kind = .end,
    flags: u16 = 0,
    /// The payload's bytes, without the padding.
    length: u32 = 0,
    /// crc32 over this header with `checksum` zero, then the payload.
    checksum: u32 = 0,
};

/// Kind.meta's payload: the fixed part, then the name and the comment.
pub const Meta = extern struct {
    inode: u32 = 0,
    /// The directory it is in; the root's parent is itself.
    parent: u32 = 0,
    /// ST_ROOT, ST_USERDIR or ST_FILE, as a FileInfoBlock has it.
    kind: i32 = 0,
    /// fib_Protection
    protection: u32 = 0,
    /// fib_Date
    date: DateStamp = .{},
    /// fib_OwnerUID and fib_OwnerGID.
    owner_uid: u16 = 0,
    owner_gid: u16 = 0,
    name_len: u8 = 0,
    comment_len: u8 = 0,
    pad: u16 = 0,
};

/// Kind.data's payload: the fixed part, then the bytes.
pub const Data = extern struct {
    inode: u32 = 0,
    pad: u32 = 0,
    /// Where in the file the bytes go.
    offset: u64 align(4) = 0,
};

/// Kind.trunc's payload.
pub const Trunc = extern struct {
    inode: u32 = 0,
    pad: u32 = 0,
    size: u64 align(4) = 0,
};

/// Kind.kill's payload.
pub const Kill = extern struct {
    inode: u32 = 0,
};

/// Records are laid out on four-byte boundaries.
pub fn padded(length: usize) usize {
    return (length + 3) & ~@as(usize, 3);
}

/// The bytes a record takes in a segment, header included.
pub fn recordSize(payload: usize) usize {
    return @sizeOf(RecordHeader) + padded(payload);
}

// --- crc32 ------------------------------------------------------------------

/// crc32 as zip and PNG use it (the reflected 0xEDB88320 polynomial), a
/// nibble at a time: a 16-entry table costs 64 bytes of ROM instead of a
/// kilobyte, and a record is short.
const crc_table = blk: {
    var table: [16]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var c: u32 = i;
        for (0..4) |_| c = if (c & 1 != 0) 0xEDB8_8320 ^ (c >> 1) else c >> 1;
        entry.* = c;
    }
    break :blk table;
};

pub fn crcStart() u32 {
    return 0xFFFF_FFFF;
}

/// More bytes into a running crc. `crcEnd` finishes it.
pub fn crcAdd(crc_in: u32, bytes: []const u8) u32 {
    var crc = crc_in;
    for (bytes) |b| {
        crc = crc_table[(crc ^ b) & 0xF] ^ (crc >> 4);
        crc = crc_table[(crc ^ (b >> 4)) & 0xF] ^ (crc >> 4);
    }
    return crc;
}

pub fn crcEnd(crc: u32) u32 {
    return ~crc;
}

/// The crc32 of one block of bytes.
pub fn crc32(bytes: []const u8) u32 {
    return crcEnd(crcAdd(crcStart(), bytes));
}

/// A structure's bytes, for checksumming and for writing it out.
pub fn bytesOf(value: anytype) []const u8 {
    const T = @TypeOf(value.*);
    const p: [*]const u8 = @ptrCast(value);
    return p[0..@sizeOf(T)];
}
