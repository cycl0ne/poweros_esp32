// SPDX-License-Identifier: MIT
//! GetAudioStreamAttrs: what a stream's tags say, in full.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const utility = sdk.utility;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");
const _modules = @import("../modules/_modules.zig");

/// Says what a stream's tags say, each answer where its tag points.
///
/// SYNOPSIS:
/// ```zig
/// fn GetAudioStreamAttrs(base: *AudioCodecBase, stream: ?*ac.AudioStream, tags: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.1. LVO -48.
///
/// INPUTS:
/// - `stream`: an open stream, or null to ask only what is the library's
///   own (`ACA_Codecs`; SINCE 1.12).
/// - `tags`: what is asked, each tag's data the address its answer goes
///   to: `ACA_Title`, `ACA_Artist`, `ACA_Album`, `ACA_AlbumArtist`,
///   `ACA_Composer`, `ACA_Genre` and `ACA_Comment` a `*[*:0]const u8`;
///   `ACA_Year`, `ACA_Track`, `ACA_Tracks`, `ACA_Chapters`, `ACA_Link`
///   and `ACA_Codecs` a `*u32`; `ACA_Picture` a
///   `*?*const ac.AudioPicture`; `ACA_ChapterList` a
///   `*?[*]const ac.AudioChapter`.
///
/// RESULT:
/// How many of the tags it answered; one it does not know is left as it
/// is and not counted, and so is a stream's tag asked with no stream.
///
/// BEHAVIOR:
/// The answers are what the stream's tags said when it was opened: an
/// MP3's ID3v2 tag, over an ID3v1 tag at its end, a WAV's INFO list, or
/// the Vorbis comments of a FLAC or an Ogg Vorbis stream (SINCE 1.2).
/// A text the tags do not hold is empty, a number 0. The names are whole,
/// up to 127 characters - the info's are cut at 63 - and a comment up to
/// 255. A genre an MP3 gives by ID3v1's number is named. `ACA_Picture` is
/// null unless the stream was opened with `ACA_KeepPicture` and its tags
/// hold a picture: then it is that picture, the front cover where there
/// are several - an ID3v2 tag's, a FLAC's PICTURE block, an Ogg stream's
/// METADATA_BLOCK_PICTURE comment. The chapters are an ID3v2 tag's CHAP
/// frames, each with the title of its own TIT2, or the CHAPTERnnn and
/// CHAPTERnnnNAME comments, each ending where the next begins - up to 256
/// of them. In a chained Ogg stream (SINCE 1.5) they are the link's being
/// decoded - its own comments, nothing of the link before - and
/// `ACA_Link` is which link that is, 0 for the first: a program that asks
/// for it after each `DecodeAudio` call knows when they changed.
///
/// `ACA_Codecs` is not a stream's: it says which kinds of sound this
/// machine decodes, a bit per `ACODEC_*`. A kind is in it when a module
/// on this disk says it decodes it, which is not the same question as the
/// library's version - the large decoders are on the 64-bit disks alone,
/// so audiocodec.library 1.12 on an ESP32-P4 answers without
/// `ACODEC_DTS` although the library knows DTS. It is what a program
/// asks before it offers a track to be picked. It is answered from the
/// modules' own tags, read out of their files with nothing loaded, so it
/// costs the directory being looked through and, for a module whose file
/// changed, its tag read again. A kind two modules decode is in it once;
/// AC-3 and E-AC-3 are one module and come together because that
/// module's tag names both.
///
/// CONTEXT:
/// - Waits: with `ACA_Codecs`, while `LIBS:codecs/` is looked through;
///   otherwise no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Every text, the picture and the chapters are the stream's: read them,
/// and keep a copy of what is needed after `CloseAudioStream`. In a chain
/// the texts and the chapters are written again where they are as a link
/// begins, and a link's picture stays until the link after next begins:
/// read them again when `ACA_Link` rises.
///
/// NOTES:
/// Texts are UTF-8, as the tags have them whatever they are written in;
/// one too long is cut where a character starts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenAudioStream`, `GetAudioStreamInfo`
///
/// EXAMPLES:
/// ```zig
/// var kinds: u32 = 0;
/// _ = acb.GetAudioStreamAttrs(null, &[_]utility.TagItem{
///     .{ .tag = ac.ACA_Codecs, .data = @intFromPtr(&kinds) },
///     .{},
/// });
/// const dts_here = kinds & (@as(u32, 1) << @intCast(ac.ACODEC_DTS)) != 0;
///
/// var genre: [*:0]const u8 = "";
/// var year: u32 = 0;
/// var cover: ?*const ac.AudioPicture = null;
/// _ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
///     .{ .tag = ac.ACA_Genre, .data = @intFromPtr(&genre) },
///     .{ .tag = ac.ACA_Year, .data = @intFromPtr(&year) },
///     .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&cover) },
///     .{},
/// });
/// ```
pub fn GetAudioStreamAttrs(base: *AudioCodecBase, stream: ?*ac.AudioStream, tags: ?[*]const utility.TagItem) u32 {
    const own = if (stream) |open| _stream.streamOf(open) else null;
    var list = tags;
    var answered: u32 = 0;
    while (base.utility_base.NextTagItem(&list)) |item| {
        const storage = item.data;
        if (storage == 0) continue;
        // The library's own: asked of the disk, not of a stream, so it is
        // answered whether there is one or not.
        if (item.tag == ac.ACA_Codecs) {
            const answer: *u32 = @ptrFromInt(storage);
            answer.* = codecsHere(base);
            answered += 1;
            continue;
        }
        // Everything else is a stream's, and without one is left as it is.
        const open = own orelse continue;
        const kept = &open.tags;
        switch (item.tag) {
            ac.ACA_Title => textInto(storage, &kept.title),
            ac.ACA_Artist => textInto(storage, &kept.artist),
            ac.ACA_Album => textInto(storage, &kept.album),
            ac.ACA_AlbumArtist => textInto(storage, &kept.album_artist),
            ac.ACA_Composer => textInto(storage, &kept.composer),
            ac.ACA_Genre => textInto(storage, &kept.genre),
            ac.ACA_Comment => textInto(storage, &kept.comment),
            ac.ACA_Year => numberInto(storage, kept.year),
            ac.ACA_Track => numberInto(storage, kept.track),
            ac.ACA_Tracks => numberInto(storage, kept.tracks),
            ac.ACA_Chapters => numberInto(storage, kept.chapter_count),
            ac.ACA_Link => numberInto(storage, open.links),
            ac.ACA_ChapterList => {
                const answer: *?[*]const ac.AudioChapter = @ptrFromInt(storage);
                answer.* = if (kept.chapter_count != 0) kept.chapters else null;
            },
            ac.ACA_Picture => {
                const answer: *?*const ac.AudioPicture = @ptrFromInt(storage);
                answer.* = if (kept.picture_block != null) &kept.picture else null;
            },
            else => continue,
        }
        answered += 1;
    }
    return answered;
}

/// Which kinds this machine decodes: a bit per ACODEC_*, set when a
/// module on the disk says it decodes that kind. The modules are the
/// table's (`modules/_modules.zig`), which is read from their tags and
/// loads nothing; a kind two modules decode is in it once.
///
/// ACODEC_UNKNOWN's bit is cleared whatever a tag says: nothing decodes
/// "not known what it is".
fn codecsHere(base: *AudioCodecBase) u32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.modules_lock);
    defer sys.ReleaseSemaphore(&base.modules_lock);
    const table = _modules.refresh(base) orelse return 0;
    var mask: u32 = 0;
    for (table.rows()) |*found| mask |= _modules.codecsOf(found);
    return mask & ~@as(u32, 1);
}
fn textInto(storage: usize, text: []const u8) void {
    const answer: *[*:0]const u8 = @ptrFromInt(storage);
    answer.* = @ptrCast(text.ptr);
}

fn numberInto(storage: usize, value: u32) void {
    const answer: *u32 = @ptrFromInt(storage);
    answer.* = value;
}
