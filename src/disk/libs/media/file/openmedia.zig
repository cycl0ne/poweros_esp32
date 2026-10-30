// SPDX-License-Identifier: MIT
//! OpenMedia: a container file opened, its index read.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const utility = sdk.utility;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");
const File = _file.File;
const mp4 = @import("../mp4/_mp4.zig");
const mkv = @import("../mkv/_mkv.zig");
const ebml = @import("../mkv/ebml.zig");

/// Opens a container file - MP4, Matroska - and reads its index.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenMedia(base: *MediaBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*media.MediaFile
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags`: where the bytes come from - one of `MDA_Name` (a file to
///   open), `MDA_FileHandle` (a file the program has open, the container
///   beginning where it is) or `MDA_ReadFunc` with `MDA_ReadData` (a
///   function of the program's) - and `MDA_Kind` to say what it is rather
///   than have it found out, `MDA_KeepPicture` to have the cover kept.
/// - `err`: where why it failed goes (MERR_*), or null.
///
/// RESULT:
/// The file, or null - and `err` says why: MERR_OPEN without a source or
/// when the file would not open, MERR_UNKNOWN for bytes that are not a
/// container the library knows, MERR_UNSUPPORTED for an MP4 in fragments
/// or one whose index lies behind its packets read through a function,
/// MERR_READ, MERR_CORRUPT, MERR_NOMEMORY.
///
/// BEHAVIOR:
/// The kind is found by the first bytes: a Matroska file begins with
/// EBML's header, an MP4 with a box of the kinds one begins with -
/// `ftyp`, or QuickTime's `moov`, `mdat`, `wide`, `free`.
///
/// An MP4's index, the `moov` box, is read whole into memory, wherever it
/// lies in a file; through a read function the boxes before it are
/// passed, and the packets must come after it. Each track is made out of
/// it - its kind, its codec and the codec's setup, its sample tables, its
/// edits - and every track's cursor is at its first packet. The tags, the
/// chapters - Nero's list, or the text track a track names for them,
/// read from a file - and iTunes's note of the priming are read with it.
///
/// A Matroska file's segment is read up to its first cluster, and what
/// its seek heads say lies behind the clusters is read from there: its
/// info, its tracks - whole, into memory - its cues, its tags and its
/// chapters (SINCE 1.2). Through a read function only what comes before
/// the clusters is read. Each track walks the clusters from the first.
///
/// Up to 16 tracks are read; past them, tracks are passed over.
///
/// CONTEXT:
/// - Waits: yes, on the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process for a file (MDA_Name, MDA_FileHandle); a task will
///   do with MDA_ReadFunc.
///
/// OWNERSHIP:
/// The file is the caller's, given back with `CloseMedia`. A file opened
/// with MDA_Name is closed with it; a handle given with MDA_FileHandle
/// stays the program's, and must stay open until then.
///
/// NOTES:
/// It takes the index's size in memory - a few megabytes for a film of
/// hours - and 64 KiB or its largest packet for each track read; a
/// Matroska file its tracks and its cues, and 256 KiB or its largest
/// block for each track read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseMedia`, `GetMediaInfo`, `GetMediaTrack`, `ReadMediaPacket`,
/// `IdentifyMedia`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const film = mb.OpenMedia(&[_]utility.TagItem{
///     .{ .tag = media.MDA_Name, .data = @intFromPtr("SD0:Films/trip.mp4") },
///     .{},
/// }, &err) orelse return;
/// defer mb.CloseMedia(film);
/// ```
pub fn OpenMedia(base: *MediaBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*media.MediaFile {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const dl = base.dos_base;
    const name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(media.MDA_Name, 0, tags));
    const handle: ?*dos.FileHandle = @ptrFromInt(ub.GetTagData(media.MDA_FileHandle, 0, tags));
    const read_fn: ?media.ReadFn = @ptrFromInt(ub.GetTagData(media.MDA_ReadFunc, 0, tags));
    const read_data: ?*anyopaque = @ptrFromInt(ub.GetTagData(media.MDA_ReadData, 0, tags));
    const hint: u32 = @truncate(ub.GetTagData(media.MDA_Kind, media.MEDIA_UNKNOWN, tags));

    // Cleared: every field of a file starts at zero.
    const memory = sys.AllocVec(@sizeOf(File), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(err, media.MERR_NOMEMORY);
    const file: *File = @ptrCast(@alignCast(memory));
    file.base = base;
    file.info = .{};
    file.tags.keep_picture = ub.GetTagData(media.MDA_KeepPicture, 0, tags) != 0;
    sys.InitSemaphore(&file.lock);

    if (name) |path| {
        file.file = dl.Open(path, dos.MODE_OLDFILE) orelse {
            sys.FreeVec(memory);
            return failed(err, media.MERR_OPEN);
        };
        file.owns_file = true;
    } else if (handle) |given| {
        file.file = given;
        const here = dl.Seek(given, 0, dos.OFFSET_CURRENT);
        if (here > 0) file.origin = @intCast(here);
    } else if (read_fn) |read| {
        file.read_fn = read;
        file.read_data = read_data;
    } else {
        sys.FreeVec(memory);
        return failed(err, media.MERR_OPEN);
    }
    if (file.file) |opened| {
        var fib: dos.FileInfoBlock = .{};
        if (dl.ExamineFH(opened, &fib) and fib.size > file.origin) file.size = fib.size - file.origin;
    }

    const kind = if (hint != media.MEDIA_UNKNOWN) hint else kindOf(file);
    const result = switch (kind) {
        media.MEDIA_MP4 => mp4.open(file, hint == media.MEDIA_UNKNOWN),
        media.MEDIA_MKV => mkv.open(file),
        else => media.MERR_UNKNOWN,
    };
    if (result != media.MERR_OK) {
        _file.destroy(file);
        return failed(err, result);
    }
    if (err) |out| out.* = media.MERR_OK;
    return _file.publicOf(file);
}

/// The kind by the first four bytes - EBML's header, else an MP4's to be
/// looked at - kept for a read function, which cannot give them again.
fn kindOf(file: *File) u32 {
    var first: [4]u8 = undefined;
    const got = _file.readSome(file, 0, &first);
    _file.keep(file, 0, first[0..got]);
    if (got == first.len and _file.be32(&first) == ebml.EBML) return media.MEDIA_MKV;
    return media.MEDIA_MP4;
}

fn failed(err: ?*i32, code: i32) ?*media.MediaFile {
    if (err) |out| out.* = code;
    return null;
}
