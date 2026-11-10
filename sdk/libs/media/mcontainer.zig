// SPDX-License-Identifier: MIT
//! A container module's structures (SINCE media 1.5): what one kind of
//! container is read by, as a library of its own in `LIBS:codecs/`, which
//! media.library opens for a file. The calls every module has are in
//! `sdk.interface.mcontainer` (sdk/fd/mcontainer_lib.fd).
//!
//! **Finding one.** Each module says in its own ROM tag which kinds of
//! container it reads (`ResidentMContainer`), and the library reads those
//! tags out of the files of `MCONTAINER_DIR` without loading anything:
//! there is no list in the library of the kinds there are, so a module
//! left off a board's disk is not there and one dropped in is found. What
//! a file is, is found out by the library from its first bytes
//! (IdentifyMedia), which loads nothing either. A file put in place of a
//! module is taken once the old one has gone from memory: at
//! `Avail FLUSH`, or when memory runs low.
//!
//! **What a module does** is all its kind's: reading its index, making its
//! tracks and tags, and finding each track's packets. The library keeps
//! the source, the tags and the tracks as programs see them, each with a
//! buffer of the file's bytes - all in the `MediaContainerFile`, which both
//! sides read and write, so its layout is theirs together: a module
//! answers MERR_UNSUPPORTED to a file whose `layout` is not its
//! `MCONTAINER_LAYOUT`.
//!
//! **A file's state**: `state`, and each track's `own`, are the module's,
//! given back at CloseContainer with what they hold. The file is one
//! allocation, cleared.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const media = @import("media.zig");
const interface_exec = @import("../../interface/exec.zig");
const interface_dos = @import("../../interface/dos.zig");
const interface_utility = @import("../../interface/utility.zig");

/// Where the modules are, as OpenLibrary is given it.
pub const MCONTAINER_PREFIX = "codecs/";

/// Where the container modules are, as dos is given it; the prefix above
/// is the same place as OpenLibrary is given it.
pub const MCONTAINER_DIR = "LIBS:codecs";

/// `ResidentMContainer.magic`, after a module's library tag: "MCON".
pub const MCONTAINER_MAGIC: u32 = 0x4D43_4F4E;

/// A container module's ROM tag: a library's, with what it reads after
/// it, as a sound module's is (`acodec.ResidentACodec`). media.library
/// reads it out of the module's file without loading it.
///
/// There is no chip kind here as sound and pictures have: a container is
/// read, never decoded, and no part does that in hardware. `priority`
/// orders two modules that read the same kind.
pub const ResidentMContainer = extern struct {
    resident: exec.Resident,
    magic: u32 = MCONTAINER_MAGIC,
    /// The kinds it reads, a bit each: `kindBit(MEDIA_MP4)`.
    kinds: u32,
    /// Among the modules for one kind, the higher is tried first.
    priority: i32 = 0,
};

/// A kind's bit in `ResidentMContainer.kinds`.
pub fn kindBit(kind: u32) u32 {
    return if (kind < 32) @as(u32, 1) << @intCast(kind) else 0;
}

/// `MediaContainerFile.layout`: which layout the file has. Raised whenever
/// the structures here change.
pub const MCONTAINER_LAYOUT: u32 = 2;

/// The most tracks a file's are read of; past them, tracks are passed
/// over.
pub const MCONTAINER_MOST_TRACKS = 16;

/// The longest a name is kept, and a comment.
pub const MCONTAINER_NAME_BYTES = 128;
pub const MCONTAINER_COMMENT_BYTES = 256;

/// The libraries a file is read through.
pub const MContainerLibs = extern struct {
    sys_base: *interface_exec.ExecBase,
    dos_base: *interface_dos.DosBase,
    utility_base: *interface_utility.UtilityBase,
};

/// What the tags say, at full length, NUL-terminated, UTF-8.
pub const MContainerTags = extern struct {
    title: [MCONTAINER_NAME_BYTES]u8,
    artist: [MCONTAINER_NAME_BYTES]u8,
    album: [MCONTAINER_NAME_BYTES]u8,
    album_artist: [MCONTAINER_NAME_BYTES]u8,
    composer: [MCONTAINER_NAME_BYTES]u8,
    genre: [64]u8,
    comment: [MCONTAINER_COMMENT_BYTES]u8,
    year: u32,
    track: u32,
    tracks: u32,
    keep_picture: bool,
    has_picture: bool,
    picture: media.MediaPicture,
    /// The chapters, in a block of their own, and how many.
    chapters: ?[*]media.MediaChapter,
    chapter_count: u32,
};

/// A track, as the library and its module share it.
pub const MContainerTrack = extern struct {
    /// What GetMediaTrack hands out.
    info: media.MediaTrack,
    /// What the module keeps of the track.
    own: ?*anyopaque,
    /// Bytes of the file from `cached_at` on, `cached` of them, in a
    /// buffer `buffer_size` large.
    buffer: ?[*]u8,
    buffer_size: u32,
    cached_at: u64 align(4),
    cached: u32,
};

/// A file, as the library and its module share it.
pub const MediaContainerFile = extern struct {
    /// MCONTAINER_LAYOUT.
    layout: u32,
    base: MContainerLibs,
    file: ?*dos.FileHandle,
    owns_file: bool,
    read_fn: ?media.ReadFn,
    read_data: ?*anyopaque,
    /// How far a read function has read; the size of a file, 0 when not
    /// known; where in the file the container begins - where a handle
    /// the program gave was.
    position: u64 align(4),
    size: u64 align(4),
    origin: u64 align(4),
    /// A read function's bytes kept to be read again, as they lie from
    /// `kept_at`.
    kept: [16]u8,
    kept_at: u64 align(4),
    kept_length: u32,
    /// Lets one task at a time at the source.
    lock: exec.SignalSemaphore,
    info: media.MediaInfo,
    /// The index, read whole.
    index: ?[*]u8,
    index_size: usize,
    tracks: [MCONTAINER_MOST_TRACKS]MContainerTrack,
    track_count: u32,
    /// The text track the file marks to be shown, ~0 for none.
    subtitles: u32,
    tags: MContainerTags,
    /// The module that reads it, the library's to open and close; and
    /// what the module made of the file.
    module: ?*exec.Library,
    state: ?*anyopaque,
};
