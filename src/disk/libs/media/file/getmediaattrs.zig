// SPDX-License-Identifier: MIT
//! GetMediaAttrs: what a file's tags say, in full.

const sdk = @import("sdk");
const media = sdk.media;
const utility = sdk.utility;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");

/// Says what a container file's tags say, each answer where its tag
/// points.
///
/// SYNOPSIS:
/// ```zig
/// fn GetMediaAttrs(base: *MediaBase, file: *media.MediaFile, tags: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `file`: an open file.
/// - `tags`: what is asked, each tag's data the address its answer goes
///   to: `MDA_Title`, `MDA_Artist`, `MDA_Album`, `MDA_AlbumArtist`,
///   `MDA_Composer`, `MDA_Genre` and `MDA_Comment` a `*[*:0]const u8`;
///   `MDA_Year`, `MDA_Track`, `MDA_Tracks`, `MDA_Chapters` and
///   `MDA_Subtitles` (SINCE 1.3) a `*u32`;
///   `MDA_Picture` a `*?*const media.MediaPicture`; `MDA_ChapterList` a
///   `*?[*]const media.MediaChapter`.
///
/// RESULT:
/// How many of the tags it answered; one it does not know is left as it
/// is and not counted.
///
/// BEHAVIOR:
/// The answers are an MP4's iTunes items: `©nam`, `©ART`, `©alb`, `aART`,
/// `©wrt`, `©gen` - or `gnre`, ID3's number, named - `©cmt`, the year of
/// `©day`, `trkn`. A text the tags do not hold is empty, a number 0; the
/// names are whole up to 127 characters, a comment up to 255.
/// `MDA_Picture` is null unless the file was opened with
/// `MDA_KeepPicture` and holds a cover (`covr`): then it is the first,
/// a JPEG or a PNG. The chapters are Nero's list (`chpl`), else the text
/// track a track names for them - read from a file only - each ending
/// where the next begins, up to 1000. `MDA_Subtitles` is the text track,
/// as `GetMediaTrack` numbers them, a Matroska file marks to be shown:
/// the first marked forced and to be played (FlagForced, FlagDefault),
/// else the first marked to be played; ~0 when none is - always for an
/// MP4, which marks none.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Every text, the picture and the chapters are the file's, good until
/// `CloseMedia`.
///
/// NOTES:
/// Texts are Latin-1; a character past it is a `?`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenMedia`, `GetMediaInfo`
///
/// EXAMPLES:
/// ```zig
/// var year: u32 = 0;
/// var cover: ?*const media.MediaPicture = null;
/// _ = mb.GetMediaAttrs(song, &[_]utility.TagItem{
///     .{ .tag = media.MDA_Year, .data = @intFromPtr(&year) },
///     .{ .tag = media.MDA_Picture, .data = @intFromPtr(&cover) },
///     .{},
/// });
/// ```
pub fn GetMediaAttrs(base: *MediaBase, file: *media.MediaFile, tags: ?[*]const utility.TagItem) u32 {
    const own = _file.fileOf(file);
    const kept = &own.tags;
    var list = tags;
    var answered: u32 = 0;
    while (base.utility_base.NextTagItem(&list)) |item| {
        const storage = item.data;
        if (storage == 0) continue;
        switch (item.tag) {
            media.MDA_Title => textInto(storage, &kept.title),
            media.MDA_Artist => textInto(storage, &kept.artist),
            media.MDA_Album => textInto(storage, &kept.album),
            media.MDA_AlbumArtist => textInto(storage, &kept.album_artist),
            media.MDA_Composer => textInto(storage, &kept.composer),
            media.MDA_Genre => textInto(storage, &kept.genre),
            media.MDA_Comment => textInto(storage, &kept.comment),
            media.MDA_Year => numberInto(storage, kept.year),
            media.MDA_Track => numberInto(storage, kept.track),
            media.MDA_Tracks => numberInto(storage, kept.tracks),
            media.MDA_Chapters => numberInto(storage, kept.chapter_count),
            media.MDA_Subtitles => numberInto(storage, own.subtitles),
            media.MDA_ChapterList => {
                const answer: *?[*]const media.MediaChapter = @ptrFromInt(storage);
                answer.* = if (kept.chapter_count != 0) kept.chapters else null;
            },
            media.MDA_Picture => {
                const answer: *?*const media.MediaPicture = @ptrFromInt(storage);
                answer.* = if (kept.has_picture) &kept.picture else null;
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
