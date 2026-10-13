// SPDX-License-Identifier: MIT
//! GetAudioStreamAttrs: what a stream's tags say, in full.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const utility = sdk.utility;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");

/// Says what a stream's tags say, each answer where its tag points.
///
/// SYNOPSIS:
/// ```zig
/// fn GetAudioStreamAttrs(base: *AudioCodecBase, stream: *ac.AudioStream, tags: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.1. LVO -48.
///
/// INPUTS:
/// - `stream`: an open stream.
/// - `tags`: what is asked, each tag's data the address its answer goes
///   to: `ACA_Title`, `ACA_Artist`, `ACA_Album`, `ACA_AlbumArtist`,
///   `ACA_Composer`, `ACA_Genre` and `ACA_Comment` a `*[*:0]const u8`;
///   `ACA_Year`, `ACA_Track`, `ACA_Tracks` and `ACA_Chapters` a `*u32`;
///   `ACA_Picture` a `*?*const ac.AudioPicture`; `ACA_ChapterList` a
///   `*?[*]const ac.AudioChapter`.
///
/// RESULT:
/// How many of the tags it answered; one it does not know is left as it
/// is and not counted.
///
/// BEHAVIOR:
/// The answers are what the stream's tags said when it was opened: an
/// MP3's ID3v2 tag, over an ID3v1 tag at its end, or a WAV's INFO list.
/// A text the tags do not hold is empty, a number 0. The names are whole,
/// up to 127 characters - the info's are cut at 63 - and a comment up to
/// 255. A genre an MP3 gives by ID3v1's number is named. `ACA_Picture` is
/// null unless the stream was opened with `ACA_KeepPicture` and its tags
/// hold a picture: then it is that picture, the front cover where there
/// are several. The chapters are an ID3v2 tag's CHAP frames, each with
/// the title of its own TIT2 - up to 256 of them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Every text, the picture and the chapters are the stream's: read them,
/// and keep a copy of what is needed after `CloseAudioStream`.
///
/// NOTES:
/// Texts are Latin-1; a character past it is a `?`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenAudioStream`, `GetAudioStreamInfo`
///
/// EXAMPLES:
/// ```zig
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
pub fn GetAudioStreamAttrs(base: *AudioCodecBase, stream: *ac.AudioStream, tags: ?[*]const utility.TagItem) u32 {
    const kept = &_stream.streamOf(stream).tags;
    var list = tags;
    var answered: u32 = 0;
    while (base.utility_base.NextTagItem(&list)) |item| {
        const storage = item.data;
        if (storage == 0) continue;
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

fn textInto(storage: usize, text: []const u8) void {
    const answer: *[*:0]const u8 = @ptrFromInt(storage);
    answer.* = @ptrCast(text.ptr);
}

fn numberInto(storage: usize, value: u32) void {
    const answer: *u32 = @ptrFromInt(storage);
    answer.* = value;
}
