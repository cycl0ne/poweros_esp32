// SPDX-License-Identifier: MIT
//! posfs-handler's own packets: what C:PosFS (and, later, a window on the
//! same packets) asks a posfs volume.
//!
//! **Their numbers are the DosType's plus one, two, ...** (`ID_POSFS_DISK +
//! n`), which needs no registry: no other handler answers them, so one
//! sent to another drive comes back with ERROR_ACTION_NOT_KNOWN. A program
//! asks DISK_INFO first anyway and sends them only to a drive whose
//! id_DiskType is ID_POSFS_DISK.
//!
//! Each takes a pointer to its structure in dp_Arg1 and answers DOSTRUE,
//! or DOSFALSE with the error in dp_Res2. A structure starts with its own
//! size, which the program sets (`.size = @sizeOf(...)` is the default),
//! so a later handler can grow one and still answer a program built
//! against the shorter.

const posfs = @import("posfs.zig");

fn action(n: u32) i32 {
    return @intCast(posfs.ID_POSFS_DISK + n);
}

/// The volume's numbers and switches (Info).
pub const ACTION_POSFS_INFO = action(1);
/// The switches changed (Settings): durable when answered. Recycled on
/// makes its directory - ERROR_OBJECT_EXISTS while the root has another
/// object of that name - and off empties it and takes it away,
/// ERROR_OBJECT_IN_USE while something in it, or it itself, is in use.
pub const ACTION_POSFS_SETTINGS = action(2);
/// A snapshot of what is committed, under the name given (SnapshotArgs),
/// read under `.snapshots/<name>/`: durable when answered.
/// ERROR_OBJECT_EXISTS for a name a snapshot has,
/// ERROR_INVALID_COMPONENT_NAME for one a snapshot cannot have (empty,
/// longer than `posfs.max_snapshot_name` bytes of UTF-8, `/`, `:` or a
/// control character), ERROR_DISK_FULL past `posfs.max_snapshots`.
pub const ACTION_POSFS_MAKE_SNAPSHOT = action(3);
/// A snapshot deleted, by name (SnapshotArgs), and what only it held
/// freed: ERROR_OBJECT_NOT_FOUND for none of that name,
/// ERROR_OBJECT_IN_USE while a lock is on something in it.
pub const ACTION_POSFS_DELETE_SNAPSHOT = action(4);
/// The volume put back to the snapshot named (SnapshotArgs), which must
/// be the newest - ERROR_OBJECT_EXISTS while a newer one is there; the
/// snapshot stays. Only with the drive inhibited and nothing on it
/// locked or open, else ERROR_OBJECT_IN_USE.
pub const ACTION_POSFS_ROLLBACK = action(5);
/// Something in Recycled given back (UndeleteArgs). ERROR_DIR_NOT_FOUND
/// when it is to go where it came from and that directory has gone.
/// Without Recycled, every Recycled action is ERROR_OBJECT_NOT_FOUND.
pub const ACTION_POSFS_UNDELETE = action(6);
/// Recycled emptied (no structure: dp_Arg1 is 0), the oldest first. What
/// is open or locked stays, and the answer is then ERROR_OBJECT_IN_USE.
pub const ACTION_POSFS_EMPTY_RECYCLED = action(7);
/// Where something in Recycled came from, and when (OriginArgs).
pub const ACTION_POSFS_ORIGIN = action(8);
/// One slice of a check (CheckArgs): about 50 ms of work, then the
/// answer, with a cursor to go on from.
///
/// A check reads the newest checkpoint - one is written first when changes
/// wait - and keeps what it names from being handed out until it ends, so
/// the volume may change between slices. It ends when it is done, when
/// a slice asks for CHECK_STOP, when no slice has come for about ten
/// seconds, when another check starts, or when a write needs its blocks
/// (that slice answers ERROR_DISK_FULL). A cursor the handler no longer
/// knows is ERROR_INVALID_ARGUMENT.
pub const ACTION_POSFS_CHECK = action(9);

/// Info.settings and Settings.settings: the switches.
pub const SET_RECYCLED: u32 = 1 << 0;
pub const SET_CHECKSUMS: u32 = 1 << 1;
pub const SET_COMPRESS: u32 = 1 << 2;

pub const Info = extern struct {
    size: u32 = @sizeOf(Info),
    /// The format's version and the volume's block size and write unit.
    version: u32 = 0,
    block_size: u32 = 0,
    write_unit: u32 = 0,
    blocks: u64 align(4) = 0,
    free: u64 align(4) = 0,
    /// What the blocks in use hold: the live files and directories and
    /// their trees, what only snapshots still hold, Recycled's, what is
    /// waiting to be given back, and the reserve kept for deletes.
    live: u64 align(4) = 0,
    snapshots: u64 align(4) = 0,
    recycled: u64 align(4) = 0,
    pending: u64 align(4) = 0,
    reserve: u64 align(4) = 0,
    /// The newest checkpoint's generation.
    gen: u64 align(4) = 0,
    /// The journal's blocks in use, and how many there may be before a
    /// checkpoint is written.
    journal_used: u32 = 0,
    journal_limit: u32 = 0,
    /// Blocks erased ahead of use (flash only).
    erased: u32 = 0,
    settings: u32 = 0,
    recycled_count: u64 align(4) = 0,
    recycled_max_count: u32 = 0,
    snapshot_count: u32 = 0,
    recycled_max_bytes: u64 align(4) = 0,
    /// When the last check ended without finding anything, in
    /// microseconds since 1 Jan 1978; 0 for never.
    last_check: u64 align(4) = 0,
    /// The feature masks the volume uses: its label's and its volume
    /// table's.
    incompat: u32 = 0,
    ro_compat: u32 = 0,
};

pub const Settings = extern struct {
    size: u32 = @sizeOf(Settings),
    /// Which switches to set (SET_*): those not named stay as they are.
    mask: u32 = 0,
    /// Their new state.
    settings: u32 = 0,
    /// Recycled's limits, set when SET_RECYCLED is in `mask`: 0 for none.
    recycled_max_count: u32 = 0,
    recycled_max_bytes: u64 align(4) = 0,
};

pub const SnapshotArgs = extern struct {
    size: u32 = @sizeOf(SnapshotArgs),
    reserved: u32 = 0,
    /// The snapshot's name, UTF-8 or Latin-1 as every name.
    name: ?[*:0]const u8 = null,
};

pub const UndeleteArgs = extern struct {
    size: u32 = @sizeOf(UndeleteArgs),
    reserved: u32 = 0,
    /// The name in Recycled.
    name: ?[*:0]const u8 = null,
    /// Where it goes: a path on the volume - a directory, which it goes
    /// into under its old name, or the name it takes - or null for where it
    /// came from.
    to: ?[*:0]const u8 = null,
};

pub const OriginArgs = extern struct {
    size: u32 = @sizeOf(OriginArgs),
    /// The bytes `path` holds.
    path_size: u32 = 0,
    /// The name in Recycled.
    name: ?[*:0]const u8 = null,
    /// Filled in: the path it was deleted from, from the volume's root,
    /// NUL-terminated (ERROR_BUFFER_OVERFLOW when it does not fit).
    path: ?[*]u8 = null,
    /// When it was deleted, in microseconds since 1 Jan 1978: filled in
    /// too when the directory it was in has gone (ERROR_DIR_NOT_FOUND).
    deleted: u64 align(4) = 0,
};

/// CheckArgs.flags: read every file's data and check it against its
/// checksums too.
pub const CHECK_DATA: u32 = 1 << 0;
/// CheckArgs.flags: the check of this cursor ended where it is.
pub const CHECK_STOP: u32 = 1 << 1;

pub const CheckArgs = extern struct {
    size: u32 = @sizeOf(CheckArgs),
    flags: u32 = 0,
    /// 0 to start; the answer's, to go on. 0 in the answer: done.
    cursor: u64 align(4) = 0,
    /// What the slices so far found wrong, and what they looked at.
    errors: u32 = 0,
    reserved: u32 = 0,
    nodes: u64 align(4) = 0,
    objects: u64 align(4) = 0,
    data_blocks: u64 align(4) = 0,
    /// The first thing found wrong, as text, NUL-terminated.
    message: [80]u8 = @splat(0),
};
