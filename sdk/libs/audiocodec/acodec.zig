// SPDX-License-Identifier: MIT
//! A sound module's structures (SINCE audiocodec 1.10): what one kind of
//! sound is decoded by, as a library of its own in `LIBS:codecs/`, which
//! audiocodec.library opens for a stream. The calls every module has are
//! in `sdk.interface.acodec` (sdk/fd/acodec_lib.fd).
//!
//! **Finding one.** The codec names the file: `ACODEC_MP3` is
//! "codecs/mp3.acodec" (`moduleName`). What some sound is, is found out by
//! the library from its first bytes (IdentifyAudio), which loads nothing.
//! A file put in place of a module is taken once the old one has gone from
//! memory: at `Avail FLUSH`, or when memory runs low.
//!
//! **What a module does** is all its kind's: finding the frames in a file,
//! its tags, its seek, and the decoding. The library keeps the source and
//! the bytes read ahead, the tags and the info, and for a container its
//! file and track - all in the `ACodecStream`, which both sides read and
//! write, so its layout is theirs together: a module answers
//! ACERR_UNSUPPORTED to a stream whose `layout` is not its
//! `ACODEC_LAYOUT`.
//!
//! **A stream's state**: `state` is the module's, null until it makes it,
//! given back at CloseACodec with what it holds. The stream is one
//! allocation, cleared; so is what a module makes of its state.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const ac = @import("audiocodec.zig");
const media = @import("../media/media.zig");
const interface_exec = @import("../../interface/exec.zig");
const interface_dos = @import("../../interface/dos.zig");
const interface_utility = @import("../../interface/utility.zig");
const interface_media = @import("../../interface/media.zig");

/// Where the modules are, as OpenLibrary is given it.
pub const ACODEC_PREFIX = "codecs/";

/// `ACodecStream.layout`: which layout the stream has. Raised whenever
/// the structures here change.
pub const ACODEC_LAYOUT: u32 = 1;

/// The longest a name is kept, and a comment; a frame's text read whole,
/// at most.
pub const ACODEC_NAME_BYTES = 128;
pub const ACODEC_COMMENT_BYTES = 256;
pub const ACODEC_FRAME_TEXT_BYTES = 1024;

/// Samples a stream holds decoded, the channels interleaved: an MP3
/// frame's in stereo.
pub const ACODEC_MOST_SAMPLES = 1152 * 2;

/// The module's name for a codec, null for one that has none. AC-3 and
/// E-AC-3 are one module's.
pub fn moduleName(codec: u32) ?[*:0]const u8 {
    return switch (codec) {
        ac.ACODEC_WAV => ACODEC_PREFIX ++ "wav.acodec",
        ac.ACODEC_MP3 => ACODEC_PREFIX ++ "mp3.acodec",
        ac.ACODEC_FLAC => ACODEC_PREFIX ++ "flac.acodec",
        ac.ACODEC_VORBIS => ACODEC_PREFIX ++ "vorbis.acodec",
        ac.ACODEC_AAC => ACODEC_PREFIX ++ "aac.acodec",
        ac.ACODEC_AC3, ac.ACODEC_EAC3 => ACODEC_PREFIX ++ "ac3.acodec",
        ac.ACODEC_OPUS => ACODEC_PREFIX ++ "opus.acodec",
        ac.ACODEC_DTS => ACODEC_PREFIX ++ "dts.acodec",
        else => null,
    };
}

/// The libraries a stream is read and decoded through.
pub const ACodecLibs = extern struct {
    sys_base: *interface_exec.ExecBase,
    dos_base: *interface_dos.DosBase,
    utility_base: *interface_utility.UtilityBase,
};

/// What the tags say, at full length, NUL-terminated.
pub const ACodecTags = extern struct {
    title: [ACODEC_NAME_BYTES]u8,
    artist: [ACODEC_NAME_BYTES]u8,
    album: [ACODEC_NAME_BYTES]u8,
    album_artist: [ACODEC_NAME_BYTES]u8,
    composer: [ACODEC_NAME_BYTES]u8,
    genre: [64]u8,
    comment: [ACODEC_COMMENT_BYTES]u8,
    /// The comment kept has no description of its own - the one a person
    /// wrote, not one a program keeps for itself.
    plain_comment: bool,
    year: u32,
    track: u32,
    tracks: u32,
    /// Whether the program wants the picture; the block the kept one is
    /// in, null when none is; and what it is.
    keep_picture: bool,
    picture_block: ?[*]u8,
    picture: ac.AudioPicture,
    /// The block of the link before's picture, given back at the next
    /// link or with the stream.
    spent_picture: ?[*]u8,
    /// The chapters the tags mark, in a block of their own made at the
    /// first, and how many.
    chapters: ?[*]ac.AudioChapter,
    chapter_count: u32,
    /// A text frame's body, read whole to be looked at.
    frame_text: [ACODEC_FRAME_TEXT_BYTES]u8,
};

/// A container's track the stream decodes (audiocodec's stream/_media.zig
/// says how its times are kept).
pub const ACodecSource = extern struct {
    /// media.library and the file - the stream's own to close, or the
    /// program's - while the stream reads a container; null otherwise.
    base: ?*interface_media.MediaBase,
    file: ?*media.MediaFile,
    owns: bool,
    track: u32,
    /// The track's ticks a second, and the sound's frames a second.
    timescale: u32,
    rate: u32,
    /// The frames of priming before the sound.
    delay: i64 align(4),
    /// The frames the sound has, when the length is `exact`; and whether
    /// a packet past them has come.
    exact: bool,
    total: i64 align(4),
    done: bool,
    /// After a seek, the frames before this one are passed over.
    skip_until: i64 align(4),
    /// Where the next packet's sound begins, in frames from the sound's
    /// first, once a packet has placed it.
    position: i64 align(4),
    placed: bool,
    /// Where the sound begins: 0, or later in a Matroska file - its
    /// priming before it. And the frames of silence to hand out before
    /// the next decoded ones, up to where it begins.
    start: i64 align(4),
    gap: i64 align(4),
    /// The packet read to see where the sound begins, or held back after
    /// a hole, handed out first.
    held: media.MediaPacket,
    holding: bool,
    /// A hole stopped the codec: its silence is handed out, then the
    /// codec goes on.
    paused: bool,
    /// The last packet's ticks: one at the same time is laced to it.
    last_ticks: u64 align(4),
};

/// A stream, as the library and its module share it.
pub const ACodecStream = extern struct {
    /// ACODEC_LAYOUT.
    layout: u32,
    base: ACodecLibs,
    /// The source: a file - the stream's own to close, or the program's -
    /// or the program's read function.
    file: ?*dos.FileHandle,
    owns_file: bool,
    read_fn: ?ac.ReadFn,
    read_data: ?*anyopaque,
    /// Where in a file the sound ends - its tags after it - and whether
    /// that is known.
    end: u64 align(4),
    has_end: bool,
    /// Where `in[0]` lies in the source.
    position: u64 align(4),
    in: [ac.AUDIO_READ_AHEAD]u8,
    start: usize,
    stop: usize,
    /// The source has no more; or it failed.
    eof: bool,
    failed: bool,
    info: ac.AudioStreamInfo,
    tags: ACodecTags,
    /// The links of a chain begun after the first (`ACA_Link`).
    links: u32,
    /// The track of a container to decode (`ACA_MediaTrack`), ~0 for the
    /// first sound track; the container while one is read.
    media_track: u32,
    media: ACodecSource,
    /// The module that decodes it, the library's to open and close; and
    /// what the module made of the stream.
    module: ?*exec.Library,
    state: ?*anyopaque,
    /// Samples decoded and not handed out yet, the channels interleaved,
    /// `pcm_start` to `pcm_stop`.
    pcm: [ACODEC_MOST_SAMPLES]i16,
    pcm_start: usize,
    pcm_stop: usize,
};
